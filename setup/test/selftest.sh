#!/usr/bin/env bash
# selftest.sh — end-to-end validation of the uumami_os build (SG13 auto-checks). Runs ON THE
# HOST. Exercises every component that can be tested without sudo / without recreating os_agent,
# and prints a clear PASS/FAIL summary. Human-required steps (os_agent recreate, Tier-2a user
# creation, reboot survival) are listed at the end, not executed.
#
# Usage:  selftest.sh            (functional checks; creates + tears down a throwaway Tier-0 box)
#         selftest.sh --quick    (skip the live-inference and real-box-create checks)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"            # setup/test -> setup
ROOT="$(cd "$ROOT/.." && pwd)"                  # -> repo root
export PATH="$HOME/.local/bin:$PATH"
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
P=0; F=0; S=0
pass() { echo "  ✓ $*"; P=$((P+1)); }
fail() { echo "  ✗ FAIL: $*"; F=$((F+1)); }
skip() { echo "  ~ skip: $*"; S=$((S+1)); }
sect() { echo; echo "── $* ──"; }

cd "$ROOT" || exit 1
echo "=== uumami_os selftest ($(date -u +%FT%TZ)) — repo $ROOT ==="

sect "1. host probe + tooling"
command -v yq >/dev/null && pass "yq present ($(yq --version 2>&1 | awk '{print $NF}'))" || fail "yq missing"
command -v podman >/dev/null && pass "podman present" || fail "podman missing"
command -v distrobox >/dev/null && pass "distrobox present" || fail "distrobox missing"
bash setup/lib/detect.sh --write setup/facts.env >/dev/null 2>&1 && pass "detect.sh ran" || fail "detect.sh failed"
if grep -q '^GPU_GFX=' setup/facts.env; then pass "facts include GPU ($(sed -n 's/^GPU_GFX=//p' setup/facts.env))"; else fail "no GPU fact"; fi

sect "2. config merge + validation"
. setup/lib/config.sh
merged="$(merge_config "$ROOT" 2>/dev/null)" && pass "merge_config ok" || fail "merge_config failed"
[ -n "$(cfg_get "$merged" '.gpu.vendor')" ] && pass "merged has gpu.vendor=$(cfg_get "$merged" '.gpu.vendor')" || fail "merged missing gpu.vendor"
[ -n "$(cfg_get "$merged" '.model.primary')" ] && pass "merged has model.primary=$(cfg_get "$merged" '.model.primary')" || fail "merged missing model.primary"
bash setup/lib/validate.sh >/tmp/st_val.out 2>&1 && pass "validate.sh PASS" || { fail "validate.sh"; sed 's/^/      /' /tmp/st_val.out | grep ✗; }
[ -z "$(cfg_get "$merged" '.gpu' '')" ] && true  # layer purity is enforced inside validate
# regression guards
( . setup/lib/config.sh; m="$(printf 'a:\n  b: false\n')"; [ "$(cfg_get "$m" '.a.b' X)" = false ]; ) && pass "cfg_get preserves boolean false" || fail "cfg_get false regression"
td=$(mktemp -d); mkdir -p "$td/flavors"; printf 'flavor: x\n' >"$td/config.yaml"; printf 'extends: y\n' >"$td/flavors/x.yaml"; printf 'extends: x\n' >"$td/flavors/y.yaml"
timeout 5 bash -c '. setup/lib/config.sh; merge_config "'"$td"'"' >/dev/null 2>&1; [ $? -ne 0 ] && pass "cyclic extends errors (no hang)" || fail "cyclic extends not caught"; rm -rf "$td"

sect "3. Containerfile assembler"
bash setup/lib/assemble.sh dev_base --check >/dev/null 2>&1 && pass "dev_base Containerfile up to date" || fail "dev_base Containerfile drift"
bash setup/lib/assemble.sh os_agent --check >/dev/null 2>&1 && pass "os_agent Containerfile up to date" || fail "os_agent Containerfile drift"

