#!/usr/bin/env bash
# deploy-aliases.sh <home>          install the FULL shared aliases (incl. agents) into one
#                                   box profile (SG11; SG8 interface, called by tenant-create).
# deploy-aliases.sh --host-safe [h] install the HOST-safe subset (no agent/box-only aliases)
#                                   into the host user's home (default $HOME). Run on the host.
# Idempotent, no sudo. Run as the target home's owner.
#
# Design: aliases are COPIED into the home (~/.config/uumami/aliases*.sh) rather than pointed
# at a cross-user path — a Tier-2a tenant cannot read another user's files (the wall), so a
# pointer would dangle. Propagating new aliases = re-run this script (tenant-create does).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ensure_bashrc_d <home> — make sure ~/.bashrc sources ~/.bashrc.d/* (Fedora skel does; a
# fresh profile may not). Idempotent.
ensure_bashrc_d() {
  local home="$1"
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
}

if [ "${1:-}" = --host-safe ]; then
  home="${2:-$HOME}"
  src="$ROOT/setup/templates/qol/aliases-host.sh"
  [ -f "$src" ] || { echo "deploy-aliases: host template missing at $src" >&2; exit 1; }
  install -d -m 700 "$home/.config/uumami" "$home/.bashrc.d"
  install -m 644 "$src" "$home/.config/uumami/aliases-host.sh"
  cat > "$home/.bashrc.d/uumami-host-aliases.sh" <<'EOF'
# uumami_os host-safe aliases (no agent/box-only aliases — those live inside distroboxes).
[ -f "$HOME/.config/uumami/aliases-host.sh" ] && . "$HOME/.config/uumami/aliases-host.sh"
EOF
  ensure_bashrc_d "$home"
  echo "[deploy-aliases] host-safe aliases installed into $home"
  exit 0
fi

home="${1:?usage: deploy-aliases.sh <profile-home> | --host-safe [home]}"
src="$ROOT/setup/templates/qol/aliases.sh"
[ -f "$src" ] || { echo "deploy-aliases: template missing at $src" >&2; exit 1; }

install -d -m 700 "$home/.config/uumami" "$home/.bashrc.d"
install -m 644 "$src" "$home/.config/uumami/aliases.sh"
cat > "$home/.bashrc.d/shared_aliases.sh" <<'EOF'
# uumami_os opt-in: source the deployed shared aliases (deploy-aliases.sh refreshes the copy).
[ -f "$HOME/.config/uumami/aliases.sh" ] && . "$HOME/.config/uumami/aliases.sh"
EOF
ensure_bashrc_d "$home"
echo "[deploy-aliases] installed into $home"
