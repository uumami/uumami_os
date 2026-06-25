#!/usr/bin/env bash
# os-module.sh — OS-module interface + loader (SG8 #2/#3).
#
# Core scripts NEVER branch on the OS. They call the functions below; the active
# OS module (setup/lib/os/<id>-<variant>.sh) implements them. This file documents
# the contract and loads the right module from detected facts.
#
# CONTRACT — every OS module MUST define these functions:
#   os_name                      -> echoes a human label (e.g. "Fedora Kinoite 44")
#   os_pkg_manager               -> echoes rpm-ostree|dnf|apt|...
#   os_is_immutable              -> return 0 if the host root is immutable (atomic)
#   os_pkg_installed <pkg>       -> return 0 if installed on the HOST
#   os_pkg_install <pkg...>      -> install host pkgs. AUTO where safe; on atomic/sudo
#                                   hosts emit a human-required instruction and return 2.
#   os_selinux_mode              -> echoes Enforcing|Permissive|Disabled|none
#   os_shared_mount_flag         -> echoes the volume suffix for SHARED host dirs (e.g. :z)
#   os_private_mount_flag        -> echoes the suffix for PRIVATE single-box volumes (e.g. :Z)
#   os_enable_linger <user>      -> enable lingering for <user>. AUTO if no sudo needed,
#                                   else emit human-required and return 2. Idempotent.
#   os_add_user_groups <u> <g..> -> add user to groups. Host-mutating: emit human-required
#                                   instruction and return 2 (needs sudo). Idempotent guidance.
#   os_gpu_selinux_boolean       -> echo the setsebool name if GPU device access needs it, else ""
#
# Return-code convention shared by all modules:
#   0 = done (idempotent: already-satisfied also returns 0)
#   2 = human-required: the function printed an exact instruction; caller must PAUSE
#   1 = hard error
#
# Usage:  . os-module.sh ; os_module_load [facts-file] ; os_name
set -euo pipefail

# Map detected facts -> module file, then source it.
os_module_load() {
  local facts="${1:-}" id variant
  if [ -n "$facts" ] && [ -f "$facts" ]; then
    # facts file is key=value (from detect.sh --write); read without executing arbitrary code.
    id="$(sed -n 's/^OS_ID=//p' "$facts" | tr -d "'\"" | head -1)"
    variant="$(sed -n 's/^OS_VARIANT=//p' "$facts" | tr -d "'\"" | head -1)"
  else
    . /etc/os-release 2>/dev/null || true
    id="${ID:-unknown}"; variant="${VARIANT_ID:-}"
  fi
  local dir; dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os"
  local mod="$dir/${id}-${variant}.sh"
  [ -f "$mod" ] || mod="$dir/${id}.sh"
  [ -f "$mod" ] || { echo "os-module: no module for id='$id' variant='$variant' in $dir" >&2; return 1; }
  # shellcheck source=/dev/null
  . "$mod"
  echo "[os-module] loaded $(os_name)" >&2
}
