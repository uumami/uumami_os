#!/usr/bin/env bash
# ensure-yq.sh — make `yq` (mikefarah) available on the host without sudo.
# Installs a static binary to ~/.local/bin if missing. Idempotent.
set -euo pipefail

if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -qi mikefarah; then
  echo "yq present: $(command -v yq) ($(yq --version))"
  exit 0
fi

mkdir -p "$HOME/.local/bin"
case "$(uname -m)" in
  x86_64)  arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *)       arch="$(uname -m)" ;;
esac
url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
echo "installing yq ($arch) -> $HOME/.local/bin/yq"
curl -fsSL "$url" -o "$HOME/.local/bin/yq.tmp"
chmod +x "$HOME/.local/bin/yq.tmp"
mv -f "$HOME/.local/bin/yq.tmp" "$HOME/.local/bin/yq"
"$HOME/.local/bin/yq" --version
echo "NOTE: ensure ~/.local/bin is on PATH (Fedora login shells add it by default)."
