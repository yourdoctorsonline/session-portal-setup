#!/bin/bash
# fd-watchdog.sh — keep ttyd from walking into its file-descriptor ceiling.
#
# ttyd 1.7.7 leaks the /dev/ptmx master descriptor for most terminals it serves,
# and 1.7.7 is the newest release, so there is nothing to upgrade to. Left alone
# the count climbs until it hits the process limit; from that moment on every
# pty_spawn fails with EMFILE, the websocket closes cleanly, and the launcher
# shows ttyd's "Press ⏎ to Reconnect" overlay instead of a terminal — forever,
# because tapping reconnect just burns another descriptor. (launchd's default
# soft limit is 256, so an untended portal typically breaks about a day in.)
#
# Recycling ttyd is cheap and safe: tmux sessions belong to the tmux server, not
# to ttyd, so they survive untouched and the browser simply reconnects.
#
# Runs every 5 minutes:
#   macOS       — com.sessionlauncher.watchdog LaunchAgent (StartInterval 300)
#   Linux/WSL2  — session-watchdog.timer (OnUnitActiveSec=5min)
#
# The ttyd service is a launchd agent on macOS and a systemd --user unit on
# Linux, so PID lookup, the log source, and "recycle" differ per platform; the
# orphan reaping and the fd/EMFILE thresholds are shared. Stays username-generic:
# $HOME is resolved at runtime, nothing is baked in. The PATH export mirrors the
# other portal scripts so tmux/lsof resolve no matter how we were launched — this
# matters: if `tmux` fell off PATH, list-clients would come back empty.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -u

LAUNCHER_DIR="$HOME/.claude-launcher"
HIGH=2000                                    # recycle well before the 4096 limit
LOG="$LAUNCHER_DIR/watchdog.log"
STATE="$LAUNCHER_DIR/.watchdog-emfile-count"

# macOS launchd label / Linux systemd --user unit for the ttyd terminal service.
MAC_LABEL="com.sessionlauncher.terminal"
SD_UNIT="session-terminal"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

case "$(uname -s)" in
  Darwin) PLATFORM="mac" ;;
  *)      PLATFORM="linux" ;;
esac

# --- platform shims ----------------------------------------------------------
# ttyd_pid          — echo the live ttyd PID, or nothing when the service is down.
# ttyd_recycle      — restart the ttyd service (tmux sessions survive; see above).
# ttyd_fd_count PID — echo how many descriptors ttyd currently holds.
# ttyd_emfile_count — echo how many "Too many open files" ttyd has logged so far.
if [ "$PLATFORM" = "mac" ]; then
  ttyd_pid()     { launchctl list 2>/dev/null | awk -v l="$MAC_LABEL" '$3==l {print $1}'; }
  ttyd_recycle() { launchctl kickstart -k "gui/$(id -u)/$MAC_LABEL"; }
  ttyd_fd_count() { lsof -p "$1" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }
  # The LaunchAgent redirects ttyd's stderr to terminal.log.
  TTYD_LOG="$LAUNCHER_DIR/terminal.log"
  ttyd_emfile_count() {
    [ -f "$TTYD_LOG" ] && grep -c "Too many open files" "$TTYD_LOG" 2>/dev/null || echo 0
  }
else
  ttyd_pid() {
    local p
    p="$(systemctl --user show "$SD_UNIT" -p MainPID --value 2>/dev/null)"
    [ -n "$p" ] && [ "$p" != "0" ] && echo "$p"
  }
  ttyd_recycle() { systemctl --user restart "$SD_UNIT"; }
  # /proc is cheaper than lsof and always present on Linux/WSL2.
  ttyd_fd_count() { ls "/proc/$1/fd" 2>/dev/null | wc -l | tr -d ' '; }
  # systemd captures ttyd's stderr into the journal.
  ttyd_emfile_count() {
    journalctl --user -u "$SD_UNIT" -q -o cat 2>/dev/null | grep -c "Too many open files"
  }
fi

recycle() { log "recycling ttyd — $1"; ttyd_recycle; exit 0; }

PID="$(ttyd_pid)"
[ -n "${PID:-}" ] && [ "$PID" != "-" ] || exit 0

# 1) Reap ttyd's orphaned `tmux attach` children — terminals whose websocket is
#    long gone but whose client process never exited, each pinning a PTY. The
#    signature is unambiguous: parented by ttyd, older than 10 minutes, yet tmux
#    itself does not list them as a connected client. A genuinely live terminal
#    is always a registered client, so this cannot hit one.
CLIENTS=" $(tmux list-clients -F '#{client_pid}' 2>/dev/null | tr '\n' ' ') "
# NB: BSD/macOS `ps` has no `etimes` (seconds) keyword — only `etime`, formatted
# as [[DD-]HH:]MM:SS. Convert it to seconds inside awk so the >600s age guard is
# a real number, not a lexical compare against "10:23". `=` suffixes suppress
# the header row. (GNU/Linux `ps` accepts the same fields and etime format.)
for c in $(ps -eo pid=,ppid=,etime=,command= 2>/dev/null \
           | awk -v t="$PID" '
               $2==t && /tmux attach/ {
                 n=split($3,a,/[-:]/); s=0
                 if(n==2) s=a[1]*60+a[2]
                 else if(n==3) s=a[1]*3600+a[2]*60+a[3]
                 else if(n==4) s=a[1]*86400+a[2]*3600+a[3]*60+a[4]
                 if(s>600) print $1
               }'); do
  case "$CLIENTS" in *" $c "*) continue ;; esac
  kill -9 "$c" 2>/dev/null && log "reaped orphaned tmux client $c (ttyd child, no tmux client entry)"
done

# 2) Reactive: if ttyd is reporting EMFILE it is broken right now and the
#    descriptor count no longer matters — recycle immediately. Covers the case
#    where the raised limit somehow failed to apply.
#
#    Trigger on the EMFILE count *rising*, not on its mere presence. Old errors
#    stay in the log after a recycle, so a presence check would re-fire on every
#    pass and put ttyd in a 5-minute restart loop. Comparing against the last
#    seen count is idempotent, and needs no log truncation (which would race
#    with the service manager's own writer).
COUNT="$(ttyd_emfile_count)"
PREV="$(cat "$STATE" 2>/dev/null || echo 0)"
case "$COUNT$PREV" in *[!0-9]*) COUNT=0; PREV=0 ;; esac
echo "$COUNT" > "$STATE"
[ "$COUNT" -gt "$PREV" ] && recycle "ttyd reported new EMFILE errors ($PREV -> $COUNT)"

# 3) Preventive: recycle while there is still plenty of headroom.
FDS="$(ttyd_fd_count "$PID")"
[ -n "${FDS:-}" ] && [ "$FDS" -ge "$HIGH" ] 2>/dev/null \
  && recycle "fd count $FDS >= $HIGH"

exit 0
