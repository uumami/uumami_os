# uumami_os shared aliases — deployed per profile by setup/lib/deploy-aliases.sh (SG11).
# Sourced from ~/.bashrc.d/shared_aliases.sh inside every opted-in box. $HOME resolves to
# the profile of whichever box is running, so nothing here hardcodes a user or a box.

# --- host access (the one sanctioned door; keep it visible and deliberate) ---
alias host='distrobox-host-exec'

# --- git shortcuts ---
alias gs='git status -sb'
alias gl='git log --oneline -15'
alias gd='git diff'
alias ga='git add'
alias gc='git commit'
alias gp='git push'

# --- tmux ---
alias ta='tmux new-session -A -s main'    # quick-attach the default session

# --- llm_server helpers (loopback endpoint; works from any box) ---
alias llm-models='curl -fsS http://127.0.0.1:11434/api/tags | jq -r ".models[].name"'
alias llm-ps='distrobox-host-exec distrobox enter llm_server -- ollama ps'
alias llm-pull='distrobox-host-exec distrobox enter llm_server -- ollama pull'

# --- GitHub SSH: load this profile's key into the host ssh-agent (manual fallback;
#     with AddKeysToAgent yes in ~/.ssh/config it happens on first use) ---
alias github-auth='distrobox-host-exec ssh-add "$HOME/.ssh/id_ed25519_github"'

# --- portability shims ---
command -v fd >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'; }
