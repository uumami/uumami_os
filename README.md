# uumami_os — a local AI coding environment

Turn a Linux computer into a workstation where **AI models run on your own hardware** and each
project gets its own walled-off space. Nothing is sent to a cloud unless you choose a cloud agent.

**You do not need to know how to code.** There is one command to run. It asks questions, explains
each step, and you can stop and restart it whenever you like.

---

## What you need before starting

| | |
|---|---|
| A Linux computer | Tested on Fedora Kinoite 44; the scripts adapt to other distributions |
| About 60 GB free disk | The toolchain is ~9 GB, an AI model is ~20 GB |
| A GPU (recommended) | AMD or NVIDIA. Without one it still works, just slowly |
| 30-60 minutes | Mostly waiting for downloads |

Two programs must be installed first: **podman** and **distrobox**. If they are missing, the
installer stops and prints the exact command to install them — it will not carry on and leave
you with a half-built machine.

---

## Step 1 — Get the files onto your computer

Don't worry about where they end up — Step 2 sorts that out.

### The normal way: a ZIP file

You will have been given a ZIP file (the project is currently private, so there is no public
download link). Save it to your `Downloads` folder, then open a terminal and run:

```bash
cd ~/Downloads
unzip uumami_os.zip
ls
```

> If it says `unzip: command not found`, install it first — on Fedora
> `sudo dnf install unzip`, on Ubuntu/Debian `sudo apt install unzip`. Or just double-click the
> ZIP in your file manager and choose "Extract".

`ls` lists what unzipping created — a folder such as `uumami_os` or `uumami_os-main`. Enter it
using the name you actually see:

```bash
cd uumami_os        # <- use the name ls showed you
```

### The alternative: `git clone`

Only works once the project is public, or if you have been given access and have already set up
a GitHub account with an SSH key. If you are not sure whether that applies to you, it does not —
use the ZIP above.

```bash
git clone https://github.com/uumami/uumami_os.git ~/Containers
cd ~/Containers
```

If this prints `repository not found` or asks for a password, you do not have access yet. That
is not something you can fix from here — ask for the ZIP file instead.

---

## Step 2 — Run the installer

From inside the folder you just entered:

```bash
bash install.sh
```

If it says **"this folder is not a complete copy of the project"**, you are in the wrong
folder or the download was cut short — `cd` into the right one, or download it again.

The installer checks where the files are and offers to move them to the standard location
(`~/Containers`). **Say yes.** Then it prints one line to copy — run that, and it carries on.

> **Why this matters:** ending up with two copies in two folders — editing one while the tools
> use the other — is the single most common cause of baffling errors. The installer detects
> that and fixes it. Never move the folder by hand with `mv` afterwards: if the destination
> already exists, `mv` quietly puts your folder *inside* it instead of replacing it, which
> creates exactly the mess it looks like it avoided.

That is the whole thing. It will:

1. **Check your computer can run this** — and stop with exact instructions if something is missing.
2. **Confirm the files are in the right place** — and offer to fix it if not.
3. **Work out your hardware settings.** If your graphics card is not one it already knows, it
   writes you a file to paste into any AI chat in your browser; the chat replies with the
   settings file to save. It tells you the exact filename.
4. **Build and start the AI model server** and download a model.
5. **Build your personal dev box** with the coding agents inside it.
6. **Install the `uu` command** and the keyboard shortcuts.
7. **Check it all actually works** and tell you if it does not.

**It is safe to stop it** (Ctrl-C) and run `bash install.sh` again — it continues where it
stopped. It never starts over and never deletes your work.

Useful variations:

```bash
bash install.sh --status     # what is done so far? (changes nothing)
bash install.sh --dry-run    # show every action without doing any of it
bash install.sh --repair     # shortcuts missing or broken? fix them
```

---

## Step 3 — Use it

Open a **new terminal** (so the new commands are found), then:

```bash
uu status              # how is everything doing? Always tells you what to do next
uu enter os_agent      # go into your dev box
```

Inside the box you have the coding agents (`claude`, `codex`, `opencode`, `pi`, `omp`,
`hermes`), plus short forms — `uu aliases` lists them all.

