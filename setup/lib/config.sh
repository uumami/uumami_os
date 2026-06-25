#!/usr/bin/env bash
# config.sh — resolve and deep-merge the layered configuration.
# Merge order (later wins): config.yaml (general) → OS flavor → hardware flavor.
# The active flavor is named in config.yaml; flavors chain via `extends:`.
# Usage:  merged="$(merge_config /path/to/repo)" ; echo "$merged" | yq '.gpu.gfx'
set -euo pipefail

merge_config() {
  local root="${1:?repo root required}"
  local cfg="$root/config.yaml"
  [ -f "$cfg" ] || { echo "merge_config: $cfg not found" >&2; return 1; }

  local active chain=() f
  active="$(yq -r '.flavor // ""' "$cfg")"

  # Walk the extends chain leaf→base, prepend so the final order is base→leaf.
  f="$active"
  while [ -n "$f" ] && [ "$f" != "null" ]; do
    local ff="$root/flavors/$f.yaml"
    [ -f "$ff" ] || { echo "merge_config: flavor '$f' ($ff) not found" >&2; return 1; }
    chain=("$ff" "${chain[@]}")
    f="$(yq -r '.extends // ""' "$ff")"
  done

  # config.yaml is the general base; then the flavor chain base→leaf. Later wins (deep merge).
  yq eval-all '. as $i ireduce ({}; . * $i)' "$cfg" "${chain[@]}"
}

# cfg_get <merged-yaml> <yq-path> [default]  — read one value from merged config.
cfg_get() {
  local merged="$1" path="$2" def="${3:-}"
  local v; v="$(printf '%s' "$merged" | yq -r "$path // \"\"")"
  [ -n "$v" ] && [ "$v" != "null" ] && printf '%s' "$v" || printf '%s' "$def"
}

# expand_tilde <path> — expand a leading ~ to $HOME (yq returns literal ~).
expand_tilde() { case "$1" in "~"*) printf '%s' "${HOME}${1#\~}";; *) printf '%s' "$1";; esac; }
