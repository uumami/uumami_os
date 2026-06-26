#!/usr/bin/env bash
# detect.sh — read-only host probe. Emits machine facts for config/flavor selection.
# Runs ON THE HOST (invoke via `distrobox-host-exec bash setup/lib/detect.sh` from a box).
# Read-only: changes nothing. Output: key=value facts on stdout; --write <file> to persist.
set -euo pipefail

OUT=""
[ "${1:-}" = "--write" ] && OUT="${2:?--write needs a path}"

emit() { printf '%s=%q\n' "$1" "$2"; }

# --- OS / atomicity ---
. /etc/os-release 2>/dev/null || true
os_id="${ID:-unknown}"; os_ver="${VERSION_ID:-unknown}"; os_variant="${VARIANT_ID:-}"
atomic=no
command -v rpm-ostree >/dev/null 2>&1 && rpm-ostree status >/dev/null 2>&1 && atomic=yes
case "$os_id" in fedora) pkg_mgr=$([ "$atomic" = yes ] && echo rpm-ostree || echo dnf);; debian|ubuntu) pkg_mgr=apt;; arch) pkg_mgr=pacman;; *) pkg_mgr=unknown;; esac

# --- kernel / selinux ---
kernel="$(uname -r)"
selinux="$(getenforce 2>/dev/null || echo none)"

# --- cpu / memory ---
cpu_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
[ -n "$cpu_model" ] || cpu_model=unknown
cpu_cores="$(nproc)"
ram_gib="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)"

# --- gpu ---
gpu_line="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -1 || true)"
gpu_pciid="$(printf '%s' "$gpu_line" | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}' | tail -1 || true)"
gpu_vendor=none; gpu_gfx=unknown
case "$gpu_line" in
  *AMD*|*ATI*|*Radeon*) gpu_vendor=amd ;;
  *NVIDIA*) gpu_vendor=nvidia ;;
  *Intel*) gpu_vendor=intel ;;
esac
# Known AMD PCI-id -> gfx target (extend as needed; otherwise flavor sets it explicitly)
case "$gpu_pciid" in
  1002:1586) gpu_gfx=gfx1151; gpu_codename="strix-halo" ;;   # Ryzen AI MAX / Radeon 8060S
  1002:150e) gpu_gfx=gfx1150; gpu_codename="strix-point" ;;
  1002:7550|1002:7551) gpu_gfx=gfx1201; gpu_codename="rdna4" ;;
  *) gpu_codename="" ;;
esac
gpu_compute_open=no
{ [ -e /dev/kfd ] && [ -r /dev/dri/renderD128 ]; } && \
  [ "$(stat -c '%a' /dev/kfd 2>/dev/null)" = 666 ] && gpu_compute_open=yes

# --- session prereqs ---
linger="$(loginctl show-user "$USER" 2>/dev/null | sed -n 's/^Linger=//p' || echo unknown)"
in_render=no; id -nG 2>/dev/null | tr ' ' '\n' | grep -qx render && in_render=yes
in_video=no;  id -nG 2>/dev/null | tr ' ' '\n' | grep -qx video  && in_video=yes
overlay="$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo unknown)"

# --- emit ---
{
  emit OS_ID "$os_id"; emit OS_VERSION "$os_ver"; emit OS_VARIANT "$os_variant"
  emit ATOMIC "$atomic"; emit PKG_MGR "$pkg_mgr"
  emit KERNEL "$kernel"; emit SELINUX "$selinux"; emit OVERLAY_DRIVER "$overlay"
  emit CPU_MODEL "$cpu_model"; emit CPU_CORES "$cpu_cores"; emit RAM_GIB "$ram_gib"
  emit GPU_VENDOR "$gpu_vendor"; emit GPU_PCIID "${gpu_pciid:-none}"
  emit GPU_GFX "$gpu_gfx"; emit GPU_CODENAME "${gpu_codename:-}"
  emit GPU_COMPUTE_NODES_OPEN "$gpu_compute_open"
  emit USER_LINGER "$linger"; emit IN_RENDER_GROUP "$in_render"; emit IN_VIDEO_GROUP "$in_video"
} | { if [ -n "$OUT" ]; then tee "$OUT"; else cat; fi; }

[ -n "$OUT" ] && echo "# facts written to $OUT" >&2
exit 0
