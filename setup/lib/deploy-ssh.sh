#!/usr/bin/env bash
# deploy-ssh.sh <home> — per-profile GitHub SSH scaffolding (SG11; SG8 interface, called by
# tenant-create per user). Idempotent, no sudo. Run as the profile's owner.
#
# Generates a per-profile ed25519 key (one identity per tenant — never share keys across
# profiles) and a ~/.ssh/config block for github.com.
#
# PASSPHRASE POLICY — a passphrase is the default, and the only way a key is created without
# one is if you say so explicitly. An unencrypted private key is a plaintext credential: any
# process in the box, any backup, any stray `cp -a` of the profile carries a working GitHub
# identity with it. The passphrase is typed once per login thanks to `AddKeysToAgent yes`.
#
# Because tenant-create runs unattended, this script will NOT quietly fall back to an
# unencrypted key when there is no terminal to type into: it skips key creation and tells the
# human to finish with `uu github setup`. Skipping is recoverable; a silent plaintext key is not.
#
# Usage:
#   deploy-ssh.sh <home>                   prompt for a passphrase (default; skips if no terminal)
#   deploy-ssh.sh --no-passphrase <home>   deliberately create an UNENCRYPTED key
#   deploy-ssh.sh --passphrase <home>      same as the default (kept for compatibility)
set -euo pipefail

home=""; NOPASS=0
for a in "$@"; do case "$a" in
  --no-passphrase) NOPASS=1 ;;
  --passphrase)    NOPASS=0 ;;
  -*) echo "deploy-ssh: unknown flag $a" >&2; exit 1 ;;
  *)  home="$a" ;;
esac; done
[ -n "$home" ] || { echo "usage: deploy-ssh.sh [--no-passphrase] <profile-home>" >&2; exit 1; }

key="$home/.ssh/id_ed25519_github"
install -d -m 700 "$home/.ssh"

# NOTE: the passphrase prompt itself (uu-askpass) is deployed by deploy-aliases.sh, because that
# is the script `uu repair` re-runs — a profile whose dialog is missing must be repairable
# without touching keys. A passphrase is only a real default if it can actually be typed.

# --- the github.com config block (independent of whether a key exists yet) ---
if ! grep -qs 'Host github.com' "$home/.ssh/config" 2>/dev/null; then
  cat >> "$home/.ssh/config" <<EOF
Host github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
  chmod 600 "$home/.ssh/config"
  echo "[deploy-ssh] wrote github.com block into $home/.ssh/config"
else
  echo "[deploy-ssh] github.com block already present"
fi

# --- the key ----------------------------------------------------------------
if [ -f "$key" ]; then
  echo "[deploy-ssh] key exists: $key (leaving it alone)"
  # Report, don't touch: re-keying would silently break an already-authorised identity.
  if ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
    cat >&2 <<EOF
[deploy-ssh] WARNING: this key has NO passphrase. To add one (keeps the same key, so GitHub
             needs no update):   ssh-keygen -p -f $key
EOF
  fi
  exit 0
fi

if [ "$NOPASS" = 1 ]; then
  ssh-keygen -t ed25519 -N "" -f "$key" -C "$(basename "$home")-github" -q
  echo "[deploy-ssh] generated $key (UNENCRYPTED — you asked for --no-passphrase)"
elif [ -t 0 ] && [ -r /dev/tty ]; then
  echo "[deploy-ssh] creating a GitHub key for this profile: $key"
  echo "             Choose a passphrase. You will type it once per login (it is then held"
  echo "             by the ssh-agent). Press Ctrl-C to skip and do this later."
  ssh-keygen -t ed25519 -f "$key" -C "$(basename "$home")-github" </dev/tty
  echo "[deploy-ssh] generated $key (passphrase-protected)"
else
  cat <<EOF
[deploy-ssh] no terminal available, so no key was created.
             A key without a passphrase is a plaintext credential, and this script will not
             create one behind your back. Finish it yourself (10 seconds):

                 uu github setup

             or, if you deliberately want an unencrypted key (CI, throwaway box):
                 bash $0 --no-passphrase $home
EOF
  exit 0
fi

echo "[deploy-ssh] next (human): add the public key to GitHub, then test —"
echo "    cat $key.pub        # → GitHub > Settings > SSH keys"
echo "    ssh -T git@github.com   # expect: 'Hi <user>! You've successfully authenticated'"
