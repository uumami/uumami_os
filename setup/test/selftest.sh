#!/usr/bin/env bash
# selftest.sh — end-to-end validation of the uumami_os build (SG13 auto-checks). Runs ON THE
# HOST. Exercises every component that can be tested without sudo / without recreating os_agent,
# and prints a clear PASS/FAIL summary. Human-required steps (os_agent recreate, Tier-2a user
# creation, reboot survival) are listed at the end, not executed.
#
# Usage:  selftest.sh            (functional checks; creates + tears down a throwaway Tier-0 box)
#         selftest.sh --quick    (skip the live-inference and real-box-create checks)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"            # setup/test -> setup
ROOT="$(cd "$ROOT/.." && pwd)"                  # -> repo root
export PATH="$HOME/.local/bin:$PATH"
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
P=0; F=0; S=0
pass() { echo "  ✓ $*"; P=$((P+1)); }
fail() { echo "  ✗ FAIL: $*"; F=$((F+1)); }
skip() { echo "  ~ skip: $*"; S=$((S+1)); }
sect() { echo; echo "── $* ──"; }

cd "$ROOT" || exit 1

# This suite inspects the HOST (distrobox, images, boxes, the user service). Run from inside a
# box it reports a pile of false failures — "distrobox missing", "images missing" — that look
# like a broken install but only mean "wrong place". Say so instead, and offer the fix.
if [ -f /run/.containerenv ]; then
  cat >&2 <<EOF
selftest must run on the HOST, not inside a box.

You are inside '$(sed -n 's/^name="\(.*\)"/\1/p' /run/.containerenv)'. From here, distrobox and
the image store are not visible, so every check would fail for the wrong reason.

Run it from here without leaving the box:
    uu doctor            # does the host hop for you
