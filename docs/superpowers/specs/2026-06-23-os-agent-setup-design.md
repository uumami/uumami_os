# Master Reference: uumami_os Development Environment Setup

**Status:** Phase 2 IN PROGRESS — foundation validated on real hardware; see "Execution Progress & TODO" below (READ FIRST).  
**Phase 2 mode:** Autonomous + adversarially-validated (expert panels, spikes, evidence gates — §4). Generate-and-sandbox-validate; host-mutating steps are tagged `human-required` (execution model A, §4.5).  
**Ground truth documents:** `atomic_distrobox_local_agent_architecture_requirements.md` and `fedora_kinoite_local_agent_canonical_runbook.md` — validate against them; do not redesign what they define.

---

## 0. Phase 2 Execution Progress & TODO (READ FIRST)

This section is the resume point for a fresh session. The design below (§1–§10) is the spec; this section records what has been **executed and validated on the real machine** and what remains. Continue from here — do not redo validated work. Inspect the repo (`config.yaml`, `flavors/`, `setup/`, `images/`) and `git log` for the artifacts.

### Confirmed machine facts (do NOT re-research — validated 2026-06-25)
- **Hardware:** AMD Ryzen AI MAX+ 395 / Radeon 8060S = **Strix Halo, gfx1151**, 121 GiB unified RAM, 32 cores. PCIID `1002:1586`.
- **OS:** Fedora **Kinoite 44**, atomic (rpm-ostree), **SELinux Enforcing**, kernel **7.0.10**, native `overlay`, podman 5.8.2 / distrobox 1.8.2.4.
- **GPU works with NO sudo / NO reboot / NO render-video groups:** `/dev/kfd` + `/dev/dri/renderD128` are world-rw. Validated `100% GPU` with `--security-opt label=disable`. `HSA_OVERRIDE_GFX_VERSION=11.5.1` + `OLLAMA_FLASH_ATTENTION=1` confirmed.
- **Ollama:** `ollama/ollama:rocm` resolves to **0.24.0 (known-good)**; **avoid 0.30.0–0.30.2-rocm** (2 GiB regression on gfx1151).
- **VRAM:** Ollama sees **64.7 GiB** (BIOS UMA carveout). Expandable to ~90 GiB (verified: BIOS→0.5 GB + `ttm.pages_limit=23592960`; NOT 110 GiB = OOM-kill regime; NOT `page_pool_size`/`amd_iommu=off`). **Not needed for 30B/8B** — defer until 70B+/MoE. Full verified procedure in `flavors/fedora-kinoite-strix-halo.yaml`.
- **linger** self-enables without sudo. **sudo** needs a password (uumami ∈ wheel); the user will provide it for the few rooted steps (tenant users). The core build needs none.

### Operational learnings (carry forward)
- This agent runs **inside the `os_agent` distrobox**; reach the host via `distrobox-host-exec` (runs as host user `uumami`). Scripts are written to run **on the host**.
- **Cannot recreate `os_agent` from within it** (would kill the session) — building its image is fine; the recreate is `human-required` (host terminal).
- Host needs `yq` — installed no-sudo via `setup/lib/ensure-yq.sh` (static binary in `~/.local/bin`).
- **`.gitignore` is the Python template**: its `lib/` and `var/` rules hide our source — the un-ignore block at the bottom of `.gitignore` fixes it. Keep it.
- Never `--rm-home`; never bind the host container socket across a tenant boundary; loopback-only.