Each agent needs to be logged in once, inside the box:

| Agent | First run | Uses your local model? |
|---|---|---|
| `claude` | `claude login` | only through a translation proxy — see the guide |
| `codex` | `codex login` | yes — `codex --oss` |
| `opencode` | provider login | yes |
| `pi` / `omp` | set endpoint on first run | yes |
| `hermes` | `hermes model` wizard | yes |

Ready-made settings for each: [`setup/templates/agent-configs/`](setup/templates/agent-configs/README.md).

---

## Giving a project its own walled-off space

Your personal box (`os_agent`) is convenient but not sealed. For client work, or any project you
want genuinely separated — its own credentials, its own code, its own browser logins:

```bash
uu tenant new acme
```

At the default strength the project gets its **own Linux user account**, which is the only part
of this whole system that needs administrator rights. `uu tenant new` does not do that for you —
it stops and prints the exact numbered commands to copy, and you will be asked for your password.
Run them in order, and the last one finishes the setup.

Want to avoid the password step? Create a lighter space that lives under your own account:

```bash
uu tenant new acme --tier 0
```

At the strongest setting the separation is enforced by the operating system itself: one
project's account genuinely cannot read another's files. (Proof:
`setup/spikes/evidence-tenant-isolation.log`.)

Switch between setups inside a box with `work <name>` (`work --list` shows them).

---

## When something goes wrong

Run this first — it explains problems in plain language and suggests the fix:

```bash
uu doctor
```

| Symptom | What to do |
|---|---|
| `uu: command not found` | Open a new terminal. Still missing? `bash ~/Containers/install.sh --repair` |
| Shortcuts like `gs` or `cl` do nothing | `uu repair`, then `exec bash` |
| Answers are very slow | The model is on the CPU, not the GPU. `uu status` — the processor line should say `100% GPU` |
| The model server is not responding | `uu logs` shows why |
| "no such container" | The box was never created or was deleted: `uu setup` |
| Running low on disk | `uu clean --dry-run` shows what is safe to delete |

Nothing here deletes your code, your credentials or your models unless you explicitly ask it to.

---

## How it is put together

```
Your computer
│
├── llm_server            the AI model, on your GPU, reachable only from this machine
│                         (127.0.0.1 — never exposed to the network)
│
└── dev boxes             each one = a separate identity with its own credentials and code
    ├── os_agent          your personal box
    └── acme, ...         one per walled-off project
```

Everything that survives deleting a box lives in exactly one of three places:

| | What it holds | Shared? |
|---|---|---|
| **Image** (`images/*/modules/*.layer`) | installed programs | shared by every box |
| **Profile** (`~/Profiles/<name>`) | credentials, settings, sessions | one per box |
| **Code** (mounted at `/workspace`) | your project files | one per box |

Because the toolchain image is shared, fixing something once fixes it everywhere. Because
credentials live in profiles, two projects can never see each other's logins.

To change what is installed in the boxes, edit a file in `images/dev_base/modules/` and run
`uu rebuild`. To change settings, edit `config.yaml` and run `uu validate`.

---

## Going deeper

- [Post-install guide](docs/post-install-guide.md) — daily use, credentials, models, updating
- [Per-project workflow](docs/per-project-workflow.md) — a worked two-project example
- [Propagating fixes](docs/propagating-fixes.md) — updating the toolchain everywhere
- [Housekeeping](docs/housekeeping.md) — how disk is really used, what is safe to clean
- [Porting guide](docs/porting-guide.md) — a different computer or distribution
- [Agents guide](docs/agents-guide.md) — the rules AI agents follow inside the boxes
- [Variables manifest](setup/schema/MANIFEST.md) — every setting explained
- [Master design spec](docs/superpowers/specs/2026-06-23-os-agent-setup-design.md) — the full architecture

**Safety rules the tools enforce for you:** the model server is only reachable from this
computer; boxes never hold model files; no passwords or keys are ever written into the config or
images; deleting a box never deletes its profile; hardware settings stay in `flavors/`.
