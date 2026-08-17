#!/usr/bin/env bash
# validate.sh — schema validator (SG8/SG9). Validates config.yaml + the flavor chain
# against the SG4 variables manifest (setup/schema/MANIFEST.md). Transparent rule-checker
# (bash + yq) rather than a JSON-Schema engine, to stay dependency-free and auditable.
# Read-only. Exit 0 = valid; exit 1 = one or more violations (all printed).
# Usage:  validate.sh [repo-root]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

CFG="$ROOT/config.yaml"
require_yq || exit 3      # one clear message beats 40 "yq: command not found" lines
FAILS=0
fail() { printf '  ✗ %s\n' "$1" >&2; FAILS=$((FAILS+1)); }
ok()   { printf '  ✓ %s\n' "$1"; }

# q <file> <path> — literal value; null/missing -> "". Does NOT use yq's `//` (which would
# coalesce boolean false to "" and make a false toggle look identical to a missing one).
q() { local v; v="$(yq -r "$2" "$1" 2>/dev/null)"; [ "$v" = null ] && v=""; printf '%s' "$v"; }

echo "[validate] config: $CFG"
[ -f "$CFG" ] || { echo "  ✗ config.yaml not found" >&2; exit 1; }

# --- 1. general-layer required keys + enums ---------------------------------
[ -n "$(q "$CFG" .flavor)" ] && ok "flavor set" || fail "flavor: required"
for p in containers profiles models code; do
  [ -n "$(q "$CFG" ".paths.$p")" ] && ok "paths.$p" || fail "paths.$p: required"
done
ce="$(q "$CFG" .container_engine)"
case "$ce" in podman|docker) ok "container_engine=$ce";; *) fail "container_engine: must be podman|docker (got '$ce')";; esac
lb="$(q "$CFG" .llm.backend)"
case "$lb" in ollama|lemonade) ok "llm.backend=$lb";; *) fail "llm.backend: must be ollama|lemonade (got '$lb')";; esac
host="$(q "$CFG" .llm.host)"
case "$host" in
  127.0.0.1|localhost|::1) ok "llm.host=$host (loopback)" ;;
  "") fail "llm.host: required" ;;
  *) fail "llm.host: must be loopback (127.0.0.1|localhost|::1) — never expose the model server (got '$host')" ;;
esac
port="$(q "$CFG" .llm.port)"
[[ "$port" =~ ^[0-9]+$ ]] && ok "llm.port=$port" || fail "llm.port: must be integer (got '$port')"
for a in claude_code codex opencode pi omp hermes; do
  v="$(q "$CFG" ".agents.$a")"
  case "$v" in true|false) ok "agents.$a=$v";; *) fail "agents.$a: must be true|false (got '$v')";; esac
done
v="$(q "$CFG" .ide.cursor)"; case "$v" in true|false) ok "ide.cursor=$v";; *) fail "ide.cursor: must be true|false";; esac
tier="$(q "$CFG" .tenants.default_tier)"
case "$tier" in 0|1|2a|2b|3) ok "tenants.default_tier=$tier";; *) fail "tenants.default_tier: must be 0|1|2a|2b|3 (got '$tier')";; esac
bd="$(q "$CFG" .tenants.browser_default)"
case "$bd" in shared|per-tenant|per-session) ok "tenants.browser_default=$bd";; *) fail "tenants.browser_default: invalid ('$bd')";; esac

# --- 2. layer purity: no hardware/OS keys in the GENERAL config -------------
for k in gpu model memory os selinux distrobox llm_image llm_version_constraint; do
  [ "$(q "$CFG" ".$k")" = "" ] || fail "layer-purity: '$k' must live in a flavor, not config.yaml"
done
ok "layer purity (no hardware/OS keys in config.yaml)"

# --- 3. no secrets anywhere in config.yaml ----------------------------------
# Capture the paths before matching. Piping yq straight into `grep -qi` is unsafe here: grep -q
# exits at the FIRST credential-like key, yq takes SIGPIPE, and under `set -o pipefail` the
# pipeline returns 141 — so the `if` goes false and the secret is reported as clean. A false
# negative on this particular check is the one that matters. See the pipefail note in CLAUDE.md.
cfg_paths="$(yq -r '.. | path | join(".")' "$CFG" 2>/dev/null || true)"
if grep -qiE '(^|\.)(api_?key|token|secret|password|passwd)($|\.)' <<<"$cfg_paths"; then
  fail "secrets: config.yaml contains a credential-like key (secrets are per-tenant, never here)"
