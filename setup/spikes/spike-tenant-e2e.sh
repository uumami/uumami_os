#!/usr/bin/env bash
# Real Tier-0 tenant-create E2E on the host (no sudo). Creates a throwaway box, verifies
# mounts + descriptor + registry, then removes everything (no --rm-home).
set -uo pipefail
cd /var/home/uumami/Code/system/uumami_os || exit 1
export PATH="$HOME/.local/bin:$PATH"
M=/tmp/test-tenant.yaml
cat > "$M" <<YAML
name: test-tenant
tier: "0"
browser: per-tenant
model: qwen3-coder:30b
code_mount: ~/Code
sessions:
  - {name: tt-main, agent: opencode, workdir: .}
YAML
echo "=== run tenant-create (real) ==="
bash setup/lib/tenant-create.sh "$M"; echo "rc=$?"
echo "=== box exists? ==="; distrobox list | grep test-tenant || echo "NO BOX"
echo "=== container mounts: want /workspace present, /models ABSENT ==="
podman inspect test-tenant.distrobox --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '/workspace|/models|/containers' || echo "(inspect by name failed, trying alt)"
podman ps -a --filter name=test-tenant --format '{{.Names}}' | head
echo "=== descriptor written? ==="; cat "$HOME/Profiles/test-tenant/.config/uumami/tenant.yaml" 2>/dev/null || echo "NO DESCRIPTOR"
echo "=== registry entry? ==="; yq -r '(.tenants // [])[] | select(.name=="test-tenant")' "$HOME/Profiles/registry.yaml" 2>/dev/null || echo "NO REGISTRY ENTRY"
echo "=== CLEANUP (no --rm-home) ==="
distrobox rm -f test-tenant 2>&1 | tail -1
rm -rf "$HOME/Profiles/test-tenant" "$M"
N=test-tenant yq -i 'del(.tenants[] | select(.name == env(N)))' "$HOME/Profiles/registry.yaml" 2>/dev/null || true
echo "cleaned. registry tenants now: $(yq -r '(.tenants // []) | length' "$HOME/Profiles/registry.yaml" 2>/dev/null)"
