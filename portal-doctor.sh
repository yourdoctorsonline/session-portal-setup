#!/usr/bin/env bash
# ===== PORTAL DOCTOR v1 =====
# Why is the portal not up, and what fixes it?
#
# The installer's own checks say WHICH check failed. They never say why, so a
# red "dashboard service is live (port 8090)" sends you looking for logs you may
# no longer have. This reads the state, reads the logs itself, and names the
# cause.
#
# Read-only unless you pass --fix, and --fix only ever restarts services or
# reinstalls the launch agents. It never touches your Claude config, your repos,
# or anything under ~/.claude.
#
# Standalone: it needs nothing beside it, so it can be fetched and run on a
# machine that has a broken install.
#
# Exit 0 = healthy · 1 = a real problem (named) · 2 = could not check
set -u

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

LAUNCHER="$HOME/.claude-launcher"
BIN="$LAUNCHER/bin"
AGENTS="$HOME/Library/LaunchAgents"
DASH_LOG="$LAUNCHER/dashboard.log"
TERM_LOG="$LAUNCHER/terminal.log"
PROBLEMS=0

ok(){ printf '  [OK]   %s\n' "$1"; }
bad(){ PROBLEMS=$((PROBLEMS+1)); printf '  [BAD]  %s\n' "$1"; }
inf(){ printf '         %s\n' "$1"; }
head_(){ printf '\n-- %s --\n' "$1"; }

echo "===== PORTAL DOCTOR v1 ====="
echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ)   user: $(whoami)   host: $(uname -s)"

case "$(uname -s)" in
  Darwin) PLAT=mac ;;
  Linux)  PLAT=linux ;;
  *) echo "  This checks the macOS/WSL portal install only."; echo "===== END ====="; exit 2 ;;
esac

# --- 1. Python: the single most common cause -------------------------------
head_ "1. Python (the dashboard is a Python program)"
# The launch agent runs `/usr/bin/env python3` with a FIXED short PATH. On a Mac
# with no developer tools, /usr/bin/python3 exists but is a stub that errors the
# moment it runs — it looks installed to anything that only checks presence,
# then kills the dashboard at startup. Test EXECUTION, never presence.
AGENT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PY_REAL=0
if PY_V="$(PATH="$AGENT_PATH" /usr/bin/env python3 -c 'import sys;print(sys.version.split()[0])' 2>&1)"; then
  case "$PY_V" in
    3.*) PY_REAL=1; ok "python3 works where the service looks for it (${PY_V})" ;;
    *)   bad "python3 answered but not with a version: ${PY_V}" ;;
  esac
else
  bad "python3 does NOT run on the service's search path"
  inf "what happened: ${PY_V}"
  inf "This alone stops the dashboard from ever starting."
  if [ "$PLAT" = mac ]; then
    inf "Fix:  xcode-select --install     (then re-run the installer)"
  else
    inf "Fix:  sudo apt-get install -y python3"
  fi
fi

# --- 2. Are the program files even there? ----------------------------------
head_ "2. Portal files"
for f in portal-web.py portal.sh; do
  if [ -f "$BIN/$f" ]; then ok "$f present"; else bad "$f MISSING from $BIN"; fi
done
[ -d "$LAUNCHER" ] || inf "no $LAUNCHER at all — the portal was never installed here"

# --- 3. Ports first: the only ground truth ---------------------------------
# Whether the thing ANSWERS is the fact. launchctl state and log lines only
# explain a failure — they do not define one. Checking services first produced a
# doctor that called the terminal dead while it was serving requests on 7681.
head_ "3. Is the portal answering?"
port_open() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0; fi
  return 1
}
port_owner() {
  command -v lsof >/dev/null 2>&1 || { echo "unknown"; return; }
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}'
}
TERM_UP=0; DASH_UP=0
port_open 7681 && TERM_UP=1
port_open 8090 && DASH_UP=1
[ "$TERM_UP" = 1 ] && ok "terminal answering on 7681 — $(port_owner 7681)" || bad "terminal NOT answering on port 7681"
[ "$DASH_UP" = 1 ] && ok "dashboard answering on 8090 — $(port_owner 8090)" || bad "dashboard NOT answering on port 8090"

