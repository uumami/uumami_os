#!/usr/bin/env bash
# spike-dev-base.sh — evidence spike for SG5 dev_base. Rootless throwaway container.
# Validates: Fedora node version (vs Pi >=22.19), npm agent installs + --version,
# Cursor rpm endpoint, Hermes installer layout. Destroys the container after.
set -uo pipefail
FED="${1:-44}"
IMG="registry.fedoraproject.org/fedora:${FED}"
echo "=== SPIKE dev_base on $IMG  ($(date -u +%FT%TZ)) ==="

echo "### [0] cursor endpoint probe (from host, no container) ###"
for plat in linux-x64-rpm linux-x64; do
  echo "--- platform=$plat ---"
  curl -fsSL -A "Mozilla/5.0" -o /tmp/cursor-$plat.out -w 'http=%{http_code} final=%{url_effective}\n' \
    "https://www.cursor.com/api/download?platform=${plat}&releaseTrack=stable" 2>&1 | head -3
  echo "body head:"; head -c 400 /tmp/cursor-$plat.out 2>/dev/null; echo
done

echo "### [0b] hermes installer inspect (fetch, do not execute) ###"
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh 2>&1 | head -2
echo "installer size: $(wc -c </tmp/hermes-install.sh 2>/dev/null || echo FETCH_FAILED)"
grep -nE 'INSTALL_DIR|/usr/local|\.local/bin|HERMES|BINDIR|PREFIX|install -m|cp .* /|mv .* /|curl .*-o' /tmp/hermes-install.sh 2>/dev/null | head -25

echo "### [1] container: node + npm agents ###"
podman run --rm --network=host "$IMG" bash -lc '
  set -x
  dnf install -y nodejs npm >/dev/null 2>&1 || { echo "DNF_NODE_FAIL"; exit 1; }
  echo "NODE_VERSION=$(node --version)"
  echo "NPM_VERSION=$(npm --version)"
  for spec in \
    "@anthropic-ai/claude-code@2.1.191:claude" \
    "@openai/codex@0.142.2:codex" \
    "opencode-ai@1.17.11:opencode" \
    "@earendil-works/pi-coding-agent@0.80.2:pi" \
    "@oh-my-pi/pi-coding-agent@16.1.18:omp" ; do
    pkg="${spec%:*}"; bin="${spec##*:}"
    echo "--- installing $pkg ---"
    if npm install -g --ignore-scripts "$pkg" >/tmp/npm.log 2>&1; then
      echo "INSTALL_OK $pkg"
      ver="$("$bin" --version 2>&1 | head -1 || echo VERSION_FAIL)"
      echo "BIN_OK $bin -> $ver"
    else
      echo "INSTALL_FAIL $pkg"; tail -5 /tmp/npm.log
    fi
  done
'
echo "=== SPIKE DONE ($(date -u +%FT%TZ)) ==="
