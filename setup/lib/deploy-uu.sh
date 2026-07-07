#!/usr/bin/env bash
# deploy-uu.sh — install the uu CLI (+ the work launcher) into one profile (SG8 deploy
# interface, called by tenant-create per user) or onto the host. Idempotent, no sudo.
#   deploy-uu.sh <profile-home>   copy uu + work into <home>/.local/bin (copy-not-pointer:
#                                 tenants cannot and should not read the admin's repo)
#   deploy-uu.sh --host           symlink ~/.local/bin/uu -> repo (admin: fresh with git pull)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
src_uu="$ROOT/setup/bin/uu"; src_work="$ROOT/setup/lib/work.sh"
[ -f "$src_uu" ] && [ -f "$src_work" ] || { echo "deploy-uu: sources missing under $ROOT" >&2; exit 1; }

if [ "${1:-}" = --host ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$src_uu" "$HOME/.local/bin/uu"
  ln -sf "$src_work" "$HOME/.local/bin/work"
  echo "[deploy-uu] host: symlinked ~/.local/bin/{uu,work} -> repo"
  exit 0
fi
home="${1:?usage: deploy-uu.sh <profile-home> | --host}"
install -d -m 755 "$home/.local/bin"
install -m 755 "$src_uu"   "$home/.local/bin/uu"
install -m 755 "$src_work" "$home/.local/bin/work"
echo "[deploy-uu] installed uu + work into $home/.local/bin"
