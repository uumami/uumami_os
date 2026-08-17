# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The operating rules for agents are in **[docs/agents-guide.md](docs/agents-guide.md)** — read them first.

## Project

`uumami_os` is the reproducible definition of a local-AI development workstation:
a shared GPU inference server (`llm_server`, Ollama on loopback) plus isolated dev boxes
(distroboxes) built from one shared toolchain image (`dev_base`). The full architecture and
the execution state live in `docs/superpowers/specs/2026-06-23-os-agent-setup-design.md`
(**Section 0 is the resume point** — read it before continuing any build work; it also records
validated machine facts that must not be re-researched).
Reference machine: Fedora Kinoite 44, Strix Halo (gfx1151); the framework is OS-generic.

There is no compiled code — the repo is bash (`setup/lib/*.sh`, `setup/bin/uu`), YAML config,
and `.layer` Containerfile fragments. Scripts are expected to be **idempotent** and
**shellcheck-clean**.

## Layout

```
install.sh                  THE entry point: guided, resumable, idempotent installer
config.yaml                 general config (toggles); hardware/OS values live in flavors/
flavors/                    OS + hardware overlays, merged over config.yaml (extends: chains)
images/<name>/modules/      .layer fragments → assemble.sh generates the Containerfile
setup/bin/uu                the CLI front door (deterministic facade; never calls a model)
setup/lib/preflight.sh      prerequisite gate — every build/create script calls it first
setup/lib/                  all scripts (detect, config, assemble, build, validate, rebuild,
                            bootstrap, llm_server, tenant-create, work, deploy-*)
setup/lib/os/<id>.sh        OS modules — core scripts never branch on the OS (see os-module.sh)
setup/schema/MANIFEST.md    every config variable, layer-tagged (source of truth)
setup/templates/            agent configs, tenant manifest example, QoL templates
setup/spikes/               evidence logs from validation spikes (claims must be backed here)
setup/test/selftest.sh      end-to-end validation (79 checks) — run ON THE HOST after changes
docs/                       tutorial companions + the master spec
```

## Key commands

```bash
bash install.sh --status              # what onboarding steps are done (changes nothing)
bash install.sh --dry-run             # preview the whole install without touching anything
uu status / uu help --agent           # front door + full machine contract for agents
uu repair                             # re-deploy aliases/uu/tmux into the CURRENT profile
bash setup/lib/preflight.sh           # prerequisite gate (exit 3 = something required missing)
bash setup/lib/validate.sh            # config/schema check — run before building
bash setup/lib/assemble.sh <img> --check   # Containerfile drift gate (no build)
bash setup/lib/build.sh <image>       # assemble .layers + podman build (dev_base, os_agent…)
bash setup/lib/rebuild.sh             # cascade: dev_base → derived images → recreate guidance
bash setup/test/selftest.sh           # full E2E validation on the host
bash setup/test/selftest.sh --quick   # skip live inference + real box create (fast, safe)
bash setup/lib/deploy-uu.sh --host    # symlink ~/.local/bin/{uu,work} → repo
```

Scripts run **on the host**; from inside a box use `distrobox-host-exec` (`uu` proxies itself
via `host_run`, so `uu` verbs work from either side). This agent usually runs inside `os_agent`
— it **cannot recreate its own box** (host terminal, human-required).

### Testing

`selftest.sh` is one script with numbered sections (`sect "N. …"`) and no per-test selector.
To iterate on one area, run its underlying command directly instead of the whole suite:

| Area | Targeted command |
|---|---|
| §2 config merge / schema | `bash setup/lib/validate.sh` |
| §3 Containerfile drift | `bash setup/lib/assemble.sh dev_base --check` |
| §7 tenant logic | `bash setup/lib/tenant-create.sh --dry-run setup/templates/tenant-example.yaml` (expects exit 2) |
| §9 static invariants | the `grep -rInE …` guards at the bottom of `selftest.sh` |
| §11 uu contract | `bash setup/bin/uu help --agent`, `uu status --json`, `uu clean --dry-run` |
| §12 onboarding | `bash setup/lib/preflight.sh --json`, `bash install.sh --status` |
| §13 create-prompt + keys | `grep -n 'distrobox enter' setup/bin/uu` (every hit must be guarded) |

