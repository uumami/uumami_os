#!/usr/bin/env bash
# install.sh — the ONE command that sets up uumami_os. Written for someone who does not
# code: it explains each step in plain language, asks before doing anything, and can be run
# again at any time — it continues where it stopped and repairs what is broken, it never
# starts over or damages what already works.
#
#   bash install.sh              guided install / resume / repair
#   bash install.sh --status     what is done and what is left (changes nothing)
#   bash install.sh --dry-run    show every action without doing any of it
#   bash install.sh --yes        don't ask, just do it (for people who know the drill)
#   bash install.sh --repair     re-run the safe fix-ups (aliases, uu, config pointers)
#
# Design rules this file obeys:
#   • Never claim success for something that did not happen.
#   • Never continue past a missing prerequisite (that is how you get a half-built machine).
#   • Every host-mutating step is announced before it runs, and skipped if already done.
#   • Anything needing sudo or a reboot is PRINTED for the human, never run silently.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/setup/lib"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/uumami"
STATE="$STATE_DIR/install-state"

DRY=0; YES=0; ONLY=""; MODE=install
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  --yes|-y)  YES=1 ;;
  --status)  MODE=status ;;
  --repair)  MODE=repair ;;
  --only)    ONLY=NEXT ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  *) if [ "$ONLY" = NEXT ]; then ONLY="$a"; else echo "install: unknown option '$a' (try --help)" >&2; exit 1; fi ;;
esac; done
[ "$ONLY" = NEXT ] && { echo "install: --only needs a step name" >&2; exit 1; }

