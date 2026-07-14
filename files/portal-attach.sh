#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
TMUX_BIN="$(command -v tmux)"
if [ -n "$1" ]; then exec "$TMUX_BIN" attach -t "$1"
else exec bash "$HOME/.claude-launcher/bin/portal-menu.sh"; fi