or open a host terminal and run:
    bash ${ROOT#/run/host}/setup/test/selftest.sh
EOF
  exit 3
fi

echo "=== uumami_os selftest ($(date -u +%FT%TZ)) — repo $ROOT ==="

sect "1. host probe + tooling"
command -v yq >/dev/null && pass "yq present ($(yq --version 2>&1 | awk '{print $NF}'))" || fail "yq missing"
command -v podman >/dev/null && pass "podman present" || fail "podman missing"
command -v distrobox >/dev/null && pass "distrobox present" || fail "distrobox missing"
bash setup/lib/detect.sh --write setup/facts.env >/dev/null 2>&1 && pass "detect.sh ran" || fail "detect.sh failed"
if grep -q '^GPU_GFX=' setup/facts.env; then pass "facts include GPU ($(sed -n 's/^GPU_GFX=//p' setup/facts.env))"; else fail "no GPU fact"; fi

sect "2. config merge + validation"
. setup/lib/config.sh
merged="$(merge_config "$ROOT" 2>/dev/null)" && pass "merge_config ok" || fail "merge_config failed"
[ -n "$(cfg_get "$merged" '.gpu.vendor')" ] && pass "merged has gpu.vendor=$(cfg_get "$merged" '.gpu.vendor')" || fail "merged missing gpu.vendor"
[ -n "$(cfg_get "$merged" '.model.primary')" ] && pass "merged has model.primary=$(cfg_get "$merged" '.model.primary')" || fail "merged missing model.primary"
bash setup/lib/validate.sh >/tmp/st_val.out 2>&1 && pass "validate.sh PASS" || { fail "validate.sh"; sed 's/^/      /' /tmp/st_val.out | grep ✗; }
[ -z "$(cfg_get "$merged" '.gpu' '')" ] && true  # layer purity is enforced inside validate
# regression guards
( . setup/lib/config.sh; m="$(printf 'a:\n  b: false\n')"; [ "$(cfg_get "$m" '.a.b' X)" = false ]; ) && pass "cfg_get preserves boolean false" || fail "cfg_get false regression"
td=$(mktemp -d); mkdir -p "$td/flavors"; printf 'flavor: x\n' >"$td/config.yaml"; printf 'extends: y\n' >"$td/flavors/x.yaml"; printf 'extends: x\n' >"$td/flavors/y.yaml"
timeout 5 bash -c '. setup/lib/config.sh; merge_config "'"$td"'"' >/dev/null 2>&1; [ $? -ne 0 ] && pass "cyclic extends errors (no hang)" || fail "cyclic extends not caught"; rm -rf "$td"

sect "3. Containerfile assembler"
bash setup/lib/assemble.sh dev_base --check >/dev/null 2>&1 && pass "dev_base Containerfile up to date" || fail "dev_base Containerfile drift"
bash setup/lib/assemble.sh os_agent --check >/dev/null 2>&1 && pass "os_agent Containerfile up to date" || fail "os_agent Containerfile drift"

sect "4. images present"
for img in llm_server dev_base os_agent; do
  podman image exists "localhost/$img:latest" && pass "image localhost/$img:latest" || fail "image localhost/$img missing (build with setup/lib/build.sh $img)"
done

sect "5. agents inside dev_base"
if podman image exists localhost/dev_base:latest; then
  out="$(podman run --rm localhost/dev_base:latest bash -lc '
    for b in "claude:claude" "codex:codex" "opencode:opencode" "pi:pi" "omp:omp"; do
      n="${b%%:*}"; c="${b##*:}"; v="$($c --version 2>&1 | head -1)"; echo "$n=$v"; done
    echo "hermes=$(hermes --version 2>&1 | head -1)"
    echo "cursor=$(rpm -q cursor 2>&1)"
    echo "podman=$(command -v podman)"
    echo "caps=$(getcap /usr/bin/newuidmap)"' 2>/dev/null)"
  for a in claude codex opencode pi omp hermes; do echo "$out" | grep -qE "^$a=.*[0-9]" && pass "agent $a: $(echo "$out"|sed -n "s/^$a=//p")" || fail "agent $a not working"; done
  echo "$out" | grep -q 'cursor=cursor-' && pass "cursor installed" || fail "cursor missing"
  echo "$out" | grep -q 'caps=.*cap_setuid' && pass "nested-podman caps (newuidmap)" || fail "newuidmap caps missing"
  # A dev image with node but no compiler cannot install any npm package containing native code:
  # node-gyp calls which() for `make`, finds nothing, and dies with a stack trace that never
  # names the missing tool. That cost two rounds of misdiagnosis (it looked like a network
  # timeout) before `make MISSING / gcc MISSING` explained it.
  tc="$(podman run --rm localhost/dev_base:latest bash -lc 'for t in make gcc g++ cc; do command -v $t >/dev/null || echo -n "$t "; done' 2>/dev/null)"
  [ -z "$tc" ] && pass "dev_base can build native modules (make/gcc/g++ present)" \
    || fail "dev_base has no build toolchain (missing: $tc) — native npm/pip modules cannot compile"
else skip "dev_base image absent — agent checks"; fi

sect "5b. agents in the shared tree (what you actually run)"
# Section 5 checks the IMAGE. Since `uu update agents` exists, the image is only the fallback —
# the binaries on your PATH come from ~/Agents/current/bin. Without this, the suite would stay
# green while the tree was empty, stale, or full of broken shims (npm writes a bin shim BEFORE
# the postinstall, so a failed install leaves one behind).
AGENTS_TREE="$HOME/Agents/current"
SRCF="$ROOT/setup/schema/sources.yaml"
# These agents must be exercised INSIDE a box, not here. The tree holds npm packages whose
# shims need `node`, which lives in the image — the host has no node at all, so running them
# here reports "env: node: No such file or directory" and looks like version drift when nothing
# is wrong. Guard `podman container exists` first: `distrobox enter` on a missing box offers to
# create a fedora-toolbox instead of failing.
inbox() { timeout 90 distrobox enter --no-tty os_agent -- bash -lc "$1" 2>/dev/null; }
if ! podman container exists os_agent 2>/dev/null; then
  skip "os_agent box absent — shared-tree agent checks"
elif [ -d "$AGENTS_TREE/bin" ] && [ -f "$SRCF" ]; then
  for a in $(yq -r '.agents | keys | .[]' "$SRCF" 2>/dev/null); do
    [ "$(cfg_get "$merged" ".agents.$a" false)" = true ] || continue
    kind="$(yq -r ".agents.$a.kind" "$SRCF")"; bin="$(yq -r ".agents.$a.bin // \"\"" "$SRCF")"
    pin="$(yq -r ".agents.$a.pin // \"\"" "$SRCF")"
    [ "$kind" = image ] && { skip "$a is image-only by declaration"; continue; }
    [ -n "$bin" ] || continue
    if [ ! -x "$AGENTS_TREE/bin/$bin" ]; then fail "agent $a: not in the shared tree (uu update agents)"; continue; fi
    # It must RUN, not merely exist — that is the broken-shim class. Run it in the box.
    vout="$(inbox "\"\$UU_AGENTS_DIR/current/bin/$bin\" --version" | head -1)"
    if [ -z "$vout" ]; then fail "agent $a: present in the tree but does not run"; continue; fi
    if [ "$kind" = script ]; then
      # A commit pin cannot be compared to a version string; running is the contract here.
      pass "agent $a runs from the tree ($vout, pinned ${pin:0:12})"
    elif grep -qF "$pin" <<<"$vout"; then
      pass "agent $a runs from the tree at its pinned version ($pin)"
    else
      # The exact drift that hid claude 2.1.220 behind an image claiming 2.1.191.
      fail "agent $a version drift: tree reports '$vout' but sources.yaml pins '$pin'"
    fi
  done
  # The tree must WIN over the image, or pinning is decorative.
  shell_path="$(inbox 'command -v claude' | tail -1)"
  case "$shell_path" in
    */Agents/current/bin/*) pass "a login shell in the box resolves agents from the shared tree" ;;
    "") skip "could not resolve an agent in a box login shell" ;;
    *) fail "a box login shell resolves claude from '$shell_path' — the image shadows the shared tree" ;;
  esac
else
  skip "no shared agent tree yet (uu update agents)"
fi

sect "6. llm_server live inference (GPU)"
if [ "$QUICK" = 1 ]; then skip "live inference (--quick)"; else
  if curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/tmp/st_tags.json 2>/dev/null; then
    pass "endpoint 127.0.0.1:11434 responds"
    model="$(cfg_get "$merged" '.model.primary' qwen3-coder:30b)"
    grep -q "$model" /tmp/st_tags.json && pass "model $model is pulled" || skip "model $model not pulled (ollama pull $model)"
    if grep -q "$model" /tmp/st_tags.json; then
      resp="$(curl -fsS --max-time 90 http://127.0.0.1:11434/api/generate -d "{\"model\":\"$model\",\"prompt\":\"reply with the word READY\",\"stream\":false,\"options\":{\"num_predict\":5}}" 2>/dev/null)"
      echo "$resp" | grep -q '"response"' && pass "inference returned a response" || fail "inference produced no response"
      # Guard the box's existence first: `distrobox enter <missing>` PROMPTS to create a
      # fedora-toolbox box and blocks on stdin when its output is captured.
      ps_out=""; podman container exists llm_server 2>/dev/null \
        && ps_out="$(timeout 30 distrobox enter llm_server -- ollama ps </dev/null 2>/dev/null)"
      if echo "$ps_out" | grep -q 'GPU'; then pass "ollama ps shows GPU ($(echo "$ps_out" | grep -oE '[0-9]+% GPU' | head -1))"
      elif echo "$ps_out" | grep -qw 'CPU'; then fail "ollama ps shows CPU fallback"
      else skip "no model loaded in ollama ps (idle)"; fi
    fi
  else fail "llm_server endpoint not responding (service active? systemctl --user status llm_server)"; fi
fi

sect "7. tenant-create + work"
bash setup/lib/tenant-create.sh --dry-run setup/templates/tenant-example.yaml >/tmp/st_t2a.out 2>&1; rc=$?
{ [ $rc -eq 2 ] && grep -q 'human-required' /tmp/st_t2a.out; } && pass "Tier-2a dry-run emits human-required (rc=2)" || fail "Tier-2a dry-run wrong (rc=$rc)"
sed 's/tier: "2a"/tier: "0"/' setup/templates/tenant-example.yaml >/tmp/st_t0.yaml
bash setup/lib/tenant-create.sh --dry-run /tmp/st_t0.yaml >/tmp/st_t0.out 2>&1
grep -q ':/workspace' /tmp/st_t0.out && pass "Tier-0 create mounts /workspace" || fail "Tier-0 missing /workspace"
grep -q '/models' /tmp/st_t0.out && fail "Tier-0 mounts /models (INVARIANT VIOLATION)" || pass "Tier-0 does NOT mount /models"
# work session resolution (stubbed tmux)
desc=$(mktemp); printf 'name: t\ntier: "0"\nmodel: m\nbrowser: shared\nsessions:\n  - {name: s1, agent: opencode, workdir: .}\n' >"$desc"
stub=$(mktemp -d); printf '#!/usr/bin/env bash\necho stub-tmux "$@"\n' >"$stub/tmux"; chmod +x "$stub/tmux"
work_out="$(PATH="$stub:$PATH" UUMAMI_TENANT_DESC="$desc" bash setup/lib/work.sh --list 2>&1 || true)"
grep -q s1 <<<"$work_out" && pass "work --list resolves sessions" || fail "work --list"
PATH="$stub:$PATH" UUMAMI_TENANT_DESC="$desc" bash setup/lib/work.sh nope >/dev/null 2>&1; [ $? -ne 0 ] && pass "work rejects unknown session" || fail "work accepted bad session"
rm -rf "$stub" "$desc" /tmp/st_t0.yaml

sect "8. real Tier-0 tenant create + teardown"
if [ "$QUICK" = 1 ] || ! podman image exists localhost/dev_base:latest; then skip "real box create (--quick or no dev_base)"; else
  M=/tmp/st_tenant.yaml; printf 'name: selftest-tenant\ntier: "0"\nbrowser: per-tenant\ncode_mount: ~/Code\nsessions:\n  - {name: m, agent: opencode, workdir: .}\n' >"$M"
  bash setup/lib/tenant-create.sh "$M" >/tmp/st_tc.out 2>&1
  box_list="$(distrobox list 2>/dev/null || true)"
  grep -qw selftest-tenant <<<"$box_list" && pass "Tier-0 box created" || fail "Tier-0 box not created"
  [ -f "$HOME/Profiles/selftest-tenant/.config/uumami/tenant.yaml" ] && pass "tenant descriptor written" || fail "descriptor missing"
  mounts="$(podman inspect selftest-tenant --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null)"
  echo "$mounts" | grep -q /workspace && pass "box mounts /workspace" || skip "could not inspect mounts"
  echo "$mounts" | grep -q /models && fail "box mounts /models (INVARIANT VIOLATION)" || pass "box does NOT mount /models"
  distrobox rm -f selftest-tenant >/dev/null 2>&1; rm -rf "$HOME/Profiles/selftest-tenant" "$M"
  N=selftest-tenant yq -i 'del(.tenants[] | select(.name == env(N)))' "$HOME/Profiles/registry.yaml" 2>/dev/null || true
  pass "teardown clean (no --rm-home)"
fi

sect "9. architecture invariants (static)"
# Precise: ignore comments / forbidding-docs; flag only REAL usage.
grep -rInE 'distrobox +rm.*--rm-home' setup/lib images 2>/dev/null | grep -q . && fail "real --rm-home usage" || pass "no --rm-home usage (only forbidding docs)"
grep -rInE '^[^#]*0\.0\.0\.0' config.yaml flavors images/llm_server 2>/dev/null | grep -q . && fail "0.0.0.0 in a real value" || pass "no 0.0.0.0 outside comments (loopback only)"
grep -iE '^[[:space:]]*(CMD|ENTRYPOINT|EXPOSE)' images/llm_server/Containerfile | grep -q . && fail "llm_server has a real CMD/ENTRYPOINT/EXPOSE directive" || pass "llm_server: no CMD/ENTRYPOINT/EXPOSE directive"
grep -rInE '^[^#]*/models([^.a-z]|$)' images/os_agent/Containerfile images/dev_base/Containerfile 2>/dev/null | grep -q . && fail "real /models path in an agent image" || pass "no /models mount in dev_base/os_agent images"
# `producer | grep -q` under `set -o pipefail` reports FAILURE ON A MATCH when the producer is
# still writing: grep -q exits at the first hit and the producer takes SIGPIPE (141). In a
# `&& fail` guard that silently flips the verdict to pass, so the check stops checking.
# Builtins (printf/echo) finish before grep exits, so only external producers are flagged.
risky="$(grep -nE '[^|]\|[[:space:]]*grep -[a-zA-Z]*q' setup/bin/uu setup/lib/*.sh 2>/dev/null \
  | grep -vE ':[[:space:]]*#' | grep -vE '(printf|echo)[^|]*\|[[:space:]]*grep' || true)"
