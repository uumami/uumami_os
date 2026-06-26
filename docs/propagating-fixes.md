# Propagating fixes

How a change flows from one edit to every box that should get it — and how to stop it from
reaching a box that shouldn't.

## The cascade

Images form a tree rooted at `dev_base`:

```
dev_base ──FROM──┬── os_agent
                 ├── acme        (only if acme has its own image)
                 └── beta        (only if beta has its own image)
llm_server  (independent — not derived from dev_base)
```

When you change a shared `.layer` (bump an agent version, add a package), the fix must
rebuild `dev_base` and **every image derived from it**, then the boxes must be **recreated**
to pick up the new image. `rebuild.sh` does the builds and prints the recreate steps:

```bash
bash setup/lib/rebuild.sh
```

It will:
1. `build.sh dev_base` — re-assemble the Containerfile from modules and rebuild.
2. `build.sh <each derived image>` — `os_agent` plus any tenant images in the registry.
3. **Print** the 🔶 human-required recreate commands (it does not run them — see below).

Add `--recreate-llm` to also rebuild + recreate `llm_server` (safe: it's never the box you're
running inside).

## Why recreates are human-required (not automated)

`distrobox create` is idempotent — but it will **not** re-apply a changed image to an existing
box. A Containerfile change only takes effect after `distrobox rm` + `distrobox create`. Two
reasons that step is left to you:

- **A box cannot recreate itself.** If you're working *inside* `os_agent`, recreating it would
  kill your session. Do it from a **host terminal**.
- **Tenant boxes belong to other Linux users** (Tier 2a) — recreating them needs that user's
  session or sudo.

The recreate is safe for your data: **profiles and code mounts survive**. The golden rule:

> **Never pass `--rm-home`.** It deletes the persistent profile (all your credentials and
> sessions). `rebuild.sh` and `llm_server.sh` only ever use `distrobox rm -f` (no `--rm-home`).

Typical recreate (printed for you by `rebuild.sh`):

```bash
distrobox rm -f os_agent && distrobox create --name os_agent \
  --image localhost/os_agent:latest --home "$HOME/Profiles/os_agent" \
  --volume "$HOME/Code:/workspace" --volume "$HOME/Containers:/containers:ro"
```

## Pinning a project to an older toolchain (opting OUT of the cascade)

Sometimes you *don't* want a project to move when `dev_base` changes — it depends on an older
agent or a frozen tool. Give that project its **own image** so the cascade doesn't touch it:

- Build it `FROM dev_base:<a-tag-you-pinned>` instead of `:latest`, **or**
- Build it `FROM` a base you don't rebuild, and capture its tools in its own
  `images/<project>/modules/`.

Because the cascade only rebuilds images you ask it to (and recreates only the boxes you
choose), a project on its own pinned image simply isn't swept along. See
[per-project workflow #3](per-project-workflow.md#3-a-per-project-image-when-a-project-needs-different-tools).

## Verifying a propagation worked

After recreating a box, confirm the change actually landed:

```bash
distrobox enter os_agent -- claude --version      # e.g. the version you bumped to
bash setup/lib/assemble.sh dev_base --check       # generated Containerfile matches the modules
```

`assemble.sh … --check` is also useful in CI / a pre-commit hook: it fails if the committed
Containerfile drifts from the `.layer` modules, so the audited artifact never goes stale.

## Quick reference

| You changed… | Run | Then 🔶 recreate |
|---|---|---|
| a shared `.layer` (agent/tool) | `rebuild.sh` | os_agent + derived boxes (printed) |
| a flavor's GPU/model/version | `llm_server.sh` | llm_server (`rebuild.sh --recreate-llm`) |
| a single project's own image | `build.sh <project>` | just that project's box |
| only `config.yaml` toggles | `build.sh dev_base` | os_agent + derived boxes |