Full-suite runs create and tear down a throwaway Tier-0 box; `--quick` skips that and the live
GPU inference check. Human-required checks (os_agent recreate, Tier-2a users, reboot survival)
are never executed — they live in `docs/validation-runbook.md`.

## Architecture in three moves

1. **Config resolves by layered merge.** `merge_config` (`setup/lib/config.sh`) deep-merges
   `config.yaml` → the flavor `extends:` chain (base→leaf, later wins). Every script sources
   `config.sh` and reads values via `cfg_get "$merged" '.some.path' default`.
2. **Images assemble from toggled modules.** `assemble.sh <image>` concatenates
   `images/<image>/modules/NN-*.layer` in lexical order into a **generated, committed**
   `Containerfile`. Each module needs a header: `# module:`, `# toggle: always | <yq.path>`,
   `# summary:`. A path-toggle is included only when that path is `true` in the merged config.
3. **Rebuilds cascade, recreates don't.** `rebuild.sh` rebuilds `dev_base` → derived images →
   *prints* the box-recreate commands (execution model A).

### Onboarding path (what a new user actually runs)

`install.sh` is the only thing a user should need. It is a step machine: `STEPS=(prereqs
location config server boxes shell verify)`, each `step_<name>` idempotent and re-verifying
reality (not just the state file at `~/.config/uumami/install-state`). Steps that need a human
call `pause_for_human` and exit 2. **Boxes are created through `tenant-create.sh` — including
os_agent** — because that is what runs the `deploy-*` QoL scripts; a hand-rolled `distrobox
create` produces a box with no aliases, no `uu`, and no session descriptor.

### Gotchas that bite

- **`distrobox enter <missing-box>` PROMPTS to create a fedora-toolbox box.** In a command
  substitution (`$(...)` with stderr discarded) that prompt is invisible and blocks on stdin
  forever — and answering yes silently creates a wrong box. Never call it without first
  checking `podman container exists`; prefer the loopback HTTP API (`/api/tags`, `/api/ps`)
  for anything read-only. `uu` has `box_exists`/`llm_box_run`/`llm_api` for this; selftest §13
  guards it.
- **Host-only scripts must refuse to run inside a box.** `selftest.sh` and `install.sh` check
  `/run/.containerenv` and exit with the host command to run instead. Without that they emit a
  wall of false failures ("distrobox missing", "images missing") that look like a broken install.
- **Never mint an SSH key non-interactively.** `deploy-ssh.sh` writes the `github.com` config
  block always, but only generates a key when it can prompt for a passphrase (or when given
  `--no-passphrase`). An unattended key would be an unencrypted credential inside the profile.
- **Don't hardcode a box's mounts.** `uu recreate` reads them off the live container with
  `podman inspect`; the previous hardcoded `$HOME/Code/system:/workspace` silently re-pointed
  the workspace on recreate.
- **`repo_root()` prefers the script's own location over the `~/.config/uumami/repo` pointer.**
  A stale pointer silently redirects `build`/`validate`/`rebuild`/`doctor` to a *different copy*
  of the project. The pointer is only a fallback for an installed copy of `uu` in `~/.local/bin`.
- **Anything a human retypes must be a real host path.** Strip the `/run/host` prefix (`hp()` in
  `tenant-create.sh`, `host_path()` in `install.sh`) — it exists on both sides here, but it
  reads as a broken path and belongs to the box, not the person.
- **A file referenced by printed instructions must outlive the command that printed it.**
  `uu tenant new` writes `~/.config/uumami/tenants/<name>.yaml`; it used to `mktemp` and delete
  it on exit, so the `--user-setup <manifest>` line it printed always failed.
- **Cross-user handoffs need a copy, not a path.** A tier-2a tenant cannot read the admin's 700
  profile, so the instructions `install -m 644 -o <user>` the manifest into the tenant's home.
- **`mv src dest` nests silently when `dest` exists** (you get `dest/src`, no error). Use
  `move_into_place`. And never let a y/n prompt default to yes when there is no tty —
  `install.sh` exits instead of guessing.
