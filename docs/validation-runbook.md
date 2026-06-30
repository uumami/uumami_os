# Validation runbook (SG13) — the human-in-the-loop tests

The automated checks all pass (`bash setup/test/selftest.sh` → 42/42). This runbook is the
set of steps the scripts **cannot** run for you — they need sudo, a host terminal, a reboot,
or a GUI. Do them in order; each says exactly what to run and what "good" looks like.

> Convention: `🔶` = needs sudo or a reboot. Run everything from a **host terminal** (not from
> inside a distrobox) unless told otherwise.

---

## A. GPU memory — what you have now, and how to get the rest

### What's in use right now (measured 2026-06-30)

Strix Halo has **no fixed VRAM** — the GPU uses two pools:

| Pool | Size | What it is |
|---|---|---|
| Dedicated VRAM | **4 GiB** | the BIOS UMA carveout (`/sys/class/drm/card*/device/mem_info_vram_total`) |
| GTT | **60.7 GiB** | system RAM the GPU maps on demand (`ttm.pages_limit`, default = RAM/2) |
| **GPU-addressable total** | **~64 GiB** | what Ollama sees and loads models into |
| Host RAM total | 121 GiB | |

`qwen3-coder:30b` uses ~45 GB (at 256K context) and runs at **100% GPU** — it fits
comfortably in the ~64 GiB pool. **You do not need to expand anything for 30B/8B models.**

### When to expand, and when NOT to

Strix Halo is **memory-bandwidth-bound** (~213 GB/s). For a model that already fits, more
VRAM does **not** raise tokens/sec. Expand **only** for models that don't fit today:
70B-dense, 100B+ MoE, or very-long-context runs. For everything you're doing now, skip this.

### 🔶 How to expand to ~90 GiB (when you actually need it)

The lever is `ttm.pages_limit` (raises the GTT pool). One kernel arg + one reboot:

```bash
# 1. (optional) In BIOS: set "UMA Frame Buffer / Dedicated VRAM" to MINIMUM — AMD-recommended;
#    frees stranded RAM. Yours is already small (4 GiB), so this is optional.

# 2. Raise the GTT limit to ~90 GiB (90 * 262144 = 23592960 pages). Append ONE karg:
sudo rpm-ostree kargs --append=ttm.pages_limit=23592960
sudo systemctl reboot

# 3. After reboot, verify it took:
cat /sys/module/ttm/parameters/pages_limit          # expect: 23592960
cat /sys/class/drm/card*/device/mem_info_gtt_total  # expect: ~96636764160 (≈90 GiB)
```

This leaves ~31 GiB for the host (121 − 90). **Do NOT exceed `28835840` (~110 GiB)** — that
is a confirmed multi-user OOM-kill regime. **Do NOT** use `ttm.page_pool_size`,
`amd_iommu=off`, or `amdgpu.gttsize` (see `flavors/fedora-kinoite-strix-halo.yaml` for why).

**Recovery if a bad karg won't boot:** at GRUB pick the previous deployment, boot, then
`sudo rpm-ostree rollback`.

---

## B. 🔶 Recreate `os_agent` onto the new image

The new `os_agent` image (with all 6 agents + Cursor) is built, but the running box still
uses the old image. A box can't recreate itself, so do this from a **host terminal** (close
any agent session running inside os_agent first). Your profile and code survive — **never
`--rm-home`**. These flags match your current box exactly (only the image changes):

```bash
distrobox rm os_agent
distrobox create --name os_agent --image localhost/os_agent:latest \
  --home "$HOME/Profiles/os_agent" \
  --volume "$HOME/Code/system:/workspace" \
  --volume "$HOME/Containers:/containers"
distrobox enter os_agent
```

**Good looks like:** inside the box, every agent answers:

```bash
claude --version && codex --version && opencode --version \
  && pi --version && omp --version && hermes --version && rpm -q cursor
```

---

## C. Run the full self-test yourself

From a host terminal:

```bash
cd ~/Containers          # (or wherever you cloned this repo)
bash setup/test/selftest.sh
```

**Good looks like:** `selftest: 42 passed, 0 failed`. Use `--quick` to skip the live-inference
and throwaway-box checks.

---

## D. 🔶 Create a real isolated tenant (Tier 2a) and prove the wall

This is the headline feature: a project whose credentials/code another project **cannot read**.

```bash
cd ~/Containers
cp setup/templates/tenant-example.yaml acme.yaml      # edit name/user/code/agents/sessions
bash setup/lib/tenant-create.sh acme.yaml             # prints the 🔶 sudo commands
```

It will print exact commands like these — run them (this is the only sudo step):

```bash
sudo useradd -m -d /home/acme acme
sudo chmod 700 /home/acme
sudo loginctl enable-linger acme
sudo usermod -aG render,video acme
```

Then the unprivileged per-user setup (creates the box, profile, browser, sessions):

```bash
sudo -iu acme bash ~/Containers/setup/lib/tenant-create.sh --user-setup ~/path/to/acme.yaml
```

Enter and use it (credentials you log in here live only in acme's home):

```bash
sudo -iu acme -- distrobox enter acme
#   inside:  claude login   (or codex/opencode…)   then:   work acme-opus
```

### Prove the isolation (the part worth seeing yourself)

Make a second tenant `beta` the same way, then from your own user try to read acme's creds:

```bash
sudo -u beta cat /home/acme/.claude/.credentials.json    # EXPECT: Permission denied
ls -ld /home/acme                                         # EXPECT: drwx------ (700) acme
```

Permission denied is the kernel UID wall — exactly what the sandbox spike proved
(`setup/spikes/evidence-tenant-isolation.log`). To tear a tenant down without losing its
home: `distrobox rm -f acme` (never `--rm-home`).

---

## E. 🔶 Survives-logout / survives-reboot (the llm_server service)

The inference server should come back on its own after a reboot (it's a lingering user
service). Verify once:

```bash
sudo systemctl reboot
# after logging back in (do NOT open a terminal session as a prerequisite — that's the point):
systemctl --user is-active llm_server.service          # expect: active
curl -fsS http://127.0.0.1:11434/api/tags | head -c 80 # expect: JSON list of models
distrobox enter llm_server -- ollama ps                # (after a request) PROCESSOR = 100% GPU
```

If it's not active after reboot, linger may be off: `loginctl enable-linger $USER` then
re-run `bash setup/lib/install-llm-service.sh`.

---

## Checklist

- [ ] A. (only if you need >64 GiB) expand `ttm.pages_limit`, verify after reboot
- [ ] B. recreate `os_agent`, confirm all 6 agents + cursor
- [ ] C. `selftest.sh` → 42 passed
- [ ] D. create `acme` + `beta` tenants, confirm mutual `Permission denied`
- [ ] E. reboot, confirm `llm_server` auto-starts on GPU
