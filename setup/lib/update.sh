#!/usr/bin/env bash
# update.sh — keep the things you actually use current: agents, skills, desktop apps, and uu
# itself. Backs `uu update` (SG11 facade).
#
# THE RULE THIS FILE OBEYS: bare `uu update` CHANGES NOTHING. It reports what is installed, what
# is behind, and prints the exact command for each. You have to name a category to mutate
# anything. Read first, act deliberately.
#
# WHY THINGS LIVE WHERE THEY DO
#   agents  npm packages installed at a pinned version into ~/Agents/versions/<stamp>, with
#           ~/Agents/current repointed afterwards. No image rebuild and no box recreate: every
#           box picks the new version up immediately because it is on PATH via that symlink.
#   skills  instructions the agents READ. Pinned in setup/schema/sources.yaml; marketplace ones
#           go through the agent's own installer (already SHA-pinned upstream).
#   apps    Flatpaks on the HOST. Never rpm layering: on an image-based OS that means a reboot.
#           One install; per-box separation comes from the browser PROFILE, not a second copy.
#   self    uu + the QoL scripts, redeployed into every profile from this repo.
#
# NOTHING HERE DELETES DATA. Updates add a new version directory and move a symlink; the old
# version stays for rollback. Profiles are never touched except to add/refresh a symlink, and an
# existing real directory is never replaced by one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$ROOT/setup/schema/sources.yaml"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[ -t 1 ] || { B=""; G=""; Y=""; D=""; N=""; }
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf 'uu update: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf 'hint: %s\n' "$2" >&2; exit "${3:-1}"; }

in_box()  { [ -f /run/.containerenv ]; }
hrun()    { if in_box; then distrobox-host-exec "$@"; else "$@"; fi; }
have()    { command -v "$1" >/dev/null 2>&1; }

# The agent tree lives in the HOST home so every box shares one copy. Inside a box $HOME is that
# box's profile, so the host home has to be asked for explicitly.
if in_box; then HOST_HOME="$(hrun bash -c 'echo $HOME' 2>/dev/null || echo "$HOME")"
else HOST_HOME="$HOME"; fi
AGENTS_DIR="$HOST_HOME/Agents"
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY=0; YES=0; PRUNE=0; ROLLBACK=""; declare -a WANT=()
while [ "$#" -gt 0 ]; do case "$1" in
  --dry-run)  DRY=1 ;;
  --yes|-y)   YES=1 ;;
  --all)      WANT=(repo self agents skills apps) ;;
  --rollback) ROLLBACK="${2:-agents}"; shift ;;
  --prune)    PRUNE=1 ;;
  -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
  -*)         die "unknown option '$1'" "uu update   # shows what is available" ;;
  *)          WANT+=("$1") ;;
esac; shift; done