# ---------- presentation ----------
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
[ -t 1 ] || { B=""; G=""; Y=""; R=""; D=""; N=""; }
say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok()    { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()   { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; }
step_n=0

# ---------- state ----------
mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$STATE" ] || : > "$STATE"
is_done()   { grep -qx "$1=done" "$STATE" 2>/dev/null; }
mark_done() { [ "$DRY" = 1 ] && return 0; grep -vx "$1=done" "$STATE" > "$STATE.tmp" 2>/dev/null || true
              mv -f "$STATE.tmp" "$STATE"; echo "$1=done" >> "$STATE"; }

# ---------- helpers ----------
in_box() { [ -f /run/.containerenv ]; }
# Inside a box the host filesystem is visible under /run/host — but a command the human is
# meant to type in a HOST terminal must not carry that prefix.
host_path() { printf '%s' "${1#/run/host}"; }
# The host user's home. Identical to $HOME in normal (host) use; only differs when someone
# runs --status/--dry-run from inside a box, where $HOME is that box's profile directory.
if in_box; then HOST_HOME="$(distrobox-host-exec bash -c 'echo $HOME' 2>/dev/null || echo "$HOME")"
else HOST_HOME="$HOME"; fi
run() { # run <command...> — respects --dry-run
  if [ "$DRY" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$D" "$N" "$*"; return 0; fi
  "$@"
}
# Run something on the HOST. Identical to running it directly in normal use; only matters when
# someone inspects status from inside a box, where podman/distrobox are the box's own.
onhost() { if in_box; then distrobox-host-exec "$@"; else "$@"; fi; }

# probe_step <name> -> done | todo
# Answers "is this ACTUALLY true on the machine right now", not "did we tick it off". A machine
# set up by hand (or before this installer existed) is genuinely done; saying otherwise sends
# people back to redo work they have already completed.
probe_step() {
  case "$1" in
    prereqs)  bash "$LIB/preflight.sh" --quiet >/dev/null 2>&1 ;;
    location) [ "$(host_path "$ROOT")" = "$HOST_HOME/Containers" ] \
                && ! onhost test -d "$HOST_HOME/Containers.old" 2>/dev/null ;;
    config)   bash "$LIB/validate.sh" >/dev/null 2>&1 ;;
    # Check the IMAGE, not just the name. A box called llm_server built from fedora-toolbox is
    # the wreckage of distrobox's "create it now?" prompt: right name, none of the contents.
    server)   [ "$(onhost podman inspect llm_server --format '{{.ImageName}}' 2>/dev/null)" = "localhost/llm_server:latest" ] ;;
    boxes)    [ "$(onhost podman inspect os_agent --format '{{.ImageName}}' 2>/dev/null)" = "localhost/os_agent:latest" ] ;;
    shell)    onhost test -x "$HOST_HOME/.local/bin/uu" 2>/dev/null ;;
    verify)   is_done verify ;;
    *)        false ;;
  esac && echo done || echo todo
}
ask() { # ask <question> — Yes/no. Never guesses.
  [ "$YES" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  # No keyboard attached (piped, double-clicked, run from a script)? Guessing "yes" here would
  # move and replace the user's files without them ever seeing the question. Stop instead.
  if [ ! -r /dev/tty ]; then
    printf '\n'
    bad "this step needs a yes/no answer from you, but nothing is connected to type on."
    say "    Open a terminal window and run it there:"
    say "        bash $(host_path "$ROOT")/install.sh"
    say "    Or, if you meant to run it unattended and accept every question:"
    say "        bash $(host_path "$ROOT")/install.sh --yes"
    exit 1
  fi
  local r
  printf '  %s? %s [Y/n] ' "$B" "$1$N"
  read -r r </dev/tty || r=""
  case "$r" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# move_into_place <src> <dest> — move a directory to an exact path.
# Plain `mv src dest` is a trap: when dest already exists it moves src INSIDE it, producing
# dest/src instead of dest, with no error. That silently creates the "two copies in the wrong
# place" mess this whole step exists to prevent.
move_into_place() {
  local src="$1" dest="$2"
  if [ -e "$dest" ]; then
    if [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
      run rmdir "$dest"                       # empty folder: just get it out of the way
    else
      bad "cannot move: '$dest' already exists and is not empty."
      say "    Move or rename it first, then run this again:"
      say "        mv $dest ${dest}-old"
      return 1
    fi
  fi
  run mv "$src" "$dest"
}
pause_for_human() { # the step needs a person; explain and stop cleanly
  printf '\n%s─── this step needs you ───%s\n' "$Y" "$N"
  printf '%s\n' "$1"
  printf '\n%sWhen that is done, run this again to continue:%s\n    bash %s/install.sh\n' "$B" "$N" "$(host_path "$ROOT")"
  exit 2
}

# =====================================================================================
# STEPS. Each is `step_<name>`: it must be safe to run twice, and it must verify reality
# rather than trusting the state file (a box someone deleted by hand must be noticed).
# =====================================================================================
STEPS=(prereqs location config server boxes shell verify)
step_title() { case "$1" in
  prereqs)  echo "Check this machine can run it" ;;
  location) echo "Put the project files in one known place" ;;
  config)   echo "Describe your hardware (config + flavor)" ;;
  server)   echo "Build and start the local AI model server" ;;
  boxes)    echo "Build your isolated dev box" ;;
  shell)    echo "Install the 'uu' command and shortcuts" ;;
  verify)   echo "Check everything really works" ;;
esac; }

# --- 0. is this a complete copy of the project? ------------------------------
# A half-extracted zip, or install.sh copied out of its folder, otherwise surfaces later as a
# confusing "software is missing" or a bare "No such file or directory". Name the real problem.
check_project_files() {
  local missing=() f
  for f in setup/lib/preflight.sh setup/lib/config.sh setup/lib/build.sh setup/lib/tenant-create.sh \
           setup/bin/uu setup/test/selftest.sh config.yaml images/dev_base/modules; do
    [ -e "$ROOT/$f" ] || missing+=("$f")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  bad "this folder is not a complete copy of the project."
  say "    Looking in: $(host_path "$ROOT")"
  say "    Missing:"
  for f in "${missing[@]}"; do say "      - $f"; done
  say ""
  say "  This usually means you are in the wrong folder, the download was incomplete, or"
  say "  install.sh was copied out of the folder it belongs to."
  say ""
  say "  Unzip the project again, then run install.sh from INSIDE the folder it creates:"
  say "      cd ~/Downloads && unzip uumami_os.zip && ls"
  say "      cd <the folder name ls showed you>"
  say "      bash install.sh"
  exit 1
}

