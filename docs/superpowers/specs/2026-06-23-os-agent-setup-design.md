# Master Reference: uumami_os Development Environment Setup

**Status:** Phase 1 complete — approved for Phase 2 execution  
**Phase 2 mode:** Autonomous (no user input between subgoals)  
**Ground truth documents:** `atomic_distrobox_local_agent_architecture_requirements.md` and `fedora_kinoite_local_agent_canonical_runbook.md` — validate against them; do not redesign what they define.

---

## 1. Overview and End State

The goal is a tutorial and set of scripts that take someone from a fresh Linux install to a fully configured development environment by editing a small configuration file and following documented steps. The same tutorial must work on existing (non-fresh) machines via idempotent checks throughout.

**The scripts are OS-agnostic.** OS-specific behavior (package manager, group management, SELinux, immutability) is detected at runtime and handled through OS modules. A user fills in a config template for their OS; the scripts read it and adapt. Phase 2 produces one concrete config template — for Fedora Kinoite — but the framework must accommodate any OS that runs distrobox and rootless Podman. Adding a new OS means writing a new template and OS module, not changing the core scripts.

**The end state has three distrobox roles:**

```
Host (Fedora Kinoite or compatible Linux)
│
├── llm_server distrobox
│   ├── LLM inference server (default: Ollama) on 127.0.0.1:11434 (loopback only)
│   ├── GPU-accelerated (AMD ROCm / NVIDIA CUDA / CPU fallback)
│   ├── Model: config variable — default suggestion: largest qwen3-coder that fits VRAM
│   └── Accessible to any distrobox via host network namespace
│
├── os_agent distrobox  (CLI agents only — broad workspace access)
│   ├── Claude Code      (Anthropic — calls Anthropic cloud, login per distrobox)
│   ├── Codex            (OpenAI — calls OpenAI cloud, login/key per distrobox)
│   ├── OpenCode         (configurable: local Ollama or cloud)
│   ├── Pi / pimono      (configurable: local Ollama or cloud)
│   ├── Hermes harness   (NousResearch — configurable: local Ollama or cloud)
│   └── Podman client    (host socket passthrough — no nested daemon)
│
└── project boxes  (one per project/client — from dev_base, own profile, own code mount)
    ├── OMP (omp.sh IDE — configurable, exported to host desktop)
    ├── Cursor IDE        (configurable, exported to host desktop)
    └── CLI agents (inherited from dev_base — initialized per box)
```

IDE tools (OMP, Cursor) live in **per-project boxes, not os_agent**. This is the isolation boundary: the IDE's AI assistant can only see the code mounted in that box. Credentials are in that box's profile. Two client projects cannot see each other's files by construction.

**Persistent state lives outside containers, in four host directories:**

| Directory | Contents |
|---|---|
| `~/Containers/` | Containerfiles, modules, and service definitions (this repo) |
| `~/Profiles/` | One isolated HOME per distrobox |
| `~/Models/` | Model weights (mounted into llm_server at `/models`) |
| `~/Code/` | Source workspaces |

**The three-layer model — everything that survives a container deletion must be in one of:**
1. **Image** (Containerfile) — reproducible tooling, binaries, packages
2. **Profile** (`~/Profiles/<name>/`) — credentials, IDE settings, agent sessions, git config
3. **Code mount** (`~/Code/<project>/`) — project files, project-local venvs, node_modules

Runtime installs to the container filesystem (`/usr/local`, global npm/pip outside the profile) are the danger zone. If a container is deleted for any reason, anything there is gone. The image + profile + code mount must be sufficient to fully reconstruct the working environment.

This is a design **principle**, not a mechanically enforced gate. Capture project-specific tooling in the Containerfile, or in an optional committed setup script inside the code mount, as suits the project. The point is that nothing important should live *only* in a container's ephemeral filesystem.

**Two base images:**
- `dev_base` — shared Fedora toolchain; parent for os_agent and all project boxes
- `llm_server` — Ollama (or alternative LLM backend) image; standalone

**Container engine:** Podman is the default (rootless, no daemon, built into Kinoite). Docker is supported via a flavor toggle. The choice affects only where image layers are cached and how the engine is managed — the four host directories above are identical either way.

The tutorial must also produce:
- A curated guide for humans and agents on how to use the environment after setup
- A "Zen Coding Practice" section defining the target working style
- A per-project workflow pattern (one box per project, optional inheritance)
- A propagating-fixes guide

---

## 2. Architecture

### 2.1 Why Ollama is separate (not inside os_agent)

Ollama is long-running shared infrastructure. Its lifecycle (model loading, GPU memory, restart behavior) is independent of which agent is calling it. If Ollama lived inside os_agent, it would restart whenever the agent box is rebuilt or recreated. Every future project distrobox would need its own model copy. Separating them means: one model server, many agents, clean rebuild cycles for each.

Since distrobox uses the host network namespace, `127.0.0.1:11434` is reachable from every distrobox on the machine without port publishing. This is a design invariant.

### 2.2 Profile isolation

Each distrobox receives a `--home` pointing to a dedicated directory under `~/Profiles/`. This means git config, SSH keys, AWS credentials, agent sessions, and shell history are isolated per box. The container filesystem is disposable; the profile survives.

**Security note:** Distrobox mounts `/run/host` in every box, giving read access to the full host filesystem. Profile isolation prevents *accidental* config mixing; it is not a strong security sandbox. The os_agent is a trusted workstation actor.

**Security note:** The `--volume ~/Containers:/containers` mount in os_agent is `:ro` (read-only). The agent reads definitions; it does not write them. An agent modifying its own service definition is not the correct workflow.

### 2.3 Inheritance hierarchy

```
dev_base image (Fedora, core dev tools)
└── project distroboxes (one per project/org, own profile, own code mount)

llm_server image (Ollama + GPU userspace)
└── llm_server distrobox

os_agent image (from dev_base or standalone, adds coding agents)
└── os_agent distrobox
```

Do not create additional parent images speculatively. Add a shared layer only when duplication between two real, stable images justifies it.

### 2.4 Podman in os_agent

os_agent contains the Podman *client binary* only. The host Podman socket is passed in explicitly when needed for specific tasks. There is no nested Podman daemon inside the distrobox. This follows the architecture requirements document section on agent permissions.

### 2.5 Agent client provider model

**CLI agents (in os_agent):**