[ -z "$risky" ] && pass "no external producer piped into grep -q (pipefail false-failure trap)" \
  || fail "pipe into grep -q under pipefail — capture first, match with a here-string: $risky"
# A --volume source that does not exist fails create with a bare 'no such file or directory',
# and only AFTER the multi-GB image build has succeeded.
awk '/mkdir -p .*models_dir/{m=NR} /distrobox create/{c=NR} END{exit !(m && c && m<c)}' setup/lib/llm_server.sh \
  && pass "llm_server creates the models mount source before create" \
  || fail "llm_server mounts \$models_dir without creating it first"

sect "10. QoL deploy scripts (aliases/tmux/ssh)"
qh=$(mktemp -d)
for s in deploy-aliases deploy-tmux deploy-ssh; do
  bash "setup/lib/$s.sh" "$qh" >/dev/null 2>&1 && bash "setup/lib/$s.sh" "$qh" >/dev/null 2>&1 \
    && pass "$s idempotent" || fail "$s failed"
done
[ -f "$qh/.bashrc.d/shared_aliases.sh" ] && [ -f "$qh/.config/uumami/aliases.sh" ] && pass "aliases deployed + pointer" || fail "aliases files missing"
# A desktop session's SSH_ASKPASS names a HOST binary that does not exist in a box; with DISPLAY
# set, ssh then dies instead of prompting, breaking passphrase-protected keys specifically.
[ -x "$qh/.local/bin/uu-askpass" ] && pass "uu-askpass deployed into the profile" \
  || fail "uu-askpass missing — a box has no way to raise a passphrase dialog"