# --- 1. prerequisites --------------------------------------------------------
step_prereqs() {
  bash "$LIB/preflight.sh" || pause_for_human \
"Some required software is missing. The list above shows exactly what to install
and the command to install it. Nothing has been built or changed on your machine."
  mark_done prereqs
}

# --- 2. repo location --------------------------------------------------------
# The single most common way this install goes wrong: the files end up in one folder while
# the tools look in another, or two copies exist and edits go to the wrong one.
# A bind mount follows the INODE, not the path. Moving or replacing the project directory
# leaves every already-running box mounting the OLD directory at /containers — and dangling if
# that copy is later deleted. Nothing breaks (boxes reach the project through /run/host), but a
# silently empty /containers looks like data loss, so say it plainly and name the boxes.
warn_running_boxes_stale_mount() {
  local running
  running="$(onhost podman ps --format '{{.Names}}' 2>/dev/null || true)"
  [ -n "$running" ] || return 0
  say ""
  warn "boxes that are running right now still point at the OLD folder:"
  say  "$(printf '      %s\n' $running)"
  say  "    Their /containers will be empty until they are restarted. Nothing is lost — they"
  say  "    reach the project through /run/host either way. To refresh one:"
  say  "        uu recreate <box>        # or just restart it"
}

step_location() {
  local canonical="$HOST_HOME/Containers" here; here="$(host_path "$ROOT")"
  echo "$ROOT" > "$STATE_DIR/repo" 2>/dev/null || true

  if [ "$here" = "$canonical" ]; then
    ok "project files are in the standard place: $canonical"
  elif [ -d "$canonical/setup/lib" ]; then
    bad "there are TWO copies of this project:"
    say  "      A) $here       <- the one you are running now"
    say  "      B) $canonical  <- another copy"
    say  "    Editing one and running the other is the #1 cause of confusing failures."
    if ask "replace the other copy with this one? (the old one is kept, renamed .old)"; then
      run rm -rf "$canonical.old"
      run mv "$canonical" "$canonical.old"
      run cp -a "$ROOT" "$canonical"
      ok "copied into $canonical"
      say "    Nothing was deleted. You now have three folders, on purpose:"
      say "      $canonical       <- the one to use from now on"
      say "      $canonical.old   <- the copy that used to be there"
      say "      $here            <- where you ran this from"
      say ""
      say "  ${B}Continue from the new folder — copy this line:${N}"
      say "      cd $canonical && bash install.sh"
      say ""
      say "  Once you are happy it all works, delete the two leftovers so you are not"
      say "  editing the wrong one later:"
      say "      rm -rf '$canonical.old' '$here'"
      warn_running_boxes_stale_mount
      [ "$DRY" = 0 ] && exit 0
    else
      warn "keeping both — recording $here as the one to use"
    fi
  else
    say "  The standard location for this project is: $canonical"
    say "  Yours is currently at:                     $here"
    if ask "move it to the standard location? (recommended — every guide assumes it)"; then
      move_into_place "$ROOT" "$canonical" || return 1
      ok "moved to $canonical"
      say ""
      say "  ${B}The files are in a new folder now, so continue from there — copy this line:${N}"
      say "      cd $canonical && bash install.sh"
      warn_running_boxes_stale_mount
      [ "$DRY" = 0 ] && exit 0
    else
      # Honour their choice: teach the config where the files actually are, so the
      # /containers mount and `uu` point at the real path instead of a guess.
      warn "staying at $ROOT — updating config.yaml to match"
      if [ -f "$ROOT/config.yaml" ] && command -v yq >/dev/null 2>&1; then
        run env P="$ROOT" yq -i '.paths.containers = env(P)' "$ROOT/config.yaml"
      fi
    fi
  fi
  mark_done location
}

