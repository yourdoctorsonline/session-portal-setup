#!/bin/bash
# launch-claude-session.sh
# -----------------------------------------------------------------------------
# Launch a new REMOTE-CONTROL Claude Code session in a chosen working directory,
# inside a detached tmux session, using one of the two account configs.
#
# This mirrors the claude-personal / claude-ydo zsh functions in ~/.zshrc, but:
#   - targets a chosen working directory via LAUNCH_CWD (default: the agentic-os
#     repo; the aliases don't cd)
#   - names the session (tmux name AND Claude's --remote-control name) with what
#     you typed, so it's identifiable in the Claude mobile app
#   - never attaches (headless), so it can be driven remotely instead of locally
#
# The --remote-control flag is what exposes the running session for control from
# the Claude mobile app (and the in-app terminal) — the same mechanism the
# aliases use, just named and pointed at the chosen directory.
#
# Usage:
#   launch-claude-session.sh <account> <perm> [session name...]
#     account : personal | ydo
#     perm    : auto | bypass
#     name    : free-text session name (may contain spaces); optional
#
# Prints machine-parseable lines on stdout. On success:
#   NAME=<session name as typed>
#   URL=<claude.ai/code session URL, or empty if not captured in time>
#   STATUS=OK tmux=<name> account=<a> perm=<mode>
# On failure:
#   STATUS=ERR msg=<reason>
# -----------------------------------------------------------------------------
set -u

# Default to the invoking user's home — the app always passes LAUNCH_CWD, so
# this only matters for bare shell invocations. Must stay username-generic.
REPO="${LAUNCH_CWD:-$HOME}"
# Username-generic tool resolution. SSH exec channels get the bare sshd PATH
# (no ~/.local/bin, no homebrew), so candidates are probed explicitly:
# Apple-Silicon homebrew, Intel homebrew/local, and the claude installer's
# ~/.local/bin.
TMUX_BIN="/opt/homebrew/bin/tmux"
[ -x "$TMUX_BIN" ] || TMUX_BIN="/usr/local/bin/tmux"
CLAUDE_BIN="$HOME/.local/bin/claude"
EXTRA_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

fail() { echo "STATUS=ERR msg=$1"; exit 1; }

ACCOUNT="${1:-}"
PERM="${2:-}"
if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
NAME="${*:-}"

[ -n "$ACCOUNT" ] || fail "missing-account"
[ -n "$PERM" ]    || fail "missing-perm"

# Account mapping is generic: "default" runs plain `claude` (no config-dir
# override); any other name X uses ~/.claude-X and must already exist. The
# legacy accounts (personal, ydo) are covered by the same rule.
if [ "$ACCOUNT" = "default" ]; then
  CONFIG_DIR=""
else
  CONFIG_DIR="$HOME/.claude-$ACCOUNT"
  [ -d "$CONFIG_DIR" ] || fail "bad-account:$ACCOUNT"
fi

case "$PERM" in
  auto)   PERM_MODE="auto" ;;
  bypass) PERM_MODE="bypassPermissions" ;;
  *)      fail "bad-perm:$PERM" ;;
esac

# Resolve tools, falling back to a PATH lookup that includes the usual install
# locations (the inherited sshd PATH alone would miss them).
[ -x "$TMUX_BIN" ]   || TMUX_BIN="$(PATH="$EXTRA_PATH" command -v tmux 2>/dev/null)"   || true
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(PATH="$EXTRA_PATH" command -v claude 2>/dev/null)" || true
[ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ]     || fail "no-tmux"
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || fail "no-claude"
[ -d "$REPO" ] || fail "no-repo"

# Trim whitespace; default the name to the alias-style timestamped form.
NAME="$(printf '%s' "$NAME" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$NAME" ] || NAME="claude-$ACCOUNT-$(date +%H%M%S)"

# tmux session names can't contain '.' ':' or whitespace — derive a safe handle.
TMUX_NAME="$(printf '%s' "$NAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9_-')"
[ -n "$TMUX_NAME" ] || TMUX_NAME="claude-$ACCOUNT-$(date +%H%M%S)"

# Guarantee a unique tmux session name.
BASE="$TMUX_NAME"; n=2
while "$TMUX_BIN" has-session -t "=$TMUX_NAME" 2>/dev/null; do
  TMUX_NAME="${BASE}-${n}"; n=$((n + 1))
done

# Effort level for the session. Default is ultracode (multi-agent orchestration
# on every substantive task); override per launch with LAUNCH_EFFORT=low|...|max.
# Unknown values are safe: claude warns and falls back to its default.
EFFORT="${LAUNCH_EFFORT:-ultracode}"

# Inner command run inside the tmux pane. Absolute paths + explicit PATH make it
# independent of how the outer shell was invoked. exec binds the pane lifetime
# to Claude, so the tmux session ends when the session ends.
CONFIG_EXPORT=""
[ -n "$CONFIG_DIR" ] && CONFIG_EXPORT="export CLAUDE_CONFIG_DIR=$(printf '%q' "$CONFIG_DIR"); "
INNER="export PATH=$(printf '%q' "$EXTRA_PATH"):\$PATH; \
${CONFIG_EXPORT}\
exec $(printf '%q' "$CLAUDE_BIN") --permission-mode $PERM_MODE \
--effort $(printf '%q' "$EFFORT") \
--name $(printf '%q' "$NAME") \
--remote-control $(printf '%q' "$NAME")"

# How long (seconds) to wait for Claude to print its remote-control session URL.
URL_TIMEOUT="${LAUNCH_URL_TIMEOUT:-12}"

# Poll the new session's pane for the claude.ai/code session URL that Claude
# prints once remote control registers. Echoes the URL (empty if it never
# appears within URL_TIMEOUT). capture-pane -J un-wraps the line so the URL
# survives even on a narrow pane.
capture_url() {
  local deadline=$(( $(date +%s) + URL_TIMEOUT )) url=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # No "=" prefix here: capture-pane rejects the exact-match form. TMUX_NAME is
    # already guaranteed unique above, so a plain target resolves to this pane.
    url="$("$TMUX_BIN" capture-pane -p -J -t "$TMUX_NAME" 2>/dev/null \
            | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1)"
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    sleep 0.5
  done
  return 0
}

# Set LAUNCH_DRYRUN=1 to print what would run without spawning anything.
if [ "${LAUNCH_DRYRUN:-0}" = "1" ]; then
  echo "DRYRUN tmux=$TMUX_NAME repo=$REPO"
  echo "  $TMUX_BIN new-session -d -x 200 -y 50 -s $TMUX_NAME -c $REPO <inner>"
  echo "  inner: $INNER"
  echo "NAME=$NAME"
  echo "URL="
  echo "STATUS=OK tmux=$TMUX_NAME account=$ACCOUNT perm=$PERM_MODE"
  exit 0
fi

# Launch wide (-x 200) so the URL Claude prints doesn't wrap before capture.
if "$TMUX_BIN" new-session -d -x 200 -y 50 -s "$TMUX_NAME" -c "$REPO" "$INNER"; then
  # Store the human name (spaces/case preserved) as a tmux user option so the
  # launcher's session list shows it instead of the sanitized handle — making
  # it unambiguous which session to kill.
  "$TMUX_BIN" set-option -t "$TMUX_NAME" @display_name "$NAME" 2>/dev/null || true
  URL="$(capture_url)"
  echo "NAME=$NAME"
  echo "URL=$URL"
  echo "STATUS=OK tmux=$TMUX_NAME account=$ACCOUNT perm=$PERM_MODE"
else
  fail "tmux-launch-failed"
fi
