#!/usr/bin/env bash
# deploy-ssh.sh <home> — per-profile GitHub SSH scaffolding (SG11; SG8 interface, called by
# tenant-create per user). Idempotent, no sudo. Run as the profile's owner.
#
# Generates a per-profile ed25519 key (one identity per tenant — never share keys across
# profiles) and a ~/.ssh/config block for github.com. Non-interactive by default (empty
# passphrase) so tenant-create can call it; pass --passphrase to be prompted instead.
# Uploading the public key to GitHub and testing is printed as the human follow-up.
set -euo pipefail

home=""; ASK=0
for a in "$@"; do case "$a" in --passphrase) ASK=1;; *) home="$a";; esac; done
[ -n "$home" ] || { echo "usage: deploy-ssh.sh [--passphrase] <profile-home>" >&2; exit 1; }

key="$home/.ssh/id_ed25519_github"
install -d -m 700 "$home/.ssh"

if [ -f "$key" ]; then
  echo "[deploy-ssh] key exists: $key (leaving it alone)"
else
  if [ "$ASK" = 1 ]; then ssh-keygen -t ed25519 -f "$key" -C "$(basename "$home")-github"
  else ssh-keygen -t ed25519 -N "" -f "$key" -C "$(basename "$home")-github" -q; fi
  echo "[deploy-ssh] generated $key"
fi

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

echo "[deploy-ssh] next (human): add the public key to GitHub, then test —"
echo "    cat $key.pub        # → GitHub > Settings > SSH keys"
echo "    ssh -T git@github.com   # expect: 'Hi <user>! You've successfully authenticated'"
