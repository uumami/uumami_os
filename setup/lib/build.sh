#!/usr/bin/env bash
# build.sh <image> — assemble the Containerfile from modules, then build the image.
# Runs ON THE HOST. Generic over image name (dev_base, os_agent, ...). Idempotent:
# rebuilds from cache; layer cache makes a no-op rebuild fast. No box mutation here.
# Usage:  build.sh <image-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

image="${1:?usage: build.sh <image-name>}"
[ -d "$ROOT/images/$image/modules" ] || { echo "build: no image '$image' (images/$image/modules missing)" >&2; exit 1; }

# 1. (re)generate the Containerfile from the enabled modules.
"$SCRIPT_DIR/assemble.sh" "$image"

# 2. build with the Fedora version + engine from the merged config.
merged="$(merge_config "$ROOT")"
fedver="$(cfg_get "$merged" '.os.version' '42')"
engine="$(cfg_get "$merged" '.container_engine' 'podman')"

echo "[build] $image: engine=$engine FEDORA_VERSION=$fedver"
"$engine" build --build-arg FEDORA_VERSION="$fedver" -t "localhost/$image:latest" "$ROOT/images/$image"
echo "[build] built localhost/$image:latest"