# With the forwarder present, prompts must be routed to it (dialog when there is no tty)...
( SSH_ASKPASS=/nonexistent/askpass DISPLAY=:0 HOME="$qh"; . "$qh/.bashrc.d/shared_aliases.sh" >/dev/null 2>&1
  [ "${SSH_ASKPASS:-}" = "$qh/.local/bin/uu-askpass" ] && [ -z "${SSH_ASKPASS_REQUIRE:-}" ] ) \
  && pass "box shell routes a stale SSH_ASKPASS to uu-askpass (keeps the desktop dialog)" \
  || fail "box shell does not route SSH_ASKPASS to uu-askpass"
# ...and without it, fall back to terminal prompting rather than leaving a broken binary.
( SSH_ASKPASS=/nonexistent/askpass DISPLAY=:0 HOME="$qh/no-forwarder"
  mkdir -p "$HOME"; . "$qh/.bashrc.d/shared_aliases.sh" >/dev/null 2>&1
  [ -z "${SSH_ASKPASS:-}" ] && [ "${SSH_ASKPASS_REQUIRE:-}" = never ] ) \
  && pass "without uu-askpass, a stale SSH_ASKPASS falls back to terminal prompting" \
  || fail "a stale SSH_ASKPASS would fail with no prompt at all"
# uu-askpass must never interpolate the prompt into the host command line.
grep -q 'UU_ASKPASS_PROMPT=' "$ROOT/setup/templates/qol/uu-askpass" \
  && ! grep -qE 'host-exec.*\$\{?1\}?' "$ROOT/setup/templates/qol/uu-askpass" \
  && pass "uu-askpass passes the prompt by environment, not shell interpolation" \
  || fail "uu-askpass interpolates the prompt into a host shell command"
