#!/usr/bin/env bash
# preflight.sh — the prerequisite gate. NOTHING in this repo should build, create a box, or
# claim success before this passes. It answers one question in plain language: "can this
# machine actually run uumami_os, and if not, exactly what do I type to fix it?"
#
# Why this exists: without it, the scripts happily assembled Containerfiles, wrote config and
# printed success on a host that had no distrobox at all — leaving a half-built environment
# and no idea what went wrong. A missing prerequisite must STOP the run, loudly, with the fix.
#
# Runs ON THE HOST. If called from inside a box it probes the HOST (via distrobox-host-exec),
# because the host is where podman/distrobox have to exist.
#
# Usage:
#   preflight.sh                  human report; exit 0 = ready, 3 = something required missing
#   preflight.sh --quiet          print only failures (for use at the top of other scripts)
#   preflight.sh --warn-only      never exit non-zero (report only)
#   preflight.sh --json           machine-readable
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE=human; WARN_ONLY=0
for a in "$@"; do case "$a" in
  --quiet) MODE=quiet ;; --json) MODE=json ;; --warn-only) WARN_ONLY=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "preflight: unknown flag $a" >&2; exit 1 ;;
esac; done

in_box() { [ -f /run/.containerenv ]; }
# Probe the HOST, not the box we might be sitting in.
h() { if in_box; then distrobox-host-exec "$@"; else "$@"; fi; }
h_has() { h command -v "$1" >/dev/null 2>&1; }

FAILS=0; WARNS=0; JSON_ROWS=()
row() { # row <status ok|missing|warn> <key> <human message> [fix]
  local st="$1" key="$2" msg="$3" fix="${4:-}"
  JSON_ROWS+=("{\"check\":\"$key\",\"status\":\"$st\",\"message\":\"${msg//\"/\'}\"}")
  case "$st" in
    ok)      [ "$MODE" = human ] && printf '  \033[32m✓\033[0m %s\n' "$msg" ;;
    warn)    WARNS=$((WARNS+1)); [ "$MODE" != json ] && printf '  \033[33m!\033[0m %s\n' "$msg" >&2
             [ -n "$fix" ] && [ "$MODE" != json ] && printf '      %s\n' "$fix" >&2 ;;
    missing) FAILS=$((FAILS+1)); [ "$MODE" != json ] && printf '  \033[31m✗\033[0m %s\n' "$msg" >&2
             [ -n "$fix" ] && [ "$MODE" != json ] && printf '      fix: %s\n' "$fix" >&2 ;;
  esac
  return 0
}

# --- identify the OS so the fix instructions are the RIGHT ones --------------
OS_ID=unknown; OS_VER=""; ATOMIC=no
eval "$(h cat /etc/os-release 2>/dev/null | grep -E '^(ID|VERSION_ID|VARIANT_ID)=' | sed 's/^/OSREL_/')" 2>/dev/null || true
OS_ID="${OSREL_ID:-unknown}"; OS_VER="${OSREL_VERSION_ID:-}"
h command -v rpm-ostree >/dev/null 2>&1 && h rpm-ostree status >/dev/null 2>&1 && ATOMIC=yes

# how to install a host package on THIS os
pkg_fix() {
  local pkgs="$*"
  case "$OS_ID" in
    fedora|rhel|centos)
      if [ "$ATOMIC" = yes ]; then
        echo "sudo rpm-ostree install $pkgs   &&   sudo systemctl reboot   (atomic host: needs a reboot)"
      else echo "sudo dnf install -y $pkgs"; fi ;;
    debian|ubuntu|linuxmint|pop) echo "sudo apt update && sudo apt install -y $pkgs" ;;
    arch|endeavouros|manjaro)    echo "sudo pacman -S --needed $pkgs" ;;
    opensuse*|suse)              echo "sudo zypper install -y $pkgs" ;;
    *)                           echo "install '$pkgs' with your distribution's package manager" ;;
  esac
}
# distrobox has an official no-sudo installer — the preferred route on atomic hosts, where
# layering a package costs a reboot.
DISTROBOX_NOSUDO='curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local'

[ "$MODE" = human ] && {
  echo "== preflight: can this machine run uumami_os? =="
  echo "   host: ${OS_ID} ${OS_VER}$([ "$ATOMIC" = yes ] && echo ' (atomic/immutable)')"
  echo
}

# --- REQUIRED ---------------------------------------------------------------
if h_has podman; then
  pv="$(h podman --version 2>/dev/null | awk '{print $3}')"
  row ok podman "podman installed (${pv:-?})"
else
  row missing podman "podman is NOT installed — nothing can be built or run without it" \
    "$(pkg_fix podman)"
fi

if h_has distrobox; then
  dv="$(h distrobox --version 2>/dev/null | awk '{print $NF}')"
  row ok distrobox "distrobox installed (${dv:-?})"
else
  row missing distrobox "distrobox is NOT installed — the dev boxes cannot be created" \
    "no sudo, no reboot:  $DISTROBOX_NOSUDO
           or system-wide:      $(pkg_fix distrobox)"
