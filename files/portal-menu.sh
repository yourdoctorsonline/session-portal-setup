#!/bin/bash
# Session Portal menu — the landing screen ttyd shows. Lists live tmux
# sessions, attach by number, create a new Claude session, or kill one.
# Phone-friendly: typed numbers/letters only, no Ctrl key. To leave a session,
# reload the browser tab — tmux keeps it running and you land back here.
# bash 3.2 safe (macOS default): no mapfile.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
TMUX_BIN="$(command -v tmux)"
LAUNCH="$HOME/.claude-launcher/bin/launch-claude-session.sh"
"$TMUX_BIN" set -g mouse on 2>/dev/null

c_reset=$'\033[0m'; c_dim=$'\033[2m'; c_grn=$'\033[1;32m'; c_cyn=$'\033[1;36m'
c_yel=$'\033[1;33m'; c_bold=$'\033[1m'

SESS=()
load_sessions() {
  SESS=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && SESS+=("$line")
  done < <("$TMUX_BIN" list-sessions -F '#{session_name}	#{?session_attached,attached,idle}	#{session_windows}' 2>/dev/null)
}

draw() {
  clear
  printf '%s╭───────────────────────────────╮%s\n' "$c_grn" "$c_reset"
  printf '%s│      S E S S I O N   H U B     │%s\n' "$c_grn" "$c_reset"
  printf '%s╰───────────────────────────────╯%s\n\n' "$c_grn" "$c_reset"
  load_sessions
  if [ "${#SESS[@]}" -eq 0 ]; then
    printf '  %sNo active sessions yet — press n to create one.%s\n\n' "$c_dim" "$c_reset"
  else
    printf '  %sActive sessions:%s\n' "$c_bold" "$c_reset"
    local i=1 row name att wins mark
    for row in "${SESS[@]}"; do
      name="$(printf '%s' "$row" | cut -f1)"
      att="$(printf '%s' "$row" | cut -f2)"
      wins="$(printf '%s' "$row" | cut -f3)"
      mark="  "; case "$name" in claude*|*claude*) mark="* ";; esac
      printf '   %s%2d%s  %s%-30s %s%s, %sw%s\n' \
        "$c_cyn" "$i" "$c_reset" "$mark" "$name" "$c_dim" "$att" "$wins" "$c_reset"
      i=$((i+1))
    done
    printf '\n'
  fi
  printf '  %s[number]%s  open that session\n' "$c_yel" "$c_reset"
  printf '  %sn%s         new Claude session\n' "$c_yel" "$c_reset"
  printf '  %sk%s         kill a session\n' "$c_yel" "$c_reset"
  printf '  %sr%s         refresh\n\n' "$c_yel" "$c_reset"
  printf '  %sTo leave a session, reload this page.%s\n\n' "$c_dim" "$c_reset"
}

new_claude() {
  printf '\n  %sNew Claude session%s\n' "$c_bold" "$c_reset"
  printf '  Name: '; read -r name
  [ -n "$name" ] || name="claude-$(date +%H%M%S)"
  printf '  Account [default / personal / ydo] (Enter=default): '; read -r acct
  [ -n "$acct" ] || acct="default"
  printf '  Permissions [bypass / auto] (Enter=bypass): '; read -r perm
  [ -n "$perm" ] || perm="bypass"
  printf '  %sLaunching…%s\n' "$c_dim" "$c_reset"
  out="$(LAUNCH_CWD="$HOME" bash "$LAUNCH" "$acct" "$perm" "$name" 2>&1)"
  tname="$(printf '%s' "$out" | sed -n 's/.*tmux=\([^ ]*\).*/\1/p' | head -1)"
  if [ -n "$tname" ]; then
    printf '  %s✓ created — opening…%s\n' "$c_grn" "$c_reset"; sleep 1
    "$TMUX_BIN" attach -t "$tname"
  else
    printf '  %s✗ failed:%s %s\n  press Enter…' "$c_yel" "$c_reset" "$out"; read -r _
  fi
}

kill_one() {
  load_sessions
  [ "${#SESS[@]}" -eq 0 ] && return
  printf '  Kill which number? '; read -r n
  case "$n" in ''|*[!0-9]*) return;; esac
  local pick="${SESS[$((n-1))]}"; [ -n "$pick" ] || return
  local name; name="$(printf '%s' "$pick" | cut -f1)"
  printf '  Kill %s%s%s? [y/N] ' "$c_yel" "$name" "$c_reset"; read -r yn
  [ "$yn" = "y" ] && "$TMUX_BIN" kill-session -t "$name"
}

while true; do
  draw
  printf '  > '; read -r choice
  case "$choice" in
    n|N) new_claude ;;
    k|K) kill_one ;;
    r|R|"") : ;;
    *[!0-9]*) : ;;
    *)
      load_sessions
      pick="${SESS[$((choice-1))]}"
      if [ -n "$pick" ]; then
        name="$(printf '%s' "$pick" | cut -f1)"
        "$TMUX_BIN" attach -t "$name"
      fi
      ;;
  esac
done
