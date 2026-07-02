#!/usr/bin/env bash
# deploy-tmux.sh <home> — install the tmux config + bare-entry auto-attach hook into one
# profile (SG11; SG8 interface, called by tenant-create per user). Idempotent, no sudo.
# Precedence contract (SG10.5): this hook owns BARE entry (-> 'main'); `work <session>`
# attaches its own named session first, so the hook no-ops inside it ($TMUX set).
# A user's customized .tmux.conf is respected: we only install if absent or still ours.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
home="${1:?usage: deploy-tmux.sh <profile-home>}"
conf_src="$ROOT/setup/templates/qol/tmux.conf"
hook_src="$ROOT/setup/templates/qol/tmux-autoattach.sh"
[ -f "$conf_src" ] && [ -f "$hook_src" ] || { echo "deploy-tmux: templates missing under $ROOT/setup/templates/qol" >&2; exit 1; }

install -d -m 700 "$home/.bashrc.d"
if [ ! -f "$home/.tmux.conf" ] || grep -q 'uumami_os minimal tmux config' "$home/.tmux.conf"; then
  install -m 644 "$conf_src" "$home/.tmux.conf"
else
  echo "[deploy-tmux] $home/.tmux.conf is user-customized — leaving it alone"
fi
install -m 644 "$hook_src" "$home/.bashrc.d/zz-tmux-autoattach.sh"   # zz- so aliases load first
echo "[deploy-tmux] installed into $home"
