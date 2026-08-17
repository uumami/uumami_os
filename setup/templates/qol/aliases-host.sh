# uumami_os HOST-safe aliases — deployed by `deploy-aliases.sh --host-safe`.
# ONLY aliases whose commands exist on the host and make sense there. Deliberately EXCLUDES:
#   - agent aliases (cl/co/oc/pi/omp/he/cur…): the agents live INSIDE boxes, not on the host.
#   - the `host` alias and llm-ps/llm-pull's box form: those wrap `distrobox-host-exec`, which
#     only exists inside a distrobox — on the host we call distrobox/podman directly.
# The full catalog (incl. agents) is deployed per box profile by `deploy-aliases.sh <home>`.

# --- containers / system (podman + distrobox are on the host) ---
alias docker='podman'                                      # @containers: docker muscle-memory -> podman
alias dbl='distrobox list'                                 # @containers: list boxes
alias dbe='distrobox enter'                                # @containers: enter a box: dbe os_agent

# --- llm (host-native: no distrobox-host-exec wrapper) ---
alias llm-models='curl -fsS http://127.0.0.1:11434/api/tags | jq -r ".models[].name"'  # @llm: models on the shared server
# Functions, not aliases: they check the box exists first, because `distrobox enter` on a
# missing box offers to create a generic fedora-toolbox box instead of failing.
# Keep each definition on ONE line — `uu aliases` reads the annotation from the name's line.
_llm_box() { podman container exists llm_server 2>/dev/null || { echo "llm_server box does not exist yet — run: uu setup" >&2; return 3; }; }
llm-ps() { _llm_box && distrobox enter llm_server -- ollama ps; }          # @llm: what is loaded + GPU check
llm-pull() { _llm_box && distrobox enter llm_server -- ollama pull "$@"; } # @llm: pull a model

# --- git (works if git is installed on the host) ---
alias gs='git status -sb'                                  # @git: short status
alias gl='git log --oneline -15'                           # @git: recent commits
alias gd='git diff'                                        # @git: unstaged diff
alias ga='git add'                                         # @git: stage
alias gc='git commit'                                      # @git: commit (opens editor)
alias gcm='git commit -m'                                  # @git: commit: gcm "message"
alias gco='git checkout'                                   # @git: checkout
alias gcb='git checkout -b'                                # @git: new branch: gcb feature-x
alias gp='git push'                                        # @git: push
alias gpl='git pull'                                       # @git: pull

# (uu itself is on the host too — symlinked by `deploy-uu.sh --host`.)