| Client | Provider | Local Ollama? |
|---|---|---|
| Claude Code | Anthropic (account login or API key) | No — format incompatible |
| Codex | OpenAI (account login or API key) | No — standard provider |
| OpenCode | Configurable in profile | Yes — `~/.config/opencode/opencode.json` |
| Pi (pimono) | Configurable in profile | Yes — endpoint + optional API key |
| Hermes harness | NousResearch, configurable | Yes — Ollama → `hermes3:8b` |

**IDE tools (in per-project boxes — NOT os_agent):**

| Tool | Type | Provider |
|---|---|---|
| OMP (omp.sh) | GUI IDE | Configurable per project box |
| Cursor | GUI IDE (Electron) | Configurable per project box |

Claude Code and Codex use their standard cloud providers as designed. The configurable clients (OpenCode, Pi, Hermes, OMP, Cursor) choose local Ollama or cloud per distrobox at initialization time.

### 2.6 LLM server module design

The `llm_server` distrobox exposes an OpenAI-compatible endpoint. The implementation (Ollama, Lemonade, llama-server) is a swappable module — the contract to the rest of the system is just the endpoint URL. Agent clients never depend on which backend is running.

**Default module: Ollama**

Validated by research as the right default for single-user interactive workstations across NVIDIA, AMD, and CPU. Best model management UX, broadest hardware coverage via official images.

**Hardware-specific tuning lives in the hardware flavor, not here.** GPU environment variables (AMD `HSA_OVERRIDE_GFX_VERSION`, `OLLAMA_IGPU_ENABLE`, NVIDIA CUDA settings, etc.), the chosen ROCm/CUDA/Vulkan path, model selection, and context-length tuning are all flavor-level concerns. The general llm_server design only knows: "start the LLM backend module, bind loopback, read its env block from the active flavor." See §2.7 for the flavor system, and the flavor worked example for the concrete gfx1151 block.

**Alternative module: Lemonade (AMD)**

AMD's own open-source local AI server. Explicitly targets recent AMD APUs/GPUs with ROCm bundled — no separate ROCm installation needed. OpenAI-compatible API. Best fallback if the Ollama ROCm path has persistent issues on specific AMD hardware. Selected via the `llm_backend` config variable; the framework treats it as another module behind the same endpoint contract. GitHub: `lemonade-sdk/lemonade`. (Versions and exact endpoint port to be confirmed by SG2 research.)

**No router/proxy layer.** LiteLLM and similar gateways are deliberately excluded: LiteLLM had a confirmed supply-chain compromise and carries a large Python attack surface for a single-user box. Backend switching is achieved by changing the `llm_backend` config value, not by running a proxy — the module interface already decouples clients from the backend. If URL-level routing is ever genuinely needed, a minimal audited option (llama-swap, or nginx upstream) is preferred over a large dependency.

**Backends confirmed dead/unsupported (do not build on):**
- LiteLLM: supply-chain compromise + large attack surface — excluded as proxy
- TGI (Hugging Face): archived March 2026
- IPEX-LLM (Intel): archived by Intel January 2026 — Intel Arc has no viable container path
- MLC-LLM: incompatible with ROCm 7
- cortex.cpp: archived July 2025
- KoboldCpp ROCm fork: stops at gfx1102 — no gfx1151 or gfx1201 support
- llamafile: ROCm path largely untested on gfx1151

### 2.7 Configuration: general → OS flavor → hardware flavor

Configuration is layered. Each layer is a YAML file; layers are merged at runtime in order, later overriding earlier. Nothing hardware- or OS-specific ever lives in the core scripts.

```
config.yaml                                  general schema + sensible defaults (OS/hardware-agnostic)
  └── flavors/fedora-kinoite.yaml            OS specifics: rpm-ostree, SELinux booleans, :Z, linger
        └── flavors/fedora-kinoite-radeon-8060s.yaml   hardware: gfx env block, model pick, context length
              └── user overrides (optional)  anything the user sets explicitly wins last
```

**Merge order:** general → OS flavor → hardware flavor → user overrides. The active flavor chain is named in `config.yaml` (e.g. `flavor: fedora-kinoite-radeon-8060s`, which itself declares `extends: fedora-kinoite`).

**What goes where:**
- **General (`config.yaml`):** the variable schema, agent toggles, paths, distrobox names, model *suggestion* (not a hard value), defaults that are true everywhere.
- **OS flavor:** package manager behavior, SELinux handling, immutability, linger — anything that differs by operating system. Pairs with the OS module (SG8).
- **Hardware flavor:** GPU backend, GPU env vars, ROCm/CUDA/Vulkan path, concrete model choice, context length. The gfx1151 block lives *only* here.

**Phase 2 produces three concrete files as a worked set:** the general `config.yaml`, one OS flavor (`fedora-kinoite`), and one hardware flavor (the target machine, e.g. `fedora-kinoite-radeon-8060s`). Together they prove the layering works. Any new OS or chip is a new flavor file — never a change to core scripts.

**Worked example — the gfx1151 hardware flavor** (`flavors/fedora-kinoite-radeon-8060s.yaml`), values to be confirmed by SG2/SG3:
```yaml
extends: fedora-kinoite
gpu:
  backend: amd
  path: rocm          # not vulkan — vulkan hangs on Qwen3.5/GLM
  env:
    HSA_OVERRIDE_GFX_VERSION: "11.5.1"   # without this: silent CPU fallback
    OLLAMA_IGPU_ENABLE: "1"              # fixes VRAM detection regression in Ollama 0.30.x
    OLLAMA_FLASH_ATTENTION: "1"
    # HSA_ENABLE_SDMA: "0"               # only on kernel 6.19.x
model:
  primary: qwen3-coder:30b
  context_length: 65536
versions:
  ollama: "0.21.0"    # known-good with ROCm 7.2.2; pin for reproducibility
```

### 2.8 Credential isolation is structural, not a policy

The `--home ~/Profiles/<name>` flag on each `distrobox create` command is what makes isolation real. `~/.claude/` inside `os_agent` resolves to `~/Profiles/os_agent/.claude/`. Inside `project_x`, it resolves to `~/Profiles/project_x/.claude/`. These paths are physically separate; there is nothing to configure or enforce. A Claude Code session initialized in one box cannot be seen by another box by construction.

This means: every agent in every distrobox is initialized interactively after first entry. Re-logging in per box is expected and correct — it is the isolation working as intended. One distrobox = one identity = one set of credentials for each agent.

