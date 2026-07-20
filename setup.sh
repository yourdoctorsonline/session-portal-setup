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
  # step_banner TITLE  (step count varies by preset, so no "N of M")
  printf '\n%s%s— %s —%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
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

# normalize_preset RAW -> echoes canonical full|harness|portal (rc 0); else nothing (rc 1).
# Accepts the menu numbers 1/2/3 or the names, case-insensitive.
normalize_preset() {
  local r
  r="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')"
  case "$r" in
    1|full)    echo "full";    return 0 ;;
    2|harness) echo "harness"; return 0 ;;
    3|portal)  echo "portal";  return 0 ;;
    *)         return 1 ;;
  esac
}

# preset_wants PRESET COMPONENT -> rc 0 if that preset installs that component.
# full = everything; harness = only the YDO Agentic Harness; portal = everything
# except the harness and extra-account sign-in.
preset_wants() {
  local p="$1" c="$2"
  case "$p" in
    full) return 0 ;;
    harness) [ "$c" = "harness" ] && return 0 ; return 1 ;;
    portal)
      case "$c" in
        tools|signin|tailscale|portal|workspace) return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# any_creds -> rc 0 if a completed Claude login exists in ~/.claude OR any ~/.claude-*
# config dir (multi-account setups keep the primary login outside ~/.claude).
any_creds() {
  creds_ok "$HOME/.claude" && return 0
  local d
  for d in "$HOME"/.claude-*; do
    [ -d "$d" ] && creds_ok "$d" && return 0
  done
  return 1
}