[ -f "$qh/.tmux.conf" ] && [ -f "$qh/.bashrc.d/zz-tmux-autoattach.sh" ] && pass "tmux conf + auto-attach hook" || fail "tmux files missing"
# deploy-ssh deliberately does NOT mint a key unattended (that key would have no passphrase);
# it always writes the config block, and only generates when asked explicitly. See §13.
grep -qs 'Host github.com' "$qh/.ssh/config" && pass "ssh config block written" || fail "ssh config block missing"
[ -f "$qh/.ssh/id_ed25519_github" ] && fail "unattended run created an unencrypted ssh key" \
  || pass "no unencrypted key created unattended (uu github setup does it interactively)"
env HOME="$qh" bash -ic 'alias host' >/dev/null 2>&1 && pass "aliases resolve in an interactive shell" || fail "aliases do not load"
rm -rf "$qh"

sect "11. uu CLI"
UU="$ROOT/setup/bin/uu"
[ -x "$UU" ] && pass "uu present + executable" || fail "uu missing"
bash "$UU" >/tmp/uu_help.$$ 2>&1; [ $? -eq 0 ] && grep -q "Common tasks" /tmp/uu_help.$$ \
  && pass "bare uu prints help, exit 0" || fail "bare uu broken"
bash "$UU" frobnicate >/dev/null 2>/tmp/uu_err.$$; rc=$?
[ "$rc" -eq 1 ] && grep -qi "hint" /tmp/uu_err.$$ && pass "unknown verb: exit 1 + hint" || fail "unknown verb handling (rc=$rc)"
bash "$UU" staus >/dev/null 2>/tmp/uu_err.$$; grep -q "did you mean" /tmp/uu_err.$$ \
  && pass "did-you-mean suggestion" || fail "no did-you-mean"
# every verb has an Examples block in its help
miss=""
for v in setup repair status enter agent work update tenant models clean rebuild recreate build logs github bootstrap validate doctor aliases; do
  vhelp="$(bash "$UU" help "$v" 2>/dev/null || true)"
  grep -q "Example" <<<"$vhelp" || miss="$miss $v"
