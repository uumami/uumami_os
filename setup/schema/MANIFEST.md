# Variables Manifest (SG4)

Single source of truth for every configuration variable: what it controls, which **layer**
it lives in, and its constraints. `setup/lib/validate.sh` enforces this file. Downstream
work (SG5–SG13) must not introduce variables absent from here (the no-orphan-variables rule).

## Layers (merge order, later wins)

`config.yaml` (general) → OS flavor → hardware flavor → tenant → session.
The active flavor is named in `config.yaml`; flavors chain via `extends:`.
Deep-merge semantics (proven by Spike I, implemented in `config.sh`):
**maps merge recursively; scalars override; lists replace (not append)**.

| Layer | File | Holds |
|---|---|---|
| general | `config.yaml` | OS/hardware-agnostic choices |
| OS flavor | `flavors/<os>.yaml` | package manager, SELinux, immutability, linger |
| hardware flavor | `flavors/<os>-<chip>.yaml` | GPU env, model pick, VRAM, image/version pins |
| tenant | tenant manifest (see below) | identity boundary + per-tenant overrides |
| session | session entry in the registry | runtime granularity within a tenant |

**Purity rule:** no hardware/OS value may appear in `config.yaml`. Forbidden general-layer
keys: `gpu`, `model`, `memory`, `os`, `selinux`, `distrobox`, `llm_image`,
`llm_version_constraint`. **Secrets never appear in any committed layer** — they are
initialized per tenant after first entry.

## General variables (`config.yaml`)

| Key | Controls | Constraint |
|---|---|---|
| `flavor` | active hardware/OS flavor (root of the `extends` chain) | string; `flavors/<flavor>.yaml` must exist |
| `paths.containers` | Containerfiles/modules/services dir | path (host) |
| `paths.profiles` | one isolated HOME per tenant (Tier 0) | path (host) |
| `paths.models` | model weights (shared RO into llm_server) | path (host) |
| `paths.code` | source workspaces, mounted per tenant | path (host) |
| `container_engine` | engine for build/run | `podman` \| `docker` |
| `llm.backend` | LLM server module | `ollama` \| `lemonade` |
| `llm.host` | inference bind/connect host | loopback only (`127.0.0.1`) |
| `llm.port` | inference port | integer (default `11434`) |
| `agents.claude_code` | bake Claude Code layer into dev_base | bool |
| `agents.codex` | bake Codex layer | bool |
| `agents.opencode` | bake OpenCode layer | bool |
| `agents.pi` | bake Pi layer | bool |
| `agents.omp` | bake oh-my-pi layer | bool |
| `agents.hermes` | bake Hermes layer | bool |
| `skills.<name>` | agent skill enabled; source + pin in `setup/schema/sources.yaml` | bool |
| `apps.<name>` | desktop app enabled (host Flatpak); id in `sources.yaml` | bool |

**`setup/schema/sources.yaml`** answers *where from, and at which version*, while `config.yaml`
answers *on or off*. Both must agree or `validate.sh` fails: an enabled toggle with no pinned
source is a silent no-op. Skills are pinned to a tag or SHA on purpose — they are instructions
your agents obey, so a floating branch would let upstream change your agents' behaviour on the
next update. `uu update` shows old → new and never moves a pin for you.
| `ide.cursor` | bake Cursor (GUI IDE) layer | bool (consumed by dev_base, not os_agent) |
| `tenants.default_tier` | default isolation tier for new tenants | `0`\|`1`\|`2a`\|`2b`\|`3` (default `2a`) |
| `tenants.browser_default` | default browser isolation mode | `shared`\|`per-tenant`\|`per-session` |

> Agent/IDE **version pins** live inline in each `images/dev_base/modules/*.layer` (one
> tool = one file = its pinned version), not as separate config variables — co-located with
> the install they govern. Verified pins (spike, 2026-06-25): claude-code 2.1.191,
> codex 0.142.2, opencode-ai 1.17.11, pi 0.80.2, omp 16.1.18 (+ bun 1.3.14), cursor resolved
> at build time, hermes rolling (curl installer, no pin — flagged).

