#!/usr/bin/env bash
# tenant-create.sh — create an isolated tenant from a manifest (SG10.5). Runs ON THE HOST.
#
# A tenant = one isolation boundary (own credentials, code, config). Tier 0 lives under YOUR
# user; Tier >= 2a gets a DEDICATED Linux user (kernel-walled — proven in
# setup/spikes/evidence-tenant-isolation.log). Execution model A: the non-privileged work runs
# here; the privileged parts (creating the Linux user) are EMITTED as human-required steps and
# never executed. Idempotent throughout (never --rm-home; never mounts /models; loopback only).
#
# Usage:
#   tenant-create.sh [--dry-run] <manifest.yaml>      # orchestrate (validate, register, set up / emit)
#   tenant-create.sh --user-setup [--dry-run] <m>     # the per-user phase (run AS the tenant user)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/config.sh"

DRY=0; USER_SETUP=0; MANIFEST=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --user-setup) USER_SETUP=1 ;;
    -*) echo "tenant-create: unknown flag $a" >&2; exit 1 ;;
    *) MANIFEST="$a" ;;
  esac
done
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "usage: tenant-create.sh [--dry-run] <manifest.yaml>" >&2; exit 1; }

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
mq()  { local v; v="$(yq -r "$1" "$MANIFEST" 2>/dev/null)"; [ "$v" = null ] && v=""; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${2:-}"; }

merged="$(merge_config "$ROOT")"
def_tier="$(cfg_get "$merged" '.tenants.default_tier' '2a')"
def_browser="$(cfg_get "$merged" '.tenants.browser_default' 'per-tenant')"
def_model="$(cfg_get "$merged" '.model.primary' '')"
profiles="$(expand_tilde "$(cfg_get "$merged" '.paths.profiles' "$HOME/Profiles")")"
containers="$(expand_tilde "$(cfg_get "$merged" '.paths.containers' "$HOME/Containers")")"
registry="$profiles/registry.yaml"

# --- resolve manifest -------------------------------------------------------
name="$(mq '.name')"; [ -n "$name" ] || { echo "manifest: .name required" >&2; exit 1; }
case "$name" in *[!a-z0-9-]*) echo "manifest: .name must be kebab-case (a-z0-9-)" >&2; exit 1 ;; esac
tier="$(mq '.tier' "$def_tier")"
image="$(mq '.image' 'localhost/dev_base:latest')"
browser="$(mq '.browser' "$def_browser")"
model="$(mq '.model' "$def_model")"
k8s="$(mq '.k8s' 'false')"

if [ "$tier" = 0 ]; then
  # Tier 0: the box runs under YOU. The profile (box HOME) is ~/Profiles/<name>, but `~` in
  # code_mount means your REAL home — keep them distinct (owner_home != profile dir here).
  tuser="$(id -un)"; thome="$profiles/$name"; owner_home="$HOME"
else
  tuser="$(mq '.user' "$name")"
  # getent exits 2 for an absent user; tolerate it (|| true inside the sub) so set -e/pipefail
  # doesn't silently abort before we even reach the human-required user-creation guidance.
  thome="$(getent passwd "$tuser" 2>/dev/null | cut -d: -f6 || true)"; [ -n "$thome" ] || thome="/home/$tuser"
  owner_home="$thome"   # Tier >= 2a: the tenant user IS the owner; ~ resolves to their home
fi

# code_mount: expand ~ / ~user against the tenant OWNER's home; default to <owner_home>/code/<name>
code_raw="$(mq '.code_mount' "$owner_home/code/$name")"
# shellcheck disable=SC2088  # the `~` below are case PATTERNS, not paths to be expanded
case "$code_raw" in
  "~/"*)        code_mount="$owner_home/${code_raw#\~/}" ;;
  "~$tuser/"*)  code_mount="$owner_home/${code_raw#\~$tuser/}" ;;
  "~"*)         code_mount="$owner_home/${code_raw#\~*/}" ;;   # any ~user → owner home (best effort)
  *)            code_mount="$code_raw" ;;
esac

