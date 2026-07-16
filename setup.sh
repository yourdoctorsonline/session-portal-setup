#!/bin/bash
# setup.sh — Session Launcher team installer
# -----------------------------------------------------------------------------
# One command a new teammate pastes on their Mac (or Windows-via-WSL2) that walks
# them from a blank machine to a working, phone-reachable Session Launcher portal.
#
# It is interactive, idempotent (every step checks state and skips when already
# satisfied), and speaks in plain words — the person running it may not code.
#
# Two halves:
#   1. a LIBRARY of pure helpers (say/ask/run/platform_detect/validate/upsert...)
#   2. the MAIN FLOW of 8 steps.
# A sourcing guard between them lets the test harness load only the library:
#   SETUP_LIB_ONLY=1 . setup.sh
#
# Dry run (no prompts, no mutation, exits 0) for smoke-testing the whole flow:
#   SETUP_DRYRUN=1 SETUP_SRC=<assembled public layout> bash setup.sh
#
# bash-3.2 SAFE (macOS default /bin/bash): no `declare -A`, no `${var,,}`.
# -----------------------------------------------------------------------------
set -u

# Every `sudo` in this installer asks for the COMPUTER login password, not a
# Tailscale/GitHub/Claude password. A bare sudo prompt just says "Password:",
# which people mistake for the app they're installing — so spell it out.
export SUDO_PROMPT='Enter your computer password (the one you log into this computer with — NOT Tailscale/GitHub/Claude): '

# ============================================================================
# LIBRARY
# ============================================================================

# ---- colored output (respects NO_COLOR) ------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

say()      { printf '%s\n' "$*"; }
ok()       { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()     { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail_msg() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

step_banner() {
  # step_banner N TITLE
  printf '\n%s%s— Step %s of 8: %s —%s\n' "$C_BOLD" "$C_CYAN" "$1" "$2" "$C_RESET"
}

# ask VAR "prompt" "default"
# Reads from the terminal directly (works even when stdin is a pipe from curl).
# Under SETUP_DRYRUN=1 it never prompts — it takes the default silently.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    eval "$__var=\$__default"
    return 0
  fi
  if [ -n "$__default" ]; then
    printf '%s [%s]: ' "$__prompt" "$__default" > /dev/tty
  else
    printf '%s: ' "$__prompt" > /dev/tty
  fi
  if ! read -r __reply < /dev/tty; then __reply=""; fi
  [ -z "$__reply" ] && __reply="$__default"
  eval "$__var=\$__reply"
}

# run "human description" cmd args...
# Executes the command. Under SETUP_DRYRUN=1 it prints what WOULD run and no-ops.
run() {
  local desc="$1"; shift
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    printf 'DRYRUN: %s\n' "$*"
    return 0
  fi
  [ -n "$desc" ] && say "  $desc"
  "$@"
}

# platform_detect — echoes mac|wsl|unsupported and returns 0|0|2.
# uname is overridable for tests via SETUP_FAKE_UNAME; the WSL probe reads a
# /proc/version-style file path (SETUP_FAKE_PROCVERSION), missing == empty.
platform_detect() {
  local sys="${SETUP_FAKE_UNAME:-$(uname -s)}"
  case "$sys" in
    Darwin)
      echo "mac"; return 0 ;;
    Linux)
      local pv_file="${SETUP_FAKE_PROCVERSION:-/proc/version}" pv=""
      [ -r "$pv_file" ] && pv="$(cat "$pv_file" 2>/dev/null)"
      # case-insensitive match for "microsoft" (bash-3.2: use tr, not ${,,})
      if printf '%s' "$pv" | tr 'A-Z' 'a-z' | grep -q "microsoft"; then
        echo "wsl"; return 0
      fi
      echo "unsupported"; return 2 ;;
    *)
      echo "unsupported"; return 2 ;;
  esac
}

# validate_account_name NAME — 0 if a legal, non-reserved account name.
validate_account_name() {
  local name="$1"
  # must be lowercase letters, digits, dashes only, at least one char
  case "$name" in
    "" ) return 1 ;;
  esac
  printf '%s' "$name" | grep -qE '^[a-z0-9-]+$' || return 1
  # reserved names
  case "$name" in
    default|launcher) return 1 ;;
    swap-backup*)     return 1 ;;
  esac
  return 0
}