# ws_repo_state DIR -> echoes what to do with the shared-workspace target dir:
#   pull     = DIR is already the your-doctors-online repo (has .git + that remote)
#   occupied = DIR exists and is non-empty but is NOT that repo (don't touch it)
#   clone    = DIR is absent or empty (safe to clone into)
ws_repo_state() {
  local d="$1"
  # Match the EXACT org/repo at a boundary (optional .git, then space/end) so a fork
  # (someone/your-doctors-online) or look-alike (…-online-DIFFERENT) is NOT treated as
  # the canonical workspace.
  if [ -d "$d/.git" ] && git -C "$d" remote -v 2>/dev/null \
       | grep -Eq "yourdoctorsonline/your-doctors-online(\.git)?([[:space:]]|$)"; then
    echo pull
  elif [ -e "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    echo occupied
  else
    echo clone
  fi
}

# tsip — first line of `tailscale ip -4`, probing the usual install locations
# because a piped-in installer inherits a bare PATH.
# ts_bin -> echoes a usable tailscale CLI path, or nothing (rc 1). Checks the macOS
# GUI app's IN-BUNDLE binary FIRST (the common case — the menu-bar app doesn't put
# `tailscale` on PATH), then Homebrew locations, then PATH. Overridable for tests via
# SETUP_FAKE_TSAPP (a dir standing in for /Applications/Tailscale.app).
ts_bin() {
  local c
  for c in \
    "${SETUP_FAKE_TSAPP:-/Applications/Tailscale.app}/Contents/MacOS/Tailscale" \
    /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /usr/bin/tailscale \
    "$(command -v tailscale 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# tsip — the tailnet IPv4, via whichever tailscale CLI ts_bin resolves (empty if none/down).
tsip() {
  local ts
  ts="$(ts_bin)" || return 0
  "$ts" ip -4 2>/dev/null | head -1
}

# wire_global_hooks SETTINGS_FILE HOOKS_DIR
# Idempotently merge the two enforcement hooks into a global Claude settings.json:
# merge-gate on PreToolUse[Bash] and precompact-run-snapshot on PreCompact. Uses a
# python3 stdlib-json merge — preserves every existing key/hook, and adds each entry
# only if its script basename isn't already wired (so re-running is safe). Writes
# atomically (temp + os.replace) so a crash can't corrupt the file.
# rc: 0 = wired or already-present · 3 = python3 missing OR settings.json isn't valid
# JSON · other nonzero = write error. Callers treat any nonzero as "warn + wire by hand".
wire_global_hooks() {
  local settings="$1" hooks_dir="$2"
  have python3 || return 3
  python3 - "$settings" "$hooks_dir" <<'PY'
import json, os, sys
settings, hooks_dir = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(settings) and os.path.getsize(settings) > 0:
    try:
        with open(settings) as f:
            data = json.load(f)
    except Exception:
        print("INVALID_JSON", file=sys.stderr); sys.exit(3)
if not isinstance(data, dict):
    print("INVALID_JSON", file=sys.stderr); sys.exit(3)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}; data["hooks"] = hooks

def has_cmd(section, needle):
    for g in (hooks.get(section) or []):
        if not isinstance(g, dict):
            continue
        for h in (g.get("hooks") or []):
            if isinstance(h, dict) and needle in (h.get("command") or ""):
                return True
    return False

def section_list(name):
    v = hooks.get(name)
    if not isinstance(v, list):
        v = []; hooks[name] = v
    return v

changed = False
mg = 'python3 "%s"' % os.path.join(hooks_dir, "merge-gate.py")
pc = 'python3 "%s"' % os.path.join(hooks_dir, "precompact-run-snapshot.py")
if not has_cmd("PreToolUse", "merge-gate.py"):
    section_list("PreToolUse").append(
        {"matcher": "Bash", "hooks": [{"type": "command", "command": mg}]})
    changed = True
if not has_cmd("PreCompact", "precompact-run-snapshot.py"):
    section_list("PreCompact").append(
        {"hooks": [{"type": "command", "command": pc}]})
    changed = True

if changed:
    os.makedirs(os.path.dirname(settings) or ".", exist_ok=True)
    tmp = "%s.tmp.%d" % (settings, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2); f.write("\n")
    os.replace(tmp, settings)
    print("WIRED")
else:
    print("NOOP")
PY
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
say "This sets up Claude Code tooling on your machine. Pick what you want below."
say "It's safe to re-run: anything already done gets skipped."

# ---- preset: choose what to install -----------------------------------------
# SETUP_PRESET=full|harness|portal skips the menu (also lets DRYRUN pick full).
PRESET=""
if [ -n "${SETUP_PRESET:-}" ]; then
  PRESET="$(normalize_preset "$SETUP_PRESET")" || PRESET=""
  [ -n "$PRESET" ] || warn "SETUP_PRESET='$SETUP_PRESET' isn't valid — showing the menu."
fi
if [ -z "$PRESET" ]; then
  say ""
  say "${C_BOLD}What do you want to set up?${C_RESET}"
  say ""
  say "  ${C_BOLD}1) Full Session Launcher${C_RESET}"
  say "     Run Claude Code from your phone over your private network, plus the YDO"
  say "     Agentic Harness. Installs tmux/ttyd, signs you in, sets up Tailscale, the"
  say "     phone portal, and the harness. (The whole thing.)"
  say ""
  say "  ${C_BOLD}2) YDO Agentic Harness only${C_RESET}"
  say "     Just the build-discipline harness for Claude Code: the spec -> plan ->"
  say "     build -> verify -> ship skill plus its merge-gate and compaction hooks,"
  say "     wired into your global Claude settings. No sign-in, no Tailscale, no portal."
  say ""
  say "  ${C_BOLD}3) Portal only${C_RESET}"
  say "     The phone-reachable portal, without the harness."
  say ""
  while [ -z "$PRESET" ]; do
    ask _PCHOICE "Choose 1, 2, or 3" "1"
    PRESET="$(normalize_preset "$_PCHOICE")" || PRESET=""
    [ -n "$PRESET" ] || warn "Please type 1, 2, or 3."
  done
fi
case "$PRESET" in
  full)    PRESET_LABEL="Full Session Launcher" ;;
  harness) PRESET_LABEL="YDO Agentic Harness only" ;;
  portal)  PRESET_LABEL="Portal only" ;;
