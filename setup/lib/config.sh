#!/usr/bin/env bash
# config.sh — resolve and deep-merge the layered configuration.
# Merge order (later wins): config.yaml (general) → OS flavor → hardware flavor.
# The active flavor is named in config.yaml; flavors chain via `extends:`.
# Usage:  merged="$(merge_config /path/to/repo)" ; echo "$merged" | yq '.gpu.gfx'
#
# NOTE: this is a SOURCED library — it deliberately does NOT `set -e`/`-u`, which would leak
# into and change the caller's shell (validate.sh runs without -e on purpose, to collect all
# violations). Callers that want strict mode set it themselves before sourcing.

# require_yq — yq is THE config parser; every function below needs it. Without this guard a
# missing yq produces a cascade of "yq: command not found" from every call site while the
# calling script keeps going and reports success on empty values. One clear sentence instead.
# Also self-heals the common case: yq is installed but ~/.local/bin is not on PATH.
require_yq() {
  command -v yq >/dev/null 2>&1 && return 0
  if [ -x "$HOME/.local/bin/yq" ]; then PATH="$HOME/.local/bin:$PATH"; export PATH; return 0; fi
  cat >&2 <<EOF
config: 'yq' (the configuration reader) is not available, so no setting can be read.
Install it — no sudo, one second:
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-yq.sh"
If it is already installed, add its folder to your PATH:
    export PATH="\$HOME/.local/bin:\$PATH"
EOF
  return 1
}

merge_config() {
  require_yq || return 1
  local root="${1:?repo root required}"
  local cfg="$root/config.yaml"
  [ -f "$cfg" ] || { echo "merge_config: $cfg not found" >&2; return 1; }

  local active chain=() f
  active="$(yq -r '.flavor // ""' "$cfg")"

  # Walk the extends chain leaf→base, prepend so the final order is base→leaf.
  f="$active"; local depth=0 seen=" "
  while [ -n "$f" ] && [ "$f" != "null" ]; do
    case "$seen" in *" $f "*) echo "merge_config: cyclic 'extends' at flavor '$f'" >&2; return 1;; esac
    seen="$seen$f "; depth=$((depth+1))
    [ "$depth" -gt 20 ] && { echo "merge_config: 'extends' chain too deep (cycle?)" >&2; return 1; }
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
  # Read the literal value — do NOT use yq's `//`, which coalesces boolean `false` to the
  # default (so `false` would be indistinguishable from missing). Only null/empty → default.
  local v; v="$(printf '%s' "$merged" | yq -r "$path")"
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$def"; else printf '%s' "$v"; fi
}

# expand_tilde <path> — expand a leading ~ to $HOME (yq returns literal ~).
# Only `~` alone or `~/…` (NOT the `~user` form, which $HOME can't resolve).
# shellcheck disable=SC2088  # the `~` here is a case PATTERN, not a path to be expanded
expand_tilde() { case "$1" in "~"|"~/"*) printf '%s' "${HOME}${1#\~}";; *) printf '%s' "$1";; esac; }
