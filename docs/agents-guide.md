# Agents guide — operating rules for AI agents in this environment

You (an AI coding agent) are running **inside a distrobox** on a host you must treat as
sacred. This page is your contract. It applies to every agent (Claude Code, Codex, OpenCode,
Pi, OMP, Hermes) in every box (`os_agent` or any tenant).

## Where you are

- `$HOME` = this box's **profile** (credentials, sessions, config — *this identity only*).
- `/workspace` = the code mount (the only project code you can see — by design).
- `/containers` = the shared container/image definitions, read-only.
- The host filesystem is reachable at `/run/host/...` — **read** freely, **write** deliberately.
- The shared LLM endpoint is `http://127.0.0.1:11434` (OpenAI-compatible at `/v1`).

## The rules

1. **Host changes only through the door, with approval.** The one sanctioned path to the host
   is `distrobox-host-exec` (alias `host`). Anything host-mutating — package installs, systemd,
   creating users/boxes, kernel args — must be proposed to the human first, tagged clearly
   (e.g. `human-required`), never run as a silent side effect.
2. **Never touch another identity.** Do not read, copy, or symlink credential dirs
   (`~/.claude`, `~/.codex`, `~/.config/opencode`, `~/.pi`, `~/.omp`, `~/.hermes`) across
   profiles; do not reach into other tenants' homes or `~/Profiles/*` from the host mount.
3. **Never delete a box with `--rm-home`.** It destroys the profile (credentials, sessions).
   `distrobox rm -f <name>` alone is safe — profiles and code survive.
4. **Loopback only.** Never bind or reconfigure services to `0.0.0.0`; the model server stays
   on `127.0.0.1`. Never mount `/models` into an agent box.
5. **No host container socket, no nested daemons.** Build/run dev containers with the
   *rootless podman inside this box* (already configured). Never bind the host's
   podman/docker socket.
6. **Make changes reproducible.** Anything installed into the box filesystem at runtime dies
   on recreate. Durable tooling goes in a `.layer` module (`images/dev_base/modules/`) or a
   committed project setup script; durable state goes in the profile or `/workspace`.
7. **Idempotence + evidence.** Scripts you write should be re-runnable; claims you make should
   be verified by running the command and reading its output (`setup/test/selftest.sh` for
   the environment itself).

## How to work (the loop the human expects)

Inspect → propose the smallest reversible next step → get approval for anything
host-touching → act → **verify with evidence**. Details: [zen-coding.md](zen-coding.md).

## Environment know-how you'll need

| Task | How |
|---|---|
| The CLI front door | `uu help --agent` — full machine contract (exit codes 0/2/3/1, --json reads, --dry-run plans). Prefer `uu` verbs over raw scripts. |
| Talk to the local LLM | `curl http://127.0.0.1:11434/v1/chat/completions` (or your agent's provider config — templates in `setup/templates/agent-configs/`) |
| See loaded models / GPU | `llm-ps` (must say `100% GPU`), `llm-models` |
| Run something on the host | `host <cmd>` — with human approval for mutations |
| Validate the repo config | `bash setup/lib/validate.sh` |
| Full environment health check | `bash setup/test/selftest.sh` (42 checks) |
| Change an image | edit `.layer` → `bash setup/lib/build.sh <image>` → recreate is human-required |
| The architecture / why | `docs/superpowers/specs/2026-06-23-os-agent-setup-design.md` |
| Adapt to a new machine/OS | [porting-guide.md](porting-guide.md) — facts from detect.sh outrank your training data; spike before you claim |

## Session context

`~/.config/uumami/tenant.yaml` (if present) describes this tenant: its tier, default model,
browser mode, and named sessions. `work <session>` switches sessions; `UUMAMI_SESSION`,
`UUMAMI_MODEL`, `UUMAMI_BROWSER_PROFILE` are exported inside one. Respect the active
session's model choice unless the human asks otherwise.