esac
say ""
ok "Installing: $PRESET_LABEL"

# ---- STEP 1: machine check --------------------------------------------------
# Runs BEFORE anything touches the disk or network (AC-TI-003: an unsupported
# machine must get the Windows/WSL guidance and exit 2 with zero side effects).
step_banner "Checking your machine"
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
if preset_wants "$PRESET" tools; then
step_banner "Installing the basic tools"
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
else
  say "  [skip] basic tools — not needed for: $PRESET_LABEL"
fi

# ---- STEP 3: Claude Code install + sign-in ----------------------------------
# Install the CLI only for presets that RUN it live (portal/full). The harness preset
# just needs it present (the skill + hooks land under ~/.claude either way), so it
# warns-if-absent rather than doing a network install — keeping "harness only" to
# exactly the skill + hooks. Sign-in is a SEPARATE, resilient step.
if preset_wants "$PRESET" signin; then
  step_banner "Installing Claude Code"
  if have claude; then
    ok "Claude Code already installed."
  elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install Claude Code."
  else
    say "Installing Claude Code..."
    run "installing Claude Code" /bin/bash -c "curl -fsSL https://claude.ai/install.sh | bash"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) : ;;
      *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
    esac
  fi
  if ! have claude && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
    warn "Claude Code isn't on PATH yet — if later steps can't find it, open a new"
    say  "  terminal (or add ~/.local/bin to your PATH) and re-run me."
  fi
elif preset_wants "$PRESET" harness && ! have claude && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
  warn "Claude Code isn't installed. The YDO Agentic Harness installs into your Claude"
  say  "  config, but you need Claude Code to use it — install it from"
  say  "  https://claude.ai/download  (or  curl -fsSL https://claude.ai/install.sh | bash)."
fi

if preset_wants "$PRESET" signin; then
  step_banner "Signing in to Claude"
  if any_creds; then
    ok "You're already signed in to Claude."
  elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would sign in to Claude (interactive)."
  elif [ ! -r /dev/tty ]; then
    # No controlling terminal (piped without a tty) is exactly when the CLI crashes on
    # process.stdout.isTTY — DON'T launch it. Guide instead, and continue.
    warn "Can't open an interactive sign-in here (no terminal attached)."
    say  "  Run  claude  yourself in a normal terminal, sign in, type /exit, then"
    say  "  re-run me. Continuing with everything that doesn't need sign-in."
  else
    say ""
    say "Claude will open now. Sign in, then type  /exit  to come back here."
    say "(Press Enter when you're ready.)"
    read -r _ < /dev/tty 2>/dev/null || true
    claude < /dev/tty > /dev/tty 2>&1 || true
    if any_creds; then
      ok "Signed in to Claude."
    else
      # Non-fatal: a failed / crashed sign-in must NOT abort the whole install.
      warn "It doesn't look like the sign-in finished."
      say  "  Run  claude  yourself (in your normal terminal / with your account"
      say  "  switcher), sign in, type /exit, then re-run me. Continuing for now."
    fi
  fi
fi

# ---- STEP 4: extra accounts loop (AC-TI-005) --------------------------------
if preset_wants "$PRESET" accounts; then
step_banner "Adding extra Claude accounts (optional)"
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
else
  say "  [skip] extra accounts — not needed for: $PRESET_LABEL"
fi