# upsert_env KEY VALUE [FILE]
# Replace an existing `KEY=` line in place, else append. All other lines are
# preserved verbatim. Default file: ~/.claude-launcher/portal.env (parent made).
# bash-3.2 / BSD-safe: rewrite through a temp file with grep -v + printf.
upsert_env() {
  local key="$1" value="$2" file="${3:-$HOME/.claude-launcher/portal.env}"
  local dir tmp
  dir="$(dirname "$file")"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$file" ] || : > "$file"
  tmp="$(mktemp "${TMPDIR:-/tmp}/portalenv.XXXXXX")"
  # keep every line that is NOT this key, then append the fresh key line
  grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

have()     { command -v "$1" >/dev/null 2>&1; }
creds_ok() {
  # Is this account signed in? Named config dirs (and all of Linux) keep the
  # login in a .credentials.json file. But the DEFAULT account on macOS stores
  # it in the login Keychain (service "Claude Code-credentials") with NO file —
  # so a file-only check false-negatives even right after a successful sign-in,
  # and this installer would loop through Step 3 forever (and, before the stdio
  # fix, crash there). Check the Keychain too for the default account. No `-w`
  # means we only test existence — no password is read and no prompt appears.
  [ -f "$1/.credentials.json" ] && return 0
  if [ "$(uname -s)" = "Darwin" ] && [ "$1" = "$HOME/.claude" ]; then
    security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# find_agentic_os — echo the path to an agentic-os git repo if one can be found
# in the usual spots, so non-technical users never have to know or type a path.
# Empty if none found. Checks common locations first (fast), then a shallow
# bounded search under HOME and mounted volumes.
find_agentic_os() {
  local d
  for d in "$HOME/repos/agentic-os" "$HOME/agentic-os" "$HOME/Documents/agentic-os" \
           "$HOME/Desktop/agentic-os" "$HOME/Developer/agentic-os" "$HOME/code/agentic-os" \
           "$HOME/projects/agentic-os"; do
    [ -d "$d/.git" ] && { printf '%s' "$d"; return 0; }
  done
  # Only match dirs that are actually git repos (a bare `-name agentic-os | head`
  # can land on an empty stub folder and miss the real repo deeper down).
  d="$(find "$HOME" /Volumes -maxdepth 4 -type d -name agentic-os \
        -not -path '*/node_modules/*' -not -path '*/.Trash/*' \
        -exec sh -c '[ -d "$1/.git" ]' _ {} \; -print 2>/dev/null | head -1)"
  [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  return 1
}

# setup_backup — ensure the user's agentic-os repo is backed up to a PRIVATE repo
# on their OWN GitHub (outside any org), if it isn't already. Uses gh to create a
# private repo named `agentic-os`, wires it as the `backup` remote, and pushes.
# The hourly job (backup-agentic-os.sh) keeps it current with one-way snapshot
# force-pushes — it never merges/pulls, so no conflicts. Idempotent.
setup_backup() {
  local ws repo ghuser
  ws="$(grep '^WORKSPACE_ROOT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  repo="${ws:-$HOME/repos}/agentic-os"
  if [ ! -d "$repo/.git" ]; then
    say "  No agentic-os git repo at $repo yet — skipping backup. Re-run me after you clone it."
    return 0
  fi
  if ! have gh; then warn "GitHub CLI (gh) isn't available — skipping backup."; return 0; fi
  if ! gh auth status >/dev/null 2>&1; then
    say "  To back up privately to YOUR OWN GitHub, sign in to GitHub now (a browser code):"
    gh auth login < /dev/tty || { warn "GitHub sign-in didn't finish — skipping backup (re-run me later)."; return 0; }
  fi
  ghuser="$(gh api user -q .login 2>/dev/null)"
  [ -n "$ghuser" ] || { warn "Couldn't read your GitHub username — skipping backup."; return 0; }
  # Already backed up to a repo you personally own?
  if git -C "$repo" remote -v 2>/dev/null | grep -qiE "github\.com[:/]$ghuser/"; then
    ok "agentic-os is already backed up to your own GitHub ($ghuser) — leaving it."
    return 0
  fi
  if gh repo view "$ghuser/agentic-os" >/dev/null 2>&1; then
    say "  Using your existing private repo $ghuser/agentic-os as the backup."
  else
    run "creating your private backup repo ($ghuser/agentic-os)" gh repo create "$ghuser/agentic-os" --private
  fi
  git -C "$repo" remote get-url backup >/dev/null 2>&1 \
    || git -C "$repo" remote add backup "https://github.com/$ghuser/agentic-os.git"
  say "  Pushing the first backup…"
  bash "$BIN_DIR/backup-agentic-os.sh" "$repo" || true
  say ""
  say "  ${C_BOLD}Backed up to a PRIVATE repo: github.com/$ghuser/agentic-os${C_RESET}"
  say "  Only you can see it — not the yourdoctorsonline org and not your teammates."
  say "  (It refreshes on its own every hour; it only ever pushes, never merges.)"
}

# apply_orchestrator_defaults SRC — make every signed-in Claude account launch as
# an ENGINEERING ORCHESTRATOR: Opus 4.8 + ultracode effort, the eng-harness
# conductor skill (with its superpowers + zero-trust-verification deps), and a
# standing instruction to route routine subagent work to Sonnet. SRC is the
# extracted repo root (it ships the skills under SRC/skills/). Idempotent.
apply_orchestrator_defaults() {
  local src="$1" cfg name sk
  for cfg in "$HOME"/.claude "$HOME"/.claude-*; do
    [ -d "$cfg" ] || continue
    name="$(basename "$cfg")"
    case "$name" in .claude-launcher|.claude-swap-backup*) continue ;; esac
    creds_ok "$cfg" || continue   # only accounts that are actually signed in
    say "  configuring $name as an engineering orchestrator…"
    mkdir -p "$cfg/skills"
    # eng-harness + its hard dep, copied in (survive without the source repo)
    for sk in eng-harness zero-trust-verification; do
      [ -d "$src/skills/$sk" ] && { rm -rf "$cfg/skills/$sk"; cp -R "$src/skills/$sk" "$cfg/skills/$sk"; }
    done
    # superpowers plugin — the harness invokes superpowers:brainstorming etc.
    if ! ls -d "$cfg"/plugins/cache/*/superpowers >/dev/null 2>&1; then
      CLAUDE_CONFIG_DIR="$cfg" claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 || true
      CLAUDE_CONFIG_DIR="$cfg" claude plugin install superpowers@claude-plugins-official >/dev/null 2>&1 || true
    fi
    # model + effort in settings.json, AND mark first-run onboarding complete in
    # .claude.json. Without the onboarding flag, a freshly-signed-in account shows
    # the interactive theme picker on first launch — which a headless launcher
    # session can't answer, so it hangs on a black screen and registers nothing.
    python3 - "$cfg" <<'PY'
import json, os, sys
cfg = sys.argv[1]
sf = os.path.join(cfg, "settings.json")
s = json.load(open(sf)) if os.path.exists(sf) else {}
s["model"] = "opus"; s["effortLevel"] = "ultracode"   # plain 'opus' = Opus 4.8, works for everyone (opus[1m] needs 1M access most accounts lack)
s.setdefault("theme", "dark")
json.dump(s, open(sf, "w"), indent=2); open(sf, "a").write("\n")
cf = os.path.join(cfg, ".claude.json")
c = json.load(open(cf)) if os.path.exists(cf) else {}
c["hasCompletedOnboarding"] = True
c.setdefault("theme", "dark")
json.dump(c, open(cf, "w"), indent=2)
PY
    # Sonnet-subagent routing instruction (no hard switch exists — this is it)
    if ! grep -q "Engineering Orchestrator" "$cfg/CLAUDE.md" 2>/dev/null; then
      cat >> "$cfg/CLAUDE.md" <<'MD'

# Session defaults — Engineering Orchestrator

- **Model:** Opus 4.8 (settings.json). Keep the main loop, judgment, and final verification on Opus.
- **Effort:** ultracode (settings.json) — reach for the Workflow tool on substantive work.
- **Engineering discipline:** invoke the **eng-harness** skill for any build / fix / refactor / script / ship (it is the mandatory conductor; a fast lane covers small changes).
- **Model routing:** delegate routine, parallel, mechanical, and first-pass subagent work to **Sonnet** (`model: 'sonnet'` in Workflow `agent()` / Task). Reserve Opus for the conductor, hard judgment, and final adversarial verification.
MD
    fi
  done
}

# claude_signin [CONFIG_DIR] — run `claude` interactively for sign-in with stdio
# that WON'T crash. Newer Bun-based claude builds throw
# `TypeError: undefined is not an object (evaluating 'process.stderr.fd')` when
# stdout/stderr are shell-redirected to /dev/tty (as `> /dev/tty 2>&1` does).
# When we already have a real terminal on stdout, let claude inherit it (fd 1/2
# stay real TTYs → no crash) and only take stdin from /dev/tty. The full
# /dev/tty redirect is kept solely as a fallback for `curl | bash`, where stdout
# is the pipe and claude has no terminal otherwise.
claude_signin() {
  local cfg="${1:-}"
  if [ -t 1 ]; then
    if [ -n "$cfg" ]; then CLAUDE_CONFIG_DIR="$cfg" claude < /dev/tty
    else claude < /dev/tty; fi
  else
    if [ -n "$cfg" ]; then CLAUDE_CONFIG_DIR="$cfg" claude < /dev/tty > /dev/tty 2>&1
    else claude < /dev/tty > /dev/tty 2>&1; fi
  fi
}

# tsip — first line of `tailscale ip -4`, probing the usual install locations
# because a piped-in installer inherits a bare PATH.
tsip() {
  local ts=""
  for c in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /usr/bin/tailscale; do
    [ -x "$c" ] && { ts="$c"; break; }
  done
  [ -n "$ts" ] || ts="$(command -v tailscale 2>/dev/null)"
  [ -n "$ts" ] || return 0
  "$ts" ip -4 2>/dev/null | head -1
}

# brew_bin — path to an installed Homebrew, or empty. Probes the standard
# Apple-Silicon / Intel locations, NOT just PATH: a `curl … | bash` installer
# runs with a bare PATH that omits /opt/homebrew/bin, so a plain `command -v
# brew` false-negatives on Macs that already have Homebrew — which then triggers
# a doomed reinstall. (Same bare-PATH reason as tsip().)
brew_bin() {
  local b
  b="$(command -v brew 2>/dev/null)" && { printf '%s' "$b"; return 0; }
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# claude_bin — path to the claude CLI, or empty. Probes ~/.local/bin (where the
# official installer drops it) in addition to PATH, for the same bare-PATH
# reason — otherwise an already-installed claude gets needlessly reinstalled.
claude_bin() {
  local c
  c="$(command -v claude 2>/dev/null)" && { printf '%s' "$c"; return 0; }
  [ -x "$HOME/.local/bin/claude" ] && { printf '%s' "$HOME/.local/bin/claude"; return 0; }
  return 1
}

# --- sourcing guard: the test harness stops here -----------------------------
if [ "${SETUP_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ============================================================================
# MAIN FLOW
# ============================================================================

LAUNCHER_DIR="$HOME/.claude-launcher"
BIN_DIR="$LAUNCHER_DIR/bin"
ENV_FILE="$LAUNCHER_DIR/portal.env"
REPO_URL="https://github.com/yourdoctorsonline/session-portal-setup/archive/refs/heads/main.tar.gz"

say "${C_BOLD}Session Launcher — team setup${C_RESET}"
say "This gets you from a blank machine to a phone-reachable portal. It's safe to"
say "re-run: anything already done gets skipped."

# ---- STEP 1: machine check --------------------------------------------------
# Runs BEFORE anything touches the disk or network (AC-TI-003: an unsupported
# machine must get the Windows/WSL guidance and exit 2 with zero side effects).
step_banner 1 "Checking your machine"
PLATFORM="$(platform_detect)"; PLAT_RC=$?
case "$PLATFORM" in
  mac)
    ok "macOS detected."
    if pmset -g batt 2>/dev/null | grep -q "InternalBattery"; then
      warn "This looks like a laptop. Keep it plugged in and awake so the portal stays reachable from your phone."
    fi
    ;;
  wsl)
    ok "Windows (WSL2 Ubuntu) detected."
    ;;
  *)
    # AC-TI-003: unsupported platform — print the Windows guide, change nothing, exit 2.
    fail_msg "This doesn't look like a Mac or WSL2 Ubuntu."
    say ""
    say "If you're on Windows, set up WSL2 first, then re-run this:"
    say "  1. Open PowerShell as Administrator (right-click > Run as administrator)"
    say "  2. Run:  wsl --install"
    say "  3. Restart your PC when it asks."
    say "  4. Open the 'Ubuntu' app from the Start menu and finish its first-time setup."
    say "  5. Paste this same install command into the Ubuntu window."
    exit 2
    ;;
esac

# ---- resolve SRC (the public-repo layout we install from) -------------------
SRC=""
if [ -n "${SETUP_SRC:-}" ]; then
  SRC="$SETUP_SRC"
  [ -d "$SRC" ] || { fail_msg "SETUP_SRC=$SRC is not a folder."; exit 1; }
else
  say ""
  say "Downloading the Session Launcher files..."
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would download $REPO_URL"
    SRC="$LAUNCHER_DIR/.dryrun-src"
  else
    DL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/session-portal.XXXXXX")"
    trap 'rm -rf "$DL_DIR"' EXIT
    if have curl && curl -fsSL "$REPO_URL" -o "$DL_DIR/main.tar.gz" 2>/dev/null \
        && tar -xzf "$DL_DIR/main.tar.gz" -C "$DL_DIR" 2>/dev/null; then
      SRC="$DL_DIR/session-portal-setup-main"
    fi
    if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
      fail_msg "Couldn't download the setup files."
      say "Check your internet connection, or download the repo yourself and re-run"
      say "with SETUP_SRC pointing at the extracted folder."
      exit 1
    fi
  fi
fi

# ---- STEP 2: basics (package tools) -----------------------------------------
step_banner 2 "Installing the basic tools"
if [ "$PLATFORM" = "mac" ]; then
  BREW="$(brew_bin || true)"
  if [ -n "$BREW" ]; then
    # Already installed — just bring it onto PATH for the rest of this run.
    [ "${SETUP_DRYRUN:-0}" = "1" ] || eval "$("$BREW" shellenv)"
    ok "Homebrew already installed."
  elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install Homebrew"
  else
    say "Installing Homebrew (the tool that installs other tools)..."
    # Homebrew's own installer needs a real terminal for its password prompt
    # (you must be an admin on this Mac). A `curl … | bash` pipe leaves stdin as
    # the pipe, so Homebrew goes non-interactive and dies on "Need sudo access."
    # Feed it /dev/tty so it can prompt. If there's no controlling terminal at
    # all (can't even open /dev/tty), we can't install it — bail with
    # instructions instead of failing cryptically three commands later.
    if ( exec < /dev/tty ) 2>/dev/null; then
      run "installing Homebrew" /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
    fi
    BREW="$(brew_bin || true)"
    if [ -n "$BREW" ]; then
      eval "$("$BREW" shellenv)"
      ok "Homebrew installed."
    else
      fail_msg "Homebrew isn't installed, and I couldn't install it automatically."
      say "Install it yourself (you'll need to be an admin on this Mac), then re-run me:"
      say '  1. Open the Terminal app.'
      say '  2. Paste this and press Enter, then type your Mac password when asked:'
      say '     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      say '  3. Re-run this installer.'
      exit 1
    fi
  fi
  for tool in tmux ttyd qrencode gh; do
    if have "$tool"; then
      ok "$tool already installed."
    else
      run "installing $tool" brew install "$tool"
    fi
  done
  # Homebrew python specifically — NOT Apple's /usr/bin/python3. The dashboard
  # service runs the portal under Homebrew python because Apple's python is
  # sandboxed by macOS privacy (TCC) away from external volumes, which silently
  # breaks browsing/launching for a workspace on an external drive. `have python3`
  # is always true on macOS (the Apple shim), so check for the Homebrew binary.
  if [ -x "$(brew --prefix 2>/dev/null)/bin/python3" ]; then
    ok "python already installed."
  else
    run "installing python" brew install python
  fi
elif [ "$PLATFORM" = "wsl" ]; then
  # Install per-package, NOT one atomic `apt-get install tmux ttyd python3 qrencode`:
  # on Ubuntu releases where ttyd isn't packaged, an atomic install aborts and
  # leaves ALL of them missing. A loop lets ttyd's absence fail on its own while
  # tmux/python3/qrencode still install.
  APT_UPDATED=0
  for tool in tmux python3 qrencode gh; do
    if have "$tool"; then
      ok "$tool already installed."
    else
      [ "$APT_UPDATED" = "1" ] || { run "updating package lists" sudo apt-get update -qq; APT_UPDATED=1; }
      run "installing $tool" sudo apt-get install -y "$tool"
    fi
  done
  # ttyd often isn't in apt. Try apt first; if that fails, drop the official
  # static binary into ~/.local/bin (which portal.sh already has on PATH).
  if have ttyd; then
    ok "ttyd already installed."
  else
    [ "$APT_UPDATED" = "1" ] || { run "updating package lists" sudo apt-get update -qq; APT_UPDATED=1; }
    sudo apt-get install -y ttyd 2>/dev/null || true
    if ! have ttyd; then
      say "  ttyd isn't in apt here — fetching the official static binary..."
      ARCH="$(uname -m)"; case "$ARCH" in aarch64|arm64) TARCH="aarch64" ;; *) TARCH="x86_64" ;; esac
      mkdir -p "$HOME/.local/bin"
      if curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${TARCH}" \
           -o "$HOME/.local/bin/ttyd" 2>/dev/null && [ -s "$HOME/.local/bin/ttyd" ]; then
        chmod +x "$HOME/.local/bin/ttyd"
        case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
        ok "ttyd installed to ~/.local/bin."
      else
        fail_msg "Couldn't install ttyd automatically."
        say "Install it yourself, then re-run me:"
        say "  sudo snap install ttyd --classic    # (needs systemd; see below)"
        say "  — or download a static build from https://github.com/tsl0922/ttyd/releases into ~/.local/bin/ttyd"
        exit 1
      fi
    fi
  fi
fi

# ---- STEP 3: Claude Code install + login ------------------------------------
# Claude Code is installed because the portal's whole job is to launch
# `claude --remote-control` sessions — without the CLI there's nothing to run.
# We detect an existing install via ~/.local/bin (not just PATH) so teammates
# who already use Claude Code aren't put through a pointless reinstall. The
# interactive sign-in is a separate step below.
step_banner 3 "Installing Claude Code and signing in"
if [ -n "$(claude_bin || true)" ]; then
  # make sure it's on PATH for the sign-in step and the launcher's checks
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
  esac
  ok "Claude Code already installed."
else
  say "Installing Claude Code..."
  run "installing Claude Code" /bin/bash -c "curl -fsSL https://claude.ai/install.sh | bash"
  # the installer drops the binary in ~/.local/bin
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
  esac
fi

if creds_ok "$HOME/.claude"; then
  ok "You're already signed in to Claude."
elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would open Claude for interactive sign-in."
else
  say ""
  say "Claude will open now. Sign in, then type  /exit  to come back here."
  say "(Press Enter when you're ready.)"
  read -r _ < /dev/tty 2>/dev/null || true
  claude_signin || true
  if creds_ok "$HOME/.claude"; then
    ok "Signed in to Claude."
  else
    fail_msg "It doesn't look like the sign-in finished."
    say "Run  claude  yourself, sign in, type /exit, then re-run this installer."
    exit 1
  fi
fi

# ---- STEP 4: extra accounts loop (AC-TI-005) --------------------------------
step_banner 4 "Adding extra Claude accounts (optional)"
say "If you use more than one Claude account, add each one here. Otherwise just"
say "press Enter to move on."
while : ; do
  ask ACC_NAME "Add another Claude account? Type a short name (letters/numbers/dashes, e.g. personal) or press Enter to continue" ""
  [ -z "$ACC_NAME" ] && break
  if ! validate_account_name "$ACC_NAME"; then
    warn "'$ACC_NAME' isn't a usable name. Use lowercase letters, numbers and dashes only, and don't use 'default', 'launcher', or names starting with 'swap-backup'."
    continue
  fi
  ACC_DIR="$HOME/.claude-$ACC_NAME"
  if creds_ok "$ACC_DIR"; then
    ok "'$ACC_NAME' is already signed in — skipping."
    continue
  fi
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would sign in account '$ACC_NAME' into $ACC_DIR"
    continue
  fi
  say "Claude will open for '$ACC_NAME'. Sign in with THAT account, then type /exit."
  claude_signin "$ACC_DIR" || true
  if creds_ok "$ACC_DIR"; then
    ok "'$ACC_NAME' signed in."
  else
    warn "That one didn't finish signing in — you can re-run me later to add it."
  fi
done

# ---- Engineering-orchestrator defaults --------------------------------------
# Every launched Claude session runs on Opus 4.8 at ultracode effort with the
# eng-harness conductor and Sonnet-subagent routing. (Team standard — the owner
# saw lower-effort models give low-quality answers, so this is the floor.)
say ""
say "Setting up engineering defaults (Opus 4.8 + ultracode + eng-harness)…"
if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would set model/effort, install eng-harness + superpowers, add routing note for each signed-in account"
else
  apply_orchestrator_defaults "$SRC"
  ok "Engineering defaults applied."
fi

# ---- STEP 5: Tailscale (AC-TI-007) ------------------------------------------
step_banner 5 "Setting up Tailscale (your private network)"
say ""
say "${C_BOLD}Heads up: this step will ask for your computer password${C_RESET} — the one you"
say "log into this computer with, ${C_BOLD}not${C_RESET} a Tailscale password."
say "${C_BOLD}As you type it, nothing shows on screen — no dots, no stars.${C_RESET} That's"
say "normal (it's hidden on purpose). Just type it and press Enter."
say ""
if [ "$PLATFORM" = "mac" ]; then
  # Install the Homebrew FORMULA (CLI + tailscaled daemon), NOT `--cask tailscale`:
  # the cask is the GUI app only and ships NO `tailscale` command, so every step
  # below (tsip, `tailscale up`) would fail and the connect loop would time out.
  if ! have tailscale; then
    run "installing Tailscale" brew install tailscale
  else
    ok "Tailscale already installed."
  fi
  # Start tailscaled as a background service (one-time sudo). `tailscale up`
  # below then brings the connection up.
  run "starting Tailscale" sudo brew services start tailscale
elif [ "$PLATFORM" = "wsl" ]; then
  if ! have tailscale; then
    run "installing Tailscale" /bin/bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
  else
    ok "Tailscale already installed."
  fi
  # Tailscale needs systemd; WSL only has it when [boot] systemd=true is set.
  if [ "${SETUP_DRYRUN:-0}" != "1" ] && ! systemctl --user show-environment >/dev/null 2>&1 \
       && ! systemctl is-system-running >/dev/null 2>&1; then
    warn "WSL needs systemd turned on before Tailscale can run."
    # APPEND (don't truncate) so we never wipe an existing wsl.conf ([automount]/
    # [network]/[user] etc.). Only add it if systemd=true isn't already set.
    if ! grep -qs "systemd=true" /etc/wsl.conf; then
      printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null \
        && ok "enabled systemd in WSL"
    fi
    say ""
    say "Almost there — one quick restart of WSL is needed:"
    say "  1. Open PowerShell and run:  wsl --shutdown"
    say "  2. Reopen the Ubuntu app."
    say "  3. Run this same install command again — it'll pick up where it left off."
    exit 0
  fi
  run "starting Tailscale" sudo systemctl enable --now tailscaled
fi

# bring the connection up if we don't have an IP yet
if [ -z "$(tsip)" ] && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
  say ""
  say "Tailscale will print a ${C_BOLD}https://login.tailscale.com/…${C_RESET} link next."
  say "Open it in a browser and sign in — then it continues here automatically."
  run "connecting to Tailscale" sudo tailscale up
fi

# the same-account warning, boxed so it's impossible to miss
say ""
say "${C_BOLD}${C_YELLOW}+--------------------------------------------------------------+${C_RESET}"
say "${C_BOLD}${C_YELLOW}|  SIGN IN WITH THE SAME TAILSCALE ACCOUNT ON YOUR PHONE        |${C_RESET}"
say "${C_BOLD}${C_YELLOW}|  Install the Tailscale app on your phone and log in with the  |${C_RESET}"
say "${C_BOLD}${C_YELLOW}|  same account, or your phone won't be able to reach this.     |${C_RESET}"
say "${C_BOLD}${C_YELLOW}+--------------------------------------------------------------+${C_RESET}"
say ""

if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would wait for a Tailscale IP here."
  TS_IP="100.64.0.1"   # placeholder so later steps have something to print
else
  say "Waiting for Tailscale to connect..."
  TS_IP=""
  for i in $(seq 1 60); do
    TS_IP="$(tsip)"
    [ -n "$TS_IP" ] && break
    sleep 2
  done
  if [ -z "$TS_IP" ]; then
    fail_msg "Tailscale didn't connect within two minutes."
    say "Open the Tailscale app, make sure you're signed in and connected, then re-run me."
    exit 1
  fi
  ok "Tailscale connected — your address is $TS_IP"
fi

# ---- STEP 6: portal install (AC-TI-008) -------------------------------------
step_banner 6 "Installing the portal"
run "creating $BIN_DIR" mkdir -p "$BIN_DIR"
if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would copy $SRC/files/* into $BIN_DIR"
else
  cp "$SRC"/files/* "$BIN_DIR"/ 2>/dev/null || {
    fail_msg "Couldn't copy the portal files from $SRC/files."
    exit 1
  }
  chmod +x "$BIN_DIR"/*.sh 2>/dev/null || true
fi

if [ "$PLATFORM" = "mac" ]; then
  LA_DIR="$HOME/Library/LaunchAgents"
  run "creating $LA_DIR" mkdir -p "$LA_DIR"
  # Absolute Homebrew python for the dashboard plist (see the template comment):
  # prefer the brew-prefix python, fall back to whatever python3 is on PATH.
  PYBIN="$(brew --prefix 2>/dev/null)/bin/python3"
  [ -x "$PYBIN" ] || PYBIN="$(command -v python3 || echo /usr/bin/python3)"
  for label in com.sessionlauncher.terminal com.sessionlauncher.dashboard com.sessionlauncher.watchdog com.sessionlauncher.backup; do
    TPL="$SRC/templates/$label.plist.template"
    PLIST="$LA_DIR/$label.plist"
    if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
      say "DRYRUN: would render $TPL -> $PLIST and (re)load it"
      continue
    fi
    if [ ! -f "$TPL" ]; then
      warn "Template $TPL missing — skipping $label."
      continue
    fi
    sed -e "s|__HOME__|$HOME|g" -e "s|__PYTHON__|$PYBIN|g" "$TPL" > "$PLIST"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
      && ok "Loaded $label" \
      || warn "Couldn't load $label — you may need to grant permission and re-run."
  done
elif [ "$PLATFORM" = "wsl" ]; then
  SD_DIR="$HOME/.config/systemd/user"
  run "creating $SD_DIR" mkdir -p "$SD_DIR"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install session-terminal.service + session-dashboard.service + session-watchdog.service/.timer and enable them"
  else
    cp "$SRC"/templates/session-terminal.service "$SD_DIR"/ 2>/dev/null || true
    cp "$SRC"/templates/session-dashboard.service "$SD_DIR"/ 2>/dev/null || true
    # The fd watchdog (see fd-watchdog.sh) — a oneshot service fired by a timer.
    cp "$SRC"/templates/session-watchdog.service "$SD_DIR"/ 2>/dev/null || true
    cp "$SRC"/templates/session-watchdog.timer "$SD_DIR"/ 2>/dev/null || true
    # Hourly private backup (see backup-agentic-os.sh) — a oneshot + timer.
    cp "$SRC"/templates/session-backup.service "$SD_DIR"/ 2>/dev/null || true
    cp "$SRC"/templates/session-backup.timer "$SD_DIR"/ 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now session-terminal session-dashboard session-watchdog.timer session-backup.timer 2>/dev/null \
      && ok "Portal services enabled" \
      || warn "Couldn't enable the portal services automatically."
    # Keep the --user services (and thus the portal) running after the Ubuntu
    # window closes. Without linger, per-user systemd stops at logout and WSL2
    # tears the whole VM down seconds later — the portal would vanish. Note: for
    # true 24/7 you also want WSL to auto-start on boot and the PC not to sleep
    # (see GUIDE.md).
    run "keeping the portal running in the background" sudo loginctl enable-linger "$(id -un)"
    # Re-runs land the raised LimitNOFILE on an already-running terminal. Safe:
    # tmux sessions belong to the tmux server and survive a ttyd restart. no-op
    # when the unit isn't running yet (a fresh install already started it above).
    systemctl --user try-restart session-terminal 2>/dev/null || true
  fi
fi

# ---- STEP 6b: workspace folder (AC-TI-009) ----------------------------------
step_banner 7 "Choosing your projects folder"

# Try to find agentic-os automatically so non-technical folks don't have to hunt
# for a path. If we find it, use it as the default launch folder and set the
# workspace to its parent — they just press Enter.
DEF_CWD=""
say "  Looking for your agentic-os folder…"
AOS="$(find_agentic_os || true)"
if [ -n "$AOS" ]; then
  ok "Found it: $AOS"
  ask KEEP_AOS "Use this folder for your sessions? (Y/n)" "Y"
  case "$KEEP_AOS" in n|N|no|No|NO) AOS="" ;; esac
fi

if [ -n "$AOS" ]; then
  WSROOT="$(dirname "$AOS")"
  DEF_CWD="$AOS"
else
  CUR_WS=""
  [ -f "$ENV_FILE" ] && CUR_WS="$(grep '^WORKSPACE_ROOT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  say "  (Couldn't find it automatically — no worries.)"
  ask WSROOT "Where do your project folders live?" "${CUR_WS:-$HOME/repos}"
  DEF_CWD="$WSROOT/agentic-os"; [ -d "$DEF_CWD" ] || DEF_CWD="$WSROOT"
fi

run "creating $WSROOT" mkdir -p "$WSROOT"
if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would save WORKSPACE_ROOT=$WSROOT and default launch folder=$DEF_CWD"
else
  upsert_env WORKSPACE_ROOT "$WSROOT" "$ENV_FILE"
  # THE FIX: also seed the launcher's default launch folder, so the New Session
  # sheet opens pointed at this folder instead of falling back to your home dir.
  printf '%s' "$DEF_CWD" > "$LAUNCHER_DIR/default-cwd" 2>/dev/null || true
  ok "Projects folder: $WSROOT"
  ok "New sessions will open in: $DEF_CWD"
fi

# ---- Private backup of agentic-os -------------------------------------------
say ""
say "Backing up your agentic-os to a private repo…"
if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would check for a personal backup and, if missing, gh-create a private <you>/agentic-os and push"
else
  setup_backup
fi

# ---- STEP 7: verify checklist (AC-TI-013) -----------------------------------
step_banner 8 "Checking everything works"
CHECK_FAIL=0
check() {
  # check "label" 0|1  (1 == ok)
  if [ "$2" = "1" ]; then
    ok "$1"
  else
    printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$1"
    CHECK_FAIL=$((CHECK_FAIL + 1))
  fi
}

if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would run the tmux / login / accounts / tailscale / :7681 / :8090 checks."
else
  # tmux
  have tmux && check "tmux is installed ($(tmux -V 2>/dev/null))" 1 || check "tmux is installed" 0
  # claude login
  creds_ok "$HOME/.claude" && check "signed in to Claude" 1 || check "signed in to Claude" 0
  # extra accounts detected (same skip rules as the portal)
  ACC_COUNT=0
  for d in "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"; sub="${base#.claude-}"
    case "$sub" in launcher) continue ;; swap-backup*) continue ;; esac
    ACC_COUNT=$((ACC_COUNT + 1))
  done
  check "extra Claude accounts detected: $ACC_COUNT" 1
  # tailscale
  [ -n "$TS_IP" ] && check "Tailscale connected ($TS_IP)" 1 || check "Tailscale connected" 0

  # ttyd :7681 and dashboard :8090 — they bind the tailnet IP, so curl that.
  HOST="${TS_IP:-127.0.0.1}"
  port_up() {
    # port_up PORT — poll up to 30s for an HTTP response on $HOST:PORT
    local port="$1" i
    for i in $(seq 1 15); do
      if curl -s -o /dev/null -m 3 "http://$HOST:$port" 2>/dev/null; then return 0; fi
      sleep 2
    done
    return 1
  }
  port_up 7681 && check "terminal service is live (port 7681)" 1 || check "terminal service is live (port 7681)" 0
  port_up 8090 && check "dashboard service is live (port 8090)" 1 || check "dashboard service is live (port 8090)" 0
  # dashboard actually serves the default account
  if curl -s -m 3 "http://$HOST:8090/api/accounts" 2>/dev/null | grep -q '"default"'; then
    check "dashboard lists your default account" 1
  else
    check "dashboard lists your default account" 0
  fi

  if [ "$CHECK_FAIL" != "0" ]; then
    say ""
    fail_msg "$CHECK_FAIL check(s) didn't pass."
    say "Common fixes:"
    say "  - Give it a minute and re-run me — the services can take a moment to boot."
    say "  - Make sure Tailscale is connected (open the app)."
    say "  - On macOS, you may need to allow the background services when prompted."
    exit 1
  fi
fi

# ---- STEP 8: handoff (URL + QR) ---------------------------------------------
say ""; say "${C_BOLD}You're set — open it on your phone${C_RESET}"
URL="http://${TS_IP:-127.0.0.1}:8090"
say ""
say "${C_BOLD}${C_GREEN}  $URL${C_RESET}"
say ""
if have qrencode; then
  qrencode -t ANSIUTF8 "$URL" 2>/dev/null || true
  say ""
fi
say "On your phone: open this link, then Share > Add to Home Screen."
say "(Make sure the Tailscale app on your phone is signed in and connected.)"
say ""
ok "Setup complete."
exit 0
