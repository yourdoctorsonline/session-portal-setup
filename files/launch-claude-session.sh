#!/bin/bash
# launch-claude-session.sh
# -----------------------------------------------------------------------------
# Launch a new REMOTE-CONTROL Claude Code session in a chosen working directory,
# inside a detached tmux session, under a chosen account config.
#
#   - targets a chosen working directory via LAUNCH_CWD (default: the user's home)
#   - names the session (tmux name AND Claude's --remote-control name) with what
#     you typed, so it's identifiable in the Claude mobile app
#   - never attaches (headless), so it can be driven remotely instead of locally
#   - defaults the effort to ultracode (override per launch with LAUNCH_EFFORT)
#
# The --remote-control flag is what exposes the running session for control from
# the Claude mobile app (and the in-app terminal).
#
# Usage:
#   launch-claude-session.sh <account> <perm> [session name...]
#     account : default | <name>  (default = plain ~/.claude; <name> = ~/.claude-<name>)
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

# Pre-trust the launch folder. Claude Code shows a first-run "Do you trust the
# files in this folder?" security prompt for any not-yet-trusted directory. A
# headless remote-control launch has NO ONE to answer it, so claude blocks there
# forever: the session never registers (empty URL), the Claude app shows nothing,
# and the ttyd terminal shows a stuck prompt / black screen. That's the "black
# screen on launch" everyone hits on a fresh install (every folder is untrusted).
# Marking hasTrustDialogAccepted for this folder in the account's .claude.json is
# exactly what clicking "Yes, I trust this folder" persists — so claude skips the
# prompt and starts the session. (Default account => ~/.claude.json; a named
# account => its own <config-dir>/.claude.json.)
if [ -n "$CONFIG_DIR" ]; then TRUST_JSON="$CONFIG_DIR/.claude.json"; else TRUST_JSON="$HOME/.claude.json"; fi
PATH="$EXTRA_PATH" python3 - "$TRUST_JSON" "$REPO" >/dev/null 2>&1 <<'PY' || true
import json, os, sys
f, repo = sys.argv[1], sys.argv[2]
if os.path.exists(f):
    try:
        d = json.load(open(f))
    except Exception:
        sys.exit(0)  # never clobber a config we couldn't parse
else:
    d = {}
projects = d.setdefault("projects", {})
# Trust BOTH the given path and its resolved realpath — claude looks trust up by
# the resolved cwd, and on macOS /var -> /private/var (and other volumes can be
# symlinked), so the two can differ.
for path in {repo, os.path.realpath(repo)}:
    p = projects.setdefault(path, {})
    p["hasTrustDialogAccepted"] = True
    p.setdefault("allowedTools", [])
tmp = f + ".launcher-tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, f)
PY

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

# Keep the session AUTONOMOUS. A launched session is remote-control (driven from
# the phone), so the user is NOT at this machine's keyboard: Claude must DO the
# work with its tools, not print commands for a human to run. Pinned in the
# system prompt (strongest placement — survives a long session and re-anchors on
# a fresh one). Note: --permission-mode/--dangerously-skip-permissions only
# removes the *approval* gate; whether Claude actually calls a tool vs. prints
# text is behavioral — this is what keeps it executing. Override or extend per
# launch with LAUNCH_SYSTEM_PROMPT.
EXEC_MODE_PROMPT="${LAUNCH_SYSTEM_PROMPT:-You are running in a remote-control session started from the Session Launcher. The user is driving you from a phone or another device and is away from this machine, so they cannot run anything by hand. Always DO the work yourself with your tools: run shell commands, file edits, git, and deploys via tool calls. NEVER print a block of commands or manual steps for the user to run; executing them yourself is the entire purpose of this session. If a task needs CLI / deploy / git steps, run them and report the outcome.}"

# Inner command run inside the tmux pane. Absolute paths + explicit PATH make it
# independent of how the outer shell was invoked. exec binds the pane lifetime
# to Claude, so the tmux session ends when the session ends.
CONFIG_EXPORT=""
[ -n "$CONFIG_DIR" ] && CONFIG_EXPORT="export CLAUDE_CONFIG_DIR=$(printf '%q' "$CONFIG_DIR"); "
INNER="export PATH=$(printf '%q' "$EXTRA_PATH"):\$PATH; \
${CONFIG_EXPORT}\
exec $(printf '%q' "$CLAUDE_BIN") --permission-mode $PERM_MODE \
--effort $(printf '%q' "$EFFORT") \
--append-system-prompt $(printf '%q' "$EXEC_MODE_PROMPT") \
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