head_ "4. Background services"
svc_state() { # svc_state LABEL -> "loaded|absent" and last exit code if any
  [ "$PLAT" = mac ] || { echo "n/a"; return; }
  launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $1" "$2}'
}
for L in com.sessionlauncher.terminal com.sessionlauncher.dashboard; do
  PLIST="$AGENTS/$L.plist"
  if [ ! -f "$PLIST" ]; then bad "$L has no plist — never installed"; continue; fi
  ST="$(svc_state "$L")"
  if [ -z "$ST" ]; then
    bad "$L is installed but NOT loaded"
  else
    PID="$(printf '%s' "$ST" | awk '{print $1}')"
    RC="$(printf '%s' "$ST" | awk '{print $2}')"
    if [ "$PID" = "-" ]; then
      # Dead per launchctl, but if the port answers the job is doing its work
      # (ttyd is often started once and outlives the launchd wrapper). Only a
      # closed port makes this a fault.
      case "$L" in
        *terminal)  UP=$TERM_UP ;;
        *dashboard) UP=$DASH_UP ;;
        *)          UP=0 ;;
      esac
      if [ "$UP" = "1" ]; then
        ok "$L not tracked by launchctl, but its port is answering — working"
      else
        bad "$L is loaded but NOT running (last exit code ${RC:-?})"
        inf "Loaded-but-dead means it starts and immediately quits."
      fi
    else
      ok "$L running (pid $PID)"
    fi
  fi
done

# --- 5. What the logs say ---------------------------------------------------
head_ "5. What the service last said"
show_log() {
  local f="$1" name="$2" up="$3"
  if [ ! -f "$f" ]; then inf "$name: no log at $f"; return; fi
  if [ ! -s "$f" ]; then inf "$name: log is empty (it may never have started)"; return; fi
  inf "$name — last lines of $f:"
  tail -12 "$f" | sed 's/^/           /'

  # Only diagnose a service that is actually DOWN, and only from the RECENT tail.
  # Both bounds were learned the hard way on the first run: scanning the whole
  # file made a months-old "address already in use" read as today's cause, and
  # reporting it for a healthy service turned a routine client disconnect into a
  # fault. A log line is a symptom; the closed port is the illness.
  if [ "$up" = "1" ]; then
    inf "($name is answering, so anything above is history, not a fault)"
    return
  fi
  local recent; recent="$(tail -60 "$f")"
  case "$recent" in
    *"No module named"*|*"command not found"*)
      bad "$name: a program or module it needs is missing" ;;
  esac
  case "$recent" in
    *"Address already in use"*|*"address already in use"*)
      bad "$name: its port was already taken when it tried to start" ;;
  esac
  case "$recent" in
    *xcode*|*CommandLineTools*|*"command line developer tools"*)
      bad "$name: blocked by the missing macOS developer tools (the Python stub)" ;;
  esac
  case "$recent" in
    *"Permission denied"*|*"permission denied"*)
      bad "$name: blocked by permissions" ;;
  esac
}
show_log "$DASH_LOG" "dashboard" "$DASH_UP"
show_log "$TERM_LOG" "terminal" "$TERM_UP"

# --- 6. Tailscale -----------------------------------------------------------
head_ "6. Private network"
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  if [ -n "$TS_IP" ]; then ok "Tailscale connected ($TS_IP)"
  else bad "Tailscale installed but not connected — the phone link will not resolve"; fi
else
  inf "tailscale not installed (fine if you only use this Mac locally)"
fi

# --- 7. Fix what is safe to fix --------------------------------------------
if [ "$FIX" = "1" ] && [ "$PROBLEMS" -gt 0 ]; then
  head_ "7. Fixing what can be fixed"
  if [ "$PY_REAL" = "0" ]; then
    inf "Not restarting anything: without a working python3 the dashboard cannot"
    inf "start, and bouncing it would just fail again. Install Python first."
  elif [ "$PLAT" = mac ]; then
    for L in com.sessionlauncher.terminal com.sessionlauncher.dashboard; do
      PLIST="$AGENTS/$L.plist"
      [ -f "$PLIST" ] || continue
      launchctl unload "$PLIST" >/dev/null 2>&1
      launchctl load  "$PLIST" >/dev/null 2>&1 && inf "restarted $L" || inf "could not restart $L"
    done
    sleep 3
    port_open 8090 && ok "dashboard is answering now" || bad "dashboard still not answering — read section 5"
  fi
fi

# --- verdict ----------------------------------------------------------------
printf '\n'
if [ "$PROBLEMS" -eq 0 ]; then
  echo "VERDICT: HEALTHY — every part of the portal is up."
  echo "===== END ====="
  exit 0
fi
echo "VERDICT: $PROBLEMS problem(s) found — see the [BAD] lines above."
[ "$FIX" = "0" ] && echo "         Re-run with --fix to restart the services."
echo "===== END ====="
exit 1