---

## 3. Pre-Phase 2 Decisions

**The following must be decided by the human before the Phase 2 goal is launched.** Phase 2 is autonomous and cannot resolve these. Each decision must be recorded in `config.yaml` or the active flavor file.

| Decision | Options | Default |
|---|---|---|
| CLI agents in os_agent | All five / subset | All five |
| IDE tools in project boxes | OMP / Cursor / both / neither | Both (in dev_base) |
| LLM backend module | ollama / lemonade / llama-server | ollama |
| GPU backend | auto / amd / nvidia / cpu | auto (set in hardware flavor) |
| Primary model | Config variable — largest qwen3-coder that fits VRAM | `qwen3-coder:30b` |
| Config format | YAML (`config.yaml` + flavor overlays) parsed by `yq` | YAML |
| Containerfile structure | Modular (one `.layer` file per agent, assembled by build script) | Modular |
| Container engine | podman / docker | podman |
| Podman client in os_agent | Client-only with host socket passthrough / Omit | Client-only |
| Active flavor | An OS flavor, optionally extended by a hardware flavor | `fedora-kinoite` (+ hardware flavor) |

**Note on credentials:** Claude Code and Codex use their standard providers (Anthropic and OpenAI). No path decision needed — credentials are initialized interactively per distrobox after first entry. OpenCode, Pi, and the Hermes harness are configured per distrobox at initialization time to point at local Ollama or a cloud provider.

**Note on primary model:** The primary-model config variable is a suggestion, not a constraint. The recommended default is the largest `qwen3-coder` variant that fits available VRAM — for most setups with 24 GB+ VRAM that is `qwen3-coder:30b`. It lives in the hardware flavor. The tutorial must document how to choose: check `nvidia-smi` or `rocm-smi` for VRAM, pick the largest variant that leaves headroom. Users can set any model available in the Ollama library.

**Note on the bootstrap path:** A non-coder is not expected to fill these in by hand. The bootstrap subgoal (SG10) produces a script that probes the machine, then guides the user — optionally with a browser LLM — to generate a correct `config.yaml` + hardware flavor following best practices. The defaults above are what that flow falls back to.

Record decisions before launching. Phase 2 reads them from `config.yaml` and the active flavor, does not ask.

---

## 4. Autonomous Execution Contract

Phase 2 runs without user input from start to finish. This section defines how.

### 4.1 Expert panel pattern

At each subgoal, a panel of **at least 3 independent subagents** is convened. Each receives:
- The subgoal's stated inputs and success criteria
- The ground truth documents
- The decisions record from Section 3
- A different search angle or specialization focus

Subagents do not see each other's work during their investigation. Findings are synthesized after all panel members complete. The synthesis must resolve conflicts explicitly — not average them.

### 4.2 Internet research

Every subgoal that touches an external tool, package, or service must use WebSearch and WebFetch to verify current behavior. Documentation, package versions, and CLI flags change. Assumptions from the existing runbook must be confirmed against current official sources, not assumed to be correct.

Specifically: current npm package names and versions, current distrobox CLI flags, current `ollama/ollama:rocm` image tags, current agent config schema URLs.

### 4.3 Spikes

A spike is a small, isolated, non-destructive test that validates one assumption before any design is committed. Spikes are run by subagents or by the main agent in throwaway containers or isolated files. A spike must produce a binary pass/fail result with a log.

See Section 5 for the required spike at each subgoal.

### 4.4 Output contract per subgoal

Every subgoal must produce:
1. **Primary artifact** — the file, config, script, or decision produced
2. **Decision log** — what alternatives were considered and why they were rejected
3. **Open questions resolved** — items from the prior subgoal's open questions list that this subgoal closed
4. **Open questions raised** — new questions surfaced during this subgoal, for the next
5. **Validation gate result** — pass or fail, with evidence

If the validation gate fails, Phase 2 halts and writes a structured failure report. It does not proceed to the next subgoal with a broken state.

### 4.5 Hard rules for autonomous execution

- **Subgoal 0 is read-only.** The isolation audit produces a report. It does not remediate anything. Moving, deleting, or modifying credential files during an audit can corrupt an active session.
- **No `distrobox-host-exec` calls during Phase 2.** Phase 2 generates artifacts; it does not apply them to the live host.
- **No `--rm-home` ever.** This would delete a persistent profile. It is not the correct teardown path.
- **Runbook = ground truth.** If a spike produces a result that conflicts with the canonical runbook, the spike wins if it has reproducible evidence. If it does not, the runbook wins. The conflict must be logged either way.
- **Subgoal 8 (script implementation) is a fan-out.** The list of scripts produced by Subgoal 7 determines the instances. Do not bundle all scripts into one task; implement one per sub-subgoal in parallel where dependencies allow.

---

## 5. Ordered Subgoals

### SG0 — Isolation Audit
**Input:** None  
**Goal:** Understand the current state of the machine before doing anything else. Identify config pollution (credentials at the host level that should be inside a profile), existing distroboxes, existing images, existing services.  
**Expert panel:** Not required for this subgoal (read-only scan, no design decisions).  
**Spike:** None.  
**Output:** A structured audit report listing: (a) any credentials found outside `~/Profiles/`, (b) existing distroboxes and their home directories, (c) existing Podman images, (d) existing systemd user services, (e) whether `render` and `video` groups are correct for the current user, (f) whether `loginctl enable-linger` is active.  
**Validation gate:** Report is written. No changes made to the system.

---

### SG1 — Host Prerequisites Check
**Input:** SG0 audit report  
**Goal:** Detect the OS and verify the host baseline. Detection drives which OS module is loaded for all subsequent scripts.

OS detection must identify: package manager (`rpm-ostree` / `dnf` / `apt` / other), immutability model (atomic/mutable), SELinux status, init system. This is the single place OS differences are resolved — everything downstream uses the detected values through the OS module interface.

General checks (all OS): podman installed and rootless, distrobox installed, git installed, user in correct GPU groups, GPU device nodes present, lingering enabled, `fuse-overlayfs` available.

OS-module checks (examples from Kinoite template): `rpm-ostree` present, overlay filesystem type, SELinux mode enforcing.