# ---- STEP 5: Tailscale (AC-TI-007) ------------------------------------------
TS_IP=""
if preset_wants "$PRESET" tailscale; then
step_banner "Setting up Tailscale (your private network)"
if [ "$PLATFORM" = "mac" ]; then
  # Prefer the menu-bar app (easiest sign-in). Install it only if neither the app nor a
  # command-line tailscale already exists.
  if [ ! -e "/Applications/Tailscale.app" ] && ! have tailscale && [ -z "$(ts_bin)" ]; then
    run "installing Tailscale (menu-bar app)" brew install --cask tailscale
  fi
  if [ -e "/Applications/Tailscale.app" ]; then
    run "opening Tailscale" open -a Tailscale
    ok "Tailscale app opened — its icon is in the top-right menu bar."
  elif [ -n "$(ts_bin)" ]; then
    ok "Tailscale (command-line) is installed."
  else
    warn "Couldn't install Tailscale automatically — get it from https://tailscale.com/download, then re-run me."
  fi
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

# Sign in / bring the connection up if we don't have an address yet.
if [ -z "$(tsip)" ] && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
  TS_BIN="$(ts_bin)"
  if [ "$PLATFORM" = "mac" ] && [ -e "/Applications/Tailscale.app" ]; then
    # GUI app: sign-in is a menu-bar click. Nudge the browser login too (best-effort).
    [ -n "$TS_BIN" ] && "$TS_BIN" up >/dev/null 2>&1 &
    say ""
    say "  ${C_BOLD}Sign in to Tailscale on your Mac:${C_RESET}"
    say "    1. Click the Tailscale icon in the top-right menu bar (near the clock)."
    say "    2. Choose 'Log in...' and sign in with the SAME account as your phone."
    say "  A browser tab may open on its own — if it does, just sign in there."
  elif [ "$PLATFORM" = "mac" ] && [ -n "$TS_BIN" ]; then
    # Command-line variant: make sure the background service runs, then sign in.
    "$TS_BIN" status >/dev/null 2>&1 \
      || run "starting the Tailscale service" sudo "${TS_BIN%/*}/tailscaled" install-system-daemon 2>/dev/null || true
    say ""
    say "  Signing in to Tailscale — open the link it prints below and sign in:"
    sudo "$TS_BIN" up 2>&1 | sed 's/^/    /' || true
  elif [ "$PLATFORM" = "wsl" ]; then
    run "connecting to Tailscale" sudo tailscale up
  fi
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
  say "Waiting for Tailscale to connect (sign in on the Mac if you haven't yet)..."
  TS_IP=""
  for i in $(seq 1 90); do
    TS_IP="$(tsip)"
    [ -n "$TS_IP" ] && break
    if [ "$i" = "30" ]; then
      say "  ...still waiting. If you haven't: click the Tailscale menu-bar icon and choose 'Log in...'."
    fi
    sleep 2
  done
  if [ -z "$TS_IP" ]; then
    warn "Tailscale isn't connected yet."
    say "  Finish signing in on the Mac (Tailscale menu-bar icon -> Log in, same account as"
    say "  your phone), then re-run me — it's safe to re-run and picks up right here."
    exit 1
  fi
  ok "Tailscale connected — your address is $TS_IP"
fi
else
  say "  [skip] Tailscale — not needed for: $PRESET_LABEL"
fi

# ---- STEP 6: portal + harness install ---------------------------------------
if preset_wants "$PRESET" portal; then
step_banner "Installing the portal"
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
else
  say "  [skip] phone portal — not needed for: $PRESET_LABEL"
fi