run() { if [ "$DRY" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$D" "$N" "$*"; return 0; fi; "$@"; }
# Same as run(), but silences a chatty command's output ONLY on a real run. Writing
# `run cmd >/dev/null` instead would swallow the [dry-run] line too, so a plan would show a tick
# for a command it never printed — claiming something happened that did not.
runq() { if [ "$DRY" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$D" "$N" "$*"; return 0; fi; "$@" >/dev/null 2>&1; }
confirm() {
  [ "$YES" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  [ -r /dev/tty ] || die "this needs a yes/no answer but nothing is attached to type on" "re-run with --yes if you meant it unattended" 1
  local r; printf '  %s? %s [y/N] ' "$B" "$1$N"; read -r r </dev/tty || r=""
  case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- reading the manifests ----------
merged="$(merge_config "$ROOT" 2>/dev/null)"
toggled() { [ "$(cfg_get "$merged" ".$1.$2" false)" = true ]; }
src()     { yq -r ".$1.$2.$3 // \"\"" "$SRC" 2>/dev/null; }
names()   { yq -r ".$1 | keys | .[]" "$SRC" 2>/dev/null; }

# ---------- status (the default; changes nothing) ----------
installed_agent_version() {           # <bin> -> version string from the live tree
  local b="$1" p="$AGENTS_DIR/current/lib/node_modules"
  local pkg; pkg="$(src agents "$2" package)"
  [ -f "$p/$pkg/package.json" ] || { printf '%s' ""; return; }
  node -e "try{console.log(require('$p/$pkg/package.json').version)}catch(e){}" 2>/dev/null
}

status() {
  head1 "uu update — what can be updated (this screen changes nothing)"
  say "  ${D}agents dir: $AGENTS_DIR${N}"

  head1 "agents        pinned in setup/schema/sources.yaml"
  local n kind pin bin cur
  for n in $(names agents); do
    toggled agents "$n" || continue
    kind="$(src agents "$n" kind)"; pin="$(src agents "$n" pin)"; bin="$(src agents "$n" bin)"
    if [ "$kind" = image ]; then
      printf '  %-12s %-12s %s\n' "$n" "(image)" "updates with dev_base — uu rebuild, then recreate"
      continue
    fi
    cur="$(installed_agent_version "$bin" "$n")"
    if [ -z "$cur" ]; then printf '  %-12s %-12s %s\n' "$n" "$pin" "not installed here yet"
    elif [ "$cur" = "$pin" ]; then printf '  %-12s %-12s %s\n' "$n" "$cur" "current"
    else printf '  %-12s %-12s %s\n' "$n" "$cur -> $pin" "uu update $n"; fi
  done
  say "  ${D}update all:  uu update agents   ·   disk: $(du -sh "$AGENTS_DIR" 2>/dev/null | cut -f1) in $(ls -1d "$AGENTS_DIR"/versions/*/ 2>/dev/null | wc -l) version(s), prune: uu update --prune${N}"

  head1 "skills        instructions your agents read — pinned on purpose"
  for n in $(names skills); do
    if ! toggled skills "$n"; then
      printf '  %-14s %-10s %s\n' "$n" "off" "enable in config.yaml (set its source first)"
      continue
    fi
    kind="$(src skills "$n" kind)"
    case "$kind" in
      marketplace) printf '  %-14s %-10s %s\n' "$n" "plugin" "from $(src skills "$n" marketplace) (SHA-pinned upstream)" ;;
      git) if [ -z "$(src skills "$n" repo)" ]; then
             printf '  %-14s %-10s %s\n' "$n" "NO SOURCE" "set repo+pin in setup/schema/sources.yaml"
           else printf '  %-14s %-10s %s\n' "$n" "$(src skills "$n" pin)" "$(src skills "$n" repo)"; fi ;;
    esac
  done
  say "  ${D}update all:  uu update skills${N}"

  head1 "apps          Flatpaks on the host (browser data stays per box)"
  local ids; ids="$(hrun flatpak list --app --columns=application 2>/dev/null || true)"
  for n in $(names apps); do
    toggled apps "$n" || { printf '  %-12s %-14s %s\n' "$n" "off" "enable in config.yaml"; continue; }
    local id; id="$(src apps "$n" id)"
    if grep -qx "$id" <<<"$ids"; then printf '  %-12s %-14s %s\n' "$n" "installed" "$id"
    else printf '  %-12s %-14s %s\n' "$n" "not installed" "uu update $n"; fi
  done
  say "  ${D}update all:  uu update apps${N}"

  head1 "self          uu, aliases, tmux, uu-askpass — from this repo"
  local behind; behind="$(git -C "$ROOT" rev-list --count HEAD..@{u} 2>/dev/null || echo "?")"
  if [ "$behind" = 0 ]; then ok "uu is up to date with the remote"
  elif [ "$behind" = "?" ]; then say "  (no upstream configured — nothing to compare against)"
  else warn "$behind newer commit(s) on the remote — uu update repo"; fi
  say "  ${D}redeploy into every profile:  uu update self${N}"

  head1 "everything"
  say "      uu update --all           repo -> self -> agents -> skills -> apps"
  say "      uu update --dry-run --all show the plan, do nothing"
  say "      uu update --rollback agents   go back to the previous agent version"
  say ""
}

# ---------- agents ----------
agents_update() {
  have npm || die "npm is not available here" "run this from inside a box (uu enter os_agent), where node/npm live" 3
  local dest="$AGENTS_DIR/versions/$STAMP" n pkg pin any=0
  head1 "agents -> $dest"
  for n in $(names agents); do
    toggled agents "$n" || continue
    [ "$(src agents "$n" kind)" = npm ] || continue
    pkg="$(src agents "$n" package)"; pin="$(src agents "$n" pin)"
    [ -n "$pkg" ] && [ -n "$pin" ] || { warn "$n has no package/pin in sources.yaml — skipped"; continue; }
    any=1
    # </dev/null and a timeout, both deliberately: a package's postinstall script can block on
    # input nobody can answer, or simply never return, and without these `uu update` wedges
    # forever with no way to tell what it is waiting for. Same lesson as the distrobox
    # create-prompt: never let a child process wait on a prompt you cannot see.
    if run timeout "${UU_NPM_TIMEOUT:-300}" npm install -g --prefix "$dest" \
         --no-fund --no-audit --loglevel=error "$pkg@$pin" </dev/null; then
      ok "$n $pin"
    else
      # A HALF-installed agent is worse than an absent one: npm writes the bin shim before the
      # postinstall runs, so a broken shim would sit on PATH and shadow the working copy baked
      # into the image. Remove both, so this agent simply falls through to the image version.
      [ "$DRY" = 1 ] || rm -rf "$dest/lib/node_modules/$pkg" "$dest/bin/$(src agents "$n" bin)"
      warn "$n failed (timeout or postinstall) — removed from this version; the image copy still works"
    fi
  done
  [ "$any" = 1 ] || { warn "no npm agents enabled"; return 0; }
  [ "$DRY" = 1 ] && { say "  ${D}[dry-run] would repoint $AGENTS_DIR/current -> versions/$STAMP${N}"; return 0; }
  # Atomic swap of the SYMLINK, never of the directory: a bind mount follows the inode, so moving
  # a mounted directory leaves every running box pointing at the old one (this bit us once).
  ln -sfn "versions/$STAMP" "$AGENTS_DIR/.current.new" && mv -T "$AGENTS_DIR/.current.new" "$AGENTS_DIR/current"
  ok "current -> versions/$STAMP  (previous versions kept for rollback)"
  say "  ${D}open a new shell, or: exec bash${N}"
}

# Old versions are what makes rollback instant, but a full agent tree is GBs — so they are kept
# deliberately and removed only when you ask. Never touches `current` or the one before it.
agents_prune() {
  local keep=2 cur old n=0
  cur="$(readlink -f "$AGENTS_DIR/current" 2>/dev/null)"
  head1 "prune old agent versions (keeping current + $((keep - 1)) previous)"
  mapfile -t old < <(ls -1d "$AGENTS_DIR"/versions/*/ 2>/dev/null | sed 's:/$::' | head -n -"$keep")
  [ "${#old[@]}" -gt 0 ] || { ok "nothing to prune"; return 0; }
  for d in "${old[@]}"; do
    [ "$(readlink -f "$d")" = "$cur" ] && continue
    say "  would remove: $(basename "$d")  ($(du -sh "$d" 2>/dev/null | cut -f1))"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || { ok "nothing to prune"; return 0; }
  [ "$DRY" = 1 ] && return 0
  confirm "remove those $n old version(s)?" || { say "  nothing changed."; return 0; }
  for d in "${old[@]}"; do [ "$(readlink -f "$d")" = "$cur" ] || run rm -rf "$d"; done
  ok "pruned"
}

agents_rollback() {
  local prev
  prev="$(ls -1d "$AGENTS_DIR"/versions/*/ 2>/dev/null | sed 's:/$::' | tail -2 | head -1)"
  [ -n "$prev" ] && [ "$prev" != "$(readlink -f "$AGENTS_DIR/current")" ] \
    || die "no previous agent version to roll back to" "uu update agents   # installs one first" 3
  confirm "roll agents back to $(basename "$prev")?" || { say "  nothing changed."; return 0; }
  ln -sfn "versions/$(basename "$prev")" "$AGENTS_DIR/.current.new" && mv -T "$AGENTS_DIR/.current.new" "$AGENTS_DIR/current"
  ok "rolled back to $(basename "$prev")"
}

# ---------- skills ----------
skills_update() {
  local n kind
  head1 "skills"
  for n in $(names skills); do
    toggled skills "$n" || continue
    kind="$(src skills "$n" kind)"
    case "$kind" in
      marketplace)
        local mp plug; mp="$(src skills "$n" marketplace)"; plug="$(src skills "$n" plugin)"
        if ! have claude; then warn "$n needs the claude CLI (run from inside a box) — skipped"; continue; fi
        runq claude plugin install "$plug@$mp" \
          && ok "$n installed/updated from $mp" \
          || warn "$n: claude plugin install failed (already installed? try: claude plugin list)"
        ;;
      git)
        local repo pin; repo="$(src skills "$n" repo)"; pin="$(src skills "$n" pin)"
        if [ -z "$repo" ] || [ -z "$pin" ]; then
          warn "$n has no repo/pin in setup/schema/sources.yaml — skipped ON PURPOSE"
          say  "      A skill is instructions your agents obey. Pick the repo yourself and pin a"
          say  "      tag or SHA, then re-run. Nothing here will choose one for you."
          continue
        fi
        local dest="$AGENTS_DIR/skills/versions/$STAMP/$n"
        run mkdir -p "$dest"
        if run git clone --quiet --depth 1 --branch "$pin" "$repo" "$dest" 2>/dev/null \
           || run git clone --quiet "$repo" "$dest"; then
          [ "$DRY" = 1 ] || git -C "$dest" checkout --quiet "$pin" 2>/dev/null || true
          ok "$n @ $pin"
          # Executable content is the part worth looking at before you trust it.
          local hooks; hooks="$(find "$dest" -maxdepth 2 \( -name 'hooks' -o -name '*.sh' \) 2>/dev/null | head -3)"
          [ -n "$hooks" ] && warn "$n ships executable content — worth reading before you rely on it"
        else warn "$n: clone failed"; fi
        ;;
    esac
  done
  skills_link_into_profiles
}

# Symlink shared skills into each profile's skills dir. Never replaces a real directory: if you
# hand-wrote a skill of the same name, yours wins and we say so.
skills_link_into_profiles() {
  local cur="$AGENTS_DIR/skills/current" p name
  [ -d "$cur" ] || return 0
  for p in "$HOST_HOME/Profiles"/*/; do
    [ -d "$p" ] || continue
    run mkdir -p "$p/.claude/skills"
    for d in "$cur"/*/; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      if [ -e "$p/.claude/skills/$name" ] && [ ! -L "$p/.claude/skills/$name" ]; then
        warn "$(basename "${p%/}"): a real directory named '$name' already exists — left alone"
        continue
      fi
      run ln -sfn "$d" "$p/.claude/skills/$name"
    done
  done
}

# ---------- apps ----------
apps_update() {
  have flatpak || hrun true 2>/dev/null || die "flatpak not reachable" "install flatpak on the host" 3
  head1 "apps (host Flatpaks, per-user install — no sudo, no reboot)"
  # Fedora's own remote carries only a subset; the rest live on Flathub.
  local remotes; remotes="$(hrun flatpak remotes --columns=name 2>/dev/null || true)"  # capture: pipefail note in CLAUDE.md
  if ! grep -qx flathub <<<"$remotes"; then
    say "  Flathub is not configured yet; it is where most of these live."
    if confirm "add the Flathub remote (per-user)?"; then
      runq hrun flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
        && ok "flathub added" || warn "could not add flathub"
    fi
  fi
  local n id
  for n in $(names apps); do
    toggled apps "$n" || continue
    id="$(src apps "$n" id)"; [ -n "$id" ] || continue
    runq hrun flatpak install -y --user --noninteractive flathub "$id" \
      && ok "$n ($id)" || warn "$n ($id) — not installed; check: flatpak search $id"
  done
  runq hrun flatpak update -y --user --noninteractive
  ok "flatpak update finished"
  say "  ${D}browsers open with THIS box's profile — see 'uu aliases apps'${N}"
}

# ---------- self / repo ----------
repo_update() {
  head1 "repo"
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    # A plan must show the WHOLE plan. Aborting here would hide every later category behind a
    # problem the user has not asked to fix yet.
    [ "$DRY" = 1 ] && { warn "uncommitted changes — a real run would stop here (commit or stash first)"; return 0; }
    die "the project has uncommitted changes — pulling could clobber them" \
        "commit or stash first: git -C $ROOT status" 3
  fi
  local range; range="$(git -C "$ROOT" log --oneline HEAD..@{u} 2>/dev/null | head -20)"
  [ -n "$range" ] || { ok "already up to date"; return 0; }
  say "  incoming:"; printf '      %s\n' "$range"
  say "  ${D}Pulling runs code from the remote on your machine — read the list above.${N}"
  confirm "pull these?" || { say "  nothing changed."; return 0; }
  run git -C "$ROOT" pull --ff-only && ok "pulled" || warn "pull failed (not a fast-forward?)"
}

self_update() {
  head1 "self — uu, aliases, tmux, uu-askpass into every profile"
  local p
  for p in "$HOST_HOME/Profiles"/*/; do
    [ -d "$p" ] || continue
    runq bash "$SCRIPT_DIR/deploy-aliases.sh" "${p%/}"
    runq bash "$SCRIPT_DIR/deploy-tmux.sh"    "${p%/}"
    runq bash "$SCRIPT_DIR/deploy-uu.sh"      "${p%/}"
    ok "$(basename "${p%/}")"
  done
  say "  ${D}open a new shell to pick it up: exec bash${N}"
}

# ---------- dispatch ----------
[ "$PRUNE" = 1 ] && { agents_prune; exit 0; }
[ -n "$ROLLBACK" ] && { case "$ROLLBACK" in agents) agents_rollback; exit 0 ;; *) die "rollback is only implemented for 'agents'" "uu update --rollback agents" 3 ;; esac; }
[ "${#WANT[@]}" -eq 0 ] && { status; exit 0; }

for w in "${WANT[@]}"; do case "$w" in
  agents) agents_update ;;
  skills) skills_update ;;
  apps)   apps_update ;;
  self)   self_update ;;
  repo)   repo_update ;;
  *)
    # A bare name: update just that one thing, wherever it is declared.
    if   yq -e ".agents.$w" "$SRC" >/dev/null 2>&1; then agents_update
    elif yq -e ".skills.$w" "$SRC" >/dev/null 2>&1; then skills_update
    elif yq -e ".apps.$w"   "$SRC" >/dev/null 2>&1; then apps_update
    else die "don't know how to update '$w'" "uu update   # lists everything it knows" 3; fi ;;
esac; done