**Expert panel:** Not required. This is detection and verification, not design.  
**Spike:** `podman run --rm hello-world` to verify rootless Podman works.  
**Output:** (a) Detected OS profile, (b) prerequisites checklist with pass/fail per item and the exact fix command per item, (c) OS module path that will be sourced by all subsequent scripts.  
**Validation gate:** OS detected, all critical items pass or have a documented fix, rootless Podman spike passes.

---

### SG2 — Deep Research
**Input:** SG0 audit report, SG1 checklist, ground truth documents, Pre-Phase 2 decisions  
**Goal:** Produce a verified research summary covering:
- How distrobox works internally: `--home`, `--init`, `--no-tty`, device passthrough flags, `/run/host`, `distrobox-host-exec`, current CLI version and any breaking changes
- How Ollama serves models: API endpoints, model management, GPU detection, `OLLAMA_HOST` / `OLLAMA_MODELS` / `OLLAMA_CONTEXT_LENGTH` semantics, current `ollama/ollama:rocm` image tag
- Each agent client: current npm package name and version, install method, local Ollama endpoint configuration (is it possible without an API key?), config file location and schema version, known Linux/container issues
- GPU passthrough: AMD device nodes + group requirements, NVIDIA CDI vs. `--nvidia` flag status, Intel GPU support status in current Ollama
- Fedora package names for core tools (fd-find vs fd, ripgrep, gh, etc.) in current Fedora version

**Expert panel:** 3 subagents, each assigned a different research domain:
- Subagent A: distrobox internals + systemd integration; `distrobox-export --app` GUI export flow (for IDEs)
- Subagent B: LLM backend modules + GPU passthrough — Ollama (AMD/NVIDIA), Lemonade (package, endpoint port, AMD coverage), llama-server; confirm which version/path works per GPU family
- Subagent C: each agent + IDE — Claude Code, Codex, OpenCode, Pi/pimono, NousResearch Hermes harness, OMP (omp.sh), Cursor. For each: install method, package name and version, config file location and schema, credential init flow, known Linux/container issues. **Two specifically need their package/repo confirmed from scratch: the Hermes harness, and OMP (omp.sh)** — neither was conclusively identified in Phase 1.

Each subagent uses internet search heavily. Each produces a structured findings document with source citations. Conflicts between subagent findings are resolved by a synthesis step that fetches primary sources.

**Spike:** None in this subgoal — spikes follow in SG3.  
**Output:**
1. Research summary document with citations
2. List of verified facts (safe to use without re-checking in later subgoals)
3. List of open questions that spikes in SG3 must close
4. Decision log: what sources were consulted, which were authoritative

**Validation gate:** Every open question from SG0/SG1 is addressed. Every agent client's local Ollama endpoint support is answered with evidence (not assumption).

---

### SG3 — Architecture Validation Spikes
**Input:** SG2 research summary and open questions list  
**Goal:** Close the open questions from SG2 with runnable evidence. Validate that the canonical architecture still holds given current software versions.  

**Required spikes:**

| Spike | Tests | Pass condition |
|---|---|---|
| A — Configurable agent local endpoint | For OpenCode, Pi, and Hermes harness: install in throwaway container, point at local Ollama (or mock), verify connection and model selection work without a cloud API key. Claude Code and Codex are not tested against local endpoints — they use their standard providers. | Each configurable client connects to local endpoint, returns a response, accepts model selection |
| B — Distrobox systemd stability | Create minimal distrobox, write systemd user unit with `--no-tty --no-workdir`, enable it, simulate session restart, verify unit starts | Unit starts, ollama serve begins, `curl :11434/api/tags` responds |
| C — Profile isolation | Create two distroboxes from same image with different `--home`, write file in one, verify absent in other | Files are isolated |
| D — GPU passthrough | Start llm_server distrobox with device flags, run `ollama serve`, verify GPU is detected (not CPU fallback) in `ollama ps` PROCESSOR column | PROCESSOR shows GPU, not CPU |
| E — SELinux volume mount | Mount a directory with and without `:Z`, verify access from inside distrobox on SELinux-enforcing host | `:Z` is required on Kinoite; document the flag |
| F — Podman build ARG | `podman build --build-arg FEDORA_VERSION=$(rpm -E %fedora)` against trivial Containerfile | ARG expands correctly, correct base image pulled |

**Expert panel:** Panel of 3 reviews spike results and flags any that contradict the canonical runbook. Conflicts are logged and resolved before proceeding.  
**Output:**
1. Spike result log (pass/fail per spike, with reproduction steps)
2. Architecture confirmation: the canonical design (llm_server + os_agent + dev_base/project boxes) is validated, or a specific deviation is documented with evidence
3. Updated open questions list (anything not resolved by spikes)
4. Decision log

**Validation gate:** All required spikes pass. Any failed spike has a documented resolution path before SG4 begins.

---

### SG4 — Variables Manifest
**Input:** SG3 spike results, Pre-Phase 2 decisions  
**Goal:** Define every variable the setup uses, what it controls, where it lives, and what its constraints are. This manifest is the source of truth for all subsequent subgoals — SG5–SG9 must not introduce ad-hoc variables that are not in this manifest.

**Variables to define (at minimum):**
- GPU backend (amd / nvidia / cpu / auto)
- Ollama primary model name — config variable, not hardcoded. Suggestion: largest `qwen3-coder` variant that fits VRAM. Default suggestion: `qwen3-coder:30b`. Config template lists alternatives as comments. User overrides freely.
- Ollama host and port
- Ollama context length (VRAM-dependent — document minimum VRAM per context length)
- Profile base directory
- Models directory
- Containers directory
- Code directory
- Distrobox names (llm_server, os_agent)
- Image names
- Fedora version (for dev_base build)
- Agent install toggles (claude-code / codex / opencode / pi / hermes-harness)
- IDE toggles (omp / cursor) — consumed by dev_base, not os_agent
- LLM backend module (ollama / lemonade / llama-server)
- Container engine (podman / docker)
- Per-agent credential initialization method (documented in post-install guide; not a build-time variable)
- GitHub email and username (for profile git config)

**Each variable must be tagged with its layer:** general / OS-flavor / hardware-flavor. This tagging determines which file it lives in (§2.7). Hardware-specific values (GPU env, model pick, context length) must be tagged hardware-flavor and must not appear in the general schema.