## OS-flavor variables (`flavors/<os>.yaml`)

| Key | Controls | Constraint |
|---|---|---|
| `os.id` / `os.variant` / `os.version` | OS identity; `os.version` → `FEDORA_VERSION` build arg | strings |
| `os.pkg_manager` | host package manager | `rpm-ostree`\|`dnf`\|`apt`\|… |
| `os.immutable` | atomic host? | bool |
| `os.selinux` | SELinux mode | `enforcing`\|`permissive`\|`disabled` |
| `selinux.shared_mount_flag` | volume suffix for shared host dirs | e.g. `:z` |
| `selinux.private_mount_flag` | volume suffix for private volumes | e.g. `:Z` |
| `selinux.gpu_boolean` | setsebool name if GPU device access needs it | string\|absent |
| `distrobox.no_tty` / `enable_linger` / `overlay_driver` | box lifecycle prefs | bool / bool / string |

## Hardware-flavor variables (`flavors/<os>-<chip>.yaml`)

| Key | Controls | Constraint |
|---|---|---|
| `gpu.vendor` | device branching | `amd`\|`nvidia`\|`intel`\|`cpu` |
| `gpu.gfx` / `gpu.path` | gfx target; backend path | strings (e.g. `gfx1151`, `rocm`) |
| `gpu.device_flags` | `--device` flags injected at box create | list |
| `gpu.rootless_selinux_flag` | rootless GPU access flag | e.g. `--security-opt label=disable` |
| `gpu.env` | env injected into llm_server (HSA override, flash-attn, …) | map (no chip constants elsewhere) |
| `llm_image` | pinned LLM backend image | image ref |
| `llm_version_constraint.known_good` / `avoid` | reproducible version pin/guardrails | string / list |
| `model.primary` | default model | string (e.g. `qwen3-coder:30b`) |
| `model.context_length` | context window | integer (VRAM-dependent) |
| `memory.ram_gib` / `vram_gib` / `vram_expansion.*` | RAM/VRAM facts + expansion procedure | numbers / structured (human-required) |

## Tenant manifest schema (§2.9 — consumed by SG8 rebuild + SG10.5 tenant-create)

| Key | Meaning | Constraint |
|---|---|---|
| `name` | tenant id (box/profile/registry key) | kebab-case |
| `tier` | isolation strength | `0`\|`1`\|`2a`\|`2b`\|`3` |
| `user` | Linux user (Tier ≥ 2; created with sudo — human-required) | string |
| `image` | image the box builds from | image ref (default `localhost/dev_base:latest`) |
| `code_mount` | this tenant's code tree → `/workspace` | path |
| `browser` | browser isolation mode | `shared`\|`per-tenant`\|`per-session` |
| `model` | per-tenant default model override | string (optional) |
| `agents.*` | per-tenant agent enablement (subset of dev_base) | bools (optional) |
| `k8s` | enable in-tenant kind cluster (deferred-feature, §4.5) | bool (default false) |
| `sessions` | list of session entries | see below |

## Session schema (runtime granularity within a tenant)

| Key | Meaning | Constraint |
|---|---|---|
| `name` | session id (e.g. `acme-opus`) | kebab-case |
| `agent` | which agent the session launches | one of the enabled agents |
| `model` | model for this session | string |
| `browser_profile` | browser profile when `per-session` | string (optional) |
| `workdir` | working dir under the code mount | path (optional) |

## Tenant registry (state; `${paths.profiles}/registry.yaml`, gitignored)

A list under `tenants:` of created tenant manifests (above) plus their resolved `user`
and `image`. Written by `tenant-create` (SG10.5); read by `rebuild.sh` to enumerate boxes
to recreate. Not committed (runtime state, may reference real usernames).
