# Per-project workflow

How to keep several projects on the **same shared base** while staying **separated and
modular**. Sharing `dev_base` shares only the *toolchain* — never your code, credentials, or
config. This guide shows the three ways to separate projects and when to reach for each.

## The mental model

```
localhost/dev_base          ← shared, read-only parent (git, node, the agents, cursor…)
        │  (FROM)
        ├── os_agent box      home=~/Profiles/os_agent     mounts: ~/Code → /workspace
        ├── acme box          home=acme-user's $HOME       mounts: ~acme/code → /workspace
        └── beta box          home=beta-user's $HOME       mounts: ~beta/code → /workspace
```

| Layer | Shared across boxes? | Where it's set |
|---|---|---|
| **Image** (toolchain) | ✅ shared (`dev_base`) — the dedup | `images/dev_base/modules/*.layer` |
| **Profile** = box HOME (creds, sessions, IDE/git config) | ❌ one per box | `--home` |
| **Code mount** (`/workspace`) | ❌ one per box | `--volume` |
| **Runtime config** (model, opencode.json, browser) | ❌ per box/session | profile + `work` |
| **Nested containers** (the project's own podman builds) | ❌ per box | inside the box's UID |

Two projects on the same base **cannot read each other's code, credentials, or config**. At
Tier 2a they're also separated by a Linux UID, so it's kernel-enforced, not convention.

## Three ways to separate projects — pick by how strong a wall you need

### 1. Sessions inside one box (lightest)
Same box, same credentials, different *model / working dir / browser profile*. Best for
several of **your own** projects where you trust yourself across them.

```bash
# (planned: the `work` launcher) — one box, many named sessions
work acme-opus       # qwen/opus, ~/Code/acme, browser profile A
work beta-sonnet     # different model, ~/Code/beta, browser profile B
```
Cheapest to create; **no isolation between the sessions** (same UID, same creds).

### 2. A separate box / tenant per project (the default for real separation)
Its own profile + mounts, and at **Tier 2a** its own Linux user (kernel-walled). Best for
client work or anything whose credentials and code must never touch another project's.

```bash
# (planned: `tenant-create <manifest>` — needs sudo to make the Linux user → 🔶 human-required)
# Until that lands, a Tier-0 box by hand:
distrobox create --name acme --image localhost/dev_base:latest \
  --home "$HOME/Profiles/acme" \
  --volume "$HOME/Code/acme:/workspace" --volume "$HOME/Containers:/containers:ro"
distrobox enter acme
# log each agent in *inside acme* — those credentials live only in ~/Profiles/acme
```
Same toolchain as `os_agent`, completely separate identity and code.

### 3. A per-project *image* (when a project needs different tools)
When project A needs, say, Rust + a database client that project B shouldn't carry, give A its
own image built **FROM dev_base**. It shares all the base layers but adds its own.

```bash
mkdir -p images/acme/modules
cat > images/acme/modules/00-base.layer <<'EOF'
# module:  acme-base
# toggle:  always
FROM localhost/dev_base:latest
RUN dnf install -y rust cargo postgresql && dnf clean all
EOF
bash setup/lib/build.sh acme        # assembles + builds localhost/acme:latest
# then create the acme box from localhost/acme:latest instead of dev_base
```
The assembler is generic over image name, so a new project image is one module dir + one
`build.sh`. This is also how you **pin a project to an older toolchain** — see
[propagating fixes](propagating-fixes.md).

## Worked example: `acme` (client) + `beta` (personal side project)

| | acme (Tier 2a, walled) | beta (Tier 0, convenient) |
|---|---|---|
| Linux user | `acme` (own UID) | you |
| Box home / profile | `/home/acme` | `~/Profiles/beta` |
| Code mount | `/home/acme/code → /workspace` | `~/Code/beta → /workspace` |
| Image | `localhost/dev_base` (+ acme image if it needs extra tools) | `localhost/dev_base` |
| Claude/Codex creds | only in acme's profile | only in beta's profile |
| Browser | per-tenant profile (own logins) | shared |
| Model | `qwen3-coder:30b` via the shared llm_server | same shared server |

Both talk to the **one** `llm_server` over `127.0.0.1:11434` — they share *model computation*,
never *sessions, credentials, or code*. Deleting the `acme` box (without `--rm-home`) leaves
acme's profile + code intact; recreating it restores the environment exactly.

## Rules that keep the separation real

- **Never** copy or symlink a credential dir (`~/.claude`, `~/.codex`, `~/.config/opencode`,
  `~/.pi`, `~/.omp`, `~/.hermes`) between profiles — that breaks the identity boundary.
- **Never** mount `/models` into a project box. Agents reach models only via the loopback
  endpoint; only `llm_server` holds weights.
- **Never** share the host container socket into a box. Each box runs its own rootless
  nested podman (already baked into `dev_base`).
- Capture project-specific tooling in the project's image (#3) or a committed setup script in
  the code mount — not as ad-hoc runtime installs that vanish when the box is recreated.
