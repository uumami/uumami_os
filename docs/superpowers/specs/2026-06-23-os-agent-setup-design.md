# Master Reference: uumami_os Development Environment Setup

**Status:** Phase 1 complete — approved for Phase 2 execution  
**Phase 2 mode:** Autonomous (no user input between subgoals)  
**Ground truth documents:** `atomic_distrobox_local_agent_architecture_requirements.md` and `fedora_kinoite_local_agent_canonical_runbook.md` — validate against them; do not redesign what they define.

---

## 1. Overview and End State

The goal is a tutorial and set of scripts that take someone from a fresh Linux install to a fully configured development environment by editing a small configuration file and following documented steps. The same tutorial must work on existing (non-fresh) machines via idempotent checks throughout.

**The scripts are OS-agnostic.** OS-specific behavior (package manager, group management, SELinux, immutability) is detected at runtime and handled through OS modules. A user fills in a config template for their OS; the scripts read it and adapt. Phase 2 produces one concrete config template — for Fedora Kinoite — but the framework must accommodate any OS that runs distrobox and rootless Podman. Adding a new OS means writing a new template and OS module, not changing the core scripts.

**The end state is two running distroboxes:**

```
Host (Fedora Kinoite or compatible Linux)
│
├── llm_server distrobox
│   ├── Ollama serving models on 127.0.0.1:11434 (loopback only)
│   ├── GPU-accelerated (AMD ROCm / NVIDIA CUDA / CPU fallback)
│   ├── Model: user-chosen variable (hardware-dependent)
│   └── Accessible to any distrobox via host network namespace
│
└── os_agent distrobox
    ├── Claude Code      (Anthropic coding agent — calls Anthropic cloud)
    ├── Codex            (OpenAI coding agent CLI — calls OpenAI cloud)
    ├── OpenCode         (open-source agent — configurable: local Ollama or cloud)
    ├── Pi / pimono      (Pi coding agent — configurable: local Ollama or cloud)
    ├── Hermes harness   (NousResearch agent harness — configurable: local Ollama or cloud)
    └── Podman client    (host socket passthrough — no nested daemon)
```

**Persistent state lives outside containers, in four host directories:**

| Directory | Contents |
|---|---|
| `~/Containers/` | Containerfiles and service definitions (this repo) |
| `~/Profiles/` | One isolated HOME per distrobox |
| `~/Models/ollama/` | Model weights (mounted into llm_server at `/models`) |
| `~/Code/` | Source workspaces |

**A third image — `dev_base` — is the Fedora-based parent for per-project distroboxes.** It is not a running box; it is a reusable image. Project boxes inherit from it, get their own profile, mount only their code, and call the shared llm_server endpoint.

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

Each agent client has a fixed or configurable provider:

| Client | Provider | Local Ollama? |
|---|---|---|
| Claude Code | Anthropic (account login or API key) | No — format incompatible |
| Codex | OpenAI (account login or API key) | No — standard provider |
| OpenCode | Configurable in profile | Yes — `~/.config/opencode/opencode.json` |
| Pi (pimono) | Configurable in profile | Yes — endpoint + optional API key |
| Hermes harness | Configurable in profile | Yes — Ollama → `hermes3:8b` |

Claude Code and Codex use their standard cloud providers as designed. The Hermes harness, Pi, and OpenCode can be pointed at local Ollama or at a cloud API — decided per distrobox at credential-initialization time, not at build time.

### 2.6 Credential isolation is structural, not a policy

The `--home ~/Profiles/<name>` flag on each `distrobox create` command is what makes isolation real. `~/.claude/` inside `os_agent` resolves to `~/Profiles/os_agent/.claude/`. Inside `project_x`, it resolves to `~/Profiles/project_x/.claude/`. These paths are physically separate; there is nothing to configure or enforce. A Claude Code session initialized in one box cannot be seen by another box by construction.

This means: every agent in every distrobox is initialized interactively after first entry. Re-logging in per box is expected and correct — it is the isolation working as intended. One distrobox = one identity = one set of credentials for each agent.

---

## 3. Pre-Phase 2 Decisions

**The following must be decided by the human before the Phase 2 goal is launched.** Phase 2 is autonomous and cannot resolve these. Each decision must be recorded as a variable or explicit note in `config.sh` or a companion decisions file.

