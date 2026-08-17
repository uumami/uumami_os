#!/usr/bin/env bash
# work.sh — session launcher (SG10.5). Runs INSIDE a tenant box. A session is runtime
# granularity within the wall: same credentials, a chosen agent/model/workdir/browser-profile.
# It reads the per-tenant descriptor written by tenant-create (~/.config/uumami/tenant.yaml).
#
# tmux precedence (SG11 owns ~/.tmux.conf + the bare-entry auto-attach): a bare `distrobox enter`
# lands you in the default session; `work <name>` OVERRIDES that with the named session. No
# double-attach — `tmux new-session -A` attaches if it exists, else creates it.
#
# Usage:  work <session>        (or: work --list)
set -euo pipefail

DESC="${UUMAMI_TENANT_DESC:-$HOME/.config/uumami/tenant.yaml}"
if [ ! -f "$DESC" ]; then
  cat >&2 <<EOF
work: this box has no session list yet, so there is nothing to launch.

  A "session" is a saved setup — which agent, which model, which folder — that you can
  switch between. The list lives in:
      $DESC

  Create it (safe, takes a second, changes nothing else):
      uu repair

  Then see what you have:
      work --list
EOF
  exit 3
fi

command -v yq >/dev/null 2>&1 || {
  cat >&2 <<EOF
work: 'yq' (the settings reader) is not installed in this box.
  Fix it with:   uu repair
EOF
  exit 3; }

list_sessions() { yq -r '(.sessions // [])[].name' "$DESC"; }

if [ "${1:-}" = "--list" ] || [ "$#" -eq 0 ]; then
  echo "tenant: $(yq -r '.name' "$DESC")  (tier $(yq -r '.tier' "$DESC"), browser $(yq -r '.browser' "$DESC"))"
  echo "sessions:"; list_sessions | sed 's/^/  - /'
  [ "$#" -eq 0 ] && exit 0 || exit 0
fi

session="$1"
found="$(S="$session" yq -r '(.sessions // [])[] | select(.name == env(S)) | .name' "$DESC" 2>/dev/null)"
[ -n "$found" ] || { echo "work: no session '$session'. Available:" >&2; list_sessions | sed 's/^/  - /' >&2; exit 1; }

agent="$(S="$session" yq -r '(.sessions // [])[] | select(.name==env(S)) | .agent // ""' "$DESC")"
model="$(S="$session" yq -r '(.sessions // [])[] | select(.name==env(S)) | .model // ""' "$DESC")"
[ -n "$model" ] || model="$(yq -r '.model // ""' "$DESC")"
wd_rel="$(S="$session" yq -r '(.sessions // [])[] | select(.name==env(S)) | .workdir // "."' "$DESC")"
bprof="$(S="$session" yq -r '(.sessions // [])[] | select(.name==env(S)) | .browser_profile // ""' "$DESC")"

# Resolve the working directory under the code mount (/workspace).
workdir="/workspace/${wd_rel#./}"; workdir="${workdir%/}"; [ -d "$workdir" ] || workdir="/workspace"

# Session env: model + loopback endpoint + browser profile, exported for the agent.
export UUMAMI_SESSION="$session" UUMAMI_AGENT="$agent" UUMAMI_MODEL="$model"
export OLLAMA_HOST="127.0.0.1:11434"
[ -n "$bprof" ] && export UUMAMI_BROWSER_PROFILE="$HOME/.local/share/uumami-browser/$bprof"

echo "[work] session=$session agent=${agent:-?} model=${model:-?} dir=$workdir"
echo "[work] start your agent in the pane, e.g.:  ${agent:-<agent>}"

if command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s "$session" -c "$workdir"
else
  echo "[work] tmux not found — opening a shell in $workdir"
  cd "$workdir" && exec "${SHELL:-/bin/bash}"
fi