**Expert panel:** 2 subagents independently draft the variable list; synthesis reconciles differences.  
**Output:** `config.yaml` schema specification + the flavor-overlay structure (which keys belong to general vs. OS flavor vs. hardware flavor). Specs, not the final files.  
**Validation gate:** Every variable used in SG5–SG9 can be traced to this manifest and is tagged with its layer. No orphan constants. No hardware-specific value in the general schema.

---

### SG5 — Base Image Design (`dev_base`)
**Input:** SG2 research (package names, IDE install methods), SG4 variables manifest  
**Goal:** Define what goes in the Fedora-based `dev_base` image that all project distroboxes inherit from. Derive contents from: what the coding agents need (verified in SG2), what developers expect, what the canonical runbook specifies.

**dev_base also carries the IDE tools** (OMP, Cursor), gated by the `omp` / `cursor` toggles, because per-project boxes inherit from dev_base and that is where IDEs live (never in os_agent). Each IDE is its own modular `.layer` file so a user who wants neither can build a lean image. IDE credentials and settings persist in the per-project profile (`~/.cursor/`, OMP config dir); only the binary is in the image. Exported to the host desktop via `distrobox-export --app`.

**Modular Containerfile structure** (the decided approach): each agent/IDE is one `.layer` fragment under `dev_base/modules/`; a build script assembles the final Containerfile from the toggles in `config.yaml`. The generated Containerfile is committed/auditable. Adding a tool = one new `.layer` file + one toggle. Removing one = flip a boolean.

**Expert panel:** 3 subagents each propose a package list from different angles:
- Subagent A: minimum viable (what do the agents strictly require?)
- Subagent B: developer ergonomics (what would a developer miss on first entry?)
- Subagent C: review Subagent A + B and identify conflicts or redundancies

Synthesis produces the final list with justification for each package included.

**Output:**
1. `dev_base` Containerfile specification + the modular `.layer` module set (spec, not final files)
2. IDE inclusion spec (OMP, Cursor): install method, toggle behavior, export-to-host flow
3. Decision log: what was included and why, what was excluded and why
4. Open questions raised

**Validation gate:** Every package in the spec has a verified Fedora package name (from SG2 research). No package that belongs only in os_agent is in dev_base. Each agent/IDE is an independently toggleable module.

---

### SG6 — llm_server Design
**Input:** SG2 research (Ollama image, GPU passthrough), SG3 spike results (especially Spikes B, D, E), SG4 variables manifest  
**Goal:** Define the llm_server Containerfile and systemd user service. The canonical runbook already has a working version; this subgoal validates it against current software and produces a reviewed, spike-confirmed version.

The Containerfile and service stay **hardware-agnostic**: they read the GPU env block from the active flavor (§2.7) rather than hardcoding any chip's variables. The design names *where* env comes from; the flavor supplies the values.

