#!/usr/bin/env bash
# bootstrap.sh — probe the machine, match a flavor, generate+validate config (SG10).
# Idempotent: never clobbers an existing config.yaml or flavor (reports + validates them
# instead). On a fresh machine it scaffolds a config.yaml from facts and points you at the
# nearest flavor (or drafts one with uncertain fields flagged). Runs ON THE HOST.
# Hardware-specific values are NEVER written into config.yaml (they belong in a flavor).
# Usage:  bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

FACTS="$ROOT/setup/facts.env"
CFG="$ROOT/config.yaml"

echo "== bootstrap: probing host =="
bash "$SCRIPT_DIR/detect.sh" --write "$FACTS" >/dev/null
# shellcheck source=/dev/null
. "$FACTS"
echo "  OS:   ${OS_ID} ${OS_VERSION} (${OS_VARIANT:-}, atomic=${ATOMIC})"
echo "  GPU:  ${GPU_VENDOR} ${GPU_GFX} (${GPU_CODENAME:-?}, pciid ${GPU_PCIID})"
echo "  CPU:  ${CPU_CORES} cores, ${RAM_GIB} GiB RAM"

# --- match a hardware flavor from detected facts ----------------------------
suggest_flavor=""
base_flavor="${OS_ID}${OS_VARIANT:+-$OS_VARIANT}"   # avoid double/trailing dash when no VARIANT
case "${GPU_CODENAME:-}" in
  "") : ;;
  *) suggest_flavor="${base_flavor}-${GPU_CODENAME}" ;;
esac
os_flavor="$base_flavor"

# emit_flavor_request <flavor-name> — write a copy-pasteable BROWSER-AGENT prompt that
# embeds the detected facts + the flavor schema, so a non-coder can paste it into a browser
# LLM (ChatGPT/Claude/Gemini) and get a correct hardware flavor back. The scripts supply the
# correct machine facts; the browser agent does the per-GPU research (known-good Ollama tag,
# HSA override, VRAM guidance). This is the intended entry point of the whole tutorial.
emit_flavor_request() {
  local name="$1" out="$ROOT/setup/flavor-request.md"
  cat > "$out" <<EOF
# Browser-agent request: author a hardware flavor for my machine

I'm setting up a local AI dev environment (uumami_os). A probe script detected the facts
below. Please produce a single YAML file **\`flavors/${name}.yaml\`** that \`extends: ${os_flavor}\`.
Follow the **hardware-flavor schema** (keys + constraints) in \`setup/schema/MANIFEST.md\`, and
use \`flavors/fedora-kinoite-strix-halo.yaml\` in the repo as the gold-standard example of the
expected shape and comment style.

## Detected machine facts (authoritative — do not second-guess these)
\`\`\`
OS:     ${OS_ID} ${OS_VERSION} (${OS_VARIANT:-}, atomic=${ATOMIC}, pkg=${PKG_MGR}, selinux=${SELINUX})
Kernel: ${KERNEL}
CPU:    ${CPU_MODEL} (${CPU_CORES} cores)
RAM:    ${RAM_GIB} GiB
GPU:    vendor=${GPU_VENDOR} pciid=${GPU_PCIID} gfx=${GPU_GFX} codename=${GPU_CODENAME:-unknown}
GPU compute nodes world-rw: ${GPU_COMPUTE_NODES_OPEN}
\`\`\`

## Research and fill (cite sources; FLAG anything uncertain — never guess silently)
1. \`gpu\`: vendor, gfx target, backend \`path\` (rocm/cuda/vulkan/cpu), \`device_flags\`, the
   rootless SELinux flag, and the \`env\` block (e.g. AMD \`HSA_OVERRIDE_GFX_VERSION\`,
   \`OLLAMA_FLASH_ATTENTION\`) needed for **GPU** inference (not silent CPU fallback).
2. \`llm_image\` + \`llm_version_constraint\`: the **known-good** backend image tag for THIS GPU,
   and any versions to AVOID (regressions). Pin for reproducibility.
3. \`model.primary\` + \`context_length\`: the largest \`qwen3-coder\` (or comparable) that fits this
   machine's VRAM, and a safe context length. Document the minimum VRAM per context length.
4. \`memory\`: ram_gib, vram_gib (current carveout), and the VRAM-expansion procedure IF this GPU
   supports it — mark every host-mutating step (BIOS / sudo / reboot) as human-required.

Return ONLY the YAML file content, ready to save as \`flavors/${name}.yaml\`. After I save it,
the setup will validate it automatically.
EOF
  echo "  → wrote a browser-agent prompt to setup/flavor-request.md"
  echo "    Paste it into a browser LLM, save the returned YAML to flavors/${name}.yaml, re-run bootstrap."
}

echo "== bootstrap: flavor match =="
if [ -n "$suggest_flavor" ] && [ -f "$ROOT/flavors/$suggest_flavor.yaml" ]; then
  echo "  ✓ hardware flavor exists: flavors/$suggest_flavor.yaml"
elif [ -n "$suggest_flavor" ]; then
  echo "  ! no flavors/$suggest_flavor.yaml — generating a browser-agent request:"
  emit_flavor_request "$suggest_flavor"
else
  # GPU not matched to a codename — still emit a request keyed by vendor so the user isn't stuck.
  suggest_flavor="${base_flavor}-${GPU_VENDOR}"
  echo "  ! GPU codename not recognized (vendor=${GPU_VENDOR}) — generating a browser-agent request:"
  emit_flavor_request "$suggest_flavor"
fi
[ -f "$ROOT/flavors/$os_flavor.yaml" ] && echo "  ✓ OS flavor exists: flavors/$os_flavor.yaml" \
  || echo "  ! no OS flavor flavors/$os_flavor.yaml — author from MANIFEST.md (pkg_manager/selinux/immutable)"

# --- config.yaml: validate if present, scaffold if absent -------------------
echo "== bootstrap: config.yaml =="
if [ -f "$CFG" ]; then
  echo "  config.yaml exists — validating (not overwriting)."
  bash "$SCRIPT_DIR/validate.sh" "$ROOT"
else
  if [ -z "$suggest_flavor" ]; then
    echo "  ✗ cannot scaffold config.yaml without a flavor name; author the flavor first." >&2
    exit 1
  fi
  echo "  scaffolding config.yaml (general layer only — no hardware values)."
  cat > "$CFG" <<YAML
# uumami_os — general configuration (generated by bootstrap; review before use).
flavor: $suggest_flavor

paths:
  containers: ~/Containers
  profiles:   ~/Profiles
  models:     ~/Models
  code:       ~/Code

container_engine: podman

llm:
  backend: ollama
  host: 127.0.0.1
  port: 11434

agents:
  claude_code: true
  codex: true
  opencode: true
  pi: true
  omp: true
  hermes: true
ide:
  cursor: true

tenants:
  default_tier: "2a"
  browser_default: shared
YAML
  echo "  wrote $CFG — now ensure flavors/$suggest_flavor.yaml exists, then re-run to validate."
fi
echo "== bootstrap done =="