fi

for c in curl tar awk sed grep; do
  h_has "$c" && row ok "$c" "$c present" || row missing "$c" "$c is missing (core utility)" "$(pkg_fix "$c")"
done

# yq: we install it ourselves, no sudo — so a miss is a warning with a one-liner, not a wall.
yq_ver="$(h yq --version 2>/dev/null || true)"   # capture: see the pipefail note in CLAUDE.md
if h_has yq && grep -qi mikefarah <<<"$yq_ver"; then
  row ok yq "yq present (config parser)"
else
  row warn yq "yq (mikefarah) not on the host PATH — the config parser" \
    "installs itself, no sudo:  bash $ROOT/setup/lib/ensure-yq.sh"
fi

# --- ROOTLESS CONTAINER SANITY ----------------------------------------------
if h_has podman; then
  if h podman info >/dev/null 2>&1; then
    row ok podman-rootless "rootless podman works for this user"
  else
    row missing podman-rootless "podman is installed but cannot run as your user" \
      "check:  podman info    (often missing subuid/subgid: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 \$USER)"
  fi
  subs="$(h grep -c "^$(h id -un 2>/dev/null):" /etc/subuid 2>/dev/null || echo 0)"
  [ "${subs:-0}" -ge 1 ] && row ok subuid "subuid/subgid ranges allocated (needed for nested containers)" \
    || row warn subuid "no /etc/subuid entry for your user — nested rootless podman inside a box may fail" \
         "sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 \$USER"
fi

# --- SESSION / SERVICES ------------------------------------------------------
if h systemctl --user is-system-running >/dev/null 2>&1 || h systemctl --user show-environment >/dev/null 2>&1; then
  row ok systemd-user "systemd user session available (the model server runs as a user service)"
else
  row warn systemd-user "no systemd --user session — the model server cannot auto-start" \
    "usually means you are on a non-systemd distro or a bare TTY session"
fi

# --- DISK --------------------------------------------------------------------
avail_gb="$(h df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${avail_gb:-}" ]; then
  if   [ "$avail_gb" -ge 60 ]; then row ok disk "disk space: ${avail_gb} GiB free (images + models need ~50 GiB)"
  elif [ "$avail_gb" -ge 25 ]; then row warn disk "only ${avail_gb} GiB free — enough to build, tight for models" \
         "the toolchain image alone is ~9 GiB; a 30B model is ~19 GiB"
  else row missing disk "only ${avail_gb} GiB free — not enough (need ~25 GiB minimum, 60 GiB comfortable)" \
         "free space, or point paths.models at a bigger disk in config.yaml"; fi
fi

# --- GPU (never fatal: CPU inference works, just slowly) ---------------------
gpu_line="$(h lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -1)"
case "$gpu_line" in
  *AMD*|*ATI*|*Radeon*) row ok gpu "GPU detected: AMD (ROCm path)" ;;
  *NVIDIA*)             row ok gpu "GPU detected: NVIDIA (CUDA path)" ;;
  *Intel*)              row warn gpu "GPU detected: Intel — limited acceleration, expect slow inference" "" ;;
  *)                    row warn gpu "no discrete GPU detected — inference will run on CPU (slow but functional)" "" ;;
esac

# --- REPO LOCATION -----------------------------------------------------------
# A second copy of this repo elsewhere is a real trap: you edit one, the tools use the other.
canonical="$(h bash -c 'echo $HOME')/Containers"
if [ "$ROOT" != "$canonical" ] && h test -d "$canonical/setup/lib" 2>/dev/null; then
  row warn repo-copies "TWO copies of this repo exist: you are running '$ROOT', but '$canonical' also exists" \
    "keep exactly one. Check which one your tools use:  readlink -f ~/.local/bin/uu"
else
  row ok repo "repo location: $ROOT"
fi

# --- verdict -----------------------------------------------------------------
if [ "$MODE" = json ]; then
  printf '{"ready":%s,"failures":%s,"warnings":%s,"os":"%s","atomic":"%s","checks":[' \
    "$([ "$FAILS" -eq 0 ] && echo true || echo false)" "$FAILS" "$WARNS" "$OS_ID" "$ATOMIC"
  printf '%s' "$(IFS=,; echo "${JSON_ROWS[*]}")"
  printf ']}\n'
elif [ "$FAILS" -eq 0 ]; then
  [ "$MODE" = human ] && { echo; echo "== preflight PASS — this machine is ready ($WARNS warning(s)) =="; }
else
  {
    echo
    echo "== preflight FAILED — $FAILS required thing(s) missing =="
    echo "Nothing was built or changed. Install what is listed above, then run this again:"
    echo "    bash $ROOT/setup/lib/preflight.sh"
  } >&2
fi

[ "$WARN_ONLY" = 1 ] && exit 0
[ "$FAILS" -eq 0 ] || exit 3
exit 0
