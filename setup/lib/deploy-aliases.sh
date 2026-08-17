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

# uu-askpass: lets a box raise a passphrase dialog on the host desktop (see the drop-in below).
# Deployed here rather than from deploy-ssh.sh because this is the script `uu repair` re-runs —
# a profile that lost its dialog must be repairable without going anywhere near its keys.
askpass="$ROOT/setup/templates/qol/uu-askpass"
if [ -f "$askpass" ]; then
  install -d -m 700 "$home/.local/bin"
  install -m 755 "$askpass" "$home/.local/bin/uu-askpass"
fi
cat > "$home/.bashrc.d/shared_aliases.sh" <<'EOF'
# uumami_os opt-in: source the deployed shared aliases (deploy-aliases.sh refreshes the copy).
[ -f "$HOME/.config/uumami/aliases.sh" ] && . "$HOME/.config/uumami/aliases.sh"

# A desktop session exports SSH_ASKPASS pointing at a HOST binary (KDE's ksshaskpass, GNOME's
# equivalent). distrobox passes the variable through, but that path does not exist inside a box
# and no askpass ships in dev_base — so with DISPLAY also inherited, ssh/ssh-add prefer askpass
# and die with
#   ssh_askpass: exec(/usr/bin/ksshaskpass): No such file or directory
# instead of asking. That breaks passphrase-protected keys specifically: the secure ones.
#
# Point it at uu-askpass, which forwards the prompt to the host's own dialog. Then ssh's normal
# rule gives the right behaviour in both directions with no configuration: with a tty it prompts
# in the terminal, without one (an agent running `git push`) a dialog pops up on the desktop.
# Deliberately do NOT set SSH_ASKPASS_REQUIRE here — that would override that rule.
if [ -n "${SSH_ASKPASS:-}" ] && [ ! -x "${SSH_ASKPASS}" ]; then
  if [ -x "$HOME/.local/bin/uu-askpass" ]; then
    export SSH_ASKPASS="$HOME/.local/bin/uu-askpass"
  else
    # No forwarder available: prompting in the terminal is worse UX than a dialog, but it is
    # correct — whereas leaving a broken binary in SSH_ASKPASS fails with no prompt at all.
    unset SSH_ASKPASS
    export SSH_ASKPASS_REQUIRE=never
  fi
fi
EOF
ensure_bashrc_d "$home"
echo "[deploy-aliases] installed into $home"
