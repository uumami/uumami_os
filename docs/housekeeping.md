# Housekeeping — disk, images, and keeping the system clean

What actually consumes disk, what is safe to clean, what must never be touched, and the
routine that keeps the machine tidy. Read the mental model first — every recommendation
follows from it.

## The mental model: three storage pools

Everything on this machine lives in exactly one of three pools, and **cleanup tools for one
pool never touch the others**:

| Pool | Where | What's in it | Cleaned by |
|---|---|---|---|
| **1. Podman storage** | `~/.local/share/containers` (per Linux user!) | image layers + each box's writable layer | `podman image prune`, `podman rmi` |
| **2. Host state dirs** | `~/Profiles`, `~/Models`, `~/Code` | credentials/sessions, model weights, source | only ever **manually, deliberately** |
| **3. Repo artifacts** | this repo | generated Containerfiles, facts, spike/evidence logs | git hygiene (`.gitignore` already handles it) |

Podman cleanup can never delete a credential, a model, or code — those are in pool 2.
Conversely, deleting a box (`distrobox rm`) frees only its writable layer in pool 1; the
profile in pool 2 survives (that's the design).

## How image disk really works (copy-on-write)

- Image **layers are stored once** and shared. `dev_base` and `os_agent` both "show" 9.11 GB,
  but they share the same layers — the disk cost is 9.11 GB *total*, not per image.
- Each **box adds only a writable layer** on top, which starts near zero and grows *only with
  what you change inside the box's own filesystem*. Ten boxes from `dev_base` ≈ one 9.11 GB
  base + ten thin layers.
- **`podman system df`** is the truth: `SIZE` vs `RECLAIMABLE` tells you what's waste.
  `podman ps -a --size` shows each box's real writable-layer cost (the non-"virtual" number).

**Per-tenant note (accepted trade-off):** rootless podman storage is **per Linux user**, so
each Tier-2a tenant keeps its own copy of `dev_base` (~9 GB per tenant user). That is the
isolation working — tenants cannot see each other's images. We accept the duplication for
simplicity; tenants also clean *their own* store (`sudo -iu <tenant> podman image prune`).
(If tenants ever multiply, podman's read-only `additionalimagestores` is the sanctioned
optimization — a future `tenant-create` enhancement, deliberately not done yet.)

## What accumulates (the four kinds of waste)

1. **Dangling images** — every rebuild leaves the previous image untagged. Harmless, safe to
   prune, and the main thing that grows over time.
2. **Obsolete tagged images** — images from retired designs (e.g. pre-Phase-2 `localhost/base`,
   `localhost/claude_os_agent`). Podman can't know they're obsolete; a human decides, checking
   first that no box uses them (`distrobox list`).
3. **Bloated writable layers** — a box whose RW size keeps growing means things are being
   installed *at runtime inside the box*. The fix is not cleanup, it's the three-layer rule:
   move durable tooling into a `.layer` and **recreate the box** (the layer resets to ~zero,
   profile survives).
4. **Unused models** — weights in `~/Models` (pool 2). `distrobox enter llm_server -- ollama
   list` to review, `... ollama rm <model>` to remove. Never delete files there by hand.

## The safety rules

- **NEVER `podman system prune -a` / `podman image prune -a`.** The `-a` removes *every* image
  not currently used by a container — including a freshly built image whose box you haven't
  (re)created yet. This is the classic way to destroy an hour of build time. Plain
  `podman image prune` (dangling only) is always safe.
  - Corollary: **`RECLAIMABLE` in `podman system df` lies for our workflow.** It counts any
    image no *container* uses — so between "image built" and "box recreated" your newest
    images show as "reclaimable". (Observed live: right after the Phase-2 cleanup it claimed
    74% reclaimable, which was precisely the new `dev_base` + `os_agent` awaiting recreate.)
    Judge by *dangling* + your own review of `podman images`, never by that number.
- **Never `--rm-home`** on `distrobox rm` — deletes the profile (pool 2).
- **Never hand-delete inside `~/Profiles` or `~/Models`** except via the decommission
  checklist below / `ollama rm`.
- **In-use images are protected** — podman refuses to remove an image a container references.
  If `rmi` refuses, that's the system telling you a box still depends on it; investigate,
  don't `--force`.

## The routine

**After every rebuild + recreate cycle** (the moment waste is created):
```bash
uu clean          # explain-plan first; removes dangling images only (podman image prune)
```

**Monthly (or when disk feels tight) — look, then decide:**
```bash
podman system df          # how much is reclaimable?
podman ps -a --size       # any box's RW layer ballooning? → move installs to a .layer + recreate
podman images             # any tagged image no box uses anymore? → podman rmi <name>
distrobox enter llm_server -- ollama list    # models you no longer use? → ollama rm
```

**Decommissioning a tenant** (explicit, in order — nothing here is automatic by design):
```bash
distrobox rm -f <name>                        # 1. the box (writable layer freed)
# 2. its images, from THE TENANT's store:  sudo -iu <user> podman image prune
# 3. the registry entry:                   yq -i 'del(.tenants[] | select(.name=="<name>"))' ~/Profiles/registry.yaml
# 4. ONLY IF the identity is truly over:   archive/delete the profile (Tier 0: ~/Profiles/<name>;
#    Tier 2a: sudo userdel -r <user>)      ← this destroys credentials; there is no undo
```

## Why the repo stays clean by itself

Generated Containerfiles are committed on purpose (auditable); build transcripts and the
per-machine `facts.env`/`flavor-request.md` are gitignored; curated `evidence-*.log` spike
records are kept as proof. `bash setup/lib/assemble.sh <image> --check` fails if a committed
Containerfile drifts from its `.layer` modules — nothing goes stale silently.