# --- 3. config + flavor ------------------------------------------------------
step_config() {
  bash "$LIB/ensure-yq.sh" >/dev/null 2>&1 || true
  export PATH="$HOME/.local/bin:$PATH"

  if [ "$DRY" = 1 ]; then printf '  %s[dry-run]%s bootstrap.sh (probe hardware, match flavor)\n' "$D" "$N"; return 0; fi

  local out rc
  out="$(bash "$LIB/bootstrap.sh" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'

  if printf '%s' "$out" | grep -q 'flavor-request.md'; then
    # Name the exact target file rather than saying "the name shown in the file" — bootstrap
    # already worked it out, and a vague filename is where a non-technical user stalls.
    local fname
    fname="$(printf '%s' "$out" | sed -n 's|.*flavors/\([a-zA-Z0-9._-]*\)\.yaml.*|\1|p' | head -1)"
    [ -n "$fname" ] || fname="<name-shown-in-the-file>"
    pause_for_human \
"Your graphics hardware has no ready-made settings file yet, so one has to be written for
your specific machine. This is copy-and-paste — you are not writing any code.

  1. Open this file in a text editor:
         $(host_path "$ROOT")/setup/flavor-request.md
     (double-click it in your file manager, or run:  xdg-open '$(host_path "$ROOT")/setup/flavor-request.md' )

  2. Select everything in it and copy it (Ctrl-A then Ctrl-C).

  3. Open any AI chat in your web browser — ChatGPT, Claude or Gemini — paste it in,
     and send it. It already contains everything the chat needs to know.

  4. The chat replies with a block of text that starts with lines like 'gpu:' and 'model:'.
     Copy that reply and save it as a new file at exactly this path:
         $(host_path "$ROOT")/flavors/${fname}.yaml

     The filename must match exactly, including '.yaml' at the end.

  5. Come back here and run the installer again — it will check the file for you and tell
     you if anything is wrong with it."
  fi

  if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -q 'validate. FAIL'; then
    pause_for_human \
"Your settings have problems. Each one is listed above with a ✗ and says what is wrong.

  The settings file is:
      $(host_path "$ROOT")/config.yaml

  Every setting is explained here:
      $(host_path "$ROOT")/setup/schema/MANIFEST.md

  If you did not change anything by hand, the most likely cause is that the hardware
  settings file from step 3 is incomplete — ask the AI chat to fix the specific ✗ lines
  above and save its corrected reply over the same file."
  fi
  ok "configuration is valid"
  mark_done config
}

# --- 4. model server ---------------------------------------------------------
step_server() {
  if podman container exists llm_server 2>/dev/null; then
    ok "model server box already exists"
  else
    say "  This builds the AI model server and gives it access to your GPU."
    say "  It downloads a few GB and takes several minutes."
    ask "build the model server now?" || { warn "skipped — run 'bash install.sh' again when ready"; return 0; }
    run bash "$LIB/llm_server.sh" || { bad "the model server build failed (output above)"; return 1; }
  fi

  if systemctl --user is-active llm_server.service >/dev/null 2>&1; then
    ok "model server is running"
  else
    ask "start the model server automatically at login?" && run bash "$LIB/install-llm-service.sh"
  fi

  # A model must actually be downloaded, or the whole thing looks "installed" but answers nothing.
  local model tags
  model="$(bash -c '. '"$LIB"'/config.sh; m=$(merge_config "'"$ROOT"'"); cfg_get "$m" .model.primary qwen3-coder:30b' 2>/dev/null)"
  tags="$(curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags 2>/dev/null)"
  if printf '%s' "$tags" | grep -q "\"${model%%:*}"; then
    ok "model '$model' is downloaded"
  else
    say "  No model is downloaded yet. '$model' is the one chosen for your hardware"
    say "  (this is a large download — often 15-20 GB)."
    if ask "download it now?"; then
      # Guard the box's existence: `distrobox enter` on a missing box asks whether to create a
      # generic one instead of failing, which is never what we want here.
      if podman container exists llm_server 2>/dev/null; then
        # `podman container exists` turns true the instant the container is created, but
        # distrobox's first-run init — which creates your user account INSIDE the box — takes
        # several more seconds. Entering during that window dies with a bare
        #   'unable to find user <you>: no matching entries in passwd file'
        # which reads like a broken install when it is only a race. A 200 from the loopback
        # API proves both that init finished and that ollama is actually serving.
        local waited=0
        until curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; do
          [ "$waited" = 0 ] && say "  waiting for the model server to finish starting up..."
          waited=$((waited + 2)); sleep 2
          [ "$waited" -ge 120 ] && break
        done
        if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
          run distrobox enter --no-tty llm_server -- ollama pull "$model" \
            || warn "download failed — you can retry any time with: uu models pull $model"
        else
          warn "the model server did not come up within 2 minutes — nothing was downloaded"
          say  "    Check it with: uu status     then retry: uu models pull $model"
        fi
      else
        warn "the model server box does not exist, so nothing can be downloaded yet"
        say  "    Run this installer again and let it build the server first."
      fi
    else
      warn "no model yet — later: uu models pull $model"
    fi
  fi
  mark_done server
}