done
[ -z "$miss" ] && pass "every verb's help has Examples" || fail "help missing Examples:$miss"
bash "$UU" help --agent 2>/dev/null | grep "EXIT CODES" >/dev/null 2>&1 && pass "help --agent contract dump" || fail "help --agent"
bash "$UU" status --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 \
  && pass "status --json parses" || fail "status --json invalid"
bash "$UU" tenant ls --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 \
  && pass "tenant ls --json parses" || fail "tenant ls --json invalid"
bash "$UU" clean --dry-run >/tmp/uu_clean.$$ 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "untouched:" /tmp/uu_clean.$$ && pass "clean --dry-run explain-plan (exit 0)" || fail "clean --dry-run (rc=$rc)"
bash "$UU" tenant new bad.name >/dev/null 2>&1; [ $? -eq 3 ] && pass "precondition -> exit 3" || fail "precondition exit code"
# uu agent: the list is read from config.yaml, so enabling an agent there must be enough.
# NOTE: capture first, then match with a here-string. `producer | grep -q` is a trap under the
# `set -o pipefail` above: grep exits at the first match, the producer takes SIGPIPE (141), and
# the pipeline reports failure even though the match succeeded.
uu_agents="$(bash "$UU" agent --list 2>/dev/null)"
for a in claude codex; do
  grep -q "^$a " <<<"$uu_agents" && pass "uu agent --list includes $a (from config.yaml)" \
    || fail "uu agent --list missing $a — the list is not config-driven"
done
bash "$UU" agent bogus >/dev/null 2>&1; [ $? -eq 3 ] && pass "uu agent: unknown agent -> exit 3" || fail "uu agent unknown-agent exit code"
# uu update with no arguments must REPORT, never mutate. That is the whole contract of the verb.
upd_out="$(bash "$UU" update 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "changes nothing" <<<"$upd_out"; } \
  && pass "bare uu update reports and changes nothing (exit 0)" || fail "bare uu update contract (rc=$rc)"
grep -q "uu update agents" <<<"$upd_out" && pass "uu update prints the command for each category" \
  || fail "uu update does not tell you how to act on what it found"
bash "$UU" update nonsuch >/dev/null 2>&1; [ $? -eq 3 ] && pass "uu update: unknown target -> exit 3" || fail "uu update unknown-target exit code"
# A skill is instructions the agents obey. A floating branch means upstream decides what your
# agents do on the next update, silently — pins must be tags or SHAs.
badpin="$(yq -r '.skills | to_entries[] | select(.value.pin == "main" or .value.pin == "master" or .value.pin == "HEAD") | .key' "$ROOT/setup/schema/sources.yaml" 2>/dev/null || true)"
[ -z "$badpin" ] && pass "no skill tracks a floating branch (pins are tags/SHAs)" \
  || fail "skill pinned to a moving branch: $badpin"
# Resume is only claimed where it was verified against the agent's real --help; anything else
# must refuse rather than invent a flag that silently starts a fresh session.
bash "$UU" agent pi -c >/dev/null 2>&1; [ $? -eq 3 ] && pass "uu agent: refuses resume it cannot do -> exit 3" || fail "uu agent invents a resume flag"
# The destination is fixed on purpose: no workdir flag, or it becomes a worse `uu work`.
agent_help="$(bash "$UU" help agent 2>/dev/null || true)"
grep -qE '\-\-(dir|cwd|workdir)' <<<"$agent_help" \
  && fail "uu agent grew a workdir flag (that is what uu work is for)" \
  || pass "uu agent has no workdir flag (destination stays deterministic)"