else
  ok "no credential keys in config.yaml"
fi

# --- 4. flavor chain resolves; hardware leaf carries hardware ---------------
active="$(q "$CFG" .flavor)"; f="$active"; depth=0
while [ -n "$f" ] && [ "$f" != null ]; do
  ff="$ROOT/flavors/$f.yaml"
  [ -f "$ff" ] || { fail "flavor '$f' missing ($ff)"; break; }
  depth=$((depth+1)); [ "$depth" -gt 10 ] && { fail "flavor extends chain too deep (cycle?)"; break; }
  f="$(q "$ff" .extends)"
done
[ "$depth" -ge 1 ] && ok "flavor chain resolves (depth $depth)"

# --- 5. merged config has required hardware values --------------------------
merged="$(merge_config "$ROOT" 2>/dev/null)" || fail "merge_config failed"
if [ -n "${merged:-}" ]; then
  [ -n "$(cfg_get "$merged" .gpu.vendor)" ]  && ok "merged gpu.vendor"  || fail "merged: gpu.vendor missing (hardware flavor)"
  [ -n "$(cfg_get "$merged" .model.primary)" ] && ok "merged model.primary" || fail "merged: model.primary missing (hardware flavor)"
fi

# --- 6. toggle↔module coherence: every enabled toggle has a .layer ----------
moddir="$ROOT/images/dev_base/modules"
declare -A toggle_of
if [ -d "$moddir" ]; then
  for m in "$moddir"/*.layer; do
    [ -e "$m" ] || continue
    t="$(sed -n 's/^#[[:space:]]*toggle:[[:space:]]*//p' "$m" | head -1)"
    [ -n "$t" ] && toggle_of["$t"]=1
  done
  miss=0
  for a in claude_code codex opencode pi omp hermes; do
    [ "$(q "$CFG" ".agents.$a")" = true ] || continue
    [ -n "${toggle_of[agents.$a]:-}" ] || { fail "agents.$a=true but no module with '# toggle: agents.$a'"; miss=1; }
  done
  if [ "$(q "$CFG" .ide.cursor)" = true ] && [ -z "${toggle_of[ide.cursor]:-}" ]; then
    fail "ide.cursor=true but no module with '# toggle: ide.cursor'"; miss=1
  fi
  [ "$miss" -eq 0 ] && ok "every enabled toggle maps to a .layer module"
fi

# --- 5b. everything enabled must have a pinned source ------------------------
# An enabled toggle with no source is a silent no-op: `uu update` would skip it and you would
# think it was installed. For skills it is worse than a no-op — an unpinned source means the
# upstream author, not you, decides what your agents do on the next update.
SRCF="$ROOT/setup/schema/sources.yaml"
if [ -f "$SRCF" ]; then
  smiss=0
  for cat in skills apps; do
    for k in $(yq -r ".$cat | keys | .[]" "$SRCF" 2>/dev/null); do
      [ "$(q "$CFG" ".$cat.$k")" = true ] || continue
      kind="$(yq -r ".$cat.$k.kind // \"\"" "$SRCF" 2>/dev/null)"
      [ -n "$kind" ] || { fail "$cat.$k=true but sources.yaml gives it no 'kind'"; smiss=1; continue; }
      case "$kind" in
        git) [ -n "$(yq -r ".$cat.$k.repo // \"\"" "$SRCF")" ] && [ -n "$(yq -r ".$cat.$k.pin // \"\"" "$SRCF")" ] \
               || { fail "$cat.$k=true but has no repo+pin — a skill must be pinned, never a floating branch"; smiss=1; } ;;
        flatpak) [ -n "$(yq -r ".$cat.$k.id // \"\"" "$SRCF")" ] || { fail "$cat.$k=true but has no flatpak id"; smiss=1; } ;;
      esac
    done
  done
  for k in $(yq -r '.agents | keys | .[]' "$SRCF" 2>/dev/null); do
    [ "$(q "$CFG" ".agents.$k")" = true ] || continue
    [ "$(yq -r ".agents.$k.kind" "$SRCF")" = npm ] || continue
    [ -n "$(yq -r ".agents.$k.pin // \"\"" "$SRCF")" ] || { fail "agents.$k has no pinned version in sources.yaml"; smiss=1; }
  done
  [ "$smiss" -eq 0 ] && ok "every enabled skill/app/agent has a pinned source"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "[validate] PASS"; exit 0
else echo "[validate] FAIL ($FAILS violation(s))" >&2; exit 1; fi
