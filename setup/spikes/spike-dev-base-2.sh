#!/usr/bin/env bash
set -uo pipefail
IMG="registry.fedoraproject.org/fedora:44"
echo "=== SPIKE 2 ($(date -u +%FT%TZ)) ==="

echo "### [A] full cursor JSON (find rpm url field) ###"
curl -fsSL -A "Mozilla/5.0" "https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable" | tr ',' '\n' | grep -iE 'url'

echo "### [B] hermes installer: non-interactive + version-pin flags ###"
grep -nE '\-\-yes|noninteractive|non-interactive|assume|--version|VERSION=|--tag|--ref|GITHUB|releases/|prompt|read -r|stdin|tty' /tmp/hermes-install.sh 2>/dev/null | head -30

echo "### [C] container: opencode(no ignore-scripts) + bun+omp + claude --version + hermes ###"
podman run --rm --network=host "$IMG" bash -lc '
  set -x
  dnf install -y nodejs npm >/dev/null 2>&1
  echo "--- claude ---"; npm install -g --ignore-scripts @anthropic-ai/claude-code@2.1.191 >/dev/null 2>&1 && claude --version 2>&1 | head -1
  echo "--- opencode (WITH postinstall) ---"
  npm install -g opencode-ai@1.17.11 >/tmp/oc.log 2>&1 && echo OC_INSTALL_OK || { echo OC_INSTALL_FAIL; tail -8 /tmp/oc.log; }
  opencode --version 2>&1 | head -1
  echo "--- bun via npm + omp ---"
  npm install -g bun >/tmp/bun.log 2>&1 && echo BUN_OK || { echo BUN_FAIL; tail -8 /tmp/bun.log; }
  bun --version 2>&1 | head -1
  npm install -g @oh-my-pi/pi-coding-agent@16.1.18 >/dev/null 2>&1
  echo "omp version:"; omp --version 2>&1 | head -3
  echo "--- hermes installer as root (non-interactive) ---"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/h.sh 2>/dev/null
  HERMES_NONINTERACTIVE=1 CI=1 bash /tmp/h.sh --yes </dev/null >/tmp/hermes.log 2>&1; echo "installer exit=$?"
  tail -12 /tmp/hermes.log
  echo "hermes binary:"; ls -l /usr/local/bin/hermes 2>&1; command -v hermes 2>&1
  hermes --version 2>&1 | head -2
'
echo "=== SPIKE 2 DONE ($(date -u +%FT%TZ)) ==="
