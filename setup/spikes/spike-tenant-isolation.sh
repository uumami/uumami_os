#!/usr/bin/env bash
# spike-tenant-isolation.sh — adversarial proof of Tier-2a cross-UID isolation.
# Real Tier-2a tenants are distinct Linux UIDs with 0700 homes. This rootless sandbox
# reproduces exactly that (two users in a throwaway container) and proves the kernel wall:
# UID B genuinely CANNOT read UID A's 0700 credentials. No sudo, nothing touches the host.
set -uo pipefail
IMG="registry.fedoraproject.org/fedora:44"
echo "=== TENANT ISOLATION SPIKE ($(date -u +%FT%TZ)) ==="

podman run --rm "$IMG" bash -c '
  set -e
  dnf install -y -q util-linux shadow-utils >/dev/null 2>&1   # runuser + useradd
  useradd -u 1001 -m alice
  useradd -u 1002 -m bob
  # alice (tenant A) stores a credential, locks home + creds 0700 (what tenant-create does)
  install -d -m 700 -o alice -g alice /home/alice/.claude
  echo "ANTHROPIC_OAUTH_TOKEN=sk-ant-SECRET-A" > /home/alice/.claude/.credentials.json
  chown alice:alice /home/alice/.claude/.credentials.json
  chmod 700 /home/alice /home/alice/.claude /home/alice/.claude/.credentials.json
  echo "perms: home=$(stat -c "%a %U" /home/alice)  cred=$(stat -c "%a %U" /home/alice/.claude/.credentials.json)"

  echo "--- [adversarial] bob (uid 1002) reads alice cred — MUST be denied ---"
  if runuser -u bob -- cat /home/alice/.claude/.credentials.json 2>&1; then
    echo "RESULT: *** LEAK *** bob read alice secret"; exit 1
  else
    echo "RESULT: DENIED ✓ (Permission denied above is the kernel UID wall)"
  fi
  echo "--- [adversarial] bob lists alice .claude — MUST be denied ---"
  runuser -u bob -- ls /home/alice/.claude 2>&1 && { echo "*** LEAK ***"; exit 1; } || echo "RESULT: list DENIED ✓"

  echo "--- [control] alice (uid 1001) reads her OWN cred — MUST succeed ---"
  out="$(runuser -u alice -- cat /home/alice/.claude/.credentials.json)"
  [ "$out" = "ANTHROPIC_OAUTH_TOKEN=sk-ant-SECRET-A" ] && echo "RESULT: alice reads her own ✓ ($out)" || { echo "control FAILED"; exit 1; }
' 2>&1
echo "--- nested-rootless-podman prereq present (caps survive, storage configured) ---"
podman run --rm localhost/dev_base:latest bash -c 'getcap /usr/bin/newuidmap /usr/bin/newgidmap; grep mount_program /etc/containers/storage.conf' 2>&1
echo "=== SPIKE DONE ($(date -u +%FT%TZ)) ==="
