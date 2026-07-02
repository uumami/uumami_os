# Porting guide — arriving with a different machine or OS

This repo is **validated end-to-end on one reference machine** (Fedora Kinoite 44, AMD Strix
Halo). The framework is designed so that *someone arriving with anything else* — a different
GPU, a different distro — can adapt it by **adding files, not changing core scripts**. This
page is that arrival path, for a human working alone, a human + browser AI, or a coding agent
driving the port autonomously.

## What a port actually consists of

You produce at most **three small files**; everything else is already generic:

| Artifact | When you need it | Contract to follow |
|---|---|---|
| **Hardware flavor** `flavors/<os>-<chip>.yaml` | always | schema in [`setup/schema/MANIFEST.md`](../setup/schema/MANIFEST.md); gold-standard example: `flavors/fedora-kinoite-strix-halo.yaml` |
| **OS flavor** `flavors/<os>.yaml` | new OS only | same manifest (OS-flavor table) |
| **OS module** `setup/lib/os/<id>[-<variant>].sh` | new OS only | the function contract in [`setup/lib/os-module.sh`](../setup/lib/os-module.sh) (~10 functions; return 0=done / 2=human-required / 1=error) |

Core scripts (`detect`, `config`, `assemble`, `build`, `validate`, `tenant-create`, `work`,
deploys) must **not** be edited for a port. If a port seems to require editing them, that's a
framework bug — fix the interface, not the instance.

## The ordered path

### 1. Probe — let the scripts gather the truth

```bash
bash setup/lib/ensure-yq.sh
bash setup/lib/bootstrap.sh
```

`detect.sh` writes the machine facts (OS, atomicity, SELinux, GPU PCI-ID, RAM…). Facts are
**authoritative** — neither humans nor agents should re-guess them.

### 2. Author the flavor — with a browser AI doing the research

If no flavor matches, bootstrap writes **`setup/flavor-request.md`**: a ready prompt embedding
your facts + the schema + the research questions (known-good backend image for *your* GPU,
required env vars, VRAM/model guidance). Paste it into any browser AI, save the returned YAML
under `flavors/`, re-run `bootstrap.sh` until `[validate] PASS`.

Rules that keep this honest:
- Every uncertain value gets **flagged, never silently guessed** (the prompt says so).
- GPU claims must be **spike-verified** before you trust them (step 4) — a flavor is a
  hypothesis until a container proves it.

### 3. New OS? Write the OS module

Copy `setup/lib/os/fedora-kinoite.sh`, implement the contract for your package manager /
SELinux / linger behavior. Anything needing root must *print* the exact command and return 2
(human-required) — never execute it. `os_module_load` picks your module from the detected
`ID`/`VARIANT_ID` automatically.

### 4. Prove the GPU path in a throwaway container (the critical spike)

Silent CPU fallback is the classic porting failure. Before building anything real:

```bash
podman run --rm <flags-and-env-from-your-flavor> <llm-image> ollama serve &
# pull a small model, run one generation, then the gate:
#   ollama ps → PROCESSOR must show GPU
```

Keep the transcript as an evidence record (`setup/spikes/evidence-<chip>.log` — see the
existing ones for the shape). If the flavor's env doesn't produce GPU inference, fix the
flavor, not the scripts.

### 5. Build and validate everything

```bash
bash setup/lib/llm_server.sh && bash setup/lib/install-llm-service.sh
bash setup/lib/build.sh dev_base && bash setup/lib/build.sh os_agent
bash setup/test/selftest.sh        # the gate: every check green (49 on the reference machine)
```

The selftest is OS-agnostic; it reads your merged config. Green selftest = your port has the
same guarantees the reference machine proved (agents work, GPU inference, tenant isolation
logic, invariants).

### 6. Contribute it back

A finished port = your two/three files + the spike evidence log. Commit them; the next person
with your hardware skips straight to step 5. That's how "general" accretes: one validated
instance at a time.

## If you are an AI agent driving this

Follow the loop in [agents-guide.md](agents-guide.md), plus porting-specific rules:

- **Facts from `detect.sh` outrank your training data.** Research current versions/regressions
  live (or emit the browser-agent request for the human) — GPU-stack knowledge goes stale fast.
- **Spike before you claim.** No flavor value is "confirmed" until a rootless throwaway
  container demonstrated it (step 4) with a saved evidence log.
- **Respect the human-required tags.** BIOS, kernel args, package installs on the host,
  reboots: print the exact commands, wait for the human.
- **The validation gate is `selftest.sh`, not your judgment.** Add checks if your platform
  needs them; never weaken existing ones.
- Uncertain → flag it in the flavor as a comment (`# UNVERIFIED:`), keep the toggle
  conservative, and say so in your report.

## Reference-machine specifics (so you know what's *not* general)

Kept deliberately machine-specific: `flavors/fedora-kinoite-strix-halo.yaml` (measured VRAM
split + expansion procedure), `docs/validation-runbook.md` (that machine's human checklist),
the PCI-ID shortlist in `detect.sh` (extend it with yours). Everything else you read in this
repo is the general framework.