- **`os_agent` contains an underscore.** Name validators must allow `[a-z0-9_-]`; a kebab-only
  check made the installer fail on the manifest it generates itself.

- **`producer | grep -q` is a false-failure trap under `set -o pipefail`** (which `selftest.sh`
  sets). `grep -q` exits at the first match, the producer takes SIGPIPE and returns 141, and the
  pipeline reports failure *even though the match succeeded*. Capture first, then match against a
  here-string: `out="$(cmd)"; grep -q pat <<<"$out"`.
- **A desktop's `SSH_ASKPASS` names a HOST binary that does not exist in a box.** With `DISPLAY`
  also inherited, ssh prefers askpass over the terminal and dies instead of prompting — breaking
  passphrase-protected keys specifically, i.e. the secure ones, with a `Permission denied
  (publickey)` that looks exactly like an unregistered key. `uu-askpass` forwards the prompt to
  the host's dialog; deployed by `deploy-aliases.sh` (not `deploy-ssh.sh`) because that is what
  `uu repair` re-runs.
- **A bind mount follows the inode, not the path.** `install.sh --only location` does
  `mv ~/Containers ~/Containers.old`, so every *running* box keeps `/containers` pointed at the
  old directory until it is recreated — and dangles if that copy is then deleted.
- **Never hand-edit `images/*/Containerfile`** — generated; `build.sh` overwrites it and
  `assemble.sh --check` fails the selftest on drift. Edit the `.layer` and re-assemble.
- **`config.sh` is a sourced library and deliberately omits `set -e`/`-u`** (it would leak into
  callers; `validate.sh` runs without `-e` on purpose to collect *all* violations).
- **Never use yq's `//` on a config read** — it coalesces boolean `false` to the default, making
  a disabled toggle indistinguishable from a missing one. `cfg_get`/`validate.sh:q` handle this;
  selftest §2 has a regression guard for it.
- **Adding an agent/tool touches more than one file**: the `.layer` module, the toggle in
  `config.yaml`, the hardcoded agent lists in `validate.sh` (enum check + toggle↔module check),
  the agent loop in `selftest.sh` §5, and the tables in `README.md` /
  `setup/templates/agent-configs/README.md`.
- **Pin versions in `.layer` modules** and set `DISABLE_AUTOUPDATER`-style flags — images are
  immutable between rebuild cycles.

### Exit-code convention (execution model A)

`0` = done · `2` = **human-required** (instructions printed, nothing mutated) · `3` =
precondition failed · `1` = error. `tenant-create.sh`, the OS-module functions, and `uu` all
follow it, and selftest asserts on it — preserve it in anything new. Mutating verbs support
`--dry-run` (plan lines prefixed `would:` / `keeping:` / `review:` / `untouched:`) and `--yes`.
Read verbs (`uu status`, `tenant ls`, `models`, `aliases`) support `--json`.

## Invariants (enforced by validate.sh + selftest.sh — do not violate)

- Loopback-only inference (`127.0.0.1`); never `0.0.0.0`; no port publishing; `llm_server`'s
  Containerfile carries no `CMD`/`ENTRYPOINT`/`EXPOSE`.
- Agent boxes never mount `/models`; only `llm_server` holds weights; it holds no credentials.
- Never `--rm-home` (deletes a profile), never `podman prune -a`. Profiles are identity
  boundaries — never copy or symlink credential dirs between them.
- No secrets in images, `config.yaml`, or flavors — credentials are initialized per tenant
  after first entry (validate.sh greps for credential-like keys).
- Hardware/OS values live in `flavors/`, never in `config.yaml` (layer purity).
- No host container socket in any box; nested rootless podman only.
- Host-mutating steps (sudo, reboot, box recreation, tenant users) are emitted as
  `human-required` instructions, never executed silently.

## Rebuild cycle

Edit `.layer` → `build.sh` → `distrobox rm <name>` (no `--rm-home`) → `distrobox create`
(profile + mounts survive). `rebuild.sh` prints the exact recreate commands.