**Items to validate against current state:**
- Correct LLM backend image tag and version, pinned for reproducibility (from the flavor's `versions` block)
- `ENV OLLAMA_HOST`, `ENV OLLAMA_MODELS`, `ENV OLLAMA_CONTEXT_LENGTH` wiring (values from flavor)
- GPU env block is injected from the active flavor — Containerfile/service contain no chip-specific constants
- No `CMD` or `ENTRYPOINT` (Distrobox lifecycle management)
- Systemd unit with `--no-tty --no-workdir` (confirmed by Spike B)
- Device passthrough flags for AMD and NVIDIA (confirmed by Spike D)
- Volume mount flags including `:Z` for SELinux (confirmed by Spike E)
- SELinux boolean: `sudo setsebool container_use_devices=1` — required on Fedora for GPU device access (OS-flavor concern)
- `loginctl enable-linger` requirement
- User group requirements (`render`, `video`)
- GPU verification: after startup, `ollama ps` PROCESSOR column must show GPU — silent CPU fallback is a known failure mode (e.g. AMD gfx1151 without its flavor env block)

**Worked validation against the gfx1151 flavor:** confirm the env block from `flavors/fedora-kinoite-radeon-8060s.yaml` (HSA override, IGPU enable, flash attention; ROCm not Vulkan) produces GPU inference, not CPU fallback. This is the concrete proof that the flavor mechanism feeds the general design correctly.

**Expert panel:** 2 subagents review the canonical runbook's llm_server section against SG3 spike results. One plays devil's advocate — tries to find a case where the canonical version fails. The other defends it. Synthesis resolves the conflict.

**Output:**
1. llm_server Containerfile specification
2. `llm_server.service` specification
3. `distrobox create` command specification (exact flags, with GPU branching)
4. Validation gate procedure (the exact commands to run to confirm llm_server is working)
5. Decision log

**Validation gate:** The specification produces a system that passes the runbook's Phase 4 and Phase 6 validation gates: API responds, no CPU fallback, model can be pulled, service survives session restart.

---

### SG7 — os_agent Design
**Input:** SG2 research (each agent client), SG3 Spike A results, SG4 variables manifest, SG5 dev_base spec  
**Goal:** Define the os_agent Containerfile and its configuration. Each agent client's config is specified here (not in SG4) because config depends on what is installed.

**Scope note:** os_agent holds **CLI agents only**. IDE tools (OMP, Cursor) are designed in SG5 (dev_base) and live in per-project boxes. Do not add IDEs here.

**Items to define:**
- Base image: dev_base, or standalone? (Decide based on SG5 and whether the tools overlap enough)
- Each agent: install method (npm global, binary, other), verified package name and version pin, stored in image via its `.layer` module file (modular structure per SG5)
- Claude Code: standard Anthropic login — `claude login` after first entry; session in `~/.claude/` (profile, persists across rebuilds)
- Codex: standard OpenAI login or API key — initialized after first entry; no build-time credential
- OpenCode: `~/.config/opencode/opencode.json` schema (verified against installed version); configurable to local Ollama or cloud
- Pi (pimono): endpoint and optional API key configured after first entry; local Ollama or pi.dev cloud
- Hermes harness: install method and package name verified by SG2 Subagent C; configured to call local Ollama (`hermes3:8b`) or cloud
- Podman client binary: included, with host socket passthrough documented
- Volume mounts: `/workspace`, `/containers:ro`, `/models` (read-only in os_agent — models belong to llm_server)
- Profile layout: what directories exist under `~/Profiles/os_agent/` on first use

**Expert panel:** 3 subagents:
- Subagent A: focuses on agent client configuration (config file formats, env vars, credential isolation)
- Subagent B: focuses on image construction (FROM choice, layer efficiency, build args, version pinning)
- Subagent C: reviews the result against isolation invariants from the architecture requirements document

**Output:**
1. os_agent Containerfile specification
2. Per-agent post-install credential initialization guide (what to run after first entry, per agent)
3. Per-agent config spec for configurable clients (OpenCode JSON schema, Pi endpoint config, Hermes harness config)
4. `distrobox create` command specification for os_agent
5. Decision log (especially: standalone vs. dev_base inheritance decision)

**Validation gate:** Spec passes Spike A criteria (OpenCode, Pi, Hermes harness each connect to local Ollama endpoint). Claude Code and Codex are not tested against local endpoints — their credential initialization is documented, not automated.

---

### SG8 — Script Architecture
**Input:** SG4 variables manifest, SG5–SG7 specifications  
**Goal:** Define how the scripts are structured — not the scripts themselves. Decide: delivery format (shell scripts, Makefile, other), ordering, idempotency pattern, error handling convention, how OS detection works.

**Key decisions for the expert panel:**
- Shell scripts vs. a lightweight task runner (Make, just, etc.) — must work for both humans and agents
- OS module interface: what functions every OS module must implement (e.g., `pkg_install`, `pkg_is_installed`, `add_user_group`, `selinux_label_volume`, `is_immutable_host`) so core scripts never contain OS conditionals
- Idempotency pattern: how each step checks if it's already done before acting (`distrobox list` for existence, `podman image exists` for images, etc.)
- Config template structure: what a template for a new OS looks like, what fields it must provide
- Error handling: how failures are reported, whether partial state is left or cleaned up
- How the config file and OS module are sourced and validated before any script runs
- The exact list of scripts, in order, with their names and one-line descriptions

**Expert panel:** 2 subagents propose a script architecture independently. Synthesis reconciles. The output must include the named script list that SG9 uses as its fan-out index.

**Output:**
1. Script architecture specification (format, conventions, patterns)
2. OS module interface specification (the function signatures every OS module must implement)
3. Fedora Kinoite OS module implementation (the one concrete module Phase 2 produces)
4. Named and ordered script list (this becomes the SG9 fan-out index)
5. Idempotency patterns document (the exact shell patterns to use for each type of check)
6. Decision log

**Validation gate:** The named script list covers every step from SG0's audit to SG13's validation without gaps. Each script has a clear single responsibility.

---

### SG9 — Script Implementation
**Input:** SG8 named script list and architecture spec, SG4–SG7 specifications  
**Goal:** Implement each script defined by SG8. This is a fan-out — one sub-subgoal per script, parallelized where script dependencies allow.

**For each script:**
1. Implement according to architecture spec and relevant design spec
2. Run `shellcheck` (or equivalent linter) — zero warnings required
3. Test idempotency: run twice, verify second run produces no errors and no unintended changes
4. Verify the specific validation gate defined in its parent subgoal (SG5/SG6/SG7 as applicable)

**Scripts that touch `~/Profiles/` must be reviewed for:** `--rm-home` usage (prohibited), credential file modification (prohibited in automated paths), hardcoded paths that should be variables.

**Output:** Implemented, linted, idempotency-tested scripts for each item in the SG8 list.  
**Validation gate:** All scripts pass shellcheck. All scripts are idempotent. Each script's specific gate passes.

---

### SG10 — Bootstrap and Adaptive Config Generation
**Input:** SG4 variables manifest + flavor structure, SG8 script architecture, SG9 scripts  
**Goal:** Produce the entry point for someone who cannot code: a single bootstrap script that probes the machine, then guides the user to a correct `config.yaml` + hardware flavor following best practices. This is the "anyone can do it through agents" path.

**The bootstrap flow:**
1. **Probe** — gather system facts non-destructively: OS + version, GPU vendor/model and gfx target, VRAM, CPU/RAM, kernel, SELinux mode, existing distroboxes/images, group membership, linger state. Output a machine-readable facts file.
2. **Match** — select the closest existing flavor (OS + hardware). If an exact hardware flavor exists, use it. If not, start from the OS flavor and the nearest hardware family.
3. **Generate** — produce a draft `config.yaml` and, when no exact hardware flavor exists, a draft hardware-flavor overlay with the probed values filled in and uncertain fields clearly marked.
4. **Assist (optional, browser LLM)** — a documented flow where the user pastes the facts file into a browser LLM (or a local model via the running llm_server) with a provided prompt template, and the LLM helps complete/validate the flavor following the rules in this document. The prompt template is a deliverable. The LLM never executes anything — it only proposes config the user reviews.
5. **Validate** — schema-check the generated `config.yaml` against the SG4 manifest; refuse to proceed on missing required keys or hardware values placed in the general layer.

**Hard rules:**
- Probe is read-only. It changes nothing on the host.
- The browser-LLM step is advisory: output is config text the user reviews and saves, never auto-applied commands.
- No secrets (API keys, tokens) are ever written into `config.yaml` or a flavor — those are initialized interactively per distrobox after creation (§2.8).

**Expert panel:** 2 subagents — one designs the probe + schema validation; one designs the LLM-assisted generation flow and prompt template. Synthesis reconciles.

**Output:**
1. `bootstrap.sh` (probe + match + generate + validate) specification and implementation
2. Browser-LLM prompt template for flavor generation
3. The facts-file schema
4. Documentation: the non-coder walkthrough, start to finish
5. Decision log

**Validation gate:** On the target machine, `bootstrap.sh` produces a `config.yaml` + hardware flavor that schema-validates and matches what SG6/SG7 expect. Run on a deliberately different hardware profile (mocked facts), it produces a sensible draft flavor with uncertain fields flagged rather than guessed.

---

### SG11 — QoL Layer and Post-Install Guide
**Input:** All prior outputs, SG8 aliases pattern  
**Goal:** Define and implement the quality-of-life layer and write the curated post-install guide.

**QoL items to implement (each as a deliverable):**

| Item | Deliverable |
|---|---|
| Shared aliases | `~/Containers/shared/aliases.sh` with: git shortcuts, tmux quick-attach, ollama helpers, `github-auth` alias, `fd` alias for Ubuntu naming, `host` shortcut for `distrobox-host-exec` |
| tmux config | A minimal shared `~/.tmux.conf` template: sensible prefix, mouse, history limit, status bar, split keys |
| tmux auto-attach | `.bashrc.d/` hook that creates/attaches a `main` session on interactive login |
| GitHub SSH setup | Interactive script: key generation in profile, `~/.ssh/config` template, passphrase loading via `distrobox-host-exec ssh-add`, test connection |
| Dotfile strategy | Explicit statement: profiles start blank intentionally; document how to seed them from a dotfiles repo or a template directory |
| Agent update paths | Documented: updating npm-installed agents requires image rebuild + distrobox recreate; profiles survive |
| Shell preference | Document how to change default shell inside a distrobox; `chsh` inside the profile |
| Opt-in shared aliases | One-liner to opt a new distrobox into shared aliases |

**Post-install guide sections:**
- How to enter os_agent and what you see on first entry
- First-time credential initialization per agent (one section per agent — what to run, what it stores, where):
  - Claude Code: `claude login` → browser auth → session in `~/.claude/`
  - Codex: login or API key → stored in profile
  - OpenCode: edit `~/.config/opencode/opencode.json` → choose local Ollama or cloud provider
  - Pi (pimono): configure endpoint → local Ollama or pi.dev
  - Hermes harness: configure to call local Ollama → `hermes3:8b`
- Starting and verifying each agent after initialization
- Pulling models, switching models
- Creating a project distrobox (per-project workflow)
- Propagating a fix: the rebuild cycle (edit → build → rm → create)
- What to do when something breaks
- How to update individual agent CLIs

**Expert panel:** 2 subagents review the QoL list — one from a "developer first day" perspective, one from an "agent usability" perspective.

**Output:**
1. All QoL scripts and config templates
2. Post-install guide (Markdown)
3. Zen Coding Practice section (see Section 8 of this document)

**Validation gate:** A new distrobox created from dev_base opts into shared aliases and lands in a tmux session on first entry. GitHub auth flow completes without errors.

---

### SG12 — Zen Coding Practice and Per-Project Workflow
**Input:** All prior outputs  
**Goal:** Write the two documentation sections that describe the intended working style.

**Zen Coding Practice must cover:**
- The mental model: distrobox = identity + workspace; code = what you push; the box is disposable
- Enter → tmux → work → commit → detach as the rhythm
- When to use which agent (OpenCode/Pi/Hermes for local/offline; Codex for OpenAI-backed tasks; Claude Code for complex reasoning; all five available in every box)
- How agents and humans use the same workspace — no special agent mode
- When to rebuild vs. when to fix inside a running box (rebuild = image issue; fix in profile = config issue)
- The rebuild cycle as a routine, not an emergency

**Per-Project Workflow Pattern must cover:**
- Creating a project distrobox from dev_base (exact command template)
- Deciding: new image vs. reuse dev_base
- Mount strategy: one workspace per box, not ~/Code wholesale
- Git identity per profile — what it means for multi-client work
- IDE per project box: OMP/Cursor inherited from dev_base, exported to host via `distrobox-export --app`, credentials/settings isolated in the project profile — the IDE's AI sees only that project's mount
- Concurrent agents on the same repo: Git worktree strategy (from architecture requirements doc section 10)
- How project boxes call the shared llm_server endpoint (no additional setup required)

**Output:** Two complete Markdown sections ready to be included in the tutorial README, plus a concrete project-box creation script/template.  
**Validation gate:** Both sections are internally consistent with the architecture document's invariants. Creating a project box from dev_base yields an isolated IDE that cannot see other projects' mounts.

---

### SG13 — End-to-End Validation
**Input:** All scripts and documentation from SG9–SG12  
**Goal:** Validate the complete setup from a clean starting point.

**Test environment requirement:** This subgoal must run in an isolated environment — either a fresh virtual machine running Fedora Kinoite, or a documented procedure that simulates a fresh state (e.g., remove all images, remove all distroboxes, reset profiles, start the setup from step 0). Self-certification on the production machine against its own state is not acceptable.

**Validation sequence:**
1. Run the isolation audit (SG0) — verify it runs clean
2. Run the bootstrap (SG10) — verify probe is read-only and it produces a schema-valid `config.yaml` + hardware flavor
3. Run prerequisites check (SG1) — verify it detects and reports correctly
4. Run setup scripts in order — verify idempotency by running each twice
5. Verify llm_server (hardware-agnostic design + flavor env block):
   - `curl http://127.0.0.1:11434/api/tags` responds
   - `ollama ps` shows GPU in PROCESSOR column (not CPU) — confirms flavor env block worked
   - Service survives `loginctl terminate-session` and re-login
6. Verify os_agent (CLI agents only):
   - `distrobox enter os_agent` succeeds, lands in tmux session
   - OpenCode connects to local Ollama, returns a response
   - Pi connects to local Ollama, returns a response
   - Hermes harness connects to local Ollama (`hermes3:8b`), returns a response
   - Codex launches and accepts OpenAI credentials (cloud path; local Ollama not tested here)
   - Claude Code launches and accepts Anthropic login (cloud path)
   - `fd`, `rg`, `gh`, `git`, `tmux` all available
7. Verify per-project workflow + IDE isolation: create a project box from dev_base, opt into shared aliases, verify it calls llm_server endpoint; launch the IDE (OMP/Cursor) exported to host; confirm the IDE sees only that project's mount, not other projects
8. Verify rebuild cycle: rebuild os_agent image, recreate distrobox, verify profile survives
9. Verify flavor swap (mocked): point config at a different hardware flavor, confirm only the GPU env block changes and core scripts are untouched

**Output:**
1. Validation run log with pass/fail per check
2. Any failures: structured report with reproduction steps
3. If all pass: a "validated on <date> / <OS version> / <hardware>" stamp

**Validation gate:** All checks pass. The tutorial is declared ready for human use.

---

## 6. Hard Constraints

These are non-negotiable and must be enforced at every subgoal.

**Order is the primary constraint.** No subgoal begins until its predecessor's validation gate passes.

**Isolation invariants (from architecture requirements doc, section 2):**
- Each distrobox has exactly one dedicated profile under `~/Profiles/`
- Never copy or symlink credential directories between profiles
- Model data lives in `~/Models/`, not in any profile
- Code lives in `~/Code/`, mounted explicitly, not stored in profiles or images
- The host stays minimal: only podman, distrobox, git

**General operational invariants (all OS):**
- `--no-tty` flag is required in the systemd unit's `ExecStart`. Without it, the unit fails to start (no TTY in non-interactive context).
- `loginctl enable-linger $USER` is required for systemd user services to survive logout.
- `distrobox create` is not idempotent. Scripts must check for existence before creating.
- Never use `--rm-home` when removing a distrobox. It deletes the persistent profile.
- Ollama must bind to `127.0.0.1` (loopback), never `0.0.0.0`. Binding to all interfaces exposes the model server to the LAN.
- AMD GPU: user must be in `render` and `video` groups. Requires `usermod -aG render,video $USER` + logout/reboot. Group membership is not effective until the session restarts.
- NVIDIA GPU: `nvidia-container-toolkit` must be installed on the host before distrobox creation.
- Intel GPU: not supported for GPU inference. IPEX-LLM was archived by Intel (January 2026) and the Ollama SYCL path was closed unmerged (June 2026) — there is no reliable container path. Intel systems fall back to CPU with a clear warning.
- AMD silent CPU fallback: on some AMD targets (notably gfx1151 / Strix Halo) the GPU is detected but inference silently runs on CPU without the correct env block. The hardware flavor must supply it; SG6 must verify via `ollama ps` PROCESSOR column.
- Claude Code uses the Anthropic Messages API format, not compatible with Ollama's OpenAI-compatible endpoint. Connects to Anthropic cloud only. This is by design.
- Context length and VRAM: `OLLAMA_CONTEXT_LENGTH=65536` requires significant GPU memory. Float16 KV cache at this length can exceed 8 GB alone. The config template must document how to tune this to hardware.
- Podman rootless requires `fuse-overlayfs` on some systems. Verified in SG1.

**Fedora Kinoite OS module specifics (implemented in Phase 2; referenced as examples for future OS modules):**
- Package installation: `rpm-ostree install <pkg>` + reboot required. The OS module must handle this; core scripts call `pkg_install`, never `rpm-ostree` directly.
- SELinux enforcing by default: volume mounts require `:Z` flag. The OS module's `selinux_label_volume` function applies this; core scripts call the function.
- NVIDIA on Kinoite: `rpm-ostree install nvidia-container-toolkit` + reboot.
- Immutability check: `rpm-ostree status` to confirm overlay is in use.

**OS template scope:**
- **Phase 2 produces:** Fedora Kinoite template + OS module (the only concrete implementation)
- **Framework supports:** any OS by writing a new template + OS module that implements the module interface (defined in SG8)
- **Not in scope for Phase 2:** Ubuntu, Arch, or other OS modules — but the interface they would implement is defined and documented

---

## 7. QoL Requirements

These are specified in detail in SG11 above. Summary for reference:

- Shared aliases file sourced by every opted-in distrobox — never copy the file, source it via `/run/host`
- tmux minimal config deployed to each profile — sensible defaults, mouse enabled, usable status bar
- tmux auto-attach hook in `.bashrc.d/` — entering any opted-in distrobox lands in a persistent session
- GitHub SSH key per profile — isolated, passphrase-protected, loaded via `distrobox-host-exec ssh-add`
- Dotfile strategy documented — profiles start blank intentionally; seeding is the user's choice
- Agent update paths documented — rebuild image, recreate distrobox; profile survives
- Shell environment: default shell inside distrobox follows the base image; document how to change it per-profile
- IDE integration: `distrobox-export` for exporting an editor or app from inside a box to the host desktop

---

## 8. Zen Coding Practice

*Full content produced in SG12. This is the scope definition.*

The Zen Coding Practice section answers: what does working correctly in this environment look like, day to day?

It covers the rhythm (enter → tmux → work → commit → detach), the mental model (boxes are identities, not laptops — you can have many), when to use which agent, how to handle mistakes (rebuild is routine), and how to extend the setup (one new box per new project, inherit from dev_base, point at llm_server).

The goal is a calm, reproducible, well-isolated practice — not a list of rules, but a way of thinking about the environment.

---

## 9. Per-Project Workflow Pattern

*Full content produced in SG12. This is the scope definition.*

This section answers: once the base environment is set up, how do you add a new project?

It covers: when to create a new distrobox vs. reuse an existing one, how to inherit from dev_base, how to mount only the relevant code tree, how to configure git identity per profile, how to connect the project box to the shared llm_server, how to handle concurrent agents on the same repository (Git worktrees), and the optional GUI app question (per-box export vs. host-installed shared).

---

## 10. Propagating Fixes

*This is both a user guide section and a design constraint.*

When something is found broken:

**Image fix:** Edit Containerfile → rebuild image → `distrobox rm --force <name>` (profile survives) → `distrobox create` with original flags. This is the routine update path.

**Config fix:** Edit the relevant config file in `~/Profiles/<name>/` directly. For shared aliases, edit `~/Containers/shared/aliases.sh` — all opted-in boxes pick it up on next shell start.

**Service fix:** Edit the service file in `~/Containers/<name>/`, then `systemctl --user daemon-reload && systemctl --user restart <name>.service`.

**Propagating to all boxes:** A fix to `dev_base` that affects all project boxes requires rebuilding dev_base → rebuilding each derived image → recreating each distrobox. Phase 2 should produce a helper script that does this rebuild cascade.

---

## Appendix: Research Anchors for SG2

These are the primary sources the Phase 2 research subagents must consult. Do not rely on training knowledge; fetch current versions.

- Distrobox documentation: https://distrobox.it/usage/distrobox-create/ and https://distrobox.it/usage/distrobox-enter/
- Ollama AMD/ROCm: https://docs.ollama.com/docker and https://docs.ollama.com/troubleshooting
- Ollama model library: https://ollama.com/library
- Ollama OpenAI-compatible API: https://docs.ollama.com/api/openai-compatibility
- OpenCode documentation: https://opencode.ai/docs/
- OpenCode providers: https://opencode.ai/docs/providers/
- Codex CLI: https://github.com/openai/codex
- Claude Code: https://claude.ai/code (installation and configuration)
- Pi / pimono: https://pi.dev and npm package `@earendil-works/pi-coding-agent`
- NousResearch Hermes harness: research required — find the correct package name, GitHub repo, and Ollama configuration method. Search for "NousResearch Hermes agent harness" and "nous-hermes tool-use harness npm" as starting points.
- Fedora Kinoite: https://docs.fedoraproject.org/en-US/atomic-desktops/
- ROCm Ryzen AI compatibility: https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/
