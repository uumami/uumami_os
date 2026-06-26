#!/usr/bin/env bash
# rebuild.sh — rebuild-cascade (SG8/SG9). When a shared parent image changes, rebuild it
# and every image derived from it, then (re)create the affected distroboxes. Enumerates
# tenants from the SG4 tenant registry. Runs ON THE HOST.
#
# Execution model A: image BUILDS are automated (no sudo, no reboot). Box RECREATES are
# host-mutating and are emitted as human-required steps, NOT executed — because:
#   • os_agent cannot recreate itself from within (would kill the running session), and
#   • tenant boxes belong to other Linux users (sudo) — see SG10.5.
# Use --recreate-llm to also (re)create llm_server here (safe: not the box we run in).
#
# Cascade order: dev_base  →  {os_agent, every tenant image}  →  recreate guidance.
# Usage:  rebuild.sh [--recreate-llm]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

merged="$(merge_config "$ROOT")"
profiles="$(expand_tilde "$(cfg_get "$merged" '.paths.profiles' "$HOME/Profiles")")"
registry="$profiles/registry.yaml"   # SG4 tenant registry (state; created by tenant-create)

echo "== rebuild-cascade =="

# 1. shared parent.
"$SCRIPT_DIR/build.sh" dev_base

# 2. images derived from dev_base: os_agent (Tier-0) + any tenant images in the registry.
derived=(os_agent)
if [ -f "$registry" ]; then
  while IFS= read -r img; do [ -n "$img" ] && derived+=("$img"); done \
    < <(yq -r '.tenants[]?.image // empty' "$registry" 2>/dev/null | sort -u)
fi
for img in "${derived[@]}"; do
  if [ -d "$ROOT/images/$img/modules" ]; then
    "$SCRIPT_DIR/build.sh" "$img"   # a real build failure here aborts the cascade (set -e)
  else
    echo "[rebuild] note: no image dir for '$img' (tenant may build from dev_base directly)"
  fi
done

# 3. llm_server is independent of dev_base, but offer to recreate it on request.
if [ "${1:-}" = --recreate-llm ]; then
  echo "[rebuild] recreating llm_server (independent of dev_base)..."
  "$SCRIPT_DIR/llm_server.sh"
fi

# 4. recreate guidance — host-mutating, NOT executed (model A).
cat <<EOF

[human-required] Image(s) rebuilt. A Containerfile change does NOT propagate to a running
box — recreate each affected box (the profile/home survives; never pass --rm-home):

  # os_agent — run from a HOST terminal (NOT from inside os_agent):
  distrobox rm -f os_agent && \\
    distrobox create --name os_agent --image localhost/os_agent:latest \\
      --home "$profiles/os_agent" \\
      --volume "\$HOME/Code:/workspace" --volume "\$HOME/Containers:/containers:ro"
EOF
if [ -f "$registry" ]; then
  echo "  # tenants (each as its own Linux user — needs that user's session / sudo, see SG10.5):"
  yq -r '.tenants[]? | "  sudo -iu \(.user) tenant-create  # or rerun for \(.name)"' "$registry" 2>/dev/null || true
else
  echo "  # (no tenant registry at $registry yet — created by tenant-create in SG10.5)"
fi
echo "[rebuild] done (images built; box recreates are human-required above)."