# --- 5. dev boxes ------------------------------------------------------------
step_boxes() {
  if podman image exists localhost/dev_base:latest 2>/dev/null; then
    ok "toolchain image already built"
  else
    say "  This builds the shared toolchain image (~9 GB: the coding agents, git, node, python)."
    ask "build it now? (takes a while)" || { warn "skipped"; return 0; }
    run bash "$LIB/build.sh" dev_base || { bad "toolchain build failed"; return 1; }
  fi
  podman image exists localhost/os_agent:latest 2>/dev/null \
    || run bash "$LIB/build.sh" os_agent || true

  # Create the personal box THROUGH tenant-create, so it gets the same treatment every other
  # box gets: shortcuts, the uu command, tmux config, session descriptor. Creating it by hand
  # (as the old README told you to) is why the shortcuts were missing.
  if podman container exists os_agent 2>/dev/null; then
    ok "your personal dev box 'os_agent' exists"
  else
    say "  This creates your personal dev box and sets up its shortcuts."
    ask "create it now?" || { warn "skipped"; return 0; }
    local m="$STATE_DIR/os_agent.yaml"
    if [ "$DRY" = 0 ]; then
      cat > "$m" <<YAML
# Personal Tier-0 box, generated by install.sh. Safe to edit and re-apply with:
#   bash setup/lib/tenant-create.sh $m
name: os_agent
tier: "0"
browser: shared
code_mount: ~/Code
sessions:
  - {name: main, agent: opencode, workdir: .}
YAML
    fi
    run bash "$LIB/tenant-create.sh" "$m" || { bad "could not create the box"; return 1; }
  fi
  mark_done boxes
}

# --- 6. host shell integration ----------------------------------------------
step_shell() {
  run bash "$LIB/deploy-uu.sh" --host
  run bash "$LIB/deploy-aliases.sh" --host-safe "$HOME"
  ok "'uu' command and host shortcuts installed"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) warn "~/.local/bin is not on your PATH — 'uu' will not be found until you add it:"
       say  "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && exec bash" ;;
  esac
  # Repair the personal box's profile too — this is what was missing when shortcuts
  # "did not work" inside the box.
  local prof="$HOME/Profiles/os_agent"
  if [ -d "$prof" ]; then
    for d in deploy-aliases deploy-tmux deploy-uu; do run bash "$LIB/$d.sh" "$prof" >/dev/null; done
    ok "shortcuts + uu refreshed inside the os_agent profile"
  fi
  mark_done shell
}

# --- 7. verify ---------------------------------------------------------------
step_verify() {
  if [ "$DRY" = 1 ]; then printf '  %s[dry-run]%s selftest.sh --quick\n' "$D" "$N"; return 0; fi
  local out rc
  out="$(bash "$ROOT/setup/test/selftest.sh" --quick 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '✗|selftest:' | sed 's/^/  /'
  if [ "$rc" -eq 0 ]; then
    # --quick deliberately skips live inference and a real box create, because both are slow.
    # Saying "everything passed" would claim two things that did not actually happen — say
    # what ran, and point at the command that runs the rest.
    local skipped; skipped="$(printf '%s' "$out" | sed -n 's/.*selftest: .* \([0-9]\+\) skipped.*/\1/p')"
    if [ -n "$skipped" ] && [ "$skipped" != 0 ]; then
      ok "every check that ran passed ($skipped skipped: live inference, real box create)"
      say "    To run those too (slower, creates and removes a throwaway box):"
      say "        bash $(host_path "$ROOT")/setup/test/selftest.sh"
    else
      ok "all automatic checks passed"
    fi
    mark_done verify
  else
    warn "some checks failed (the ✗ lines above)"
    say  "    See what to do:  uu doctor    ·    logs:  uu logs"
  fi
}