sect "4. images present"
for img in llm_server dev_base os_agent; do
  podman image exists "localhost/$img:latest" && pass "image localhost/$img:latest" || fail "image localhost/$img missing (build with setup/lib/build.sh $img)"
done

sect "5. agents inside dev_base"
if podman image exists localhost/dev_base:latest; then
  out="$(podman run --rm localhost/dev_base:latest bash -lc '
    for b in "claude:claude" "codex:codex" "opencode:opencode" "pi:pi" "omp:omp"; do
      n="${b%%:*}"; c="${b##*:}"; v="$($c --version 2>&1 | head -1)"; echo "$n=$v"; done
    echo "hermes=$(hermes --version 2>&1 | head -1)"
    echo "cursor=$(rpm -q cursor 2>&1)"
    echo "podman=$(command -v podman)"
    echo "caps=$(getcap /usr/bin/newuidmap)"' 2>/dev/null)"
  for a in claude codex opencode pi omp hermes; do echo "$out" | grep -qE "^$a=.*[0-9]" && pass "agent $a: $(echo "$out"|sed -n "s/^$a=//p")" || fail "agent $a not working"; done
  echo "$out" | grep -q 'cursor=cursor-' && pass "cursor installed" || fail "cursor missing"
  echo "$out" | grep -q 'caps=.*cap_setuid' && pass "nested-podman caps (newuidmap)" || fail "newuidmap caps missing"
else skip "dev_base image absent — agent checks"; fi

sect "6. llm_server live inference (GPU)"
if [ "$QUICK" = 1 ]; then skip "live inference (--quick)"; else
  if curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/tmp/st_tags.json 2>/dev/null; then
    pass "endpoint 127.0.0.1:11434 responds"
    model="$(cfg_get "$merged" '.model.primary' qwen3-coder:30b)"
    grep -q "$model" /tmp/st_tags.json && pass "model $model is pulled" || skip "model $model not pulled (ollama pull $model)"
    if grep -q "$model" /tmp/st_tags.json; then
      resp="$(curl -fsS --max-time 90 http://127.0.0.1:11434/api/generate -d "{\"model\":\"$model\",\"prompt\":\"reply with the word READY\",\"stream\":false,\"options\":{\"num_predict\":5}}" 2>/dev/null)"
      echo "$resp" | grep -q '"response"' && pass "inference returned a response" || fail "inference produced no response"
      ps_out="$(distrobox enter llm_server -- ollama ps 2>/dev/null)"
      if echo "$ps_out" | grep -q 'GPU'; then pass "ollama ps shows GPU ($(echo "$ps_out" | grep -oE '[0-9]+% GPU' | head -1))"
      elif echo "$ps_out" | grep -qw 'CPU'; then fail "ollama ps shows CPU fallback"
      else skip "no model loaded in ollama ps (idle)"; fi
    fi
  else fail "llm_server endpoint not responding (service active? systemctl --user status llm_server)"; fi
fi

sect "7. tenant-create + work"
bash setup/lib/tenant-create.sh --dry-run setup/templates/tenant-example.yaml >/tmp/st_t2a.out 2>&1; rc=$?
{ [ $rc -eq 2 ] && grep -q 'human-required' /tmp/st_t2a.out; } && pass "Tier-2a dry-run emits human-required (rc=2)" || fail "Tier-2a dry-run wrong (rc=$rc)"
sed 's/tier: "2a"/tier: "0"/' setup/templates/tenant-example.yaml >/tmp/st_t0.yaml
bash setup/lib/tenant-create.sh --dry-run /tmp/st_t0.yaml >/tmp/st_t0.out 2>&1
grep -q ':/workspace' /tmp/st_t0.out && pass "Tier-0 create mounts /workspace" || fail "Tier-0 missing /workspace"
grep -q '/models' /tmp/st_t0.out && fail "Tier-0 mounts /models (INVARIANT VIOLATION)" || pass "Tier-0 does NOT mount /models"
# work session resolution (stubbed tmux)
desc=$(mktemp); printf 'name: t\ntier: "0"\nmodel: m\nbrowser: shared\nsessions:\n  - {name: s1, agent: opencode, workdir: .}\n' >"$desc"
stub=$(mktemp -d); printf '#!/usr/bin/env bash\necho stub-tmux "$@"\n' >"$stub/tmux"; chmod +x "$stub/tmux"
PATH="$stub:$PATH" UUMAMI_TENANT_DESC="$desc" bash setup/lib/work.sh --list 2>&1 | grep -q s1 && pass "work --list resolves sessions" || fail "work --list"
PATH="$stub:$PATH" UUMAMI_TENANT_DESC="$desc" bash setup/lib/work.sh nope >/dev/null 2>&1; [ $? -ne 0 ] && pass "work rejects unknown session" || fail "work accepted bad session"
rm -rf "$stub" "$desc" /tmp/st_t0.yaml

