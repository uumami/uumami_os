#!/usr/bin/env bash
# install-llm-service.sh — install + enable the llm_server systemd USER service (SG8/SG9).
# Runs ON THE HOST as your user. No sudo: it's a user unit under ~/.config/systemd/user.
# Idempotent: re-running re-links and re-enables without error. linger self-enables on this
# host so the server survives logout; if linger needs sudo elsewhere, that step is flagged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/os-module.sh"

unit_src="$ROOT/images/llm_server/llm_server.service"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
[ -f "$unit_src" ] || { echo "install-llm-service: $unit_src not found" >&2; exit 1; }

echo "[llm-service] linking unit -> $unit_dir/llm_server.service"
mkdir -p "$unit_dir"
ln -sf "$unit_src" "$unit_dir/llm_server.service"

echo "[llm-service] enabling linger (so the server survives logout)"
os_module_load "$ROOT/setup/facts.env" 2>/dev/null || true
if command -v os_enable_linger >/dev/null 2>&1; then
  os_enable_linger "$USER" || echo "[llm-service] (linger step is human-required on this host — see above)"
fi

echo "[llm-service] daemon-reload + enable --now"
systemctl --user daemon-reload
systemctl --user enable --now llm_server.service

echo "[llm-service] status:"
systemctl --user --no-pager is-active llm_server.service
echo "[llm-service] verify GPU (no silent CPU fallback):"
echo "    distrobox enter llm_server -- ollama ps    # PROCESSOR column must show GPU"
