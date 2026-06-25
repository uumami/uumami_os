#!/usr/bin/env bash
set -uo pipefail
IMG="registry.fedoraproject.org/fedora:44"
echo "=== SPIKE 3: claude(postinstall) + hermes(--non-interactive) ($(date -u +%FT%TZ)) ==="
podman run --rm --network=host "$IMG" bash -lc '
  set -x
  dnf install -y nodejs npm git >/dev/null 2>&1
  echo "--- claude WITHOUT --ignore-scripts (lets postinstall fetch native binary) ---"
  npm install -g @anthropic-ai/claude-code@2.1.191 >/tmp/cc.log 2>&1 && echo CC_INSTALL_OK || { echo CC_FAIL; tail -8 /tmp/cc.log; }
  claude --version 2>&1 | head -2
  echo "--- hermes --non-interactive as root ---"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/h.sh 2>/dev/null
  bash /tmp/h.sh --non-interactive </dev/null >/tmp/hermes.log 2>&1; echo "installer exit=$?"
  echo "...installer tail..."; tail -15 /tmp/hermes.log
  echo "hermes locations:"; ls -l /usr/local/bin/hermes 2>&1; ls -ld /usr/local/lib/hermes-agent 2>&1; command -v hermes 2>&1
  PATH="/usr/local/bin:$PATH" hermes --version 2>&1 | head -3
'
echo "=== SPIKE 3 DONE ($(date -u +%FT%TZ)) ==="
