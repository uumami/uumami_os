#!/usr/bin/env bash
# fedora-kinoite.sh — OS module for Fedora Kinoite (atomic / rpm-ostree / SELinux).
# Implements the os-module.sh contract. The core build needs NONE of the host-mutating
# functions here (GPU works via world-rw nodes + label=disable; no groups, no reboot) —
# they exist so tenant onboarding (SG10.5) and docs can emit exact human-required steps.
# Return convention: 0 = done, 2 = human-required (instruction printed), 1 = error.
set -euo pipefail

os_name() { echo "Fedora Kinoite (atomic, rpm-ostree, SELinux)"; }
os_pkg_manager() { echo "rpm-ostree"; }
os_is_immutable() { return 0; }   # Kinoite root is immutable

os_pkg_installed() { rpm -q "${1:?pkg}" >/dev/null 2>&1; }

# Host package install is layered onto the ostree and needs a reboot → human-required.
# (Per the architecture: do NOT install dev tooling on the host; this is for the rare
# host-level dep only.) Never used by the container build.
os_pkg_install() {
  # Idempotent: if EVERY requested package is already installed, it's a no-op (return 0) —
  # not just when a single package is passed.
  local all_installed=1 p
  for p in "$@"; do os_pkg_installed "$p" || { all_installed=0; break; }; done
  [ "$all_installed" -eq 1 ] && return 0
  cat >&2 <<EOF
[human-required] Install host package(s) on Fedora Kinoite (layers onto the ostree,
needs a reboot to take effect):
    sudo rpm-ostree install $*
    sudo systemctl reboot
EOF
  return 2
}

os_selinux_mode() { getenforce 2>/dev/null || echo none; }
# Shared host dirs (~/Code, ~/Models, ~/Profiles) get the lowercase relabel-shared flag.
os_shared_mount_flag() { echo ":z"; }
os_private_mount_flag() { echo ":Z"; }

# linger self-enables without sudo on this host (validated) — do it idempotently.
os_enable_linger() {
  local u="${1:?user}"
  if [ "$(loginctl show-user "$u" 2>/dev/null | sed -n 's/^Linger=//p')" = yes ]; then
    return 0
  fi
  if loginctl enable-linger "$u" 2>/dev/null; then
    echo "[os] enabled linger for $u" >&2; return 0
  fi
  echo "[human-required] sudo loginctl enable-linger $u" >&2
  return 2
}

# Adding a user to groups needs sudo → human-required. Idempotent guidance.
os_add_user_groups() {
  local u="${1:?user}"; shift
  echo "[human-required] sudo usermod -aG $(IFS=,; echo "$*") $u   # then re-login" >&2
  return 2
}

# GPU device access under enforcing SELinux: on THIS host the compute nodes are world-rw
# and rootless containers use `--security-opt label=disable`, so the boolean is NOT needed.
# Returned empty = no boolean required. (If a future host needs it, return the name.)
os_gpu_selinux_boolean() { echo ""; }
