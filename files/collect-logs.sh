#!/bin/bash
# collect-logs.sh — one-shot diagnostics for "can't launch Claude sessions".
# -----------------------------------------------------------------------------
# Run it directly (no install needed):
#   bash <(curl -fsSL https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/files/collect-logs.sh)
#
# It gathers everything relevant to a failing launch — the claude version, WHICH
# launch flags this claude actually supports, account/config state, and a LIVE
# test-launch that keeps the tmux pane alive on crash so we capture the real
# error claude prints. Writes a report to ~/.claude-launcher/diagnostics-<ts>.txt
# and prints it so you can copy/send it back.
# -----------------------------------------------------------------------------
set -u

LDIR="$HOME/.claude-launcher"
mkdir -p "$LDIR" 2>/dev/null || true
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
OUT="$LDIR/diagnostics-$TS.txt"

# Bare-PATH-safe tool resolution (curl|bash inherits a minimal PATH), mirroring
# launch-claude-session.sh so we test the SAME binaries the launcher uses.
EXTRA_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(PATH="$EXTRA_PATH" command -v claude 2>/dev/null || true)"
TMUX_BIN="/opt/homebrew/bin/tmux"
[ -x "$TMUX_BIN" ] || TMUX_BIN="/usr/local/bin/tmux"
[ -x "$TMUX_BIN" ] || TMUX_BIN="$(PATH="$EXTRA_PATH" command -v tmux 2>/dev/null || true)"

# has_flag FLAG — is FLAG listed in `claude --help`?
has_flag() {
  [ -n "$CLAUDE_BIN" ] || { echo "?"; return; }
  if "$CLAUDE_BIN" --help 2>&1 | grep -q -- "$1"; then echo "yes"; else echo "MISSING"; fi
}

report() {
  echo "===== Session Launcher diagnostics — $TS ====="
  echo "(collected by collect-logs.sh — safe to share; no passwords/tokens are included)"
  echo

  echo "## 1. System"
  uname -a 2>&1
  sw_vers 2>/dev/null
  echo "shell: ${SHELL:-?}   user: $(id -un 2>/dev/null)"
  echo

  echo "## 2. Tools the launcher uses"
  echo "claude: ${CLAUDE_BIN:-NOT FOUND}"
  if [ -n "$CLAUDE_BIN" ]; then echo -n "  version: "; "$CLAUDE_BIN" --version 2>&1 | head -1; fi
  echo "tmux:   ${TMUX_BIN:-NOT FOUND}"
  if [ -n "$TMUX_BIN" ]; then echo -n "  version: "; "$TMUX_BIN" -V 2>&1; fi
  echo "node:   $(PATH="$EXTRA_PATH" command -v node 2>/dev/null || echo 'not found')"
  echo

  echo "## 3. Does THIS claude support the launch flags? (a MISSING one = every launch fails)"
  echo "  --remote-control : $(has_flag '--remote-control')"
  echo "  --effort         : $(has_flag '--effort')"
  echo "  --name           : $(has_flag '--name')"
  echo "  --permission-mode: $(has_flag '--permission-mode')"
  echo "  (full flag list:)"
  [ -n "$CLAUDE_BIN" ] && "$CLAUDE_BIN" --help 2>&1 | grep -oE -- '--[a-z][a-z-]+' | sort -u | sed 's/^/    /' | head -60
  echo

  echo "## 4. Accounts / config"
  for d in "$HOME"/.claude "$HOME"/.claude-*; do
    [ -d "$d" ] || continue; b="$(basename "$d")"
    case "$b" in .claude-launcher|.claude-swap-backup*) continue ;; esac
    creds="NONE"
    if [ -f "$d/.credentials.json" ]; then creds="file"
    elif [ "$(uname -s)" = "Darwin" ] && [ "$d" = "$HOME/.claude" ] && security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then creds="keychain"; fi
    model="$(python3 -c "import json;print(json.load(open('$d/settings.json')).get('model','?'))" 2>/dev/null || echo '?')"
    effort="$(python3 -c "import json;print(json.load(open('$d/settings.json')).get('effortLevel','?'))" 2>/dev/null || echo '?')"
    echo "  - $b: signed-in=$creds  model=$model  effort=$effort"
  done
  echo

  echo "## 5. tmux sessions right now"
  [ -n "$TMUX_BIN" ] && "$TMUX_BIN" ls 2>&1 || echo "(no tmux)"
  echo

  echo "## 6. LIVE TEST LAUNCH — reproduces a real launch and captures what claude prints"
  if [ -n "$CLAUDE_BIN" ] && [ -n "$TMUX_BIN" ]; then
    T="diaglaunch-$TS"
    # Create the session first, turn remain-on-exit ON *before* running claude, so
    # if claude crashes the dead pane (and its error) is preserved for capture.
    "$TMUX_BIN" new-session -d -x 200 -y 50 -s "$T" -c "$HOME" 2>&1
    "$TMUX_BIN" set-option -t "$T" remain-on-exit on 2>/dev/null
    CMD="export PATH='$EXTRA_PATH':\$PATH; '$CLAUDE_BIN' --permission-mode auto --effort ultracode --name diagtest --remote-control diagtest"
    echo "  launch cmd: $CMD"
    "$TMUX_BIN" send-keys -t "$T" "$CMD" Enter 2>/dev/null
    sleep 5
    alive="$("$TMUX_BIN" has-session -t "$T" 2>/dev/null && echo yes || echo no)"
    dead="$("$TMUX_BIN" list-panes -t "$T" -F '#{pane_dead} exit=#{pane_dead_status}' 2>/dev/null | head -1)"
    echo "  session still exists after 5s: $alive"
    echo "  pane dead/exit-status: ${dead:-n/a}   (pane_dead=1 means claude exited/crashed)"
    echo "  --- exactly what the pane shows (claude's output or its error) ---"
    "$TMUX_BIN" capture-pane -p -J -t "$T" 2>&1 | sed 's/^/  | /'
    echo "  ----------------------------------------------------------------"
    "$TMUX_BIN" kill-session -t "$T" 2>/dev/null || true
  else
    echo "  SKIPPED — claude or tmux not found (see section 2)."
  fi
  echo

  echo "## 7. Portal services"
  TSIP="$(PATH="$EXTRA_PATH" tailscale ip -4 2>/dev/null | head -1)"
  echo "  tailscale ip: ${TSIP:-none}"
  for pt in 7681 8090; do
    if curl -s -o /dev/null -m 3 "http://${TSIP:-127.0.0.1}:$pt" 2>/dev/null; then echo "  port $pt: UP"; else echo "  port $pt: DOWN"; fi
  done
  if [ "$(uname -s)" = "Darwin" ]; then
    for l in com.sessionlauncher.terminal com.sessionlauncher.dashboard; do
      echo "  launchd $l: $(launchctl print "gui/$(id -u)/$l" 2>/dev/null | grep -E 'state =' | head -1 | tr -s ' ' || echo 'not loaded')"
    done
  fi
  echo

  echo "## 8. Portal logs (last 30 lines each)"
  for f in portal.log dashboard.log terminal.log; do
    echo "  --- $LDIR/$f ---"
    tail -30 "$LDIR/$f" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  done
  echo
  echo "===== end ====="
}

report > "$OUT" 2>&1

echo ""
echo "✅ Diagnostics saved to:"
echo "   $OUT"
echo ""
echo "Send that file (or copy everything below) to whoever is helping you:"
echo "──────────────────────────────────────────────────────────────────────"
cat "$OUT"