vocab="$(grep -E 'prune -a|--rm-home' "$UU" || true)"
grep -vq never <<<"$vocab" && fail "forbidden vocabulary in uu" || pass "no forbidden vocabulary (prune -a / --rm-home)"
# aliases: every alias/function annotated; catalog renders; collision allowlist
n_alias="$(grep -cE "^alias |^[a-z_]+\(\) \{" "$ROOT/setup/templates/qol/aliases.sh")"
n_annot="$(grep -c '# @' "$ROOT/setup/templates/qol/aliases.sh")"
[ "$n_annot" -ge $((n_alias - 2)) ] && pass "alias annotations cover the catalog ($n_annot/$n_alias)" \
  || fail "unannotated aliases ($n_annot/$n_alias)"
bash "$UU" aliases 2>/dev/null | grep "^agents:" >/dev/null 2>&1 && pass "uu aliases renders categories" || fail "uu aliases broken"
# The catalog reads the `# @cat:` annotation from the same line as the name. A wrapped
# definition renders the function BODY as the name — visible garbage. Names are single words.
alias_names="$(bash "$UU" aliases 2>/dev/null | awk '/^  [^ ]/ {print $1}' || true)"
if grep -qE '[;{}()]|^$' <<<"$alias_names"; then
  fail "alias catalog renders malformed names (a definition is probably wrapped over lines)"
else pass "alias catalog names are all well-formed"; fi
rm -f /tmp/uu_help.$$ /tmp/uu_err.$$ /tmp/uu_clean.$$

sect "12. onboarding: preflight + installer"
PF="$ROOT/setup/lib/preflight.sh"
[ -f "$PF" ] && pass "preflight.sh present" || fail "preflight.sh missing"
bash "$PF" --quiet >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] && pass "preflight exits 0 (ready) or 3 (missing prereq), got $rc" \
  || fail "preflight bad exit ($rc)"
bash "$PF" --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 \
  && pass "preflight --json parses" || fail "preflight --json invalid"
bash "$PF" --warn-only >/dev/null 2>&1 && pass "preflight --warn-only never fails" || fail "--warn-only returned non-zero"
# every script that BUILDS or CREATES must refuse to run without prerequisites
for s in build.sh llm_server.sh tenant-create.sh; do
  grep -q 'preflight.sh' "$ROOT/setup/lib/$s" && pass "$s gates on preflight" || fail "$s does not check prerequisites"
done
INS="$ROOT/install.sh"
[ -f "$INS" ] && pass "install.sh present" || fail "install.sh missing"
bash -n "$INS" 2>/dev/null && pass "install.sh parses" || fail "install.sh syntax error"
bash "$INS" --status >/dev/null 2>&1 && pass "install.sh --status works" || fail "install.sh --status broken"
grep -q 'is_done' "$INS" && pass "installer tracks completed steps (resumable)" || fail "installer not resumable"
# An incomplete download must be named as such, not surface as "software is missing".
incomplete=$(mktemp -d); cp "$INS" "$incomplete/"
bash "$incomplete/install.sh" --dry-run --yes >/tmp/st_inc.$$ 2>&1
grep -q 'not a complete copy' /tmp/st_inc.$$ && pass "installer detects an incomplete copy of the project" \
  || fail "incomplete project folder not detected"
rm -rf "$incomplete" /tmp/st_inc.$$
# The personal box is called os_agent — the installer generates that manifest itself, so the
# name validator must accept it (an underscore-reject broke the installer's own step 5).
osman=$(mktemp); printf 'name: os_agent\ntier: "0"\nbrowser: shared\ncode_mount: ~/Code\n' >"$osman"
bash "$ROOT/setup/lib/tenant-create.sh" --dry-run "$osman" >/dev/null 2>&1 \
  && pass "tenant-create accepts the built-in 'os_agent' name" || fail "tenant-create rejects os_agent (installer step 5 would fail)"
# ...but path traversal is still refused
travman=$(mktemp); printf 'name: ../evil\ntier: "0"\n' >"$travman"
bash "$ROOT/setup/lib/tenant-create.sh" --dry-run "$travman" >/dev/null 2>&1 \
  && fail "tenant-create accepted a path-traversal name" || pass "tenant-create still refuses path traversal"
rm -f "$osman" "$travman"
# `mv src dest` silently nests when dest exists — the installer must never do a bare move.
grep -q 'move_into_place' "$INS" && pass "installer uses a guarded move (no silent nesting)" \
  || fail "installer moves folders without the existing-destination guard"
# A yes/no prompt with no keyboard attached must stop, not assume "yes".
grep -q 'r /dev/tty' "$INS" && pass "installer refuses to guess an answer with no terminal" \
  || fail "installer would auto-answer prompts without a tty"
# `uu tenant new` prints follow-up commands that reference the manifest — so the manifest has
# to still exist afterwards (it used to be a temp file deleted on exit).
tman="${XDG_CONFIG_HOME:-$HOME/.config}/uumami/tenants/selftest-man.yaml"; rm -f "$tman"
bash "$UU" tenant new selftest-man --dry-run >/tmp/st_tn.$$ 2>&1
[ -f "$tman" ] && pass "uu tenant new saves a manifest that outlives the command" \
  || fail "uu tenant new deleted the manifest its own instructions reference"
# Instructions a human retypes must not contain the in-box /run/host prefix.
grep -q '/run/host' /tmp/st_tn.$$ && fail "printed instructions contain the /run/host prefix" \
  || pass "printed instructions use real host paths"
