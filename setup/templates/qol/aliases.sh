# uumami_os shared aliases — deployed per profile by setup/lib/deploy-aliases.sh.
# FORMAT: every alias carries `# @<category>: <description>` — `uu aliases` renders the
# catalog from these annotations; this file is the single source of truth.
# Suffix convention: c=continue r=resume-picker y=yolo h=headless p=plan. Args pass through.
# Aliases are interactive-only: scripts/programs are never affected. Known deliberate
# shadow: `pic` (groff's preprocessor — only ever invoked internally by groff, never typed).
# `oc` would collide with the OpenShift CLI, which dev_base does not ship (rename to ocd
# if you ever install it).

# --- agents: Claude Code ---
alias cl='claude'                                          # @agents: launch Claude Code
alias clc='claude -c'                                      # @agents: continue last Claude session
alias clr='claude -r'                                      # @agents: resume a Claude session (picker)
alias cly='claude --dangerously-skip-permissions'          # @agents: Claude, skip permission prompts (trusted dirs only)
alias clcy='claude -c --dangerously-skip-permissions'      # @agents: continue last session + skip permissions
alias clp='claude --permission-mode plan'                  # @agents: Claude in plan mode (design before edits)
alias cle='claude --permission-mode acceptEdits'           # @agents: Claude auto-accepts edits, still gates bash
alias clh='claude -p'                                      # @agents: Claude headless one-shot (pipes)
alias clm='claude --model'                                 # @agents: pick model: clm opus "prompt"

# --- agents: Codex (note: codex -c is config-override, NOT continue) ---
alias co='codex'                                           # @agents: launch Codex
alias coc='codex resume --last'                            # @agents: continue most recent Codex session
alias cor='codex resume'                                   # @agents: resume a Codex session (picker)
alias coo='codex --oss'                                    # @agents: Codex on the LOCAL model (Ollama)
alias coh='codex exec'                                     # @agents: Codex headless one-shot
alias coa='codex apply'                                    # @agents: apply Codex's latest diff to the worktree
alias cov='codex review'                                   # @agents: Codex non-interactive code review
# codex: no full-auto flag in this pin — coy omitted
# (probed: only --dangerously-bypass-approvals-and-sandbox and --dangerously-bypass-hook-trust found)

# --- agents: OpenCode ---
alias oc='opencode'                                        # @agents: launch OpenCode
alias occ='opencode -c'                                    # @agents: continue last OpenCode session
alias och='opencode run'                                   # @agents: OpenCode headless: och "message"
alias ocm='opencode models'                                # @agents: list OpenCode models
alias ocw='opencode web'                                   # @agents: OpenCode web UI
alias ocpr='opencode pr'                                   # @agents: checkout GitHub PR + launch: ocpr 42

# --- agents: Pi (pic shadows groff's pic — harmless, see header) ---
alias pic='pi -c'                                          # @agents: continue last Pi session
alias pir='pi -r'                                          # @agents: resume a Pi session (picker)
alias pih='pi -p'                                          # @agents: Pi headless one-shot

# --- agents: OMP ---
alias omc='omp -c'                                         # @agents: continue last OMP session
alias omr='omp -r'                                         # @agents: resume an OMP session (picker)
alias omh='omp -p'                                         # @agents: OMP headless one-shot

# --- agents: Hermes ---
alias he='hermes'                                          # @agents: launch Hermes (general assistant)
alias hec='hermes --continue'                              # @agents: continue last Hermes session
alias hey='hermes --yolo'                                  # @agents: Hermes yolo mode
alias hez='hermes -z'                                      # @agents: Hermes one-shot: hez "question"
alias hest='hermes status'                                 # @agents: Hermes component status

# --- agents: Cursor (GUI; --no-sandbox required in a container) ---
cur() { cursor --no-sandbox "${@:-.}"; }                   # @agents: open Cursor here (or: cur path)
curd() { cursor --no-sandbox --diff "$@"; }                # @agents: Cursor diff view: curd a b
curg() { cursor --no-sandbox --goto "$@"; }                # @agents: jump: curg file:line

# --- git ---
alias gs='git status -sb'                                  # @git: short status
alias gl='git log --oneline -15'                           # @git: recent commits
alias glog='git log --graph --oneline --decorate -20'      # @git: commit graph
alias gd='git diff'                                        # @git: unstaged diff
alias gdc='git diff --cached'                              # @git: staged diff
alias ga='git add'                                         # @git: stage
alias gc='git commit'                                      # @git: commit (opens editor)
alias gcm='git commit -m'                                  # @git: commit: gcm "message"
alias gca='git commit --amend'                             # @git: amend last commit
alias gco='git checkout'                                   # @git: checkout
alias gcb='git checkout -b'                                # @git: new branch: gcb feature-x
alias gb='git branch -vv'                                  # @git: branches + tracking
alias gp='git push'                                        # @git: push
alias gpl='git pull'                                       # @git: pull
alias gf='git fetch --all --prune'                         # @git: fetch everything
alias gst='git stash'                                      # @git: stash changes
alias gstp='git stash pop'                                 # @git: unstash

# --- gh (GitHub CLI) ---
alias ghpr='gh pr create'                                  # @gh: open a pull request
alias ghprs='gh pr status'                                 # @gh: my PRs at a glance
alias ghw='gh pr view --web'                               # @gh: open current PR in browser
alias ghi='gh issue list'                                  # @gh: issues

# --- tmux ---
alias ta='tmux new-session -A -s main'                     # @tmux: attach/create the main session
alias tls='tmux list-sessions'                             # @tmux: list sessions
alias tn='tmux new-session -A -s'                          # @tmux: named session: tn acme
alias tk='tmux kill-session -t'                            # @tmux: kill session: tk acme

# --- containers / system ---
alias host='distrobox-host-exec'                           # @containers: run one command on the host
alias docker='podman'                                      # @containers: docker muscle-memory -> podman
alias dbl='distrobox list'                                 # @containers: list boxes

# --- llm ---
alias llm-models='curl -fsS http://127.0.0.1:11434/api/tags | jq -r ".models[].name"'  # @llm: models on the shared server
# llm-ps / llm-pull are FUNCTIONS, not aliases, so they can check the box exists first:
# `distrobox enter <missing-box>` offers to create a generic fedora-toolbox box instead of
# failing — never let that prompt appear.
# Keep each definition on ONE line: `uu aliases` reads the `# @cat:` annotation from the same
# line as the name, so a wrapped definition renders as garbage in the catalog.
_llm_box() { distrobox-host-exec podman container exists llm_server 2>/dev/null || { echo "llm_server box does not exist yet — run: uu setup" >&2; return 3; }; }
llm-ps() { _llm_box && distrobox-host-exec distrobox enter llm_server -- ollama ps; }          # @llm: what is loaded + GPU check
llm-pull() { _llm_box && distrobox-host-exec distrobox enter llm_server -- ollama pull "$@"; } # @llm: pull a model

# --- portability shims (no annotation on purpose: internal) ---
command -v fd >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'; }
# github-auth: load this profile's key into the host ssh-agent (manual fallback)
alias github-auth='distrobox-host-exec ssh-add "$HOME/.ssh/id_ed25519_github"'  # @containers: load GitHub SSH key into host agent