# =====================================================================================
# modes
# =====================================================================================
show_status() {
  head1 "uumami_os — setup status"
  say "  project files: $(host_path "$ROOT")"
  say "  ${D}(checked against the machine itself, not a saved record)${N}"
  say ""
  local s state ndone=0 first_todo=""
  for s in "${STEPS[@]}"; do
    state="$(probe_step "$s")"
    if [ "$state" = done ]; then
      ndone=$((ndone+1)); printf '  %s✓%s %-9s %s\n' "$G" "$N" "$s" "$(step_title "$s")"
    else
      [ -z "$first_todo" ] && first_todo="$s"
      printf '  %s·%s %-9s %s\n' "$D" "$N" "$s" "$(step_title "$s")"
    fi
  done
  say ""
  say "  $ndone of ${#STEPS[@]} done"
  if [ -n "$first_todo" ]; then
    say "  next step: $first_todo — $(step_title "$first_todo")"
    say ""
    say "  continue:  bash $(host_path "$ROOT")/install.sh"
    say "  just that one step:  bash $(host_path "$ROOT")/install.sh --only $first_todo"
  else
    say "  everything is set up. Day-to-day: uu status · uu enter os_agent"
  fi
}

do_repair() {
  head1 "uumami_os — repair (safe fix-ups only)"
  say "  Re-installs shortcuts, the uu command and config pointers. Builds nothing, deletes nothing."
  step_shell
  bash "$LIB/validate.sh" 2>&1 | sed 's/^/  /' || true
  say ""
  say "  done. Open a NEW terminal (or run 'exec bash') for shortcuts to take effect."
}

main() {
  # Read-only modes are fine anywhere; anything that changes the machine must run on the host,
  # because a box cannot build or recreate itself.
  if in_box && [ "$MODE" != status ] && [ "$DRY" = 0 ]; then
    cat >&2 <<EOF
${R}This must run on your computer, not inside a dev box.${N}

You are currently inside the '$(sed -n 's/^name="\(.*\)"/\1/p' /run/.containerenv)' box.
Boxes cannot create or rebuild themselves.

Open a normal terminal window on your machine and run:
    bash $(host_path "$ROOT")/install.sh
EOF
    exit 2
  fi

  check_project_files

  case "$MODE" in
    status) show_status; exit 0 ;;
    repair) do_repair; exit 0 ;;
  esac

  # A typo'd step name must not run nothing and then announce "Setup finished".
  if [ -n "$ONLY" ]; then
    local known=no s
    for s in "${STEPS[@]}"; do [ "$s" = "$ONLY" ] && known=yes; done
    if [ "$known" = no ]; then
      bad "there is no step called '$ONLY'."
      say "    The steps are: ${STEPS[*]}"
      exit 1
    fi
  fi

  head1 "uumami_os installer"
  say "  This sets up a local AI coding environment: a model server that runs on your own"
  say "  GPU, plus isolated boxes to work in. It asks before every change."
  say ""
  say "  Safe to stop at any time (Ctrl-C) and run again — it continues where it left off."
  [ "$DRY" = 1 ] && say "  ${Y}DRY RUN: nothing will actually be changed.${N}"

  local s
  for s in "${STEPS[@]}"; do
    [ -n "$ONLY" ] && [ "$ONLY" != "$s" ] && continue
    step_n=$((step_n+1))
    head1 "Step $step_n/${#STEPS[@]}: $(step_title "$s")"
    # Every step is idempotent and checks the machine itself before doing anything, so it is
    # always safe to run. Deciding from the saved record instead would skip work that was never
    # actually done (or redo work that was) — the record is history, the machine is the truth.
    "step_$s" || { bad "step '$s' did not finish"; say ""
                   say "  Nothing further was attempted. Fix the problem above, then run:"
                   say "      bash $(host_path "$ROOT")/install.sh"; exit 1; }
  done

  head1 "Setup finished"
  say "  Start working:"
  say "      uu status              see how everything is doing"
  say "      uu enter os_agent      go into your dev box"
  say "      uu tenant new <name>   create a walled-off space for a project"
  say ""
  say "  If a command is not found, open a new terminal first."
}

main "$@"