# The follow-up must hand the tenant its own copy (it cannot read the admin's 700 profile).
grep -q 'install -m 644 -o' /tmp/st_tn.$$ && pass "tenant setup copies the manifest to the new user" \
  || fail "tenant instructions point at a file the new user cannot read"
rm -f "$tman" /tmp/st_tn.$$

sect "13. the create-prompt hazard + key hygiene"
# `distrobox enter <missing-box>` offers to CREATE a fedora-toolbox box and blocks on stdin.
# Every call site must prove the box exists first (or go over HTTP instead).
bad=""
while IFS= read -r loc; do
  case "$loc" in *box_exists*|*container\ exists*|*llm_box_run*) continue ;; esac
  bad="$bad $loc"
done < <(grep -n 'distrobox enter' "$UU" | grep -v '^\s*#' | grep -vE 'Underneath|hint|echo|cat ' | cut -d: -f1)
[ -z "$bad" ] || grep -q 'llm_box_run' "$UU" && pass "uu guards distrobox enter (no create-prompt hang)" \
  || fail "unguarded distrobox enter in uu at line(s):$bad"
grep -q 'api/ps' "$UU" && pass "uu status reads GPU state over HTTP (never enters a box)" \
  || fail "uu status still enters llm_server to read GPU state"
# Prevention is not enough — the wreckage of that prompt (a box with the right name built from
# fedora-toolbox) must be DETECTED and explained, not reported as a healthy box.
grep -q 'WRONG IMAGE' "$UU" && pass "uu status flags a box built from the wrong image" \
  || fail "uu status would report a fedora-toolbox llm_server as healthy"
grep -q "localhost/llm_server:latest" "$INS" && pass "installer verifies box images, not just names" \
  || fail "installer treats any container named llm_server as done"
# A container exists before distrobox's init has created your user inside it. Pulling straight
# after create loses that race and dies with 'no matching entries in passwd file'.
awk '/api\/tags/{w=NR} /ollama pull/{p=NR} END{exit !(w && p && w<p)}' "$INS" \
  && pass "installer waits for the server to answer before pulling a model" \
  || fail "installer pulls a model without waiting for the box to finish starting"
# SSH keys must not be created without a passphrase unless explicitly asked
grep -q 'no-passphrase' "$ROOT/setup/lib/deploy-ssh.sh" && pass "deploy-ssh has an explicit --no-passphrase opt-out" \
  || fail "deploy-ssh missing passphrase opt-out"
sshtmp=$(mktemp -d)
bash "$ROOT/setup/lib/deploy-ssh.sh" "$sshtmp" </dev/null >/dev/null 2>&1
[ -f "$sshtmp/.ssh/id_ed25519_github" ] && fail "deploy-ssh created a key with NO passphrase non-interactively" \
  || pass "deploy-ssh refuses to create an unencrypted key unattended"
[ -f "$sshtmp/.ssh/config" ] && pass "deploy-ssh still writes the github.com config block" || fail "ssh config block missing"
bash "$ROOT/setup/lib/deploy-ssh.sh" --no-passphrase "$sshtmp" >/dev/null 2>&1
[ -f "$sshtmp/.ssh/id_ed25519_github" ] && pass "--no-passphrase still works when asked for explicitly" \
  || fail "--no-passphrase did not generate a key"
rm -rf "$sshtmp"
# A stale/foreign pointer file must NOT outrank the location of the uu you actually invoked,
# or every repo verb silently operates on a different copy of the project.
ptrtmp=$(mktemp -d); mkdir -p "$ptrtmp/.config/uumami" "$ptrtmp/decoy/setup/lib"
echo "$ptrtmp/decoy" > "$ptrtmp/.config/uumami/repo"
resolved="$(HOME="$ptrtmp" bash "$UU" validate 2>&1 | sed -n 's/^\[validate\] config: //p' | head -1)"
case "$resolved" in
  "$ROOT"/*) pass "uu resolves the repo from its own location, not a stale pointer" ;;
  *)         fail "stale pointer won: uu used '$resolved' instead of $ROOT" ;;
esac
rm -rf "$ptrtmp"

echo
echo "==================================================================="
echo "  selftest: ${P} passed, ${F} failed, ${S} skipped"
echo "  Human-required (not run here): os_agent recreate; Tier-2a user"
echo "  creation (sudo); reboot/logout survival; cursor distrobox-export."
echo "==================================================================="
[ "$F" -eq 0 ]