# =====================================================================================
# do_user_setup — the NON-privileged per-user phase. Runs as the owning user (you for Tier 0,
# the tenant user for Tier >= 2a via `sudo -iu`). Idempotent. No sudo.
# =====================================================================================
do_user_setup() {
  echo "[tenant:$name] user-setup as $(id -un): tier=$tier home=$thome image=$image"
  run mkdir -p "$thome"
  [ "$tier" = 0 ] && run chmod 700 "$thome"   # Tier-0 profile under ~/Profiles; Tier-2a home is already 700
  run mkdir -p "$code_mount"                   # the box won't create if the volume source is missing

  # Browser isolation: scaffold a per-tenant (or per-session) browser profile dir.
  case "$browser" in
    per-tenant)  run mkdir -p "$thome/.local/share/uumami-browser/$name" ;;
    per-session) while IFS= read -r s; do [ -n "$s" ] && run mkdir -p "$thome/.local/share/uumami-browser/$s"; done \
                   < <(yq -r '(.sessions // [])[].name' "$MANIFEST" 2>/dev/null) ;;
    shared)      : ;;
  esac

  # The box. distrobox create is idempotent (exits 0 if it exists) but won't re-apply changed
  # flags — recreate (rm -f, never --rm-home) to pick up a new image/mounts.
  if distrobox list 2>/dev/null | grep -qw "$name"; then
    echo "[tenant:$name] box already exists (recreate with: distrobox rm -f $name && rerun)"
  else
    run distrobox create --yes --name "$name" --image "$image" --home "$thome" \
      --volume "$code_mount:/workspace" --volume "$containers:/containers:ro"
  fi

  # Per-tenant runtime descriptor consumed by `work` inside the box (sessions, model, browser).
  # Kept in the tenant's own home — never the admin registry (which it can't write).
  local desc="$thome/.config/uumami/tenant.yaml"
  run mkdir -p "$thome/.config/uumami"
  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] write $desc (name/tier/model/browser + sessions from manifest)"
  else
    { echo "name: $name"; echo "tier: \"$tier\""; echo "model: ${model:-}"; echo "browser: $browser"; echo "k8s: $k8s"; echo "sessions:"; yq -r '.sessions // []' "$MANIFEST" | sed 's/^/  /'; } > "$desc"
  fi

  # SG11 QoL deploy scripts (aliases / tmux / ssh) — call if present (implemented later).
  for d in deploy-aliases deploy-tmux deploy-ssh; do
    [ -x "$SCRIPT_DIR/$d.sh" ] && run bash "$SCRIPT_DIR/$d.sh" "$thome" || true
  done

  if [ "$k8s" = true ]; then
    echo "[tenant:$name] k8s toggle ON — in-tenant rootless kind is a deferred-feature (Spike H, human-required)."
  fi
  echo "[tenant:$name] user-setup done. Enter: distrobox enter $name ; then log each agent in (per-agent guide)."
}

# =====================================================================================
# register_tenant — record the tenant in the ADMIN registry (runs as you). Idempotent.
# =====================================================================================
register_tenant() {
  run mkdir -p "$profiles"
  if [ "$DRY" = 1 ]; then echo "  [dry-run] register '$name' in $registry"; return; fi
  [ -f "$registry" ] || echo 'tenants: []' > "$registry"
  N="$name" U="$tuser" T="$tier" I="$image" C="$code_mount" B="$browser" \
    yq -i 'del(.tenants[] | select(.name == env(N)))
           | .tenants += [{"name": env(N), "user": env(U), "tier": env(T),
                           "image": env(I), "code_mount": env(C), "browser": env(B)}]' "$registry"
  echo "[tenant:$name] registered in $registry"
}

# --- the per-user phase (invoked as the tenant user) ------------------------
if [ "$USER_SETUP" = 1 ]; then do_user_setup; exit 0; fi

# --- orchestration ----------------------------------------------------------
echo "== tenant-create: $name (tier $tier, user $tuser) =="
register_tenant

if [ "$tier" = 0 ]; then
  do_user_setup
  exit 0
fi

# Tier >= 2a: needs a dedicated Linux user.
if [ "$(id -un)" = "$tuser" ]; then
  do_user_setup
elif id "$tuser" >/dev/null 2>&1; then
  cat <<EOF

[human-required] The Linux user '$tuser' exists. Run the per-user setup AS that user:
    sudo -iu $tuser bash $SCRIPT_DIR/tenant-create.sh --user-setup $MANIFEST
EOF
  exit 2
else
  cat <<EOF

[human-required] Tier $tier needs a dedicated Linux user. As an admin, create it (this is the
ONLY sudo step — it auto-allocates non-overlapping subuid/subgid for nested rootless podman):
    sudo useradd -m -d "$thome" "$tuser"
    sudo chmod 700 "$thome"
    sudo loginctl enable-linger "$tuser"
    sudo usermod -aG render,video "$tuser"     # GPU access (harmless if the host uses open nodes)
Then run the per-user setup AS that user:
    sudo -iu $tuser bash $SCRIPT_DIR/tenant-create.sh --user-setup $MANIFEST
EOF
  exit 2
fi
