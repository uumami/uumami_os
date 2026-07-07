# CLAUDE.md

Guidance for Claude Code (and any AI agent) working in this repository. The operating rules
for agents are in **[docs/agents-guide.md](docs/agents-guide.md)** — read them first.

## Project

`uumami_os` is the reproducible definition of a local-AI development workstation:
a shared GPU inference server (`llm_server`, Ollama on loopback) plus isolated dev boxes
(distroboxes) built from one shared toolchain image (`dev_base`). The full architecture and
the execution state live in `docs/superpowers/specs/2026-06-23-os-agent-setup-design.md`
(**Section 0 is the resume point** — read it before continuing any build work).
Reference machine: Fedora Kinoite 44, Strix Halo (gfx1151); the framework is OS-generic.

## Layout

```
config.yaml                 general config (toggles); hardware/OS values live in flavors/
flavors/                    OS + hardware overlays, merged over config.yaml (extends: chains)
images/<name>/modules/      .layer fragments → assemble.sh generates the Containerfile
setup/lib/                  all scripts (detect, config, assemble, build, validate, rebuild,
                            bootstrap, llm_server, tenant-create, work, deploy-*)
setup/schema/MANIFEST.md    every config variable, layer-tagged (source of truth)
setup/templates/            agent configs, tenant manifest example, QoL templates
setup/test/selftest.sh      end-to-end validation (62 checks) — run after changes
docs/                       tutorial companions + the master spec
```

## Key commands

```bash
uu status / uu help --agent           # the CLI front door (deterministic facade over setup/lib)
bash setup/lib/validate.sh            # config/schema check — run before building
bash setup/lib/build.sh <image>       # assemble .layers + podman build (dev_base, os_agent…)
bash setup/lib/rebuild.sh             # cascade: dev_base → derived images → recreate guidance
bash setup/test/selftest.sh           # full E2E validation on the host
```

Scripts run **on the host**; from inside a box use `distrobox-host-exec`. This agent usually
runs inside `os_agent` — it **cannot recreate its own box** (host terminal, human-required).

## Invariants (enforced by validate.sh + selftest.sh — do not violate)

- Loopback-only inference (`127.0.0.1`); never `0.0.0.0`; no port publishing.
- Agent boxes never mount `/models`; only `llm_server` holds weights; it holds no credentials.
- Never `--rm-home` (deletes a profile). Profiles are identity boundaries — never copy or
  symlink credential dirs between them.
- No secrets in images, `config.yaml`, or flavors — credentials are initialized per tenant
  after first entry.
- Hardware/OS values live in `flavors/`, never in `config.yaml` (layer purity).
- No host container socket in any box; nested rootless podman only.
- Host-mutating steps (sudo, reboot, box recreation, tenant users) are emitted as
  `human-required` instructions, never executed silently (execution model A).

## Rebuild cycle

Edit `.layer` → `build.sh` → `distrobox rm <name>` (no `--rm-home`) → `distrobox create`
(profile + mounts survive). `rebuild.sh` prints the exact recreate commands.
