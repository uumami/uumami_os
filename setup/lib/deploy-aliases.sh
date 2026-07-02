#!/usr/bin/env bash
# deploy-aliases.sh <home> — install the shared aliases into one profile (SG11; SG8 interface,
# called by tenant-create per user). Idempotent, no sudo. Run as the profile's owner.
#
# Design: the aliases are COPIED into the profile (~/.config/uumami/aliases.sh) rather than
# pointed at a cross-user host path — a Tier-2a tenant cannot read another user's files (that
# is the whole point of the wall), so a pointer would dangle. Propagating new aliases = re-run
# this script (tenant-create and rebuild flows do). The pointer file in ~/.bashrc.d stays
# one line, exactly like the canonical opt-in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
home="${1:?usage: deploy-aliases.sh <profile-home>}"
src="$ROOT/setup/templates/qol/aliases.sh"
[ -f "$src" ] || { echo "deploy-aliases: template missing at $src" >&2; exit 1; }

install -d -m 700 "$home/.config/uumami" "$home/.bashrc.d"
install -m 644 "$src" "$home/.config/uumami/aliases.sh"
cat > "$home/.bashrc.d/shared_aliases.sh" <<'EOF'
# uumami_os opt-in: source the deployed shared aliases (deploy-aliases.sh refreshes the copy).
[ -f "$HOME/.config/uumami/aliases.sh" ] && . "$HOME/.config/uumami/aliases.sh"
EOF

# Fedora's skel .bashrc sources ~/.bashrc.d/*; a fresh profile may not have one yet.
if [ ! -f "$home/.bashrc" ]; then
  cat > "$home/.bashrc" <<'EOF'
# Minimal .bashrc (created by deploy-aliases.sh) — sources drop-ins like Fedora's default.
if [ -d "$HOME/.bashrc.d" ]; then
  for rc in "$HOME/.bashrc.d"/*; do [ -f "$rc" ] && . "$rc"; done
  unset rc
fi
EOF
elif ! grep -q '\.bashrc\.d' "$home/.bashrc"; then
  printf '\n# uumami_os: source drop-ins\nfor rc in "$HOME/.bashrc.d"/*; do [ -f "$rc" ] && . "$rc"; done; unset rc\n' >> "$home/.bashrc"
fi
echo "[deploy-aliases] installed into $home"
