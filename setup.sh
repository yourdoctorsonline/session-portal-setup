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
creds_ok() { [ -f "$1/.credentials.json" ]; }

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
  if ! have brew; then
    say "Installing Homebrew (the tool that installs other tools)..."
    run "installing Homebrew" /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # bring brew onto PATH for the rest of this run (Apple Silicon vs Intel)
    if [ "${SETUP_DRYRUN:-0}" != "1" ]; then
      if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
  else
    ok "Homebrew already installed."
  fi
  for tool in tmux ttyd qrencode; do
    if have "$tool"; then
      ok "$tool already installed."
    else
      run "installing $tool" brew install "$tool"
    fi
  done
elif [ "$PLATFORM" = "wsl" ]; then
  MISSING=""
  for tool in tmux ttyd python3 qrencode; do
    have "$tool" || MISSING="$MISSING $tool"
  done
  if [ -n "$MISSING" ]; then
    run "updating package lists" sudo apt-get update -qq
    run "installing$MISSING" sudo apt-get install -y $MISSING
  else
    ok "tmux, ttyd, python3, qrencode already installed."
  fi
  if ! have ttyd; then
    warn "ttyd still isn't available from apt on this system."
    say "Try installing it via snap instead, then re-run me:"
    say "  sudo snap install ttyd --classic"
  fi
fi

# ---- STEP 3: Claude Code install + login ------------------------------------
step_banner 3 "Installing Claude Code and signing in"
if have claude; then
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
  claude < /dev/tty > /dev/tty 2>&1 || true
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
  CLAUDE_CONFIG_DIR="$ACC_DIR" claude < /dev/tty > /dev/tty 2>&1 || true
  if creds_ok "$ACC_DIR"; then
    ok "'$ACC_NAME' signed in."
  else
    warn "That one didn't finish signing in — you can re-run me later to add it."
  fi
done

# ---- STEP 5: Tailscale (AC-TI-007) ------------------------------------------
step_banner 5 "Setting up Tailscale (your private network)"
if [ "$PLATFORM" = "mac" ]; then
  if ! have tailscale; then
    run "installing Tailscale" brew install --cask tailscale
  else
    ok "Tailscale already installed."
  fi
  run "opening Tailscale" open -a Tailscale
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
    run "enabling systemd in WSL" sudo tee /etc/wsl.conf >/dev/null <<'WSLCONF'
[boot]
systemd=true
WSLCONF
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

# Engineering harness skill (build conductor + learning tripwire) — optional
# payload; present in repo layouts that ship harness/.
if [ -d "$SRC/harness" ]; then
  SKILL_DIR="$HOME/.claude/skills/eng-harness"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install the engineering harness skill to $SKILL_DIR"
  else
    mkdir -p "$SKILL_DIR"
    if cp -R "$SRC/harness/." "$SKILL_DIR/" 2>/dev/null; then
      chmod +x "$SKILL_DIR"/scripts/*.sh 2>/dev/null || true
      ok "Engineering harness skill installed (with learning tripwire)"
    else
      warn "Couldn't install the engineering harness skill — portal still works."
    fi
  fi
fi

if [ "$PLATFORM" = "mac" ]; then
  LA_DIR="$HOME/Library/LaunchAgents"
  run "creating $LA_DIR" mkdir -p "$LA_DIR"
  for label in com.sessionlauncher.terminal com.sessionlauncher.dashboard; do
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
    sed "s|__HOME__|$HOME|g" "$TPL" > "$PLIST"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
      && ok "Loaded $label" \
      || warn "Couldn't load $label — you may need to grant permission and re-run."
  done
elif [ "$PLATFORM" = "wsl" ]; then
  SD_DIR="$HOME/.config/systemd/user"
  run "creating $SD_DIR" mkdir -p "$SD_DIR"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install session-terminal.service + session-dashboard.service and enable them"
  else
    cp "$SRC"/templates/session-terminal.service "$SD_DIR"/ 2>/dev/null || true
    cp "$SRC"/templates/session-dashboard.service "$SD_DIR"/ 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now session-terminal session-dashboard 2>/dev/null \
      && ok "Portal services enabled" \
      || warn "Couldn't enable the portal services automatically."
  fi
fi

# ---- STEP 6b: workspace folder (AC-TI-009) ----------------------------------
step_banner 7 "Choosing your projects folder"
CUR_WS=""
[ -f "$ENV_FILE" ] && CUR_WS="$(grep '^WORKSPACE_ROOT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
ask WSROOT "Where do your project folders live?" "${CUR_WS:-$HOME/repos}"
run "creating $WSROOT" mkdir -p "$WSROOT"
if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would save WORKSPACE_ROOT=$WSROOT to $ENV_FILE"
else
  upsert_env WORKSPACE_ROOT "$WSROOT" "$ENV_FILE"
  ok "Saved your projects folder: $WSROOT"
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