# YDO Agentic Harness — the build-discipline skill (spec -> plan -> build -> verify
# -> ship + learning tripwire). Only when the preset asks for it.
if preset_wants "$PRESET" harness && [ -d "$SRC/harness" ]; then
  step_banner "Installing the YDO Agentic Harness"
  SKILL_DIR="$HOME/.claude/skills/eng-harness"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install the YDO Agentic Harness to $SKILL_DIR"
  else
    mkdir -p "$SKILL_DIR"
    if cp -R "$SRC/harness/." "$SKILL_DIR/" 2>/dev/null; then
      chmod +x "$SKILL_DIR"/scripts/*.sh 2>/dev/null || true
      ok "YDO Agentic Harness installed (skill + learning tripwire)"
    else
      warn "Couldn't install the YDO Agentic Harness skill."
    fi
  fi
fi

# Enforcement hooks (merge-gate + compaction snapshot) — dropped into the user-level
# hooks dir and wired into the global ~/.claude/settings.json so the harness gates
# fire in every project this teammate opens. Fail-open: if we can't copy or wire them,
# the skill still lands and we print the two lines to add by hand.
if preset_wants "$PRESET" harness && [ -d "$SRC/harness/hooks" ]; then
  USER_HOOKS="$HOME/.claude/hooks"
  SETTINGS="$HOME/.claude/settings.json"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install enforcement hooks to $USER_HOOKS and wire them into $SETTINGS"
  else
    mkdir -p "$USER_HOOKS"
    if cp "$SRC"/harness/hooks/*.py "$USER_HOOKS"/ 2>/dev/null; then
      chmod +x "$USER_HOOKS"/*.py 2>/dev/null || true
      if wire_global_hooks "$SETTINGS" "$USER_HOOKS" >/dev/null 2>&1; then
        ok "Enforcement hooks wired (merge gate + compaction snapshot)"
      else
        warn "Couldn't auto-wire the enforcement hooks into $SETTINGS."
        say  "  Add these two hooks yourself in Claude Code, or re-run me:"
        say  "    PreToolUse (matcher Bash):  python3 \"$USER_HOOKS/merge-gate.py\""
        say  "    PreCompact:                 python3 \"$USER_HOOKS/precompact-run-snapshot.py\""
      fi
    else
      warn "Couldn't copy the enforcement hooks — the harness skill still works."
    fi
  fi
fi

if preset_wants "$PRESET" portal; then
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
fi

# ---- STEP 6b: workspace folder (AC-TI-009) ----------------------------------
if preset_wants "$PRESET" workspace; then
step_banner "Choosing your projects folder"
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
else
  say "  [skip] projects folder — not needed for: $PRESET_LABEL"
fi

# ---- shared YDO Agentic OS workspace repo -----------------------------------
# Offered on every preset: clone yourdoctorsonline/your-doctors-online if absent, or
# git-pull it if already present. Private repo → needs the teammate's GitHub access;
# fail-open on decline/auth/tooling (warn + manual command, never abort).
# SETUP_WORKSPACE_REPO=0 (or answering n) skips it non-interactively.
if [ "${SETUP_WORKSPACE_REPO:-1}" = "1" ]; then
  step_banner "Shared YDO workspace"
  WS_DEFAULT="$HOME/your-doctors-online"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would offer to clone/update yourdoctorsonline/your-doctors-online into $WS_DEFAULT"
  else
    ask _WSREPO "Set up the shared YDO Agentic OS workspace (yourdoctorsonline/your-doctors-online)? [Y/n]" "Y"
    case "$_WSREPO" in
      [Nn]*) say "  [skip] shared workspace — you can clone it later." ;;
      *)
        ask WS_DIR "Where should it live?" "$WS_DEFAULT"
        case "$(ws_repo_state "$WS_DIR")" in
          pull)
            say "Updating the workspace at $WS_DIR ..."
            if git -C "$WS_DIR" pull --ff-only 2>/dev/null; then
              ok "Workspace updated (fast-forward)."
            else
              warn "Couldn't fast-forward the workspace (local changes?). Update it yourself:"
              say  "  git -C \"$WS_DIR\" pull"
            fi ;;
          occupied)
            warn "$WS_DIR already exists and isn't the workspace repo — leaving it alone."
            say  "  Pick another folder and re-run, or clone it manually:"
            say  "  gh repo clone yourdoctorsonline/your-doctors-online" ;;
          clone)
            say "Cloning yourdoctorsonline/your-doctors-online into $WS_DIR ..."
            if have gh && gh repo clone yourdoctorsonline/your-doctors-online "$WS_DIR" 2>/dev/null; then
              ok "Workspace cloned to $WS_DIR"
            elif have git && GIT_TERMINAL_PROMPT=0 git clone https://github.com/yourdoctorsonline/your-doctors-online.git "$WS_DIR" 2>/dev/null; then
              ok "Workspace cloned to $WS_DIR"
            else
              warn "Couldn't clone the workspace (it's private — needs your GitHub access)."
              say  "  Sign in to GitHub, then run:"
              say  "    gh repo clone yourdoctorsonline/your-doctors-online \"$WS_DIR\""
              say  "  (or  git clone https://github.com/yourdoctorsonline/your-doctors-online.git \"$WS_DIR\")"
            fi ;;
        esac ;;
    esac
  fi
fi

# ---- verify checklist (only what this preset installed) ---------------------
step_banner "Checking everything works"
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
  say "DRYRUN: would run the checks relevant to: $PRESET_LABEL"
else
  if preset_wants "$PRESET" tools; then
    have tmux && check "tmux is installed ($(tmux -V 2>/dev/null))" 1 || check "tmux is installed" 0
  fi
  if preset_wants "$PRESET" signin; then
    any_creds && check "signed in to Claude" 1 || check "signed in to Claude (finish manually, then re-run)" 0
  fi
  if preset_wants "$PRESET" harness; then
    [ -d "$HOME/.claude/skills/eng-harness" ] \
      && check "YDO Agentic Harness skill installed" 1 \
      || check "YDO Agentic Harness skill installed" 0
    if grep -q "merge-gate.py" "$HOME/.claude/settings.json" 2>/dev/null; then
      check "harness hooks wired into ~/.claude/settings.json" 1
    else
      check "harness hooks wired into ~/.claude/settings.json" 0
    fi
  fi
  if preset_wants "$PRESET" tailscale; then
    [ -n "$TS_IP" ] && check "Tailscale connected ($TS_IP)" 1 || check "Tailscale connected" 0
  fi
  if preset_wants "$PRESET" portal; then
    # ttyd :7681 and dashboard :8090 bind the tailnet IP, so curl that.
    HOST="${TS_IP:-127.0.0.1}"
    port_up() {
      local port="$1" i
      for i in $(seq 1 15); do
        if curl -s -o /dev/null -m 3 "http://$HOST:$port" 2>/dev/null; then return 0; fi
        sleep 2
      done
      return 1
    }
    port_up 7681 && check "terminal service is live (port 7681)" 1 || check "terminal service is live (port 7681)" 0
    port_up 8090 && check "dashboard service is live (port 8090)" 1 || check "dashboard service is live (port 8090)" 0
    if curl -s -m 3 "http://$HOST:8090/api/accounts" 2>/dev/null | grep -q '"default"'; then
      check "dashboard lists your default account" 1
    else
      check "dashboard lists your default account" 0
    fi
  fi

  if [ "$CHECK_FAIL" != "0" ]; then
    say ""
    warn "$CHECK_FAIL check(s) didn't pass (the install still finished)."
    say "Common fixes:"
    say "  - Give it a minute and re-run me — services can take a moment to boot."
    say "  - Make sure Tailscale is connected (open the app)."
    say "  - On macOS, allow the background services when prompted."
    say "  - If sign-in didn't take, run  claude  yourself, sign in, then re-run me."
  fi
fi

# ---- handoff (tailored to the preset) ---------------------------------------
say ""
if preset_wants "$PRESET" portal; then
  say "${C_BOLD}Portal ready — open it on your phone${C_RESET}"
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
fi
if preset_wants "$PRESET" harness; then
  say "${C_BOLD}YDO Agentic Harness is installed.${C_RESET}"
  say "It's active in every project you open with Claude Code — build work routes"
  say "through spec -> plan -> build -> verify -> ship, and the merge-gate + compaction"
  say "hooks are wired into ~/.claude/settings.json."
  say ""
fi
ok "Setup complete."
exit 0