| Decision | Options | Default |
|---|---|---|
| Which agent clients go in os_agent? | All five / subset | All five |
| Podman client in os_agent | Client-only with host socket passthrough / Omit | Client-only |
| GPU backend for this machine | auto / amd / nvidia / cpu | auto |
| Primary model (llm_server default) | Config variable — see suggestion below | `qwen3-coder:30b` (adjust to hardware) |
| OS template to use | Select a config template or write a new one | `fedora-kinoite` (the only template Phase 2 produces) |

**Note on credentials:** Claude Code and Codex use their standard providers (Anthropic and OpenAI). No path decision needed — credentials are initialized interactively per distrobox after first entry. OpenCode, Pi, and the Hermes harness are configured per distrobox at initialization time to point at local Ollama or a cloud provider.

**Note on primary model:** The `PRIMARY_MODEL` config variable is a suggestion, not a constraint. The recommended default is the largest `qwen3-coder` variant that fits available VRAM — for most setups with 24 GB+ VRAM that is `qwen3-coder:30b`. The tutorial must document how to choose: check `nvidia-smi` or `rocm-smi` for VRAM, pick the largest variant that leaves headroom. Users can set any model available in the Ollama library. The config template should list known-good options as comments.

Record decisions before launching. Phase 2 reads them from the config file, does not ask.

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
- Subagent A: distrobox internals + systemd integration
- Subagent B: Ollama + GPU passthrough (AMD and NVIDIA)
- Subagent C: each agent client (Claude Code, Codex, OpenCode, Pi/pimono, NousResearch Hermes harness) — install method, npm package name and version, config file location and schema, credential initialization flow, known Linux/container issues. For the Hermes harness specifically: research the correct package name, GitHub repo, and how it is configured to call a local Ollama endpoint.

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
2. Architecture confirmation: the canonical two-distrobox design is validated, or a specific deviation is documented with evidence
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
- Per-agent credential initialization method (documented in post-install guide; not a build-time variable)
- GitHub email and username (for profile git config)

**Expert panel:** 2 subagents independently draft the variable list; synthesis reconciles differences.  
**Output:** `config.sh` specification (not the file itself — the spec that the implementation subgoal will use).  
**Validation gate:** Every variable used in SG5–SG8 can be traced to this manifest. No orphan constants.

---

### SG5 — Base Image Design (`dev_base`)
**Input:** SG2 research (package names), SG4 variables manifest  
**Goal:** Define what goes in the Fedora-based `dev_base` image that all project distroboxes inherit from. Derive contents from: what the coding agents need (verified in SG2), what developers expect, what the canonical runbook specifies.

**Expert panel:** 3 subagents each propose a package list from different angles:
- Subagent A: minimum viable (what do the agents strictly require?)
- Subagent B: developer ergonomics (what would a developer miss on first entry?)
- Subagent C: review Subagent A + B and identify conflicts or redundancies

Synthesis produces the final list with justification for each package included.

**Output:**
1. `dev_base` Containerfile specification (not the file — the spec)
2. Decision log: what was included and why, what was excluded and why
3. Open questions raised

**Validation gate:** Every package in the spec has a verified Fedora package name (from SG2 research). No package that belongs in os_agent is in dev_base.

---

### SG6 — llm_server Design
**Input:** SG2 research (Ollama image, GPU passthrough), SG3 spike results (especially Spikes B, D, E), SG4 variables manifest  
**Goal:** Define the llm_server Containerfile and systemd user service. The canonical runbook already has a working version; this subgoal validates it against current software and produces a reviewed, spike-confirmed version.

**Items to validate against current state:**
- Correct `ollama/ollama:rocm` image tag for AMD
- `ENV OLLAMA_HOST`, `ENV OLLAMA_MODELS`, `ENV OLLAMA_CONTEXT_LENGTH` correctness
- No `CMD` or `ENTRYPOINT` (Distrobox lifecycle management)
- Systemd unit with `--no-tty --no-workdir` (confirmed by Spike B)
- Device passthrough flags for AMD and NVIDIA (confirmed by Spike D)
- Volume mount flags including `:Z` for SELinux (confirmed by Spike E)
- `loginctl enable-linger` requirement
- User group requirements (`render`, `video`)

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

