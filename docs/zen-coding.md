# Zen coding practice

The working style this environment is built for. The setup gives you isolation and
reproducibility; these habits turn that into calm, fast, reversible work — for both humans and
agents.

## 1. The box is disposable; three things are not

Internalize the reconstruction rule: everything that matters lives in the **image**, the
**profile**, or the **code mount**. If deleting and recreating your box would lose something,
that something is in the wrong place — move it into a `.layer`, into the profile, or into a
committed setup script in the repo. Then `distrobox rm` stops being scary: it's just a refresh.

> Litmus test before you install anything ad-hoc: *"if I recreate this box tomorrow, is this
> still here?"* If no, capture it in a `.layer` or the code.

## 2. Small, reversible steps

Prefer the smallest change that moves you forward, and keep it reversible:
- One concern per change; commit often with messages that say *why*.
- Branch for anything non-trivial; the default branch stays releasable.
- Validate before you build (`validate.sh`), build before you recreate, verify after you
  recreate. Evidence before claims — run the command, read the output.

## 3. The host is sacred; touch it only on purpose

Agents and daily work happen **inside a box**. The host stays clean (no dev stacks, no project
deps installed on the host). When something genuinely must change the host, do it explicitly:

```bash
distrobox-host-exec <command>      # the one sanctioned door from box → host
```

Make that door **require approval** in your agent's permission policy. A host change should be
a deliberate, visible act — never a silent side effect of an agent run. Never run a nested
Docker/Podman *daemon* in a box; the rootless nested podman baked into `dev_base` is enough.

## 4. One identity per intent

A tenant is an identity boundary. Don't blur them:
- Client work, personal work, and experiments get **separate tenants** (or at least separate
  profiles), each with its own credentials and browser logins.
- Never copy a credential dir between profiles to "save a login." A fresh `claude login` in
  the new box is cheaper than a leaked identity.
- Pick the **tier** for the wall you need (§2.2 of the design spec), then use **sessions**
  inside it for convenience.

## 5. Let the agent propose the next step

The agent works best as a collaborator that **proposes the smallest next reproducibility
task**, you approve, it acts, you both verify. A good loop:

1. *Inspect* — the agent reads the workspace and container defs, explains the current state.
2. *Propose* — it suggests the next small, reversible step (and what could go wrong).
3. *Approve* — you okay it; host-touching steps require explicit approval.
4. *Act + verify* — it makes the change and shows the evidence it worked.

Keep the model **local by default** (the shared `llm_server`) for iteration; reach for cloud
models deliberately when a task needs them. The endpoint is loopback-only — your prompts and
code never leave the machine unless you choose a cloud agent.

## 6. Calm defaults

- **Reproducible over clever.** A change captured in a `.layer` beats a clever one-off.
- **Pinned over latest.** Version-pin tools so a rebuild is the same tomorrow; bump on purpose.
- **Loopback over exposed.** Never bind a service to `0.0.0.0`; `validate.sh` enforces it.
- **Quiet over noisy.** Fewer running boxes, fewer logins, fewer host changes. The leanest
  setup that does the job is the most Zen — and the easiest to reason about when it breaks.

---

These are principles, not a gate. The mechanics (isolation, the cascade, the layers) are in
the [README](../README.md), [per-project workflow](per-project-workflow.md), and
[propagating fixes](propagating-fixes.md); this doc is just how to hold them.
