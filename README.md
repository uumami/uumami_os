# uumami_os — a reproducible local AI dev environment

Turn a fresh Linux box into a workstation where **local LLMs** power **isolated coding
agents**, each project walled off from the others, all reproducible from this repo.

You edit one small config file, run a handful of no-sudo scripts, and you get:

```
Host (Fedora Kinoite or compatible Linux)
│
├── llm_server                     shared inference — Ollama on 127.0.0.1:11434, GPU
│        ▲ all boxes reach it over loopback
│
└── dev boxes (distroboxes)        each = one identity + its own creds, code, config
    ├── os_agent  (Tier 0)         YOUR personal box: 6 CLI agents + Cursor
    └── client_<name> (Tier 2a)    a walled tenant: own Linux user, own everything
```

**Two ideas make the whole thing work:**
1. **One shared toolchain image (`dev_base`), many isolated boxes.** The base is shared so a
   fix propagates everywhere; everything *personal* (credentials, code, config) lives outside
   the image, per box, and never leaks between projects. ([How it's organized](#7--how-its-organized))
2. **The LLM server is separate shared infrastructure.** One model server, many agents.

> **You do not need to be an expert.** Step 0 below uses a **browser AI agent** to write the
> tricky hardware config *for* you — the scripts gather the exact facts; the browser agent
> turns them into a correct config. That is the intended starting point.

---

## What you need first

- A Linux host that runs **rootless Podman** and **distrobox** (this repo's reference target
  is **Fedora Kinoite 44**, atomic/SELinux — but the scripts detect your OS and adapt).
- A GPU is strongly recommended (AMD ROCm / NVIDIA CUDA); CPU-only works but is slow.
- `git`, `podman`, `distrobox` on the host. The scripts install their own `yq` (no sudo).

Clone this repo to `~/Containers` (the canonical location):

```bash
git clone <this-repo> ~/Containers && cd ~/Containers
```

Every script lives under `setup/lib/` and runs **on the host**. None of the core build needs
sudo or a reboot. Anything that *does* (creating extra Linux users, BIOS/VRAM changes) is
clearly flagged **🔶 human-required** and never run for you.

---

## 0 — Start here: bootstrap with a browser agent

This is the entry point. One command probes your machine and prepares everything:

```bash
bash setup/lib/ensure-yq.sh          # one-time: installs yq to ~/.local/bin (no sudo)
bash setup/lib/bootstrap.sh
```

`bootstrap.sh`:
1. **Probes** your hardware/OS (read-only) and writes the facts to `setup/facts.env`.
2. **Matches a flavor.** A *flavor* is the OS/hardware-specific config (GPU env, model pick,
   image pins). If one already exists for your machine, great. If not…
3. **Writes a browser-agent prompt** to `setup/flavor-request.md` — the detected facts plus
   the exact schema and research questions.

**Now use a browser AI agent** (ChatGPT, Claude, Gemini — whatever you have):

> Open `setup/flavor-request.md`, copy its whole contents, paste into your browser AI.
> It will research *your* GPU (the known-good Ollama image, the GPU env vars, how much VRAM
> your model can use) and hand back a ready `flavors/<your-machine>.yaml`. Save that file
> into `flavors/`.

Then re-run `bootstrap.sh` — it **validates** the result and scaffolds `config.yaml` if
needed. Why a browser agent? It can do live web research about your specific chip that a
static script can't; the script guarantees it works from the *correct* detected facts, never
guesses, and flags anything uncertain.

When bootstrap ends with `[validate] PASS`, your config is correct and you can build.

> **Already on the reference machine** (Strix Halo / Kinoite 44)? The flavors and `config.yaml`
> are committed and validated — bootstrap will just confirm `PASS`.

### Your config at a glance (`config.yaml`)

The only file you normally edit. OS/hardware values live in `flavors/` and merge over it.
Full reference: [`setup/schema/MANIFEST.md`](setup/schema/MANIFEST.md).

```yaml
flavor: fedora-kinoite-strix-halo   # your matched flavor (chains via `extends:`)
llm:   { backend: ollama, host: 127.0.0.1, port: 11434 }
agents:                             # which CLI agents get baked into dev_base
  claude_code: true                 # codex, opencode, pi, omp, hermes …  (flip any to false)
ide:   { cursor: true }             # the one GUI IDE
tenants: { default_tier: "2a", browser_default: shared }
```

Secrets never go here — each agent logs in *after* first entry, inside its own box.

---

## 1 — Build the inference server (`llm_server`)

Build the Ollama image, create its box (GPU wired in from your flavor), and run it as a
user service that survives logout:

```bash
bash setup/lib/llm_server.sh             # build image + (re)create the box, GPU flags from flavor
bash setup/lib/install-llm-service.sh    # enable the systemd USER service (no sudo)
```

Pull your model and **verify it runs on the GPU** (silent CPU fallback is the classic
failure — the PROCESSOR column must say GPU):

```bash
distrobox enter llm_server -- ollama pull qwen3-coder:30b
distrobox enter llm_server -- ollama ps          # PROCESSOR must show "100% GPU"
```

The endpoint is now at `http://127.0.0.1:11434`, reachable from every box over loopback.

---

## 2 — Build the dev base and your personal box

`dev_base` is the shared toolchain (git, node, python, the agents, Cursor). `os_agent` is
*your* Tier-0 box built on top of it. The images are assembled from modular `.layer` files
that you toggle in `config.yaml`:

```bash
bash setup/lib/validate.sh               # sanity-check config + flavors first
bash setup/lib/build.sh dev_base         # assemble Containerfile from enabled modules + build
bash setup/lib/build.sh os_agent         # FROM dev_base (adds no agents — inherits them)
```

`build.sh` calls `assemble.sh` to regenerate the (committed, auditable) Containerfile from
exactly the modules your toggles enable, then builds. Add a tool later = one `.layer` file +
one toggle; remove one = flip a boolean.

### 🔶 Create / enter your box

```bash
distrobox create --name os_agent --image localhost/os_agent:latest \
  --home "$HOME/Profiles/os_agent" \
  --volume "$HOME/Code:/workspace" --volume "$HOME/Containers:/containers:ro"
distrobox enter os_agent
```

> If you are running these instructions **from inside an existing `os_agent`**, the recreate
> must be done from a **host terminal** — a box cannot recreate itself. Profiles and mounts
> survive recreation; **never** pass `--rm-home` (it deletes your profile).

---

## 3 — First entry: log each agent in

The image ships the agent *binaries* only — no credentials. On first entry, initialize each
one into this box's own profile. Full per-agent guide with local-Ollama configs:
[`setup/templates/agent-configs/README.md`](setup/templates/agent-configs/README.md).

| Agent | First-run | Talks to local Ollama? |
|---|---|---|
| `claude` (Claude Code) | `claude login` (cloud) | only via a translation proxy — see guide |
| `codex` | `codex login` / key | yes (`codex --oss` or a provider config) |
| `opencode` | provider login | yes (`~/.config/opencode/opencode.json`) |
| `pi` / `omp` | endpoint on first run | yes (`~/.pi`, `~/.omp` model config) |
| `hermes` | `hermes model` wizard | yes (≥64K context — server is set for it) |

Drop the matching template from `setup/templates/agent-configs/` into the profile to point an
agent at `http://127.0.0.1:11434/v1`.

---

## 4 — Add isolated tenants (one per project or client)

`os_agent` is just your loosest tenant. For client work or any project you want **walled off**
(its own credentials, its own code, its own browser logins — optionally its own Linux UID),
you create another tenant. Same shape, stronger boundary. See
[per-project workflow](docs/per-project-workflow.md) for a worked two-project example and the
three ways to separate projects (sessions vs. boxes vs. per-project images).

Create a tenant from a manifest (`setup/templates/tenant-example.yaml` is the starting point):

```bash
cp setup/templates/tenant-example.yaml acme.yaml    # edit name / code / agents / sessions
bash setup/lib/tenant-create.sh --dry-run acme.yaml # preview every action first (optional)
bash setup/lib/tenant-create.sh acme.yaml
```

- **Tier 0** (under your user) is created immediately.
- **Tier 2a** (dedicated Linux user) prints the exact 🔶 sudo commands to create the user —
  the *only* privileged step — then you run the per-user setup as that user:
  `sudo -iu acme bash setup/lib/tenant-create.sh --user-setup acme.yaml`.

Inside the box, switch between **sessions** (same wall, different model/workdir/browser):

```bash
work acme-opus        # or: work --list
```

Cross-tenant isolation is **kernel-enforced and adversarially proven** (see
`setup/spikes/evidence-tenant-isolation.log`): one tenant's UID genuinely cannot read
another's 0700 credentials. The box never mounts `/models`; agents reach models only over
loopback.

---

## 5 — Updating and propagating fixes

Change a `.layer` (e.g. bump an agent version), then cascade the rebuild. Image builds are
automatic; box *recreates* are 🔶 human-required (and printed for you):

```bash
bash setup/lib/rebuild.sh                 # rebuild dev_base → every derived image; print recreate steps
```

Full guide, including how to pin a project to an older toolchain:
[propagating fixes](docs/propagating-fixes.md).

---

## 6 — How to work in here

The target working style — small reversible steps, the agent proposing the next task,
host changes only through explicit `distrobox-host-exec` with approval — is described in
[Zen coding practice](docs/zen-coding.md).

---

## 7 — How it's organized

Everything that survives deleting a box lives in exactly one of three places:

| Layer | What | Shared? |
|---|---|---|
| **Image** (`images/*/modules/*.layer`) | tooling, binaries, packages | ✅ `dev_base` shared by all boxes |
| **Profile** (the box's HOME, `~/Profiles/<name>`) | credentials, agent/IDE/git config, sessions | ❌ one per box |
| **Code mount** (`--volume … :/workspace`) | your project files | ❌ one per box |

Because the base is shared, **two projects on the same base cannot see each other's code,
credentials, or config** — and at Tier 2a they're separated by Linux UID (kernel-enforced).
Anything installed at *runtime* into a box's filesystem (outside profile/code) is the danger
zone — capture it in a `.layer` or a project setup script instead.

**Repo layout:**

```
config.yaml                 your choices (general layer)
flavors/                    OS + hardware layers (merge over config.yaml)
images/<name>/modules/      .layer fragments → assembled Containerfile
setup/lib/                  the scripts (detect, config-merge, assemble, build, validate, …)
setup/schema/MANIFEST.md    every config variable, layer-tagged
setup/templates/            per-agent local-Ollama configs + post-install guide
setup/spikes/               evidence records from validation spikes
docs/                       this tutorial's companion guides + the master design spec
```

### Extending it

- **New tool/agent:** add `images/dev_base/modules/NN-agent-foo.layer` with a `# toggle:`
  header and a config toggle. Re-run `build.sh dev_base`.
- **New OS:** add `flavors/<os>.yaml` + `setup/lib/os/<os>.sh` implementing the OS-module
  contract (`setup/lib/os-module.sh`). The core scripts never branch on OS.
- **New hardware:** run `bootstrap.sh`, hand the generated request to a browser agent, save
  the flavor. No code changes.
- **A project that needs different packages:** give it `images/<project>/modules/` and
  `build.sh <project>` (FROM dev_base) — it shares the base layers but gets its own tools.

---

## Reference

- [Master design spec](docs/superpowers/specs/2026-06-23-os-agent-setup-design.md) — the full architecture & rationale
- [Variables manifest](setup/schema/MANIFEST.md) — every config key, where it lives, its constraints
- [Post-install guide](docs/post-install-guide.md) — day-to-day usage: first entry, credentials, models, updating, troubleshooting
- [Agents guide](docs/agents-guide.md) — the operating rules for AI agents working inside the boxes
- [Per-agent post-install guide](setup/templates/agent-configs/README.md)
- [Per-project workflow](docs/per-project-workflow.md) · [Propagating fixes](docs/propagating-fixes.md) · [Zen coding](docs/zen-coding.md)
- [Validation runbook](docs/validation-runbook.md) — the human-in-the-loop tests (GPU memory expansion, os_agent recreate, real tenants, reboot survival)

**Invariants the scripts enforce** (and `validate.sh` checks): loopback-only inference;
agents never hold model weights; no secrets in images or committed config; no `--rm-home`;
no host container socket across a tenant; hardware values stay in flavors, never in
`config.yaml`.