**Items to define:**
- Base image: dev_base, or standalone? (Decide based on SG5 and whether the tools overlap enough)
- Each agent client: install method (npm global, binary, other), verified package name and version pin
- Claude Code: standard Anthropic login — `claude login` runs interactively after first entry; session stored in `~/.claude/` (inside profile, persists across rebuilds). No build-time credential.
- Codex: standard OpenAI login or API key — initialized interactively after first entry. No build-time credential.
- OpenCode: `~/.config/opencode/opencode.json` schema (verified against installed version); endpoint configurable to local Ollama or cloud provider at initialization time
- Pi (pimono): endpoint and optional API key configured at initialization time; can point at local Ollama or pi.dev cloud
- Hermes harness: install method and package name verified by SG2 Subagent C research; configured to call local Ollama (`hermes3:8b`) or cloud at initialization time
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

**Validation gate:** The named script list covers every step from SG0's audit to SG12's validation without gaps. Each script has a clear single responsibility.

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

### SG10 — QoL Layer and Post-Install Guide
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

### SG11 — Zen Coding Practice and Per-Project Workflow
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
- Creating a project distrobox (exact command template)
- Deciding: new image vs. reuse dev_base
- Mount strategy: one workspace per box, not ~/Code wholesale
- Git identity per profile — what it means for multi-client work
- Concurrent agents on the same repo: Git worktree strategy (from architecture requirements doc section 10)
- Optional GUI apps: distrobox-export for per-box browser/Slack, vs. host-installed for shared apps
- How project boxes call the shared llm_server endpoint (no additional setup required)

**Output:** Two complete Markdown sections ready to be included in the tutorial README.  
**Validation gate:** Both sections are internally consistent with the architecture document's invariants.

---

### SG12 — End-to-End Validation
**Input:** All scripts and documentation from SG9–SG11  
**Goal:** Validate the complete setup from a clean starting point.

**Test environment requirement:** This subgoal must run in an isolated environment — either a fresh virtual machine running Fedora Kinoite, or a documented procedure that simulates a fresh state (e.g., remove all images, remove all distroboxes, reset profiles, start the setup from step 0). Self-certification on the production machine against its own state is not acceptable.

**Validation sequence:**
1. Run SG0 (isolation audit) — verify it runs clean
2. Run SG1 (prerequisites) — verify it detects and reports correctly
3. Run setup scripts in order — verify idempotency by running each twice
4. Verify llm_server:
   - `curl http://127.0.0.1:11434/api/tags` responds
   - `ollama ps` shows GPU in PROCESSOR column (not CPU)
   - Service survives `loginctl terminate-session` and re-login
5. Verify os_agent:
   - `distrobox enter os_agent` succeeds, lands in tmux session
   - OpenCode connects to local Ollama, returns a response
   - Pi connects to local Ollama, returns a response
   - Hermes harness connects to local Ollama (`hermes3:8b`), returns a response
   - Codex launches and accepts OpenAI credentials (cloud path; local Ollama not tested here)
   - Claude Code launches and accepts Anthropic login (cloud path)
   - `fd`, `rg`, `gh`, `git`, `tmux` all available
6. Verify per-project workflow: create a project distrobox from dev_base, opt into shared aliases, verify it calls llm_server endpoint
7. Verify rebuild cycle: rebuild os_agent image, recreate distrobox, verify profile survives

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
- Intel GPU: limited support (IPEX-LLM / oneAPI path exists but is unstable). Falls back to CPU with a clear warning.
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

These are specified in detail in SG10 above. Summary for reference:

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

*Full content produced in SG11. This is the scope definition.*

The Zen Coding Practice section answers: what does working correctly in this environment look like, day to day?

It covers the rhythm (enter → tmux → work → commit → detach), the mental model (boxes are identities, not laptops — you can have many), when to use which agent, how to handle mistakes (rebuild is routine), and how to extend the setup (one new box per new project, inherit from dev_base, point at llm_server).

The goal is a calm, reproducible, well-isolated practice — not a list of rules, but a way of thinking about the environment.

---

## 9. Per-Project Workflow Pattern

*Full content produced in SG11. This is the scope definition.*

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
