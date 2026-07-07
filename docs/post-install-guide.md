# Post-install guide — using the environment day to day

Setup is done ([README](../README.md)); this is how you *live* in it. Everything here applies
to `os_agent` and to any tenant box — they're the same shape.

## First entry: what you see

```bash
distrobox enter os_agent
```

- Your prompt lands **inside a tmux session named `main`** (the auto-attach hook; detach with
  `Ctrl-a d`, opt out for one shell with `UUMAMI_NO_AUTOATTACH=1`).
- `$HOME` is this box's **profile** (`~/Profiles/os_agent` for Tier 0, the tenant user's home
  for Tier 2a) — *not* your host home. This is the identity boundary.
- Your code is at **`/workspace`**; the shared container definitions (read-only) at `/containers`.
- The `uu` CLI and the shared aliases are live: try `uu` (the help screen), `uu status`,
  `uu aliases agents` (the agent-launcher shortcuts: `clc` = continue Claude, `coo` = Codex
  on the local model, …). `uu help <command>` explains anything with examples.

If a box is missing the QoL layer (created before SG11, or opted out), deploy it:

```bash
bash setup/lib/deploy-aliases.sh "$HOME" && bash setup/lib/deploy-tmux.sh "$HOME" && bash setup/lib/deploy-ssh.sh "$HOME"
```

## First-time credential initialization (once per box)

Each agent stores its login in **this profile only** — repeat per box, never copy between
profiles. Templates for the local-Ollama configs live in
[`setup/templates/agent-configs/`](../setup/templates/agent-configs/README.md); details per
agent (what to run, what it stores, where) are in that guide. Summary:

| Agent | Run | Stores in |
|---|---|---|
| Claude Code | `claude login` (browser auth) | `~/.claude/` |
| Codex | `codex login` or `OPENAI_API_KEY` | `~/.codex/` |
| OpenCode | drop `opencode.json` template | `~/.config/opencode/` |
| Pi | drop `pi-models.json` template | `~/.pi/agent/` |
| OMP | drop `omp-models.yml` template | `~/.omp/agent/` |
| Hermes | `hermes model` wizard | `~/.hermes/` |

**Verify each one** after init: `claude --version && claude` (opens the REPL), `codex --oss`
(local model), `opencode` (should list the Ollama provider), `hermes` (banner shows the model).

## GitHub / SSH

`deploy-ssh.sh` already generated `~/.ssh/id_ed25519_github` and the `github.com` config
block. Finish it once per box:

```bash
cat ~/.ssh/id_ed25519_github.pub    # → GitHub → Settings → SSH keys → New
ssh -T git@github.com               # expect: "Hi <you>! You've successfully authenticated"
```

(`github-auth` loads the key into the host agent manually if ever needed. For https instead,
`gh auth login` works too — it stores in this profile.)

## Models: pulling, switching, checking

```bash
llm-models                       # what's available on the shared server
llm-pull qwen3-coder:30b         # pull a new model (goes to ~/Models on the host)
llm-ps                           # what's loaded + PROCESSOR (must say GPU)
```

Switching the *default* model: edit `model.primary` in your hardware flavor, then re-run
`bash setup/lib/llm_server.sh` (🔶 recreates the llm_server box). Switching per session:
set it in the tenant manifest's session entry and use `work <session>`.

## Daily work

- **One box per identity, sessions within it:** `work --list`, `work <name>` (model/workdir/
  browser per session, own tmux session).
- **New project** → see [per-project workflow](per-project-workflow.md) (sessions vs. new
  tenant vs. per-project image).
- **New tool for everyone** → add a `.layer` + toggle, then [propagate](propagating-fixes.md).

## Updating agents

Agents are **pinned in the image** — they don't self-update (that's the reproducibility).
To update: bump the version in `images/dev_base/modules/2X-agent-*.layer` → `bash
setup/lib/rebuild.sh` → 🔶 recreate the boxes (printed for you). Profiles survive; you stay
logged in.

## Customizing your shell / dotfiles

- **Profiles start blank on purpose** — each identity accumulates only its own state. To seed
  one from your dotfiles repo, clone it *inside the box* and symlink into `$HOME` (the
  profile); it stays per-tenant.
- The deployed `~/.tmux.conf` is only a starting point — once you edit it, redeploys leave it
  alone (they detect the customization).
- **Different shell:** install it via a `.layer` (so it survives), then inside the box:
  `chsh -s /usr/bin/zsh` (persists in the profile).

## When something breaks

1. **Agent broken / box weird** → recreate the box (never `--rm-home`): profile + code survive.
   `distrobox rm -f <name>` then the create command from `rebuild.sh`'s output.
2. **Model slow / wrong device** → `llm-ps`: PROCESSOR must say `100% GPU`. If CPU: check the
   flavor's `gpu.env` reached the box (`rebuild.sh --recreate-llm` re-injects it).
3. **Endpoint dead** → `systemctl --user status llm_server` on the host;
   `bash setup/lib/install-llm-service.sh` re-installs the unit.
4. **Config confusion** → `bash setup/lib/validate.sh` tells you exactly what's wrong.
5. **Disk filling up** → see [housekeeping](housekeeping.md): `podman image prune` after every
   rebuild+recreate is the one habit; never `prune -a`; models via `ollama rm`.
6. **Everything on fire** → the three-layer rule means you can always rebuild: images from
   this repo, profiles are on disk, code is in git. `bash setup/test/selftest.sh` to confirm
   the base is healthy (49 checks).
