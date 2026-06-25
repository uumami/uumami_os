#!/usr/bin/env bash
# llm_server.sh — build the llm_server image and (re)create its distrobox from the
# merged config + active hardware flavor. Runs ON THE HOST. Idempotent (rm -f then create;
# the profile/home survives because we never pass --rm-home).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

merged="$(merge_config "$ROOT")"

name=llm_server
image=localhost/llm_server:latest
profiles="$(expand_tilde "$(cfg_get "$merged" '.paths.profiles' '~/Profiles')")"
models="$(expand_tilde "$(cfg_get "$merged" '.paths.models' '~/Models')")"
models_dir="$models/ollama"        # ollama store: blobs/ + manifests/

# --- assemble GPU device + env flags from the flavor (injected at create time) ---
extra=""
while IFS= read -r d; do [ -n "$d" ] && extra+="$d "; done \
  < <(printf '%s' "$merged" | yq -r '.gpu.device_flags[]?')
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] && extra+="--env $k=$v "
done < <(printf '%s' "$merged" | yq -r '.gpu.env // {} | to_entries[] | [.key, .value] | @tsv')

echo "[llm_server] image:        $image"
echo "[llm_server] profile home: $profiles/$name"
echo "[llm_server] models mount:  $models_dir -> /models"
echo "[llm_server] gpu flags:     $extra"

echo "[llm_server] building image..."
podman build -t "$image" "$ROOT/images/llm_server"

echo "[llm_server] (re)creating distrobox (profile survives)..."
distrobox rm -f "$name" >/dev/null 2>&1 || true
# shellcheck disable=SC2086  # $extra is intentionally word-split into flags
distrobox create --yes \
  --name "$name" \
  --image "$image" \
  --home "$profiles/$name" \
  --volume "$models_dir:/models" \
  --additional-flags "$extra"

echo "[llm_server] done. Start with the systemd service, or:"
echo "    distrobox enter $name -- ollama serve"
