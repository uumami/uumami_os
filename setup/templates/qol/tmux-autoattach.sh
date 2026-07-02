# uumami_os tmux auto-attach — deployed to ~/.bashrc.d/ by setup/lib/deploy-tmux.sh (SG11).
# Bare interactive entry into the box lands in the 'main' tmux session. `work <session>`
# overrides this naturally: it attaches its own named session, so $TMUX is set and this
# hook does nothing (no double-attach). Set UUMAMI_NO_AUTOATTACH=1 to opt out for a shell.
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if [ -z "${TMUX:-}" ] && [ -z "${UUMAMI_NO_AUTOATTACH:-}" ] && command -v tmux >/dev/null 2>&1; then
  tmux new-session -A -s main
fi
