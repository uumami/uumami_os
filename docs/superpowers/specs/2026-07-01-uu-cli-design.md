# Design: `uu` — the uumami_os umbrella CLI

**Status:** Approved design, pre-implementation.
**Date:** 2026-07-01
**Decided with the user (brainstorming session):** umbrella CLI + kept aliases · fully
deterministic · context-aware (host + in-box) · system-verbs-only scope · agent contract =
`--yes`/`--dry-run` everywhere, `--json` on reads, `uu help --agent`, structured exit codes.

## 1. Problem

Every operation today is `bash setup/lib/<script>.sh` plus a handful of flat aliases:
undiscoverable (no unified help), unsafe-by-documentation (the "never `prune -a`", "never
`--rm-home`" rules live in docs, not code), and unergonomic for both humans ("which script
was it?") and agents (no machine contract). We want one discoverable, safe command surface —
usable by a human with no agent at all, and equally by an agent as a reliable tool.

## 2. Goals / non-goals

**Goals**
- One command, `uu`, with memorable verbs covering the system: boxes, tenants, sessions,
  models, images/cleanup, health, GitHub-SSH.
- Human-first ergonomics: `uu help` with examples, guided flows, confirmation prompts,
  explain-plans before anything destructive.
- Agent-grade contract: deterministic output, `--json`, `--yes`, `--dry-run`, structured
  exit codes, `uu help --agent` full-reference dump.
- Safety rules become code: forbidden operations are *not in the vocabulary*.
- Works identically on the host and inside any box (auto-routing).

**Non-goals (explicit)**
- `uu` never calls a model or an agent. Output is always ground truth. *(A future version
  might add opt-in agent/subagent invocation — noted here as a direction only: no code, no
  hooks, no design now; we are not sure we want it.)*
- No wrapping of generic dev tools (git porcelain, gh, raw podman): universal practice stays
  as thin aliases; if it touches OUR architecture it's a `uu` verb, otherwise it isn't.
- No TUI/menus; plain argv in, text/JSON out.

## 3. Command surface (v1)

Facade rule: every verb routes to an existing `setup/lib/*.sh` script or composes a
documented best-practice sequence. **No business logic lives in `uu`**; if a verb needs real
logic, that logic belongs in (or moves to) a `setup/lib` script.

| Verb | Does | Routes to |
|---|---|---|
| `uu status [--json]` | boxes + tenant mapping, llm service/model/GPU%, disk summary, **drift detection** (box older than its image → "recreate pending"; service down; CPU fallback; config invalid) | distrobox/podman/systemctl reads + `validate.sh` |
| `uu enter [box]` | enter a box (default `os_agent`) | `distrobox enter` |
| `uu work <name> \| ls` | session launcher / list (in-box) | `work.sh` |
| `uu tenant new <name> [--tier 0\|2a] [--manifest f]` | guided tenant creation; Tier-2a prints sudo steps, **exit 2** | `tenant-create.sh` |
| `uu tenant ls [--json]` | registry + box + user + image + real RW size | registry + `podman ps --size` |
| `uu tenant rm <name> [--profile]` | decommission checklist: box → tenant images → registry. Profile only with explicit `--profile` + name-retype | housekeeping checklist |
| `uu models [ls\|pull\|rm] [--json]` | model management on the shared server | `distrobox enter llm_server -- ollama …` |
| `uu clean [--dry-run] [--yes]` | housekeeping routine: prune dangling, report obsolete tagged for human review; never `-a` | `podman image prune` + review list |
| `uu rebuild [--dry-run]` | image cascade + recreate guidance | `rebuild.sh` |
| `uu recreate <box>` | exact rm+create for that box; self-recreate from inside → **exit 2** | `rebuild.sh` guidance / `llm_server.sh` |
| `uu github` | finish SSH flow: show pubkey, config state, test hint | `deploy-ssh.sh` state |
| `uu doctor [--quick]` | selftest + plain-language summary of failures | `setup/test/selftest.sh` |
| `uu bootstrap` | the tutorial entry point: probe → flavor match → browser-agent request → validate | `bootstrap.sh` |
| `uu validate` | fast config/schema check ("is my config right?" — vs doctor's "is my system healthy?") | `validate.sh` |
| `uu build <image>` | assemble + build one image (incl. per-project images) | `build.sh` |
| `uu logs [-f]` | llm_server journal tail (the troubleshooting verb) | `journalctl --user -u llm_server` |
| `uu aliases [category] [--json]` | render the alias catalog, grouped; categories: agents git gh tmux containers llm | parses annotations in `aliases.sh` |
| `uu` (bare) / `uu help [cmd] \| --agent` / `uu --version` | bare `uu` = the help screen (never an error); per-command help with examples / full machine contract | embedded text |

**Aliases:** full catalog in Appendix A — ~50 aliases across 7 annotated categories,
rendered by `uu aliases`. Deployed as today via `deploy-aliases.sh` (copy-not-pointer).

## 4. Safety model

- Mutating verbs: explain-plan → interactive confirm; `--yes` skips; `--dry-run` prints the
  plan and exits 0.
- **Explain-plan format** (structured, human-readable, diff-able by agents):
  `would:` lines, `keeping:` lines with reasons ("in use by box X"), and an `untouched:`
  line naming the pools not involved ("profiles/models live outside podman storage").
- Vocabulary exclusions (cannot express, not merely warned): `prune -a`, `--rm-home`,
  writes under `~/Profiles`/`~/Models` content.
- `tenant rm --profile` (the no-undo step) requires retyping the tenant name even with
  `--yes` — agents cannot destroy an identity silently.
- Self-recreate guard: `uu recreate <current-box>` from inside it → exit 2 + host-terminal
  instructions.
- Preconditions checked before acting (config validates, image exists, box exists) →
  exit 3 with a one-line reason.

## 5. Agent contract (dumped verbatim by `uu help --agent`)

- Exit codes: **0** done · **2** human-required (exact instructions printed) · **3**
  precondition failed · **1** error. (Same convention as the OS-module contract.)
- `--json` on read verbs (`status`, `tenant ls`, `models ls`): stable keys, no ANSI,
  emitted via `yq -o=json` (no new dependency).
- `--yes` / `--dry-run` on every mutating verb.
- Determinism guarantee: `uu` never calls a model; output is system ground truth.

## 5b. Help & beginner UX (first-class requirement)

The CLI must be learnable by a beginner with no agent and no docs open:

- **Bare `uu` shows help** (exit 0) — running the command with nothing is never an error.
- **`uu help` is task-oriented, not just a verb list:** grouped by intent ("see what's going
  on", "daily work", "projects & tenants", "maintenance"), one-liner per verb, and a short
  "common tasks" block (e.g. *first time? → `uu status` · new project → `uu tenant new` ·
  disk full? → `uu clean --dry-run`*). Ends with "details: `uu help <command>`".
- **`uu help <cmd>`** (and `uu <cmd> --help`, same output) explains: what it does in plain
  words, what it touches / what it never touches, **2–3 copy-pasteable examples**, safety
  flags (`--dry-run`/`--yes`), exit codes, what's underneath (`setup/lib/<x>.sh`), and the
  related doc page.
- **Errors teach:** unknown verb → nearest-match suggestion ("did you mean `uu tenant ls`?")
  + help pointer, exit 1. Every failure path ends with a one-line `hint:` (the next command
  to try). Missing required arg → that verb's help excerpt, not a bare usage string.
- **Dry-run as pedagogy:** the explain-plan format (§4) doubles as the "what would happen if
  I ran this?" learning tool — help text for destructive verbs tells beginners to try
  `--dry-run` first.

## 6. Architecture & install

- **One file:** `setup/bin/uu`, bash, shellcheck-clean, `case`-dispatch, help embedded.
- **Context detection:** `/run/.containerenv` present → in-box: host-side verbs auto-prefix
  `distrobox-host-exec`; box name read for the self-recreate guard. Absent → host: direct.
- **Host install:** symlink `~/.local/bin/uu` → repo file (fresh with `git pull`). Installed
  by a new `deploy-uu.sh`.
- **Profile/tenant install:** `deploy-uu.sh <home>` (SG8 deploy interface) **copies** the
  script to `<home>/.local/bin/uu` — copy-not-pointer, same reasoning as the aliases
  (tenants cannot and should not read the admin's repo). Wired into `tenant-create`'s deploy
  loop next to deploy-aliases/tmux/ssh. Refresh = re-run (the existing propagation story).

## 7. Docs to update (surgical)

README quickstart + post-install guide (intro `uu`, keep script paths as the "what's
underneath" reference) · housekeeping routine says `uu clean` · agents-guide know-how table
points to `uu help --agent` · CLAUDE.md key-commands block adds `uu`.

## 8. Testing (selftest §11)

- `uu status --json` parses (yq) and contains expected keys.
- `uu clean --dry-run` → exit 0; output names dangling images and the untouched pools.
- Tier-2a `uu tenant new` → exit 2 · broken precondition → exit 3 · unknown verb → exit 1.
- `uu help --agent` non-empty and mentions every verb in §3.
- Bare `uu` → exit 0 and prints the help screen; `uu help <cmd>` contains an "Examples"
  block for **every** verb; unknown verb → exit 1 with a "did you mean" suggestion.
- `deploy-uu.sh` idempotent (twice).
- `uu aliases` renders every category; every alias in `aliases.sh` has an annotation
  (unannotated alias = test failure); collision scan vs dev_base passes (allowlist: `pic`).
- Alias smoke test: each agent alias family's base + one suffixed form resolve in an
  interactive shell against a deployed profile (as selftest §10 does today).
- shellcheck-clean; static invariant greps over `setup/bin/uu` (no `prune -a`, no
  `--rm-home`).

## Appendix A — the alias catalog (v1)

Ground truth: flag sets extracted from the pinned agents inside `localhost/dev_base`
(2026-07-01); collision scan run against the same image — one shadow found (`pic`, see note).
**Suffix convention:** `c`=continue last · `r`=resume picker · `y`=yolo/skip-permissions ·
`h`=headless one-shot · `p`=plan-first. Every alias passes extra args through. Every entry
carries an annotation comment (`# @<category>: <description>`) — `uu aliases` renders the
catalog from those; the file is the single source of truth.

**agents — Claude Code** *(all flags verified)*: `cl` launch · `clc` `-c` · `clr` `-r` ·
`cly` `--dangerously-skip-permissions` · `clcy` continue+yolo · `clp` `--permission-mode
plan` · `cle` `--permission-mode acceptEdits` · `clh` `-p` headless · `clm <model>` `--model`.

**agents — Codex** *(verified; note `-c` is config-override, NOT continue)*: `co` launch ·
`coc` `codex resume --last` · `cor` `codex resume` · `coo` `--oss` local · `coh` `codex exec`
· `coa` `codex apply` · `cov` `codex review` · `coy` full-auto *(exact flag: verify at impl)*.

**agents — OpenCode** *(verified)*: `oc` launch · `occ` `-c` · `och` `opencode run` · `ocm`
`models` · `ocw` `web` · `ocpr <n>` PR checkout+launch. *(`oc` would collide with the
OpenShift CLI — not shipped in dev_base; documented, fallback rename `ocd`.)*

**agents — Pi** *(verified)*: `pic` `-c` · `pir` `-r` · `pih` `-p` headless. *(NOT `pip` —
Python collision. `pic` shadows groff's `/usr/bin/pic`: harmless — aliases are
interactive-only; groff/scripts invoke the binary directly. Documented.)*

**agents — OMP** *(verified)*: `omc` `-c` · `omr` `-r` · `omh` `-p` · profile passthrough
(`omp --profile` documented as the multi-login mechanism).

**agents — Hermes** *(verified)*: `he` `hermes` · `hec` `--continue` · `hey` `--yolo` ·
`hez "q"` `-z` one-shot · `hest` `hermes status`.

**agents — Cursor** *(flags: verify at impl as non-root)*: `cur [path]` `cursor
--no-sandbox` (default `.`) · `curd a b` `--diff` · `curg file:line` `--goto`.

**git**: `gs gl gd ga gc gp` (existing) + `gco` checkout · `gcb` checkout -b · `gb` branch ·
`gpl` pull · `gf` fetch · `gst`/`gstp` stash/pop · `gdc` diff --cached · `gcm "m"` commit -m ·
`gca` commit --amend · `glog` log --graph --oneline.

**gh**: `ghpr` pr create · `ghprs` pr status · `ghw` pr view --web · `ghi` issue list.

**tmux**: `ta` (existing) + `tls` list · `tn <name>` new · `tk <name>` kill.

**containers**: `host` (existing) · `docker=podman` · `dbl` distrobox list.

**llm**: `llm-models` `llm-ps` `llm-pull` (existing, unchanged).

**Shadowing rule (documented in the catalog header):** aliases exist only in interactive
shells — they never affect scripts, programs, or each agent's internal tool calls. The one
deliberate shadow (`pic`) is safe for exactly that reason. Verify-at-impl items: codex
full-auto flag · cursor CLI flags · `oc` naming final call.

## 9. Future directions (recorded, not designed)

Possible v2: verbs that invoke agents/subagents (e.g. auto-diagnose via the local model), or
deterministic "handoff bundles" (`uu doctor --explain` packaging failing checks + docs into a
paste-ready prompt, like `flavor-request.md`). Deliberately excluded from v1 — no hooks, no
partial implementation; revisit only if real usage shows the need.