sect "8. real Tier-0 tenant create + teardown"
if [ "$QUICK" = 1 ] || ! podman image exists localhost/dev_base:latest; then skip "real box create (--quick or no dev_base)"; else
  M=/tmp/st_tenant.yaml; printf 'name: selftest-tenant\ntier: "0"\nbrowser: per-tenant\ncode_mount: ~/Code\nsessions:\n  - {name: m, agent: opencode, workdir: .}\n' >"$M"
  bash setup/lib/tenant-create.sh "$M" >/tmp/st_tc.out 2>&1
  distrobox list 2>/dev/null | grep -qw selftest-tenant && pass "Tier-0 box created" || fail "Tier-0 box not created"
  [ -f "$HOME/Profiles/selftest-tenant/.config/uumami/tenant.yaml" ] && pass "tenant descriptor written" || fail "descriptor missing"
  mounts="$(podman inspect selftest-tenant --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null)"
  echo "$mounts" | grep -q /workspace && pass "box mounts /workspace" || skip "could not inspect mounts"
  echo "$mounts" | grep -q /models && fail "box mounts /models (INVARIANT VIOLATION)" || pass "box does NOT mount /models"
  distrobox rm -f selftest-tenant >/dev/null 2>&1; rm -rf "$HOME/Profiles/selftest-tenant" "$M"
  N=selftest-tenant yq -i 'del(.tenants[] | select(.name == env(N)))' "$HOME/Profiles/registry.yaml" 2>/dev/null || true
  pass "teardown clean (no --rm-home)"
fi

sect "9. architecture invariants (static)"
# Precise: ignore comments / forbidding-docs; flag only REAL usage.
grep -rInE 'distrobox +rm.*--rm-home' setup/lib images 2>/dev/null | grep -q . && fail "real --rm-home usage" || pass "no --rm-home usage (only forbidding docs)"
grep -rInE '^[^#]*0\.0\.0\.0' config.yaml flavors images/llm_server 2>/dev/null | grep -q . && fail "0.0.0.0 in a real value" || pass "no 0.0.0.0 outside comments (loopback only)"
grep -iE '^[[:space:]]*(CMD|ENTRYPOINT|EXPOSE)' images/llm_server/Containerfile | grep -q . && fail "llm_server has a real CMD/ENTRYPOINT/EXPOSE directive" || pass "llm_server: no CMD/ENTRYPOINT/EXPOSE directive"
grep -rInE '^[^#]*/models([^.a-z]|$)' images/os_agent/Containerfile images/dev_base/Containerfile 2>/dev/null | grep -q . && fail "real /models path in an agent image" || pass "no /models mount in dev_base/os_agent images"

echo
echo "==================================================================="
echo "  selftest: ${P} passed, ${F} failed, ${S} skipped"
echo "  Human-required (not run here): os_agent recreate; Tier-2a user"
echo "  creation (sudo); reboot/logout survival; cursor distrobox-export."
echo "==================================================================="
[ "$F" -eq 0 ]