### DONE & validated (committed)
- `setup/lib/detect.sh` — read-only host probe → facts; idempotent. ✅
- `config.yaml` + `flavors/fedora-kinoite.yaml` + `flavors/fedora-kinoite-strix-halo.yaml` — parse; **yq deep-merge of the flavor chain works (Spike I)**. ✅
- `setup/lib/config.sh` (`merge_config`/`cfg_get`), `setup/lib/ensure-yq.sh`. ✅
- **`llm_server` LIVE:** `images/llm_server/Containerfile` (corrected: 127.0.0.1, no EXPOSE/CMD) + `llm_server.service` (systemd user, `--no-tty`) + `setup/lib/llm_server.sh` (build+create from flavor). Service **active**, journal `library=ROCm compute=gfx1151`, `ollama ps` = **100% GPU**. ✅ (Survives-logout/reboot = `human-required`, untested.)
- **SG4 manifest:** `setup/schema/MANIFEST.md` — every variable layer-tagged + tenant/session/registry schemas. ✅
- **SG8/SG9 core scripts (built + shellcheck-clean + idempotency-tested on host):** `assemble.sh` (`.layer`+toggles→Containerfile, `--check` mode), `validate.sh` (24-check schema/purity/secrets/toggle↔module validator — PASS), `build.sh` (assemble+podman build), `rebuild.sh` (cascade; box recreates emitted as human-required), `os-module.sh` interface + `os/fedora-kinoite.sh` module, `bootstrap.sh` (SG10: probe→match→scaffold→validate, idempotent). ✅
- **SG5 `dev_base` VALIDATED on real hardware (2026-06-25):** modular `images/dev_base/modules/*.layer` (base toolchain, nested-rootless-podman, 6 agents, cursor) → built `localhost/dev_base:latest` (9.11 GB, Fedora 44). **Every agent verified inside the image:** claude 2.1.191, codex 0.142.2, opencode 1.17.11, pi 0.80.2, omp 16.1.18 (+bun 1.3.14), hermes v0.17.0, cursor 3.8.24 (cursor.desktop present), podman 5.8.3, `newuidmap cap_setuid=ep` (shadow-utils reinstall), storage.conf=fuse-overlayfs. Evidence: `setup/spikes/evidence-*.log`. **Node 22.22.2 clears Pi's ≥22.19.** ✅
- **SG7 `os_agent` image built:** `images/os_agent/` (FROM dev_base, Tier-0 label) → `localhost/os_agent:latest`. **Recreate = human-required** (can't recreate from within). Per-agent local-Ollama config templates + post-install guide: `setup/templates/agent-configs/`. ✅
  - **Spike learnings folded in:** opencode & claude-code need their npm **postinstall** (no `--ignore-scripts`); omp's bin shim needs **bun**; hermes installs to `/usr/local` via `--non-interactive` (survives profile-mount, but unpinned/rolling); cursor RPM URL via `api/download?platform=linux-x64` → `.rpmUrl`; Claude Code local-Ollama needs a **translation proxy** (cloud is clean).
- **Adversarial correctness pass (3 independent reviewers):** all 9 architecture invariants hold. Fixed real bugs — cyclic-`extends` infinite loop (cycle guard), `cfg_get`/`q` coalescing boolean `false` to default (a false toggle couldn't validate — now it can), `set -e` leaking from the sourced lib, assembler stripping body comments, `llm_server.sh` dropping `rootless_selinux_flag` + never setting `OLLAMA_CONTEXT_LENGTH`, `rebuild.sh` masking build failures, multi-pkg idempotency. All shellcheck-clean; regression-tested. ✅
- **SG10 bootstrap entry point:** `bootstrap.sh` emits a copy-pasteable **browser-agent prompt** (`setup/flavor-request.md`) embedding detected facts + the flavor schema → a browser LLM authors a correct hardware flavor. `install-llm-service.sh` installs the systemd user service. ✅
- **SG12 docs:** `README.md` is the **tutorial** (entry = browser-agent bootstrap → llm_server → dev_base → os_agent → use → tenants → propagate). Companion docs: `docs/per-project-workflow.md`, `docs/propagating-fixes.md`, `docs/zen-coding.md`. ✅
- **SG10.5 tenant model:** `tenant-create.sh` (manifest → registry + per-user box/profile/browser/sessions; Tier-0 runs directly, Tier ≥2a emits the human-required sudo user-creation + `--user-setup` phase; idempotent; `--dry-run`) + `work.sh` (session launcher: model/workdir/browser env + tmux `new-session -A`). Example manifest `setup/templates/tenant-example.yaml`. **Cross-UID isolation proven adversarially** (`setup/spikes/evidence-tenant-isolation.log`: uid B denied read+list of uid A's 0700 creds). **Real Tier-0 E2E** on the host: box created from dev_base, `/workspace` mounted, **no `/models`**, descriptor+registry written, clean teardown (`evidence-tenant-e2e.log`). Bugs caught+fixed in build: jq-ism `// empty` (yq lexer error), `getent` exit-2 silent `set -e` abort, Tier-0 `~` resolving to the profile dir not `$HOME`. ✅

### TODO (remaining subgoals — continue here)
1. **[human-required gate] os_agent recreate:** from a HOST terminal, `distrobox rm os_agent && distrobox create … --image localhost/os_agent:latest` (see `rebuild.sh` output). Cannot run from inside the box.
2. **SG11 QoL** — implement the deploy scripts (shared-aliases / tmux `.tmux.conf` + auto-attach / SSH) named in the SG8 table. `tenant-create` already calls them if present (`deploy-aliases.sh`/`deploy-tmux.sh`/`deploy-ssh.sh`); docs/Zen/workflow already written in SG12.
3. **SG13 E2E validation runbook** — the human-in-the-loop sequence (recreate os_agent, create two Tier-2a tenants on the real host, confirm mutual unreadability, GPU/reboot survival).
4. **Deferred / human-required:** os_agent recreate, VRAM expansion (only for 70B+), tenant-user creation (sudo), survives-reboot checks, BIOS changes, cursor `distrobox-export --app` (touches host desktop).

### How to continue (the loop)
Use the superpowers flow + the §4 contract: for each remaining subgoal, convene an independent expert panel, run the required spike in a **rootless throwaway container** with an evidence record, adversarially verify, then implement → run on the host (via `distrobox-host-exec`) → confirm idempotency → commit. Tag anything host-mutating `human-required` and pause for the user rather than guessing. Keep `default_tier: 2a` and the no-sudo-for-core principle.

---

## 1. Overview and End State

The goal is a tutorial and set of scripts that take someone from a fresh Linux install to a fully configured development environment by editing a small configuration file and following documented steps. The same tutorial must work on existing (non-fresh) machines via idempotent checks throughout.

**The scripts are OS-agnostic.** OS-specific behavior (package manager, group management, SELinux, immutability) is detected at runtime and handled through OS modules. A user fills in a config template for their OS; the scripts read it and adapt. Phase 2 produces one concrete config template — for Fedora Kinoite — but the framework must accommodate any OS that runs distrobox and rootless Podman. Adding a new OS means writing a new template and OS module, not changing the core scripts.

**The end state is shared inference infrastructure plus one or more isolated tenants** (at a glance — every term here is defined in §2):

```
Host (Fedora Kinoite or compatible Linux)
│
├── llm_server                         shared inference infra — loopback 127.0.0.1:11434, GPU
│   ├── LLM backend module (default: Ollama)
│   ├── GPU-accelerated (AMD ROCm / NVIDIA CUDA / CPU fallback)
│   ├── Model: config variable — default suggestion: largest qwen3-coder that fits VRAM
│   └── Reachable from every tenant via host-loopback (all users share loopback)
│
└── tenants                            the unit of isolation + identity + environment
    ├── personal (you)                 Tier 0: your user + distrobox — max convenience, no wall
    │   └── CLI agents (Claude Code, Codex, OpenCode, Pi, OMP, Hermes)
    │
    └── client_<name>                  Tier 2a (default): dedicated Linux user + distrobox
        ├── CLI agents (per-tenant credentials, initialized after first entry)
        ├── Cursor IDE                 (GUI, exported to host via distrobox-export --app)
        ├── browser                    (own profile + tokens — no accidental cross-login)
        ├── code mount                 (only this tenant's code)
        ├── nested rootless podman     (build/run dev containers; local k8s via kind/k3d)
        └── sessions                   (e.g. acme-opus / acme-sonnet — per-project model/config)
```

**A tenant is the core unit.** It bundles one identity boundary, one set of credentials, one seamless dev environment. `os_agent` is simply *your own* tenant at the loosest tier (Tier 0). Client work is additional tenants at a stronger tier. Same shape; only the **boundary strength (tier)** differs. §2 makes each part concrete: the tenant/tier model (§2.2), sessions (§2.9), browser (§2.10), Kubernetes (§2.11).

**Persistent state lives outside containers, in four host directories:**

| Directory | Contents |
|---|---|
| `~/Containers/` | Containerfiles, modules, and service definitions (this repo) |
| `~/Profiles/` (Tier 0) or each tenant user's `$HOME` (Tier 2+) | One isolated HOME per tenant |
| `~/Models/` | Model weights (shared read-only into llm_server at `/models`) |
| `~/Code/` (Tier 0) or each tenant's own code tree | Source workspaces, mounted per tenant |

At Tier 0 these live under your single user as shown. At Tier 2+ each tenant is a dedicated Linux user, so its profile and code live under *that user's* home — the same four-domain model, replicated per tenant and walled off by UID (see §2.2).

These four directories realize a **three-layer model for each environment** (Models is shared infra, so it sits outside the per-environment layers):

**Everything that survives a container deletion must be in one of:**
1. **Image** (Containerfile) — reproducible tooling, binaries, packages
2. **Profile** (the tenant's HOME) — credentials, IDE/browser settings, agent + session state, git config
3. **Code mount** — project files, project-local venvs, node_modules

Runtime installs to the container filesystem (`/usr/local`, global npm/pip outside the profile) are the danger zone. If a container is deleted for any reason, anything there is gone. Image + profile + code mount must be sufficient to fully reconstruct the working environment.

This is a design **principle**, not a mechanically enforced gate. Capture project-specific tooling in the Containerfile, or in an optional committed setup script inside the code mount, as suits the project.

**Two base images:**
- `dev_base` — shared Fedora toolchain; **parent for os_agent and all tenant boxes** (the shared toolchain is real duplication, which justifies the layer; this is the one base image the architecture sanctions up front)
- `llm_server` — the LLM backend image; standalone

**Container engine: Podman, standardized.** Rootless, no daemon. "Docker" is used generically in this document — Podman runs your Dockerfiles (`podman build`) and compose files, and `docker` can alias to `podman`. Nested rootless Podman-in-Podman handles dev containers inside a tenant; the host container socket is never shared across a tenant boundary (see §2.4).

The tutorial must also produce:
- A curated guide for humans and agents on how to use the environment after setup
- A "Zen Coding Practice" section defining the target working style
- A per-project workflow pattern (one box per project, optional inheritance)
- A propagating-fixes guide

---

## 2. Architecture

### 2.1 Why Ollama is separate (not inside os_agent)

Ollama is long-running shared infrastructure. Its lifecycle (model loading, GPU memory, restart behavior) is independent of which agent is calling it. If Ollama lived inside os_agent, it would restart whenever the agent box is rebuilt or recreated. Every future project distrobox would need its own model copy. Separating them means: one model server, many agents, clean rebuild cycles for each.

Since distrobox uses the host network namespace, `127.0.0.1:11434` is reachable from every distrobox on the machine (loopback is shared by all local users) without port publishing. This is a design invariant.

**Two caveats the shared model introduces — noted, not alarming (it's all local, loopback-only, on one trusted host, which is fine for the normal case):**
- **The inference layer itself isn't tenant-isolated.** Ollama has no auth: any local user can hit the endpoint, all tenants' prompts pass through one process, and request logging (if enabled) is a cross-tenant bleed vector. On a single trusted machine this is acceptable and not worth over-engineering. *If* a client ever mandates more, escalation options, cheapest first: (1) keep shared, disable request logging; (2) **dedicated Ollama process per tenant** sharing the same weights read-only (process/port separation, modest extra RAM for loaded models); (3) an authenticating reverse proxy in front; (4) per-tenant network namespace. Default = shared.
- **Shared GPU is not a hardware boundary.** Tenants sharing one GPU share VRAM and driver state; the per-user (UID) wall doesn't isolate that layer. Only a VM (Tier 3) or separate hardware does. Again, fine for the normal local case. *(This is the single home for the shared-GPU caveat; §2.2 just points here.)*

### 2.2 Isolation model: tenants and tiers

**Honest starting point: distrobox is an integration tool, not a security sandbox.** By design it mounts the running user's `$HOME` (read-write) into every box, exposes the host filesystem via `/run/host`, and shares the host network namespace. `--home` only redirects where a box's *dotfiles write* so they don't litter the host home — it does **not** wall a box off from the host's real files. Two distroboxes under the *same Linux user* can therefore read each other's data. So distrobox alone gives **convenience isolation**, not a boundary against a compromised agent.

For real isolation we use the mechanism the OS actually enforces: **a separate Linux user.** A tenant running as user `client_a` cannot read `client_b`'s mode-700 home — different UID, standard Unix permissions, kernel-enforced. `/run/host` makes other homes *visible* but not *readable* (visibility ≠ access). This holds even against a fully compromised agent, and costs almost nothing.

**Scope and preconditions (verified):** the wall is kernel-enforced for **files, credentials, and processes** — *not* for shared-GPU memory/driver state (§2.1). It holds **given**: (a) non-overlapping `subuid`/`subgid` ranges per user (`useradd` auto-allocates these; verify with `grep <user> /etc/subuid`), (b) `loginctl enable-linger <user>` per tenant, (c) `render`/`video` group membership granted per tenant user. The onboarding script (SG10.5) sets all three.

**The two knobs.** Isolation is the product of two independent choices — the *boundary* (who enforces the wall) and the *convenience layer* (how host-like it feels):

| | **distrobox** (integrated, seamless) | **plain rootless podman** (minimal mounts only) |
|---|---|---|
| **Shared user** (your UID) | **Tier 0** — your own scratch work; no real wall | **Tier 1** — FS contained, but shared UID |
| **Dedicated user per tenant** | **Tier 2a** ⭐ — UID wall + seamless dev | **Tier 2b** — UID wall + smallest surface |
| **VM per tenant** | **Tier 3** — hardware-enforced | **Tier 3** — hardware-enforced |

**Tier 2a (dedicated user + distrobox) is the default for client work** — kernel-enforced separation between tenants, plus the host-like experience (seamless home, GUI export, Kubernetes) that makes daily development bearable. Tier 0 is for your own non-sensitive work (it *is* `os_agent`). Tier 2b/3 are opt-in escalations when a client demands a smaller surface or hardware isolation. **Tier is chosen per tenant**, recorded in that tenant's manifest (§2.9) — never a global mode.

**What Tier 2a does and does not protect.** A tenant's secrets (`.env` files, tokens, code) live inside that tenant user's home, which is mode `700` by default. No other tenant's UID can traverse into it — *regardless of the inner file's own mode* — so plaintext `.env` files are mutually unreadable across tenants with **zero per-file effort**. The only residual is that `/run/host` exposes *world-readable* files in *shared* locations (`/tmp`, world-readable `~/Containers`); the rule is simply "don't park secrets world-readable outside a tenant home." Tier 2a isolates *between* tenants, **not** between projects *within* one tenant (same user = same trust domain). One client = one tenant = one trust domain; a client needing project-level secret separation escalates to a user-per-project or per-session credential dirs.

**Read-only definitions:** the `~/Containers` mount is `:ro` in agent boxes — agents read service/Containerfile definitions, they do not rewrite them.

### 2.3 Inheritance hierarchy

```
dev_base image (Fedora, core dev tools + agents/IDE as modular layers)
├── os_agent / personal Tier-0 tenant
└── tenant boxes (one per client, own user at Tier 2+, own profile + code mount)

llm_server image (LLM backend + GPU userspace)
└── llm_server
```

`dev_base` is the **single** sanctioned parent image (the shared toolchain is real, stable duplication across os_agent and every tenant — which is exactly the bar the requirements doc sets for creating a base layer). Do not add *further* parent images speculatively.

### 2.4 Containers inside a tenant: nested rootless Podman, never the host socket

Developers need to build and run containers *inside* their environment (Dockerfiles, compose, Testcontainers, local Kubernetes). Three ways exist; only one is safe here:

- **Docker-in-Docker (full nested daemon)** — needs a privileged container = root on host. Breaks every boundary. **No.**
- **Host container socket passthrough** — the host daemon/socket runs as root; handing a tenant that socket = root on the host and access to every other tenant. The single worst option for this threat model. **Never across a tenant boundary.**
- **Nested rootless Podman-in-Podman** ⭐ — a rootless container runs rootless Podman inside itself, confined to that tenant's user namespace. No daemon, no added capabilities, no host socket. Confinement rests on the outer user namespace — there is no *known trivial* escape, but it is weaker than full SELinux confinement, so it is not a substitute for the UID boundary (it runs *inside* a tenant, not between tenants). Officially supported; the canonical setup needs `--device /dev/fuse` and, on SELinux hosts like Kinoite, `--security-opt label=disable` (a real, scoped SELinux relaxation). **This is the design for containers inside a tenant.**

What the **Docker/Podman socket** actually is: the API endpoint of the container engine — its control plane. Anything that *programmatically* creates containers (Testcontainers, `kind`/`k3d` making node-containers, compose, CI runners, management UIs) needs *a* socket. The rule: never the **host** socket; instead expose that **tenant's own rootless Podman socket** (`systemctl --user start podman.socket`, `DOCKER_HOST=$XDG_RUNTIME_DIR/podman/podman.sock`), which only controls containers within that tenant's UID. (Testcontainers' Ryuk reaper is flaky on rootless Podman — set `TESTCONTAINERS_RYUK_DISABLED=true`.) The dev image bakes in nested-rootless prerequisites (`/etc/subuid`, `/etc/subgid`, `fuse-overlayfs`, `/dev/fuse` access).

Kubernetes specifics are in §2.11.

### 2.5 Agent client provider model

**CLI / terminal agents** (in `dev_base`, so every tenant has them):

| Client | Provider | Local Ollama? |
|---|---|---|
| Claude Code | Anthropic (login or API key) by default | Cloud default; *advanced*: local via Ollama's Anthropic-format endpoint (`ANTHROPIC_BASE_URL=…:11434`) |
| Codex | OpenAI (login or API key) by default | Cloud default; *advanced*: local via `--oss` mode (Ollama provider) |
| OpenCode | Configurable in profile | Yes — `~/.config/opencode/opencode.json` → `:11434/v1` |
| Pi | Configurable in profile | Yes — endpoint + optional API key |
| OMP (oh-my-pi) | Terminal-first agent, a Pi fork (`can1357/oh-my-pi`, `@oh-my-pi/pi-coding-agent`) — **"the IDE wired in"**: LSP, DAP debugger, ACP plugin (Zed), TUI/one-shot/RPC, plus a shareable **web collab UI** | Yes — same provider model as Pi |
| Hermes (general assistant) | NousResearch (`NousResearch/hermes-agent`) — general-purpose assistant (memory, chat integrations), not a coding tool | Yes — configurable provider, local Ollama or cloud |

> **Pi naming:** upstream is `badlogic/pi-mono` (npm `@earendil-works/pi-coding-agent`); "pimono" was our shorthand for the `pi-mono` slug. OMP is a fork of it.
> **Hermes is intentionally the general-purpose assistant**, `NousResearch/hermes-agent` (memory, chat integrations, configurable LLM provider incl. local Ollama) — included deliberately as a *different kind* of agent alongside the coding tools, not a coding harness. (Distinct from "Hermes Function Calling" model-side tooling and "Atropos" RL envs — we mean the assistant.) SG2 confirms install/config.

**GUI IDE** (in `dev_base`, used in a tenant, exported to host desktop):

| Tool | Type | Provider |
|---|---|---|
| Cursor | GUI IDE (Electron / AppImage) — exported via `distrobox-export --app` | Configurable per tenant |

> Cursor export should use the host sandbox where possible; `--no-sandbox` is a real security downgrade (renderer RCE exposure) and usually unnecessary since distrobox shares the host user namespace — fix the sandbox (userns / SUID `chrome-sandbox`) before disabling it. Reserve `--no-sandbox` for throwaway use.

Claude Code and Codex default to their standard cloud providers; both *can* be pointed at local Ollama (caveats above) as a documented advanced option. OpenCode, Pi, OMP, and Hermes choose local Ollama or cloud per tenant at initialization time.

**On "IDEs":** Cursor is the only *standalone GUI app*. OMP installs as a CLI-agent `.layer` (not a GUI app), but its IDE features have two consequences worth tracking: its **web collab UI** is browser-reachable (→ browser-isolation knob, §2.10), and its **ACP plugin** can drive an external editor like Zed inside a tenant (a second route to "an editor in the tenant" besides Cursor).

### 2.6 LLM server module design

The `llm_server` distrobox exposes an OpenAI-compatible endpoint. The implementation (Ollama, Lemonade, llama-server) is a swappable module — the contract to the rest of the system is just the endpoint URL. Agent clients never depend on which backend is running.

**Default module: Ollama**

Validated by research as the right default for single-user interactive workstations across NVIDIA, AMD, and CPU. Best model management UX, broadest hardware coverage via official images.

**Hardware-specific tuning lives in the hardware flavor, not here.** GPU environment variables (AMD `HSA_OVERRIDE_GFX_VERSION`, `OLLAMA_IGPU_ENABLE`, NVIDIA CUDA settings, etc.), the chosen ROCm/CUDA/Vulkan path, model selection, and context-length tuning are all flavor-level concerns. The general llm_server design only knows: "start the LLM backend module, bind loopback, read its env block from the active flavor." See §2.7 for the flavor system, and the flavor worked example for the concrete gfx1151 block.

**Alternative module: Lemonade**

AMD-sponsored, community-maintained open-source local AI server. Targets recent AMD APUs/GPUs with ROCm bundled — no separate ROCm install (host amdgpu driver still required). OpenAI-compatible API. Best fallback if the Ollama ROCm path has persistent issues on specific AMD hardware. Selected via the `llm_backend` config variable; another module behind the same endpoint contract. GitHub: `lemonade-sdk/lemonade`. (Version and endpoint port to be confirmed by SG2 research.)

**No router/proxy layer.** LiteLLM and similar gateways are deliberately excluded: LiteLLM had a confirmed supply-chain compromise and carries a large Python attack surface for a single-user box. Backend switching is achieved by changing the `llm_backend` config value, not by running a proxy — the module interface already decouples clients from the backend. If URL-level routing is ever genuinely needed, a minimal audited option (llama-swap, or nginx upstream) is preferred over a large dependency.

**Backends confirmed dead/unsupported (do not build on):**
- LiteLLM: supply-chain compromise + large attack surface — excluded as proxy
- TGI (Hugging Face): archived March 2026
- IPEX-LLM (Intel): archived by Intel January 2026, and the Ollama SYCL PR closed unmerged June 2026 — **no first-party Ollama path for Intel Arc** (llama.cpp Vulkan/SYCL still works, but is not a module we ship)
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
  path: rocm          # not vulkan — Vulkan backend hangs on some models (Qwen3.5, GLM) on this chip
  env:
    HSA_OVERRIDE_GFX_VERSION: "11.5.1"   # gfx1151 recognition; without it, frequent silent CPU fallback
    OLLAMA_IGPU_ENABLE: "1"              # iGPU/VRAM-detection regression mitigation on 0.30.x builds
    OLLAMA_FLASH_ATTENTION: "1"          # may fall back to f16 on AMD; verify savings
    # HSA_ENABLE_SDMA: "0"               # SDMA-hang workaround (anecdotal; kernel-dependent)
model:
  primary: qwen3-coder:30b
  context_length: 65536
versions:
  # Pin a coherent pair. The OLLAMA_IGPU_ENABLE mitigation targets the 0.30.x line,
  # so pin a current 0.30.x patch (>= the #16529 fix) — SG2/SG3 confirm the exact tag.
  ollama: "0.30.x"    # confirm exact patch in SG2; ROCm 7.2.2+
```
*(Every value above is a worked example to be confirmed by SG2 research / SG3 spikes, not a settled constant.)*

### 2.8 Credential initialization is per tenant

Credentials are never baked into images and never written into `config.yaml` or flavors. Each agent is initialized **interactively, once, after first entry** into a tenant — `claude login`, a Codex key, an OpenCode/Pi/Hermes endpoint config — and the result lives in that tenant's HOME (`~/.claude/`, etc.), which survives container rebuilds (three-layer model).

Re-logging in per tenant is expected and correct. The *strength* of the separation is the tier's job, not this section's: at Tier 0 credential dirs are separated from each other but not from the host user; at Tier 2+ it is UID-enforced (full explanation in §2.2). For HIPAA-grade separation use Tier 2a+.

### 2.9 Tenants and sessions: runtime granularity within a boundary

*(The manifest/registry keys named here are formally schematized in SG4, so SG8 and SG10.5 can both consume one definition; this section gives their meaning.)*

Two orthogonal axes:
- **Tenant = the boundary** (§2.2). Tier decides how hard the wall is. Defined by a **tenant manifest** (YAML overlay, same merge mechanics as flavors): `name`, `tier`, `user`, code mount, browser mode, default model, agent toggles, `k8s` on/off. Onboarding a client = fill one short manifest + run one command (create user, distrobox, profile, browser, nested-podman, sessions).
- **Session = runtime config within a tenant.** Same identity, different runtime: project A on Opus, project B on Sonnet; or distinct per-tool config dirs. A session is a named overlay that sets, all rooted in the tenant HOME under `sessions/<name>/`: per-agent config-dir env (e.g. `CLAUDE_CONFIG_DIR`), model selection (`ANTHROPIC_MODEL` or a per-dir settings file), browser profile, working directory; and it attaches a dedicated tmux session. A `work <session>` launcher sets the env and drops you in.

This composes cleanly: pick a **tier** for the tenant (the wall), use **sessions** inside it (the convenience). Whether *multiple logins* can coexist in one tenant depends on each agent honoring a config-dir env var — SG2 must catalog, per agent, (a) the config/credential-dir relocation variable and (b) the model-selection variable. "Same login, different model" works almost everywhere; "different logins, one tenant" only where the agent supports it (otherwise: a new tenant).

### 2.10 Browser isolation

Per-client accounts and tokens are a real driver: logging into one must not require logging out of another, and a malicious page/extension must not reach another client's tokens. A `browser` knob in the tenant/session manifest:

```yaml
browser:
  mode: shared        # one host browser for everything (default — lightest)
  #     per-tenant    # browser in the tenant, tenant profile/tokens — isolated by UID
  #     per-session   # separate browser profile per session — strongest, heaviest
  engine: firefox     # firefox = clean multi-profile; chromium = user-data-dir
```

`shared` is the default. `per-tenant`/`per-session` run the browser inside the tenant boundary (own profile dir, exported to host via `distrobox-export --app`), so tokens live under that tenant's UID and accidental cross-login is impossible. For HIPAA clients, use `per-tenant` (or stricter).

### 2.11 Kubernetes inside a tenant

Two different roles, kept distinct:
- **k8s as something you develop *against*:** a local cluster runs at the **tenant-user level**; agents/IDE connect via kubeconfig over loopback, so `kubectl` "just works" as if on the host — but the cluster lives inside that tenant's UID like everything else. Opt-in toggle. Requirements (SG3 Spike H): `Delegate=yes` for `cpu cpuset io` in `user@.service.d/`, load `ip_tables`/`ip6_tables`/`iptable_nat`/`ip6table_nat`, pure cgroup v2 (auto on Kinoite), `KIND_EXPERIMENTAL_PROVIDER=podman`. **Prefer `kind` rootless — it is first-class/well-trodden in 2026; the spike is mostly host-prep validation.** `k3d` rootless remains officially experimental (DNS-disabled default network, `--registry-create` incompatible) and is the genuinely higher-risk option — treat it as the spike's stress case, not the default.
- **k8s as the *isolation mechanism* between clients:** no. Namespaces are soft multi-tenancy; real tenant isolation needs separate clusters/vClusters — heavier and weaker than separate users on one box. Kubernetes is a *workload inside* a boundary, never the thing that *makes* boundaries.

---

## 3. Pre-Phase 2 Decisions

**The following must be decided by the human before the Phase 2 goal is launched.** Phase 2 is autonomous and cannot resolve these. Each decision must be recorded in `config.yaml` or the active flavor file.

| Decision | Options | Default |
|---|---|---|
| CLI/terminal agents (in dev_base) | Claude Code, Codex, OpenCode, Pi, OMP, Hermes / subset | All six |
| GUI IDE (in dev_base) | Cursor / none | Cursor |
| Default tier for client work | 0 / 1 / 2a / 2b / 3 | **2a** (dedicated user + distrobox) |
| Phase 2 execution model | A: generate tested artifacts + human-run validation / B: apply to live host | **A** (only safely executable option — see §4.5) |
| Browser mode default | shared / per-tenant / per-session | shared (per-tenant for HIPAA clients) |
| LLM backend module | ollama / lemonade | ollama |
| GPU backend | auto / amd / nvidia / cpu | auto (set in hardware flavor) |
| Primary model | suggestion — largest qwen3-coder that fits VRAM (hardware flavor) | `qwen3-coder:30b` |
| Config format | YAML (`config.yaml` + flavor + tenant/session overlays) via `yq` | YAML |
| Containerfile structure | Modular (one `.layer` per agent/IDE, assembled by build script) | Modular |
| Container engine | podman (Docker generic; nested rootless inside tenants) | podman |
| Active flavor | OS flavor, optionally extended by a hardware flavor | `fedora-kinoite` (+ hardware flavor) |

**Note on credentials:** Claude Code and Codex use their standard providers (Anthropic and OpenAI). No path decision needed — credentials are initialized interactively per tenant after first entry. OpenCode, Pi, OMP, and Hermes are configured per tenant at initialization time to point at local Ollama or a cloud provider.

**Note on primary model:** the default is a *suggestion* that lives in the hardware flavor — the largest `qwen3-coder` that fits VRAM (`qwen3-coder:30b` on 24 GB+). The tutorial documents how to pick it (§2.7, SG4).

**Note on the bootstrap path:** A non-coder is not expected to fill these in by hand. The bootstrap subgoal (SG10) produces a script that probes the machine, then guides the user — optionally with a browser LLM — to generate a correct `config.yaml` + hardware flavor following best practices. The defaults above are what that flow falls back to.

Record decisions before launching. Phase 2 reads them from `config.yaml` and the active flavor, does not ask.

---

## 4. Autonomous Execution Contract

Phase 2 runs without user input from start to finish. This section defines how.

**The defining rule (execution model A): Phase 2 generates and sandbox-tests, but never mutates the live host.** It authors the tutorial, scripts, configs, and a validation runbook; it tests only what is safe in rootless throwaway containers; every step that would touch the live host is authored as a tested `human-required` instruction. The full rule and its boundary are in §4.3 (spike sandbox) and §4.5 (hard rules); everything below assumes it.

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

A spike is a small, isolated test that validates one assumption before any design is committed.

**Spike sandbox boundary (the operational form of execution model A):** spikes may use *rootless throwaway* `podman run --rm` containers and isolated temp dirs — these are discarded and touch nothing persistent. Spikes may **not** create named distroboxes, install host packages, modify `~/Profiles`/tenant homes/`~/Containers`, write systemd user units to the live host, or change live services. Anything requiring those (GPU-on-real-hardware checks, systemd-unit-survives-restart, full end-to-end) is a **human-run** step: Phase 2 produces the exact scripted procedure + expected output, and a human executes it. Each such step is tagged `human-required`.

**Spike-evidence schema (gates are not self-certifiable):** a spike "passes" only if it attaches an evidence record — exact command, raw captured stdout/stderr, exit code, and the specific substring that proves the pass condition. A prose claim ("verified — PASS") is not acceptable evidence.

See Section 5 for the required spike at each subgoal.

### 4.4 Output contract per subgoal

Every subgoal must produce:
1. **Primary artifact** — the file, config, script, or decision produced
2. **Decision log** — what alternatives were considered and why they were rejected
3. **Open questions resolved** — items from the prior subgoal's open questions list that this subgoal closed
4. **Open questions raised** — new questions surfaced during this subgoal, for the next
5. **Validation gate result** — pass or fail, with evidence

**Variable-traceability check (SG5–SG9):** every design/implementation subgoal must diff the variables it references against the SG4 manifest; a non-empty diff (an out-of-manifest constant) fails the gate. This is where "no orphan variables" is actually enforced — at the subgoal that introduces the variable, not retroactively at SG4.

If the validation gate fails, Phase 2 halts and writes a structured failure report. It does not proceed to the next subgoal with a broken state.

### 4.5 Hard rules for autonomous execution

- **Execution model = A (generate, don't apply).** Phase 2 *authors* the tutorial, scripts, configs, and a validation runbook, and *sandbox-tests* what is safe (per §4.3). It does **not** apply artifacts to the live host. Steps that mutate the host (reboots, `rpm-ostree`, group changes, `sudo`/`setsebool`/linger, browser OAuth logins, creating real distroboxes/tenants/services, GPU checks on real hardware) are produced as **tested `human-required` instructions**, not executed. SG13 is therefore a human-in-the-loop gate, not an autonomous one.
- **Subgoal 0 is read-only.** The isolation audit produces a report; it remediates nothing.
- **No `distrobox-host-exec` calls during Phase 2.** Consistent with the generate-don't-apply model above.
- **No `--rm-home` ever.** This would delete a persistent profile / tenant home.
- **De-scope rule for unidentifiable tools.** If SG2 cannot identify a tool to a verifiable package/repo with evidence, that tool's toggle defaults OFF, its spike is marked N/A with rationale, and the chain proceeds. Such tools must be *optional* in the variables manifest so their absence never fails a downstream gate.
- **Deferred-feature rule (single home for k8s/Spike-H deferral).** A feature whose enabling spike is `human-required` or unresolved (notably k8s-in-tenant, Spike H) is built behind a documented toggle and authored as a `human-required` step; it does not block the chain. SG5/SG8/SG10.5 all defer to this one rule rather than restating it.
- **Human-required spikes don't stall the chain.** For a `human-required` spike (e.g. GPU Spike D, k8s Spike H), "pass" means the procedure + expected-output is authored and evidence-ready; actual execution is deferred to SG13. A deferred human-required spike does not block the next subgoal.
- **Runbook = ground truth.** If a spike conflicts with the canonical runbook, the spike wins only with reproducible evidence (per the evidence schema); otherwise the runbook wins. Log the conflict either way.
- **Script implementation is distributed (not all in SG9).** SG8 names every script *and defines the inter-script interfaces* (call signatures). SG9 implements the core/infra scripts as a fan-out over SG8's list; **domain scripts are implemented by their owning subgoal** — tenant scripts (`tenant-create` incl. registry handling, and `work`) in SG10.5, QoL scripts (aliases, tmux, SSH) in SG11 — each against the SG8 interface. No script is implemented twice, and one script may *call* another via its SG8-defined interface even when that other is implemented in a later subgoal (e.g. `tenant-create` calls the SG11 deploy scripts).

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

OS detection must identify: package manager (`rpm-ostree` / `dnf` / `apt` / other), immutability model (atomic/mutable), SELinux status, init system. **SG1 produces detected *facts* only** — it does not author or source an OS module (the OS-module *interface* is defined in SG8; no module exists to source this early). The facts file is consumed later.

General checks (all OS): podman installed and rootless, distrobox installed, git installed, user in correct GPU groups, GPU device nodes present, lingering enabled, native `overlay` (or `fuse-overlayfs` fallback) available.

OS-specific checks (Kinoite): `rpm-ostree` present, overlay filesystem type, SELinux mode.

**Expert panel:** Not required. This is detection and verification, not design.  
**Spike:** rootless throwaway `podman run --rm hello-world` to verify rootless Podman works.  
**Output:** (a) detected OS facts file, (b) prerequisites checklist with pass/fail and the exact fix command per item (fixes that need a human — reboots, group changes, `sudo` — tagged `human-required`).  
**Validation gate:** OS detected, all critical items pass or have a documented (possibly human-required) fix, rootless Podman spike passes with evidence.

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
- Subagent C: each agent + the IDE — Claude Code, Codex, OpenCode, Pi (`badlogic/pi-mono`, npm `@earendil-works/pi-coding-agent`), OMP (`can1357/oh-my-pi`, a CLI/terminal Pi fork), Hermes, and Cursor (the one GUI IDE). For each: install method, package + current version, config location/schema, credential init flow, known Linux/container issues. OMP, Pi, and Hermes identities are known — **confirm packaging/versions and config**. Hermes = `NousResearch/hermes-agent`, a general-purpose assistant (intentionally a different kind of agent than the coding tools); confirm its install method and local-Ollama provider setup.

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
| A — Configurable agent local endpoint | For OpenCode, Pi, OMP, and Hermes: install in a rootless throwaway container, point at local Ollama (or mock), verify connection without a cloud key. Claude Code/Codex use cloud by default (their local paths are documented, not gated here). | Each client connects to the local endpoint and returns a response (evidence attached). Model-selection is additionally checked for the coding agents; Hermes (general assistant) need only connect + respond — it may not expose the same model-selection knob |
| B — Distrobox systemd stability | Create minimal distrobox, write systemd user unit with `--no-tty --no-workdir`, enable it, simulate session restart, verify unit starts | Unit starts, ollama serve begins, `curl :11434/api/tags` responds |
| C — Tenant (UID) isolation | Create two throwaway users (or simulate via UID-mapped rootless containers); write a mode-644 `.env` in one's 700 home; attempt to read it as the other | Cross-UID read is denied — proves Tier 2a contains a compromised agent |
| D — GPU passthrough *(human-required, real hardware)* | Start llm_server with device flags + flavor env block, run inference, check `ollama ps` PROCESSOR | PROCESSOR shows GPU, not CPU (evidence: raw `ollama ps` output) |
| E — SELinux volume mount | Mount a *shared* dir with `:z` vs a single-container dir with `:Z`; verify access on enforcing host | `:z` for shared `~/Code`/`~/Models`/`~/Profiles` (recursive `:Z` on shared dirs breaks other consumers); `:Z` only for single-container volumes |
| F — Podman build ARG | `podman build --build-arg FEDORA_VERSION=$(rpm -E %fedora)` against trivial Containerfile | ARG expands, correct base pulled |
| G — Nested rootless podman | In a rootless throwaway container with subuid/subgid + fuse-overlayfs, run `podman run --rm hello-world` (Podman-in-Podman) | Inner container runs without privilege/host socket |
| H — k8s in a tenant *(highest risk)* | `kind`/`k3d` (rootless podman provider) under a tenant user; `kubectl get nodes` via kubeconfig over loopback | Cluster comes up; kubectl works as if on host |
| I — `yq` deep-merge | Merge general→OS→hardware→tenant overlays with `extends` resolution; verify scalar-override + list-replace semantics | Merged result matches the defined merge semantics |
| J — Browser isolation | Launch a browser with a tenant-scoped profile dir; verify a second profile shares no cookies/tokens; `distrobox-export --app` surfaces it on host | Profiles isolated; export works (note `--no-sandbox` if needed) |

**Expert panel:** Panel of 3 reviews spike results and flags any that contradict the canonical runbook. Conflicts are logged and resolved before proceeding.  
**Output:**
1. Spike result log (pass/fail per spike, with reproduction steps)
2. Architecture confirmation: the canonical design (llm_server + dev_base + os_agent/tenant boxes) is validated, or a specific deviation is documented with evidence
3. Updated open questions list (anything not resolved by spikes)
4. Decision log

**Validation gate:** All `auto` spikes pass with evidence. For `human-required` spikes (D GPU, H k8s), "pass" = procedure + expected output authored and evidence-ready, deferred to SG13 (per §4.5 — a deferred human-required spike does not block SG4). Any failed `auto` spike has a documented resolution path before SG4 begins.

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
- Agent install toggles (claude-code / codex / opencode / pi / omp / hermes)
- IDE toggle (cursor) — consumed by dev_base, not os_agent
- LLM backend module (ollama / lemonade)
- Container engine (podman / docker)
- Per-agent credential initialization method (documented in post-install guide; not a build-time variable)
- GitHub email and username (for profile git config)

**Each variable must be tagged with its layer:** general / OS-flavor / hardware-flavor / tenant / session. This tagging determines which file it lives in (§2.7, §2.9). Hardware-specific values (GPU env, model pick, context length) must be tagged hardware-flavor and must not appear in the general schema.

**SG4 is the single home for the tenant manifest and tenant-registry schemas** (the keys whose *meaning* is given in §2.9: `name`, `tier`, `user`, code mount, `browser`, model, agent toggles, `k8s`). Both SG8 (rebuild-cascade, tenant-create naming) and SG10.5 (implementation) consume them from here, so the schema exists before either needs it.

**Expert panel:** 2 subagents independently draft the variable + manifest schemas; synthesis reconciles.  
**Output:** `config.yaml` schema spec, the flavor-overlay structure, and the tenant/session manifest + registry schemas. Specs, not final files.  
**Validation gate (evaluable now):** the schema is complete, every variable is layer-tagged, and no hardware-specific value sits in the general schema. *(Enforcement that downstream subgoals introduce no orphan variables is delegated to each of SG5–SG9's gates — see §4.4 — not asserted here.)*

---

### SG5 — Base Image Design (`dev_base`)
**Input:** SG2 research (package names, agent + Cursor install methods), SG3 spike evidence (G nested rootless podman, H k8s prerequisites, J browser export), SG4 variables manifest (incl. the tenant manifest schema)  
**Goal:** Define what goes in the Fedora-based `dev_base` image that os_agent and every tenant box inherit from. Derive contents from SG2 research, developer expectations, and the canonical runbook.

**dev_base owns the image-level prerequisites that all tenants need**, so SG10.5 configures tenants on an already-correct base (flow is SG3 → SG5 → SG10.5, no back-edge): the nested-rootless-podman prerequisites (`/etc/subuid`, `/etc/subgid`, `fuse-overlayfs` — §2.4) and the cgroup-v2 delegation needed for optional k8s-in-tenant. Concrete requirements come from SG3 Spikes G and H; if a spike is unresolved, bake the prerequisite behind a documented toggle rather than guess.

**dev_base carries all six CLI/terminal agents plus the Cursor GUI IDE**, each gated by its toggle, because every tenant inherits from dev_base (agents and the IDE live here, never separately in os_agent). Each agent and Cursor is its own modular `.layer` file, so a lean image is just fewer toggles. Cursor (the only *standalone GUI* IDE) is exported to the host desktop via `distrobox-export --app`; its settings persist in the tenant profile (`~/.cursor/`). OMP installs as a CLI-agent layer (it is terminal-first, a Pi fork) but carries IDE capability wired in (LSP/DAP/ACP/Zed + web collab) — so it is not a separate GUI app, yet provides editor-grade features and a browser-reachable collab UI.

**Modular Containerfile structure** (the decided approach): each agent/IDE is one `.layer` fragment under `dev_base/modules/`; a build script assembles the final Containerfile from the toggles in `config.yaml`. The generated Containerfile is committed/auditable. Adding a tool = one new `.layer` file + one toggle. Removing one = flip a boolean.

**Expert panel:** 3 subagents each propose a package list from different angles:
- Subagent A: minimum viable (what do the agents strictly require?)
- Subagent B: developer ergonomics (what would a developer miss on first entry?)
- Subagent C: review Subagent A + B and identify conflicts or redundancies

Synthesis produces the final list with justification for each package included.

**Output:**
1. `dev_base` Containerfile specification + the modular `.layer` module set (spec, not final files)
2. Cursor (GUI IDE) inclusion spec: install method, toggle behavior, `distrobox-export --app` flow (note `--no-sandbox` if needed); the six CLI agents are ordinary `.layer` modules
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
3. `distrobox create` command specification (exact flags, with GPU branching) — `human-required` to apply
4. Validation-procedure spec: the exact commands + expected output for "API responds / no CPU fallback / model pull / service-survives-restart" — authored here, **executed in SG13**, not run against the live host here
5. Decision log

**Validation gate:** The specification and its validation procedure are complete and internally consistent (env from flavor, no chip constants, no `CMD`, `--no-tty` service). The live checks are `human-required` and exercised in SG13 — SG6 does not create the distrobox or start the service.

---

### SG7 — os_agent Design
**Input:** SG2 research (each agent client), SG3 Spike A results, SG4 variables manifest, SG5 dev_base spec  
**Goal:** Define the os_agent Containerfile and its configuration. Each agent client's config is specified here (not in SG4) because config depends on what is installed.

**Scope note:** all six CLI agents and the Cursor GUI IDE are designed in SG5 (dev_base) and inherited by every tenant. os_agent ≈ your Tier-0 tenant from dev_base; it adds no IDE and likely no agent layers of its own. Do not re-define agents/IDE here.

**Items to define:**
- Base image: **dev_base** (settled — agents/IDE are dev_base modular layers; os_agent adds only os_agent-specific config, if any). Document the module-ownership split: which `.layer` files are dev_base (all six agents + Cursor) vs. os_agent-only (likely none — os_agent ≈ Tier-0 tenant from dev_base).
- Each agent: install method, verified package + version pin, in its `.layer` module
- Claude Code: `claude login` after first entry; session in `~/.claude/`; cloud default, local-Ollama path documented
- Codex: OpenAI login/key after first entry; cloud default, `--oss` local path documented
- OpenCode: `~/.config/opencode/opencode.json` (verified version); local Ollama or cloud
- Pi and OMP (oh-my-pi): endpoint + optional key after first entry; local Ollama or cloud
- Hermes: `NousResearch/hermes-agent`; local Ollama (`hermes3:8b`) or cloud
- Nested rootless podman config baked in (subuid/subgid, fuse-overlayfs) — §2.4; **no host socket**
- Volume mounts: code mount (`/workspace`), `~/Containers:ro`. **No `/models` mount** — agents reach models only via the llm_server loopback endpoint (invariant: agents never hold weights)
- Profile layout on first use

**Expert panel:** 3 subagents:
- Subagent A: focuses on agent client configuration (config file formats, env vars, credential isolation)
- Subagent B: focuses on image construction (FROM choice, layer efficiency, build args, version pinning)
- Subagent C: reviews the result against isolation invariants from the architecture requirements document

**Output:**
1. os_agent Containerfile specification
2. Per-agent post-install credential initialization guide (what to run after first entry, per agent)
3. Per-agent config spec for configurable clients (OpenCode JSON schema, Pi endpoint config, Hermes config)
4. `distrobox create` command specification for os_agent
5. Decision log (module-ownership split: which `.layer` files are dev_base vs. any os_agent-only config)

**Validation gate:** The os_agent **spec** is consistent with the SG3 Spike A evidence (OpenCode, Pi, OMP, Hermes already shown to connect to local Ollama in a sandbox). Live verification against a created os_agent box is a `human-required` step in SG13 — not re-run here. Claude Code and Codex credential init is documented, not automated.

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

**The named script list must map 1:1 against this required-scripts checklist** (every implied deliverable has an owner; any omission must be justified). The "implemented by" column resolves the ownership distribution from §4.5 (SG8 names + defines interfaces; the listed subgoal implements):

| Script | Purpose | Implemented by |
|---|---|---|
| audit | SG0 isolation scan | SG9 |
| os-detect / prereqs | SG1 detection + checklist | SG9 |
| config-merge engine | deep-merge general→OS→hardware→tenant→session, resolve `extends` | SG9 |
| schema validator | validate config + manifests against SG4 schemas | SG9 |
| Containerfile assembler | `.layer` modules + toggles → generated Containerfile | SG9 |
| dev_base build | build the shared base image | SG9 |
| llm_server build+create | build image, create box | SG9 |
| `llm_server.service` install | systemd user unit | SG9 |
| os_agent (Tier-0) create | your personal tenant | SG9 |
| `tenant-create` | user, box, profile, browser, nested-podman, k8s-if-toggled, calls deploy scripts, registry, sessions | **SG10.5** |
| `work <name>` session launcher | per-session env + tmux | **SG10.5** |
| shared-aliases / tmux / SSH deploy | per-user QoL setup | **SG11** |
| rebuild-cascade | dev_base → derived images → recreate boxes; enumerates from the SG4 tenant registry | SG9 |
| bootstrap | probe + match + generate + validate config | SG9 |

k8s enablement inside `tenant-create` follows the deferred-feature rule (§4.5) if Spike H is unresolved — named, not dropped.

**Merge semantics must be defined explicitly** (deep merge; scalars override; lists replace-not-append; `extends` chain resolution) and proven by SG3 Spike I.

**Expert panel:** 2 subagents propose a script architecture independently. Synthesis reconciles.

**Output:**
1. Script architecture specification (format, conventions, patterns)
2. OS module interface specification (function signatures every OS module implements) — defined here, before any module is sourced
3. **Inter-script interface contracts** — the call signatures of every script in the table, so a script can call another (e.g. `tenant-create` → deploy scripts) regardless of which subgoal implements it
4. Fedora Kinoite OS module implementation (the one concrete module Phase 2 produces)
5. Named and ordered script list = the table above, with one-line descriptions (the index SG9/SG10.5/SG11 implement against)
6. Idempotency patterns. **Note:** `distrobox create` *is* idempotent (detects an existing box, exits 0) — but it will **not** re-apply changed image/flags; a Containerfile change requires `distrobox rm` first.
7. Decision log

**Validation gate:** The script list covers the checklist with no unjustified gaps; every inter-script call has a defined interface; each script has a single responsibility and a named implementing subgoal.

---

### SG9 — Script Implementation (core/infra scripts)
**Input:** SG8 named script list, interface contracts, and architecture spec; SG4–SG7 specifications  
**Goal:** Implement the **core/infra** scripts marked "SG9" in the SG8 table — a fan-out, one sub-subgoal per script, parallelized where dependencies allow. The tenant scripts (`tenant-create`, `work`) and QoL scripts (deploy) are implemented by their owning subgoals (SG10.5, SG11) against the SG8 interfaces — SG9 does not implement those (no double-ownership).

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

### SG10.5 — Tenant Model and Onboarding
**Input:** SG2 research (tenant-user mechanics, nested rootless podman, browser export, k8s), SG3 spikes (C tenant isolation, G nested podman, H k8s, J browser), SG4 manifest/registry schemas, SG8 architecture + inter-script interfaces  
**Goal:** Implement the tenant as a first-class artifact and the onboarding flow that makes "simple config per client" real.

This subgoal **implements the tenant scripts** (`tenant-create`, `work`) against the SG8 interfaces (§4.5 ownership distribution); the **manifest/registry schemas come from SG4** (referenced, not redefined). It does not re-implement the QoL deploy scripts — it *calls* them via their SG8-defined interface (SG11 implements them).

**Items to implement:**
- **Tier mechanics** per tier: Tier 0 (your user + distrobox), Tier 1 (plain rootless podman, minimal mounts), Tier 2a (dedicated user + distrobox), Tier 2b (dedicated user + plain podman), Tier 3 (VM — spec the interface, implementation future unless a decision says otherwise).
- **`tenant-create <manifest>`**: create the Linux user (700 home, linger, render/video groups), create the box under it, scaffold profile, set up browser per mode, enable nested rootless podman, enable k8s if toggled (deferred-feature rule, §4.5), **call the SG11 deploy scripts** (shared-aliases / tmux / SSH) for the new user via their SG8 interface, register the tenant, create initial sessions. Idempotent. **Authored and isolation-logic sandbox-proven here; running it end-to-end (it creates real users/boxes) is the `human-required` SG13 step** — mirrors SG6/SG7.
- **`work <session>`** launcher: per-agent config-dir env, model selection, browser profile, workdir, tmux attach. **tmux precedence:** SG11 owns `.tmux.conf` + the default bare-entry auto-attach hook; `work` consumes that hook and *overrides* it with the named session (bare entry → default; `work` → named). No double-attach.
- **Entry UX**: dropping into a tenant (`machinectl shell <user>@.host` / wrapper) with minimal friction.

**Expert panel:** 3 subagents — (A) UID/user mechanics + GPU groups + linger per user; (B) nested rootless podman + per-tenant socket + k8s enablement; (C) review against the isolation claims in §2.2 (does Tier 2a actually contain a compromised agent? does `.env`-in-700-home hold?).

**Output:** `tenant-create` + `work` implementations (conforming to SG4 schemas + SG8 interfaces), tier-mechanics spec, entry-UX docs, decision log.

**Validation gate (sandbox + human-run split):** in rootless throwaway sandboxes, prove cross-UID file isolation and nested-rootless-podman work (with evidence). The live sequence — create two tenants on the real host, confirm mutual unreadability, launch isolated browsers, optionally run a local kind cluster — is the tested `human-required` SG13 runbook (the k8s portion is a *separately* pass/failed deliverable so it cannot sink the rest).

---

### SG11 — QoL Layer and Post-Install Guide
**Input:** All prior outputs, SG8 architecture + inter-script interfaces  
**Goal:** Define and implement the quality-of-life layer and write the curated post-install guide. The **shared-aliases / tmux / SSH deploy scripts implemented here conform to the SG8 interface**, so `tenant-create` (SG10.5) can call them for each new tenant user (per-user, idempotent).

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
  - Pi: configure endpoint → local Ollama or pi.dev
  - Hermes: configure to call local Ollama → `hermes3:8b`
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
- When to use which agent (OpenCode/Pi/OMP/Hermes for local/offline; Codex for OpenAI-backed tasks; Claude Code for complex reasoning; all six available in every tenant)
- How agents and humans use the same workspace — no special agent mode
- When to rebuild vs. when to fix inside a running box (rebuild = image issue; fix in profile = config issue)
- The rebuild cycle as a routine, not an emergency

**Per-Project Workflow Pattern must cover:**
- Creating a project distrobox from dev_base (exact command template)
- Deciding: new image vs. reuse dev_base
- Mount strategy: one workspace per box, not ~/Code wholesale
- Git identity per profile — what it means for multi-client work
- IDE per tenant: Cursor inherited from dev_base, exported to host via `distrobox-export --app`, settings isolated in the tenant profile — the IDE's AI sees only that tenant's mount (the six CLI agents are likewise per-tenant)
- Concurrent agents on the same repo: Git worktree strategy (from architecture requirements doc section 10)
- How tenant boxes call the shared llm_server endpoint (no additional setup required)

**Output:** Two complete Markdown sections ready to be included in the tutorial README, plus a concrete project-box creation script/template.  
**Validation gate:** Both sections are internally consistent with the architecture document's invariants. Creating a project box from dev_base yields an isolated IDE that cannot see other projects' mounts.

---

### SG13 — End-to-End Validation Runbook (human-in-the-loop)
**Input:** All scripts and documentation from SG9–SG12  
**Goal:** Per the execution model (§4.5, A), Phase 2 cannot build/apply on the live host, so this subgoal **produces a tested validation runbook** — the exact ordered commands plus expected output for each — that a human runs on a fresh VM or a reset machine. Phase 2 self-validates only the sandbox-safe portions (rootless throwaway containers); everything that mutates the host or needs GPU/credentials is authored as a `human-required` step. Self-certification against the build machine's own pre-existing state is not acceptable.

**Validation sequence (the runbook content; each step marked `auto`-sandbox or `human-required`):**
1. `auto` — Run the isolation audit (SG0); verify it runs clean (read-only)
2. `auto` — Run the bootstrap probe (SG10); verify it is read-only and produces a schema-valid `config.yaml` + hardware flavor
3. `auto` — Run prerequisites check (SG1); verify it detects and reports correctly (read-only)
4. `human-required` — Run setup scripts in order on the host, each twice, to confirm host-level idempotency (this *applies* — distinct from SG9's sandbox idempotency test)
5. `human-required` — Verify llm_server (real hardware + flavor env block):
   - `curl http://127.0.0.1:11434/api/tags` responds
   - `ollama ps` shows GPU in PROCESSOR column (not CPU) — confirms flavor env block worked
   - Service survives `loginctl terminate-session` and re-login
6. `human-required` — Verify os_agent (CLI agents only):
   - `distrobox enter os_agent` succeeds, lands in tmux session
   - OpenCode, Pi, OMP, and Hermes each connect to their configured provider (local Ollama) and return a response
   - Codex launches and accepts OpenAI credentials (cloud default)
   - Claude Code launches and accepts Anthropic login (cloud default)
   - `fd`, `rg`, `gh`, `git`, `tmux` all available
7. `human-required` — Verify tenant workflow + isolation (Tier 2a):
   - create two tenants from dev_base (dedicated users); confirm mutual file unreadability across UIDs; each reaches llm_server
   - launch Cursor (exported to host); confirm it sees only its tenant's mount
   - confirm per-tenant browser profiles share no tokens
8. `human-required`, *separately scored* — Verify optional k8s-in-tenant (only if a tenant's `k8s` toggle is on): under a Tier-2a tenant user bring up a `kind` rootless cluster (`KIND_EXPERIMENTAL_PROVIDER=podman`), `kubectl get nodes` over the loopback kubeconfig. This is the deferred Spike-H deliverable; it is scored on its own and does not sink the rest of the run.
9. `human-required` — Verify rebuild cycle: rebuild os_agent image, recreate distrobox, verify profile survives
10. `auto` — Verify flavor swap (mocked): point config at a different hardware flavor, confirm only the GPU env block changes and core scripts are untouched

**Output:**
1. Validation run log with pass/fail per check
2. Any failures: structured report with reproduction steps
3. If all pass: a "validated on <date> / <OS version> / <hardware>" stamp

**Validation gate:** All checks pass. The tutorial is declared ready for human use.

---

## 6. Hard Constraints

These are non-negotiable and must be enforced at every subgoal.

**Order is the primary constraint.** No subgoal begins until its predecessor's validation gate passes.

**Isolation invariants** (terse imperatives; rationale is in §2.2):
- One profile/HOME per tenant; never copy or symlink credential dirs between tenants.
- Cross-tenant boundary = the dedicated Linux user (Tier 2+); never `--home`.
- Tenant homes mode `700`; no secrets world-readable in shared locations.
- Never share the host container socket across a tenant boundary (nested rootless podman / per-tenant socket).
- Models shared read-only from `~/Models/`, never in a profile; code mounted explicitly per tenant.
- Host stays minimal: podman, distrobox, git, plus the tenant users.

**General operational invariants (all OS):**
- `--no-tty` is *recommended* for `distrobox enter` in a systemd unit's `ExecStart` (a non-interactive context degrades without it). Confirm exact behavior in SG3 Spike B.
- `loginctl enable-linger <user>` is required (per tenant user) for that user's systemd services to survive logout.
- `distrobox create` **is** idempotent (detects an existing box, exits 0) — but it will **not** re-apply changed image/flags; a Containerfile change requires `distrobox rm` first.
- Never use `--rm-home` when removing a distrobox. It deletes the persistent profile/tenant home.
- The LLM backend must bind `127.0.0.1` (loopback), never `0.0.0.0`. Loopback is reachable by all host users (so every tenant reaches it); binding all interfaces would expose it to the LAN.
- AMD GPU: the **host** user running the box must be in `render` and `video` groups (`usermod -aG render,video <user>`); effective on next **login** (logout suffices; reboot not strictly required). At Tier 2+ this applies to each tenant user.
- NVIDIA GPU: distrobox's `--nvidia` bind-mounts host drivers and does *not* need `nvidia-container-toolkit`; the modern **CDI** path (`nvidia-ctk cdi generate` + `--device`) is preferred and *does* need the toolkit. OS-flavor concern; confirm in SG2.
- Intel GPU: no first-party Ollama path (IPEX-LLM archived Jan 2026; Ollama SYCL PR closed unmerged Jun 2026). Falls back to CPU with a clear warning.
- AMD silent CPU fallback: on some AMD targets (notably gfx1151 / Strix Halo) the GPU is detected but inference silently runs on CPU without the correct env block — and the override does not *always* prevent it (build-dependent). The hardware flavor supplies the env; SG6 verifies via `ollama ps` PROCESSOR with captured evidence.
- Claude Code uses the Anthropic Messages API format — incompatible with Ollama's *OpenAI-compatible* endpoint, but Ollama now also exposes an *Anthropic-format* endpoint, so Claude Code can run local (`ANTHROPIC_BASE_URL=…:11434`). Cloud is the default; local is a documented advanced path.
- Context length and VRAM: a large `OLLAMA_CONTEXT_LENGTH` (e.g. the flavor's 65536) costs significant GPU memory — float16 KV cache can exceed 8 GB alone (Flash-Attention / KV-quant roughly halves it). This is a **hardware-flavor** value; the flavor documents how to tune it.
- Podman rootless uses native `overlay` by default on modern kernels/Fedora; `fuse-overlayfs` is the fallback (old kernels, NFS homes, `--userns=keep-id`). Verified in SG1.

**Fedora Kinoite OS module specifics (implemented in Phase 2; examples for future OS modules):**
- Package installation: `rpm-ostree install <pkg>` needs a reboot to *persist* (`--apply-live` makes it usable now but the overlay is lost on reboot). The OS module owns this; core scripts call `pkg_install`. The reboot is a `human-required` step.
- SELinux enforcing by default: **shared** host mounts (`~/Code`, `~/Models`, `~/Profiles`) use `:z`; reserve `:Z` (private, single-container) for non-shared volumes. distrobox auto-labels its own mounts — this matters mainly for hand-written `llm_server.service`/Quadlet mounts. The OS module's `selinux_label_volume` picks the right flag.
- GPU device access in rootless Podman on Fedora needs `sudo setsebool -P container_use_devices=1` (the `-P` persists it across reboot). `human-required`.
- NVIDIA on Kinoite: `rpm-ostree install nvidia-container-toolkit` + reboot.
- Immutability check: `rpm-ostree status`.

**OS template scope:**
- **Phase 2 produces:** Fedora Kinoite template + OS module (the only concrete implementation)
- **Framework supports:** any OS by writing a new template + OS module that implements the module interface (defined in SG8)
- **Not in scope for Phase 2:** Ubuntu, Arch, or other OS modules — but the interface they would implement is defined and documented

---

## 7. QoL Requirements

*Scope definition. Full deliverables are produced and specified in SG11.*

The quality-of-life layer covers: a shared aliases file (sourced via `/run/host`, never copied), a minimal shared tmux config + auto-attach hook, per-tenant GitHub SSH setup, a documented dotfile strategy (profiles start blank by design), agent update paths (rebuild image → recreate box; profile survives), shell preference, and IDE/app export to the host desktop via `distrobox-export`. See SG11 for the per-item deliverables and the post-install guide.

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

**Propagating to all boxes:** A fix to `dev_base` that affects all tenant boxes requires rebuilding dev_base → rebuilding each derived image → recreating each box. The **rebuild-cascade** script (owned by SG8/SG9, enumerating boxes from the SG4 tenant registry) does this.

---

## Appendix: Research Anchors for SG2

These are the primary sources the Phase 2 research subagents must consult. Do not rely on training knowledge; fetch current versions.

- Distrobox documentation: https://distrobox.it/usage/distrobox-create/ and https://distrobox.it/usage/distrobox-enter/
- Ollama AMD/ROCm: https://docs.ollama.com/docker and https://docs.ollama.com/troubleshooting
- Ollama model library: https://ollama.com/library
- Ollama OpenAI-compatible API: https://docs.ollama.com/api/openai-compatibility
- OpenCode documentation: https://opencode.ai/docs/
- OpenCode providers: https://opencode.ai/docs/providers/
- Codex CLI: https://github.com/openai/codex (and `--oss` / Ollama provider for local)
- Claude Code: https://claude.ai/code; local via Ollama's Anthropic endpoint: https://docs.ollama.com/integrations/claude-code
- Pi: `github.com/badlogic/pi-mono`, npm `@earendil-works/pi-coding-agent`, https://pi.dev
- OMP (oh-my-pi): `github.com/can1357/oh-my-pi`, npm/bun `@oh-my-pi/pi-coding-agent`, https://omp.sh — terminal-first Pi fork with **"the IDE wired in"** (LSP, DAP, ACP/Zed plugin, web collab UI). SG2: confirm install + how LSP/DAP/ACP/collab behave inside a tenant box.
- Hermes: `github.com/NousResearch/hermes-agent` — a general-purpose assistant (memory, chat integrations), configurable LLM provider incl. local Ollama. Included intentionally as a general assistant (not a coding tool). Verify install/config in SG2. (Distinct from NousResearch "Hermes Function Calling" and "Atropos".)
- Cursor (GUI IDE export): https://distrobox.it/usage/distrobox-export/
- Lemonade: https://github.com/lemonade-sdk/lemonade
- Rootless Podman-in-Podman + per-user socket: https://docs.podman.io (rootless, `podman.socket`)
- Local Kubernetes rootless: kind (`--provider=podman`) and k3d docs
- Fedora Kinoite: https://docs.fedoraproject.org/en-US/atomic-desktops/
- ROCm Ryzen AI compatibility: https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/
