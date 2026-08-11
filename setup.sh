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
  # No controlling terminal: we cannot prompt. Take the default, but make it VISIBLE —
  # silently defaulting the preset menu to a full install is an unconsented install.
  if ! has_tty; then
    [ -n "$__default" ] && warn "No terminal to ask \"$__prompt\" — using default: $__default"
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

# has_tty — rc 0 iff a controlling terminal can actually be OPENED. `[ -r /dev/tty ]` is
# wrong: the 0666 tty inode is always "readable" even under setsid/automation with no
# controlling terminal — only OPENING it proves one exists. SETUP_FAKE_TTY overrides for
# tests (1=present, 0=absent).
has_tty() {
  if [ -n "${SETUP_FAKE_TTY:-}" ]; then [ "$SETUP_FAKE_TTY" = "1" ]; return; fi
  ( exec 3</dev/tty ) 2>/dev/null
}

# macos_keychain_creds — rc 0 iff the macOS login Keychain holds a completed Claude login
# ("Claude Code-credentials"). macOS stores the DEFAULT account's token HERE, not in a
# .credentials.json file, so a file-only check false-negatives a signed-in default account
# (the Session-3 "sign-in never detected" bug). SETUP_FAKE_KEYCHAIN overrides for tests.
macos_keychain_creds() {
  if [ -n "${SETUP_FAKE_KEYCHAIN:-}" ]; then [ "$SETUP_FAKE_KEYCHAIN" = "1" ]; return; fi
  [ "${SETUP_FAKE_UNAME:-$(uname -s)}" = "Darwin" ] || return 1
  security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1
}

# creds_ok DIR — rc 0 iff DIR has a completed Claude login. File first (works on Linux and
# for cswap's per-account ~/.claude-* dirs); for the macOS DEFAULT dir, also accept the
# Keychain entry (the real store there).
creds_ok() {
  local dir="$1"
  [ -f "$dir/.credentials.json" ] && return 0
  [ "$dir" = "$HOME/.claude" ] && macos_keychain_creds && return 0
  return 1
}

# brew_bin -> echoes a usable Homebrew path, or nothing (rc 1). Checks the real install
# locations (Apple-Silicon /opt/homebrew, Intel /usr/local) even when brew isn't on PATH
# — the #1 cause of "brew: command not found" mid-install. Overridable via SETUP_FAKE_BREW.
brew_bin() {
  local c
  for c in "${SETUP_FAKE_BREW:-/opt/homebrew/bin/brew}" /usr/local/bin/brew "$(command -v brew 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# ensure_brew_on_path BREW [ZPROFILE] — idempotently persist a `brew shellenv` line to the
# login profile so brew stays on PATH in future shells (heals the "command not found"
# permanently, no manual PATH edit). A second call is a no-op.
ensure_brew_on_path() {
  local brew="$1" zp="${2:-$HOME/.zprofile}" bp="${3:-}" line
  # NB `$(...)` strips the trailing newline, so re-add it with '%s\n' on append — otherwise the
  # next `echo … >> profile` (Homebrew's own installer, nvm, the user) glues onto the eval line.
  line=$(printf '\n# Added by Session Launcher setup\neval "$(%s shellenv)"' "$brew")
  # zsh login profile — always.
  grep -q 'brew shellenv' "$zp" 2>/dev/null || printf '%s\n' "$line" >> "$zp"
  # bash login profile — append to the file bash ACTUALLY reads, WITHOUT shadowing an existing
  # one. Bash reads only the FIRST of .bash_profile/.bash_login/.profile, so blindly creating
  # ~/.bash_profile when the user keeps their env in ~/.profile would silently disable ~/.profile.
  if [ -n "$bp" ]; then
    :                                              # explicit test override
  elif [ -f "$HOME/.bash_profile" ]; then bp="$HOME/.bash_profile"
  elif [ -f "$HOME/.bash_login" ];   then bp="$HOME/.bash_login"
  elif [ -f "$HOME/.profile" ];      then bp="$HOME/.profile"   # append here, don't shadow it
  else bp="$HOME/.bash_profile"; fi                # nothing exists → safe to create
  grep -q 'brew shellenv' "$bp" 2>/dev/null || printf '%s\n' "$line" >> "$bp"
}

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

# aos_repo_state DIR -> echoes what to do with the Agentic OS target dir:
#   pull     = DIR is already the yourdoctorsonline/agentic-os repo (.git + that remote)
#   occupied = DIR exists and is non-empty but is NOT that repo (don't touch it)
#   clone    = DIR is absent or empty (safe to clone into)
#
# Renamed from ws_repo_state and repointed 2026-08-10: the shared your-doctors-online
# workspace is no longer installed at all, but this function's look-alike guard is the
# valuable part and is kept rather than hand-rolled again at the call site.
# "occupied" matters most on the upstream template — a teammate who already cloned
# simonc602/agentic-os into ~/repos/agentic-os must NOT have it silently pulled over.
aos_repo_state() {
  local d="$1"
  # Match the EXACT org/repo at a boundary (optional .git, then space/end) so a fork
  # (someone-else/agentic-os), the upstream (simonc602/agentic-os), or a look-alike
  # (…/agentic-os-DIFFERENT) is NOT treated as ours.
  if [ -d "$d/.git" ] && git -C "$d" remote -v 2>/dev/null \
       | grep -Eq "[/:]yourdoctorsonline/agentic-os(\.git)?([[:space:]]|$)"; then
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

# tsip — the tailnet IPv4 (empty if none/down). Prefers the FORMULA CLI (ts_cli_bin) so a
# migration machine whose GUI app was just quit still reads the formula daemon's address;
# only falls back to ts_bin (which may resolve the app bundle) when no formula CLI exists.
tsip() {
  local ts
  ts="$(ts_cli_bin)"
  [ -n "$ts" ] || ts="$(ts_bin)" || return 0
  [ -n "$ts" ] || return 0
  "$ts" ip -4 2>/dev/null | head -1
}

# tsd_bin -> echoes a usable tailscaled DAEMON path, or nothing (rc 1). CLI-only Tailscale:
# the Homebrew *formula* ships `tailscaled` next to `tailscale` (/opt/homebrew, /usr/local, PATH).
# Deliberately does NOT look inside /Applications/Tailscale.app — that's the GUI flavor we don't
# use. Overridable for tests via SETUP_FAKE_TAILSCALED.
tsd_bin() {
  local c
  for c in \
    "${SETUP_FAKE_TAILSCALED:-/opt/homebrew/bin/tailscaled}" \
    /usr/local/bin/tailscaled /usr/bin/tailscaled \
    "$(command -v tailscaled 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# ts_cli_bin -> echoes the real `tailscale` CLI client, or nothing (rc 1). Like ts_bin BUT
# deliberately skips /Applications/Tailscale.app — this is the resolver used to decide whether
# the CLI *formula* is installed, so that a machine left with the GUI app by an older installer
# still gets the formula (and is driven by it), not steered back onto the app. Overridable for
# tests via SETUP_FAKE_TSCLI.
ts_cli_bin() {
  local c
  for c in \
    "${SETUP_FAKE_TSCLI:-/opt/homebrew/bin/tailscale}" \
    /usr/local/bin/tailscale /usr/bin/tailscale \
    "$(command -v tailscale 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# claude_signin [CONFIG_DIR] — run the interactive Claude sign-in with a REAL pseudo-terminal.
# The Bun-compiled `claude` CLI dereferences process.stdout.isTTY and crashes
# (`TypeError: undefined is not an object`) when stdout isn't a TTY in the installer's launch
# context (curl|bash / .command double-click). `script(1)` allocates a PTY so isTTY is defined.
# macOS/BSD `script` takes the command as argv (`script -q /dev/null cmd args`); util-linux
# `script` needs `-c "cmd"`. Falls back to a bare launch if `script` is absent. Always returns 0
# — sign-in success is judged separately by any_creds/creds_ok. Uses /dev/tty for user I/O.
claude_signin() {
  local cfg="${1:-}" tty="${SETUP_TTY:-/dev/tty}"
  if have script; then
    case "${SETUP_FAKE_UNAME:-$(uname -s)}" in
      Darwin)
        if [ -n "$cfg" ]; then
          script -q /dev/null env CLAUDE_CONFIG_DIR="$cfg" claude <"$tty" >"$tty" 2>&1 || true
        else
          script -q /dev/null claude <"$tty" >"$tty" 2>&1 || true
        fi ;;
      *)
        # Pass the config dir through the ENVIRONMENT, never interpolated into the single-quoted
        # `script -c` string — otherwise a $HOME containing a single quote breaks/injects the
        # command. `script` inherits our env, so `claude` still sees CLAUDE_CONFIG_DIR.
        if [ -n "$cfg" ]; then
          CLAUDE_CONFIG_DIR="$cfg" script -qec 'claude' /dev/null <"$tty" >"$tty" 2>&1 || true
        else
          script -qec 'claude' /dev/null <"$tty" >"$tty" 2>&1 || true
        fi ;;
    esac
  else
    if [ -n "$cfg" ]; then
      env CLAUDE_CONFIG_DIR="$cfg" claude <"$tty" >"$tty" 2>&1 || true
    else
      claude <"$tty" >"$tty" 2>&1 || true
    fi
  fi
  return 0
}

# rustdesk_phone_guide [TAILNET_IP] — print how to reach THIS Mac from the RustDesk phone app.
# With a tailnet IP, steer the user to connect over Tailscale (private network) using that IP;
# otherwise fall back to the RustDesk relay ID. Pure output, no side effects (so tests can
# assert the text and the IP-vs-ID branch).
rustdesk_phone_guide() {
  local ip="${1:-}"
  say ""
  say "  ${C_BOLD}Remote in from your phone:${C_RESET}"
  say "    1. On this Mac, open RustDesk: it shows an ID, and lets you set a permanent"
  say "       password (Settings > Security > unattended access). Note the ID; set a password."
  say "    2. Install the RustDesk app on your phone (App Store / Google Play)."
  if [ -n "$ip" ]; then
    say "    3. Best over your private network: in the phone app's address box, enter this"
    say "       Mac's Tailscale IP  ${C_BOLD}${ip}${C_RESET}  (keep the Tailscale app connected"
    say "       on your phone), then the password. Or use the RustDesk ID from anywhere."
  else
    say "    3. In the phone app, enter this Mac's RustDesk ID, then the password."
  fi
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

# The two output gates. `oc` restates the plain-language + no-AI-tells contract
# on every prompt; `sg` reads what was actually written and BLOCKS the turn when
# it carries the banned tells. The second exists because the first alone failed:
# the rule was injected, read, and broken in the very next message. A rule the
# writer can ignore is a preference; a check that reads the output is a gate.
oc = 'python3 "%s"' % os.path.join(hooks_dir, "output-contract.py")
sg = 'python3 "%s"' % os.path.join(hooks_dir, "slop-gate.py")
if not has_cmd("UserPromptSubmit", "output-contract.py"):
    section_list("UserPromptSubmit").append(
        {"hooks": [{"type": "command", "command": oc}]})
    changed = True
if not has_cmd("Stop", "slop-gate.py"):
    section_list("Stop").append(
        {"hooks": [{"type": "command", "command": sg}]})
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

# expand_home PATH -> expand a leading ~ / ~/ to $HOME (the shell does NOT expand a tilde
# that arrives quoted from `read`, so `mkdir "~/projects"` would make a literal ~ folder).
expand_home() {
  case "$1" in
    "~")   printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# platform_help [SYS] -> machine-appropriate guidance for an unsupported platform. Native
# Linux (not WSL) gets a Linux-specific note; anything else gets the Windows/WSL2 steps.
# (Native Linux was previously told to run `wsl --install`, which is nonsense on Linux.)
platform_help() {
  local sys="${1:-${SETUP_FAKE_UNAME:-$(uname -s)}}"
  case "$sys" in
    Linux)
      say "This installer supports macOS and Windows (via WSL2 Ubuntu) today."
      say "Native Linux isn't supported yet — the portal's service wiring is Mac/WSL-specific."
      say "If you need a native-Linux path, open an issue on the session-portal-setup repo."
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Git Bash specifically. It LOOKS like a working bash — teammates paste the
      # mac one-liner into it and land here — but it is not WSL, so none of the
      # service wiring applies. Previously this fell into the generic Windows
      # branch, which told them to run `wsl --install` and then "paste this same
      # command", i.e. the bash one-liner. The PowerShell bootstrap already does
      # the whole WSL dance for them, so point at that instead.
      say "You're running Git Bash (MSYS/MINGW). This installer can't run here —"
      say "Git Bash isn't WSL, so the portal's service wiring has nothing to attach to."
      say ""
      say "Use the Windows installer instead. Open PowerShell (not Git Bash) and run:"
      say ""
      say "  irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex"
      say ""
      say "That sets up WSL2 for you if it's missing, then runs this installer inside it."
      ;;
    *)
      say "If you're on Windows, set up WSL2 first, then re-run this:"
      say "  1. Open PowerShell as Administrator (right-click > Run as administrator)"
      say "  2. Run:  wsl --install"
      say "  3. Restart your PC when it asks."
      say "  4. Open the 'Ubuntu' app from the Start menu and finish its first-time setup."
      say "  5. Paste this same install command into the Ubuntu window."
      ;;
  esac
}

# ensure_python3 -> make python3 available (the harness enforcement hooks need it). The
# harness-only preset skips the tools step, so on a fresh Mac python3 can be absent and the
# hooks silently fail to wire. Best-effort install; rc reflects whether python3 ended up present.
# python3_ok -> rc 0 iff a WORKING python3 runs. `have python3` (command -v) isn't enough on
# macOS: the /usr/bin/python3 Command-Line-Tools STUB is on PATH even with no CLT installed, so
# presence succeeds while execution fails. Test execution, not presence. SETUP_FAKE_PY3 overrides.
python3_ok() {
  if [ -n "${SETUP_FAKE_PY3:-}" ]; then [ "$SETUP_FAKE_PY3" = "1" ]; return; fi
  python3 -c '' >/dev/null 2>&1
}

ensure_python3() {
  python3_ok && return 0
  [ "${SETUP_DRYRUN:-0}" = "1" ] && return 0
  case "${SETUP_FAKE_UNAME:-$(uname -s)}" in
    Darwin)
      local brew; brew="$(brew_bin)"
      [ -n "$brew" ] && "$brew" install python3 </dev/null >/dev/null 2>&1 || true ;;
    *)
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 </dev/null >/dev/null 2>&1 || true ;;
  esac
  python3_ok
}

# wslconf_has_systemd FILE -> rc 0 iff FILE already enables systemd (so a re-run can skip the
# rewrite + forced `wsl --shutdown`). Tolerant of surrounding whitespace.
wslconf_has_systemd() {
  grep -Eqs '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' "$1" 2>/dev/null
}

# wslconf_render FILE -> emit the DESIRED /etc/wsl.conf content on stdout with [boot] systemd=true
# ensured and every existing section PRESERVED (the old `sudo tee` truncated the file, destroying
# any [automount]/[network] config — data loss). Pure filter: the caller handles the sudo write.
wslconf_render() {
  local f="$1"
  if [ ! -e "$f" ] || [ ! -s "$f" ]; then
    printf '[boot]\nsystemd=true\n'; return 0
  fi
  if ! grep -Eqs '^[[:space:]]*\[boot\]' "$f" 2>/dev/null; then
    # Common case (e.g. an [automount]-only file): NO [boot] section. Emit the existing content
    # verbatim — comments, blank lines, everything — then append a [boot] block. Zero loss.
    cat "$f"
    printf '\n[boot]\nsystemd=true\n'
    return 0
  fi
  # [boot] exists but doesn't set systemd=true → a surgical in-section edit is needed. python3
  # preferred (keys/sections preserved; inline comments may be dropped — rare, non-destructive).
  if [ -z "${SETUP_FORCE_AWK:-}" ] && have python3; then
    python3 - "$f" <<'PY'
import sys, configparser
cp = configparser.ConfigParser(); cp.optionxform = str
try:
    cp.read(sys.argv[1])
except Exception:
    sys.stdout.write(open(sys.argv[1]).read().rstrip() + "\n\n[boot]\nsystemd=true\n"); sys.exit(0)
if not cp.has_section("boot"):
    cp.add_section("boot")
cp.set("boot", "systemd", "true")
cp.write(sys.stdout)
PY
    return 0
  fi
  # no python3 (shouldn't happen on WSL after Step 2): awk pass-through that sets systemd=true
  # inside [boot], preserving all other content. Detects the header by PREFIX (tolerates an
  # inline comment) and REPLACES any existing systemd= line rather than appending a duplicate.
  awk '
    BEGIN { inboot=0; done=0 }
    /^[[:space:]]*\[/ {
      if (inboot && !done) { print "systemd=true"; done=1 }
      inboot = ($0 ~ /^[[:space:]]*\[boot\]/)
      print; next
    }
    {
      if (inboot && $0 ~ /^[[:space:]]*systemd[[:space:]]*=/) {
        if (!done) { print "systemd=true"; done=1 }
        next
      }
      print
    }
    END { if (inboot && !done) print "systemd=true" }
  ' "$f"
}

# admin_rights_ok -> can this account get admin/root via sudo at all?
# rc 0 = yes · rc 1 = no. Overridable for tests via SETUP_FAKE_ADMIN=1|0.
#
# This is a PRE-check, not an error handler. The Tailscale bring-up runs
# `sudo … up || true` on purpose — that command legitimately "fails" while the
# user finishes browser auth — so turning every non-zero into an error would
# break the normal path. What was missing is the case that can NEVER succeed:
# an account with no admin rights, which previously produced a silent sequence
# of failed sudo calls and then advice about opening an app that isn't installed.
admin_rights_ok() {
  case "${SETUP_FAKE_ADMIN:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  case "${SETUP_FAKE_UNAME:-$(uname -s)}" in
    Darwin) dseditgroup -o checkmember -m "$(whoami)" admin >/dev/null 2>&1 ;;
    *)      id -nG 2>/dev/null | tr ' ' '\n' | grep -qx -e sudo -e admin -e wheel ;;
  esac
}

# wslconf_install_ok SRC DST -> install SRC at DST, then VERIFY by reading DST
# back. rc 0 only when DST's content actually matches SRC.
# Test seam SETUP_FAKE_WSLCP: plain (ordinary cp) · fail (copy refuses) ·
# noop (copy claims success and writes nothing).
#
# The read-back is the point. The old code ran `sudo cp` through a wrapper whose
# status nobody checked and then printed "Almost there — one quick restart",
# so a refused write reported success and every re-run repeated it identically.
# A copy that exits 0 without landing is the same defect wearing a hat, which is
# why success is defined as "the destination now reads like the source" rather
# than "the copy command returned 0".
wslconf_install_ok() {
  local src="${1:-}" dst="${2:-}"
  [ -n "$src" ] && [ -n "$dst" ] || return 1
  # -s, not -f: an EMPTY source is never a valid wsl.conf, and copying it
  # TRUNCATES the destination to zero bytes while the read-back cheerfully
  # confirms the match — a guaranteed false success that also destroys the file.
  # Reachable: wslconf_render's python3 branch returns 0 without checking
  # python's exit status, so a failed render produces exactly this empty file.
  [ -s "$src" ] || return 1
  # Refuse a SYMLINKED destination. cp, chmod and the read-back all dereference,
  # so a symlink means writing through it as root, chmod'ing the link target,
  # and then verifying against the very file we were tricked into writing — the
  # check would be structurally incapable of disagreeing with itself.
  [ -L "$dst" ] && return 1
  case "${SETUP_FAKE_WSLCP:-}" in
    fail)  return 1 ;;
    noop)  : ;;
    plain) cp "$src" "$dst" 2>/dev/null || return 1 ;;
    *)     sudo cp "$src" "$dst" 2>/dev/null || return 1
           sudo chmod 644 "$dst" 2>/dev/null || true ;;
  esac
  # cmp, not string equality. `$( )` strips ALL trailing newlines from both
  # sides, so "a=1\n" and "a=1\n\n\n\n" compared EQUAL and the read-back
  # confirmed a file it had not written.
  if [ -r "$dst" ]; then cmp -s "$src" "$dst" || return 1
  else sudo cmp -s "$src" "$dst" 2>/dev/null || return 1; fi
  return 0
}

# ensure_workspace_dir DIR -> make sure DIR exists and is writable.
# rc 0 = usable · rc 1 = empty arg, or mkdir failed · rc 2 = exists, not writable.
# Extracted from the STEP 6b call site so it can be tested at all: everything
# below the sourcing guard is main flow and unreachable from test-setup.sh. The
# caller MUST check the status — this script runs under `set -u` with no `set -e`,
# so an unchecked failure here is what persisted a bad WORKSPACE_ROOT and then
# printed "Saved your projects folder" anyway.
ensure_workspace_dir() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  if [ ! -d "$d" ]; then
    mkdir -p "$d" 2>/dev/null || return 1
  fi
  [ -d "$d" ] || return 1
  [ -w "$d" ] || return 2
  return 0
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
    # AC-TI-003: unsupported platform — print the right guidance, change nothing, exit 2.
    # Native Linux gets a Linux-specific note; Windows/other gets the WSL2 steps.
    fail_msg "This doesn't look like a Mac or WSL2 Ubuntu."
    say ""
    platform_help
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
    if have curl && curl -fsSL --connect-timeout 15 --max-time 120 "$REPO_URL" -o "$DL_DIR/main.tar.gz" 2>/dev/null \
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
  BREW="$(brew_bin)"
  if [ -z "$BREW" ] && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
    # Xcode Command Line Tools are Homebrew's prerequisite. Trigger + WAIT for them so a
    # single run heals (fresh Macs don't have them; the only thing you do is click Install).
    if ! xcode-select -p >/dev/null 2>&1; then
      say "Your Mac needs Apple's Command Line Tools first — starting that now."
      run "requesting Command Line Tools" xcode-select --install 2>/dev/null || true
      say "A small Apple dialog should appear — click 'Install'. I'll wait for it to finish"
      say "(this can take several minutes)..."
      for _i in $(seq 1 120); do
        xcode-select -p >/dev/null 2>&1 && break
        printf '.'; sleep 10
      done
      say ""
      if ! xcode-select -p >/dev/null 2>&1; then
        warn "Command Line Tools still aren't ready. Finish the Apple dialog, then re-run me."
        exit 0
      fi
      ok "Command Line Tools installed."
    fi
    # Homebrew runs as YOU, never as root (it refuses root and aborts). The sudo it needs
    # is for its one-time folder setup DURING the install — so prime your password once now
    # and keep it fresh, then run the installer NON-interactively (no RETURN-keypress hang).
    say "Homebrew needs your Mac login password once to set itself up..."
    # No 2>/dev/null: sudo's "Password:" prompt must stay VISIBLE, or the step looks hung
    # while sudo silently blocks on tty input (the Session-3 "stuck at Homebrew" bug).
    sudo -v || true
    ( while sudo -n true 2>/dev/null; do sleep 50; kill -0 "$$" 2>/dev/null || break; done ) &
    _KA=$!
    say "Installing Homebrew (the tool that installs other tools)..."
    for _a in 1 2 3; do
      # </dev/null: under `curl … | bash` fd0 is the pipe carrying THIS script. If the
      # Homebrew installer reads stdin it drains the rest of the script and bash then
      # exits silently at EOF (the "stops right after the tools step" bug). Detach it.
      env NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null 2>&1 | sed 's/^/    /'
      BREW="$(brew_bin)"; [ -n "$BREW" ] && break
      warn "Homebrew attempt $_a didn't land — retrying..."
      sleep 3
    done
    kill "$_KA" 2>/dev/null || true
  fi
  if [ -n "$BREW" ]; then
    if [ "${SETUP_DRYRUN:-0}" != "1" ]; then
      eval "$("$BREW" shellenv)" 2>/dev/null || true   # this run's PATH
      ensure_brew_on_path "$BREW"                        # future shells (idempotent, no manual edit)
    fi
    ok "Homebrew ready."
  elif [ "${SETUP_DRYRUN:-0}" != "1" ]; then
    warn "Homebrew still isn't available. Install it from https://brew.sh, then re-run me."
  fi
  # tmux/ttyd/qrencode run the portal. The rest are what the SKILLS shell out to —
  # scanned from the shipped skill set, not guessed. Without them a teammate installs
  # cleanly, opens a skill, and hits "command not found" for a program they have never
  # heard of and cannot be expected to fix. Order matters only in that node comes
  # before the Playwright step below, which needs npx.
  for tool in tmux ttyd qrencode ffmpeg yt-dlp jq gh node python3; do
    if have "$tool"; then
      ok "$tool already installed."
    elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
      say "DRYRUN: would install $tool"
    elif [ -n "$BREW" ]; then
      # Install with up to 3 tries; re-apply shellenv + re-check between attempts so an
      # off-PATH or transient formula failure doesn't leave the tool missing. Never skip.
      _ok=0
      for _a in 1 2 3; do
        "$BREW" install "$tool" </dev/null 2>&1 | sed 's/^/    /'
        eval "$("$BREW" shellenv)" 2>/dev/null || true
        { have "$tool" || [ -x "$(dirname "$BREW")/$tool" ]; } && { _ok=1; break; }
        warn "$tool attempt $_a didn't land — refreshing and retrying..."
        "$BREW" update </dev/null >/dev/null 2>&1 || true
        sleep 2
      done
      [ "$_ok" = 1 ] && ok "$tool installed." \
        || warn "Couldn't install $tool after 3 tries. Run  \"$BREW\" install $tool  yourself, then re-run me."
    else
      warn "Can't install $tool — Homebrew isn't available (see the note above)."
    fi
  done
else
  :
fi

if [ "$PLATFORM" = "wsl" ]; then
  MISSING=""
  for tool in tmux ttyd python3 qrencode ffmpeg jq gh nodejs; do
    have "$tool" || MISSING="$MISSING $tool"
  done
  if [ -n "$MISSING" ]; then
    if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
      say "DRYRUN: would apt-get update && apt-get install -y$MISSING"
    else
      # </dev/null so apt can't drain the piped script (see the Homebrew note above).
      say "  updating package lists"
      sudo apt-get update -qq </dev/null || true
      say "  installing$MISSING"
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING </dev/null
    fi
  else
    ok "tmux, ttyd, python3, qrencode already installed."
  fi
  if ! have ttyd; then
    warn "ttyd still isn't available from apt on this system."
    say "Try installing it via snap instead, then re-run me:"
    say "  sudo snap install ttyd --classic"
  fi
fi
# ---- Playwright + its browser (AC-YTI-015) ----------------------------------
# Six shipped skills drive a headless browser: 00-social-content, eng-harness,
# mkt-brand-voice, mkt-visual-identity, viz-excalidraw-diagram, viz-image-gen.
# Playwright is an npm package AND a separate ~150 MB browser download; installing
# the package alone leaves every one of those skills failing at run time with an
# error about a missing executable. Both, or neither.
if preset_wants "$PRESET" tools; then
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would install Playwright + its Chromium browser (npx playwright install chromium)"
  elif have npx; then
    if npx --yes playwright install chromium </dev/null >/dev/null 2>&1; then
      ok "Playwright browser installed."
    else
      warn "Couldn't install the Playwright browser. Six skills that drive a browser"
      say  "  (social content, brand voice, diagrams, image gen, visual identity, the harness)"
      say  "  will fail until it lands. Retry with:  npx playwright install chromium"
    fi
  else
    warn "Skipping Playwright — npx isn't available (Node didn't install)."
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
    # </dev/null so the installer can't drain the piped script (see the Homebrew note).
    /bin/bash -c "curl -fsSL --connect-timeout 15 --max-time 120 https://claude.ai/install.sh | bash" </dev/null 2>&1 | sed 's/^/    /'
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
  elif ! has_tty; then
    # No controlling terminal (piped without a tty) is exactly when the CLI crashes on
    # process.stdout.isTTY — DON'T launch it. Guide instead, and continue. (has_tty OPENS
    # /dev/tty; `[ -r /dev/tty ]` was wrong — the 0666 inode reads as readable under setsid.)
    warn "Can't open an interactive sign-in here (no terminal attached)."
    say  "  Run  claude  yourself in a normal terminal, sign in, type /exit, then"
    say  "  re-run me. Continuing with everything that doesn't need sign-in."
  else
    say ""
    say "Claude will open now. Sign in, then type  /exit  to come back here."
    say "(Press Enter when you're ready.)"
    read -r _ < /dev/tty 2>/dev/null || true
    claude_signin
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
  claude_signin "$ACC_DIR"
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
  # CLI-only Tailscale: the Homebrew *formula* (a background `tailscaled` daemon + the
  # `tailscale` CLI), NOT the `--cask` menu-bar app. Login is a printed auth URL, so there's
  # nothing to click in a menu bar and no GUI app to install.
  # Migration: a machine left with the GUI app by an OLDER installer must still get the CLI —
  # so the presence check keys off the FORMULA CLI (ts_cli_bin), which never counts the app
  # bundle. If the app is present we surface it once (it's redundant now; user can remove it).
  if [ -e "/Applications/Tailscale.app" ] && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
    warn "You have the Tailscale menu-bar app installed (from an earlier setup)."
    say  "  This installer now uses the lightweight command-line Tailscale instead. To avoid"
    say  "  two copies fighting over the connection, I'll quit the app; you can delete it later"
    say  "  from Applications if you like."
    osascript -e 'quit app "Tailscale"' >/dev/null 2>&1 || true
  fi
  if [ -z "$(ts_cli_bin)" ]; then
    BREW="$(brew_bin)"
    if [ -n "$BREW" ] && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
      _ok=0
      for _a in 1 2 3; do
        # </dev/null so brew can't drain the piped script (see the Homebrew note in Step 2).
        "$BREW" install tailscale </dev/null 2>&1 | sed 's/^/    /'
        eval "$("$BREW" shellenv)" 2>/dev/null || true
        [ -n "$(ts_cli_bin)" ] && { _ok=1; break; }
        warn "Tailscale attempt $_a didn't land — refreshing and retrying..."
        "$BREW" update </dev/null >/dev/null 2>&1 || true
        sleep 2
      done
      [ "$_ok" = 1 ] && ok "Tailscale (CLI) installed." \
        || warn "Couldn't install the Tailscale CLI after 3 tries. Run  \"$BREW\" install tailscale  yourself, then re-run me."
    elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
      say "DRYRUN: would install the Tailscale CLI (brew install tailscale)"
    else
      warn "Can't install Tailscale without Homebrew — see the note above, then re-run me."
    fi
  else
    ok "Tailscale (CLI) already installed."
  fi
  # From here on, drive Tailscale through the FORMULA CLI (never the app bundle), so the
  # daemon we start and the client we bring up are the same CLI flavor.
  TS_BIN="$(ts_cli_bin)"
elif [ "$PLATFORM" = "wsl" ]; then
  if ! have tailscale; then
    if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
      say "DRYRUN: would install Tailscale (curl https://tailscale.com/install.sh | sh)"
    else
      # </dev/null so the installer can't drain the piped script (see the Homebrew note).
      /bin/bash -c "curl -fsSL --connect-timeout 15 --max-time 120 https://tailscale.com/install.sh | sh" </dev/null 2>&1 | sed 's/^/    /'
    fi
  else
    ok "Tailscale already installed."
  fi
  # Tailscale needs systemd; WSL only has it when [boot] systemd=true is set.
  if [ "${SETUP_DRYRUN:-0}" != "1" ] && ! systemctl --user show-environment >/dev/null 2>&1 \
       && ! systemctl is-system-running >/dev/null 2>&1; then
    # Snapshot the CURRENT wsl.conf into a user-readable temp first. It may be root-only-readable
    # (admin created it with a restrictive umask): a user-level read would then see an empty file
    # and the merge would truncate it. Read via sudo when we can't read it directly.
    _WSLCUR="$(mktemp "${TMPDIR:-/tmp}/wslcur.XXXXXX")"
    if [ -e /etc/wsl.conf ]; then
      if [ -r /etc/wsl.conf ]; then cat /etc/wsl.conf > "$_WSLCUR" 2>/dev/null
      else sudo cat /etc/wsl.conf > "$_WSLCUR" 2>/dev/null || true; fi
    fi
    if wslconf_has_systemd "$_WSLCUR"; then
      # Already configured — it just needs the one-time WSL restart to take effect. Don't
      # rewrite the file (and don't clobber other sections); just prompt the restart.
      warn "systemd is set in /etc/wsl.conf but WSL hasn't restarted to pick it up yet."
      rm -f "$_WSLCUR"
    else
      warn "WSL needs systemd turned on before Tailscale can run."
      # Preserve all existing content — the old `sudo tee` TRUNCATED the file, destroying any
      # [automount]/[network] config (data loss). Render a merged copy, install it, and restore
      # world-readable perms (cp from a 0600 mktemp would otherwise leave wsl.conf unreadable).
      _WSLNEW="$(mktemp "${TMPDIR:-/tmp}/wslconf.XXXXXX")"
      wslconf_render "$_WSLCUR" > "$_WSLNEW"
      # Checked AND read back. This write used to be fire-and-forget: its status
      # was discarded and the "Almost there" block below ran regardless, so a
      # refused write reported success and every re-run repeated it identically.
      say "  enabling systemd in WSL (preserving existing config)"
      if wslconf_install_ok "$_WSLNEW" /etc/wsl.conf; then
        ok "systemd enabled in /etc/wsl.conf"
      else
        warn "Couldn't write /etc/wsl.conf — systemd was NOT enabled."
        say  "  Add these two lines to the end of /etc/wsl.conf yourself (needs admin),"
        say  "  then re-run me:"
        say  "    [boot]"
        say  "    systemd=true"
        rm -f "$_WSLCUR" "$_WSLNEW"
        exit 1
      fi
      rm -f "$_WSLCUR" "$_WSLNEW"
    fi
    say ""
    say "Almost there — one quick restart of WSL is needed:"
    say "  1. Open PowerShell and run:  wsl --shutdown"
    say "  2. Reopen the Ubuntu app."
    say "  3. Run this same install command again — it'll pick up where it left off."
    exit 0
  fi
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would enable the tailscaled service (systemctl enable --now)"
  else
    say "  starting Tailscale"
    sudo systemctl enable --now tailscaled </dev/null 2>&1 | sed 's/^/    /' || true
  fi
fi

# Sign in / bring the connection up if we don't have an address yet.
if [ -z "$(tsip)" ] && [ "${SETUP_DRYRUN:-0}" != "1" ]; then
  # Everything below needs admin. Say so BEFORE the invisible password prompts:
  # without this the sudo calls just fail one after another (they all end in
  # `|| true`) and the user is left following recovery advice that cannot work.
  if ! admin_rights_ok; then
    warn "This account isn't an administrator, and Tailscale needs admin rights to start."
    say  "  The password prompts below will not accept your password, however correct it is."
    say  "  Ask whoever administers this machine to run this setup, or to grant you admin,"
    say  "  then re-run me. Everything already done is kept — re-running is safe."
  fi
  # Prefer the formula CLI (set just above on mac); fall back to whatever ts_bin resolves.
  TS_BIN="${TS_BIN:-}"; [ -n "$TS_BIN" ] || TS_BIN="$(ts_bin)"
  if [ "$PLATFORM" = "mac" ] && [ -n "$TS_BIN" ]; then
    # CLI sign-in. The #1 way this stalls: `sudo` asks for the Mac password FIRST, invisibly,
    # and the user waits for a "link" that can't appear until the password is entered. So:
    #  (1) spell out the password step, (2) prime sudo at that clear moment, (3) run `up`
    #  DIRECTLY on the terminal — never piped — so both the password prompt AND the auth URL
    #  are immediately visible (a pipe can hide/delay the URL while `up` blocks on auth).
    say ""
    say "  ${C_BOLD}Sign in to Tailscale.${C_RESET}"
    say "  ${C_YELLOW}First, macOS asks for your Mac password${C_RESET} (the one that unlocks this"
    say "  Mac). Typing is INVISIBLE — type it and press Enter. THEN a sign-in link appears."
    say "  Open that link and log in with the SAME account as your phone."
    say ""
    sudo -v || true
    # Start the background daemon (formula tailscaled) if it isn't already answering.
    if ! "$TS_BIN" status >/dev/null 2>&1; then
      TSD="$(tsd_bin)"
      [ -n "$TSD" ] && sudo "$TSD" install-system-daemon </dev/null >/dev/null 2>&1 || true
    fi
    # Direct to the terminal — no `| sed`, no `</dev/null`: the URL must be unmistakable.
    sudo "$TS_BIN" up || true
  elif [ "$PLATFORM" = "wsl" ]; then
    # Direct to the terminal so the auth URL is immediately visible (not buffered behind a pipe).
    sudo tailscale up || true
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
  say "Waiting for Tailscale to connect (finish the browser sign-in if you haven't yet)..."
  TS_IP=""
  for i in $(seq 1 90); do
    TS_IP="$(tsip)"
    [ -n "$TS_IP" ] && break
    if [ "$i" = "30" ]; then
      say "  ...still waiting. If you haven't: open the sign-in link printed above and log in."
    fi
    sleep 2
  done
  if [ -z "$TS_IP" ]; then
    warn "Tailscale isn't connected yet."
    say "  Open the sign-in link printed above and log in (same account as your phone),"
    say "  then re-run me — it's safe to re-run and picks up right here."
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
  # Fail-open (like every other step): a portal-copy failure must NOT hard-abort the whole
  # installer and skip the harness/hooks/RustDesk steps that come after. Warn and continue;
  # the verify checklist reports the portal as not-live.
  if cp "$SRC"/files/* "$BIN_DIR"/ 2>/dev/null; then
    chmod +x "$BIN_DIR"/*.sh 2>/dev/null || true
  else
    warn "Couldn't copy the portal files from $SRC/files — skipping the portal, continuing."
    say  "  (Re-run me once the download looks complete to finish the portal.)"
  fi
fi
else
  say "  [skip] phone portal — not needed for: $PRESET_LABEL"
fi

# YDO Agentic Harness — the build-discipline skill (spec -> plan -> build -> verify
# -> ship + learning tripwire). Only when the preset asks for it.
if preset_wants "$PRESET" harness; then
 SKILL_DIR="$HOME/.claude/skills/eng-harness"
 if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  step_banner "Installing the YDO Agentic Harness"
  say "DRYRUN: would install the YDO Agentic Harness to $SKILL_DIR"
 elif [ -d "$SRC/harness" ]; then
  step_banner "Installing the YDO Agentic Harness"
  mkdir -p "$SKILL_DIR"
  if cp -R "$SRC/harness/." "$SKILL_DIR/" 2>/dev/null; then
    chmod +x "$SKILL_DIR"/scripts/*.sh 2>/dev/null || true
    ok "YDO Agentic Harness installed (skill + learning tripwire)"
  else
    warn "Couldn't install the YDO Agentic Harness skill."
  fi
  # The harness's OWN dependencies. eng-harness marks zero-trust-verification
  # Required:yes — it is the gate that checks claims against real command output
  # instead of taking an agent's word. Until 2026-08-10 only eng-harness shipped, so
  # every teammate had a harness missing the one part that cannot be talked around.
  if [ -d "$SRC/harness-deps" ]; then
    for _dep in zero-trust-verification meta-proof-of-work; do
      if [ -d "$SRC/harness-deps/$_dep" ]; then
        mkdir -p "$HOME/.claude/skills/$_dep"
        if cp -R "$SRC/harness-deps/$_dep/." "$HOME/.claude/skills/$_dep/" 2>/dev/null; then
          ok "  + $_dep"
        else
          warn "  couldn't install $_dep — the harness will run degraded."
        fi
      fi
    done
  else
    warn "Harness dependency skills missing from the download — the verification gate"
    say  "  (zero-trust-verification) won't be installed, so the harness runs degraded."
  fi
 else
  # The preset asked for the harness but the (real) download didn't include it — don't
  # silently install nothing.
  step_banner "Installing the YDO Agentic Harness"
  warn "The YDO Agentic Harness files are missing from the download ($SRC/harness)."
  say  "  Re-run me once the download completes; report this if it keeps happening."
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
      # The hooks run under python3. The harness-only preset skips the tools step, so on a
      # fresh Mac python3 can be absent — provision it before wiring rather than silently fail.
      ensure_python3 || true
      if wire_global_hooks "$SETTINGS" "$USER_HOOKS" >/dev/null 2>&1; then
        ok "Enforcement hooks wired (merge gate + compaction snapshot)"
      elif ! python3_ok; then
        warn "Couldn't wire the enforcement hooks: a working Python 3 isn't available (the hooks need it)."
        say  "  Install it, then re-run me:"
        say  "    mac:  xcode-select --install   (or  brew install python3)"
        say  "    wsl:  sudo apt-get install -y python3"
      else
        warn "Couldn't auto-wire the enforcement hooks into $SETTINGS."
        say  "  Add these two hooks yourself in Claude Code, or re-run me:"
        say  "    PreToolUse (matcher Bash):  python3 \"$USER_HOOKS/merge-gate.py\""
        say  "    PreCompact:                 python3 \"$USER_HOOKS/precompact-run-snapshot.py\""
        say  "    UserPromptSubmit:           python3 \"$USER_HOOKS/output-contract.py\""
        say  "    Stop:                       python3 \"$USER_HOOKS/slop-gate.py\""
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

  # ---- retire legacy service names FIRST (AC-PPS-005) ------------------------
  # Two services under DIFFERENT names can both serve the dashboard, and launchd will
  # happily run both. The second one to start cannot bind 8090, KeepAlive restarts it,
  # and it crash-loops forever. That is what happened on the author's Mac on
  # 2026-07-26: the loop was stopped by disabling a plist, which left NO dashboard for
  # two weeks. The port is fixed at 8090 by design, so the only real fix is to
  # guarantee exactly ONE service owns it.
  #
  # Matched by the PROGRAM each service launches, not by label: older installs baked
  # the installing user's own username into the label, so a name list only ever fixes
  # the machine it was written on. Retire only AFTER the canonical pair is installed
  # below — never leave a port unserved in between.
  _LEGACY_FOUND=""
  for _pl in "$LA_DIR"/*.plist; do
    [ -f "$_pl" ] || continue
    _lbl="$(basename "$_pl" .plist)"
    case "$_lbl" in com.sessionlauncher.dashboard|com.sessionlauncher.terminal) continue ;; esac
    if grep -qE 'portal-web\.py|portal\.sh' "$_pl" 2>/dev/null; then
      _LEGACY_FOUND="$_LEGACY_FOUND $_lbl"
    fi
  done

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
    _NEWPLIST="$(mktemp "${TMPDIR:-/tmp}/plist.XXXXXX")"
    sed "s|__HOME__|$HOME|g" "$TPL" > "$_NEWPLIST"
    if cmp -s "$_NEWPLIST" "$PLIST" 2>/dev/null && launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      # Unchanged plist AND already loaded — DON'T bootout/reload: a harmless re-run must not
      # kill a live portal session (active tmux/ttyd) by tearing the service down.
      rm -f "$_NEWPLIST"
      ok "$label already loaded (unchanged)"
    else
      mv "$_NEWPLIST" "$PLIST"
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
        && ok "Loaded $label" \
        || warn "Couldn't load $label — you may need to grant permission and re-run."
    fi
  done

  # ---- NOW retire the legacy services (AC-PPS-005) ---------------------------
  # Deliberately AFTER the canonical pair is installed and loaded above. Retiring
  # first would leave the port unserved in between, and if the install then failed the
  # machine would end up with no portal at all — worse than the duplicate we came to
  # fix. Old plists are renamed, not deleted, so a mistake is reversible.
  if [ -n "$(printf '%s' "${_LEGACY_FOUND:-}" | tr -d ' ')" ]; then
    if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
      say "DRYRUN: would retire legacy portal services:$_LEGACY_FOUND"
    else
      for _old in $_LEGACY_FOUND; do
        launchctl bootout "gui/$(id -u)/$_old" >/dev/null 2>&1 || true
        mv -f "$LA_DIR/$_old.plist" "$LA_DIR/$_old.plist.retired-$(date +%Y%m%d)" 2>/dev/null || true
        ok "Retired older portal service $_old (kept as .retired-* if you want it back)"
      done
      say "  Two services under different names both try to own the same port; the"
      say "  loser restarts forever until someone disables it, and then there is no"
      say "  portal. One service per port is the whole point."
    fi
  fi

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
# A typed "~/projects" arrives quoted from read — the shell won't expand it, so mkdir would
# create a literal "~" directory. Expand a leading ~ ourselves.
WSROOT="$(expand_home "$WSROOT")"
if ! run "creating $WSROOT" ensure_workspace_dir "$WSROOT"; then
  warn "Couldn't create $WSROOT — check the path and permissions, then re-run me."
  say  "  Your projects folder was NOT saved, so nothing is left pointing at a bad path."
  WSROOT=""
fi
if [ -z "$WSROOT" ]; then
  :   # creation failed above; the warning has already been printed
elif [ "${SETUP_DRYRUN:-0}" = "1" ]; then
  say "DRYRUN: would save WORKSPACE_ROOT=$WSROOT to $ENV_FILE"
else
  upsert_env WORKSPACE_ROOT "$WSROOT" "$ENV_FILE"
  ok "Saved your projects folder: $WSROOT"
fi
else
  say "  [skip] projects folder — not needed for: $PRESET_LABEL"
fi

# ---- STEP 6c: the Agentic OS itself (AC-YTI-001/003/005/014) ----------------
# Clones yourdoctorsonline/agentic-os — a clean fork of the upstream template at
# v1.1.2 plus the paid Scrapes skill systems (51 skills). It carries NOBODY's session
# data, memory, brand content or client work: context/ is the upstream blank template
# set. See PROVENANCE.md in that repo.
#
# The old `your-doctors-online` clone that used to live here is GONE, not disabled
# (removed 2026-08-10 at the owner's instruction). That repo carries YDO business
# content whose privacy rules were last human-reviewed in July; nothing in this
# installer depends on it any more, so nothing depends on that review being current.
# AC-YTI-014 asserts the string is absent from this file.
#
# Auth is the teammate's OWN GitHub. No shared token is embedded or prompted for.
if preset_wants "$PRESET" workspace; then
  step_banner "Installing Agentic OS"
  AOS_DEFAULT="${WSROOT:-$HOME/repos}/agentic-os"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would clone/update yourdoctorsonline/agentic-os into $AOS_DEFAULT"
    say "DRYRUN: would then set up local memory (no dashboard, no server)"
  else
    ask AOS_DIR "Where should Agentic OS live?" "$AOS_DEFAULT"
    AOS_DIR="$(expand_home "$AOS_DIR")"
    AOS_OK=0
    case "$(aos_repo_state "$AOS_DIR")" in
    pull)
      say "Updating Agentic OS at $AOS_DIR ..."
      if git -C "$AOS_DIR" pull --ff-only </dev/null 2>/dev/null; then
        ok "Agentic OS updated."; AOS_OK=1
      else
        warn "Couldn't fast-forward (local changes?). Update it yourself: git -C \"$AOS_DIR\" pull"
        AOS_OK=1   # it IS installed; only the update failed
      fi ;;
    occupied)
      warn "$AOS_DIR already exists and isn't this Agentic OS — leaving it alone."
      say  "  (If it's the upstream template or someone else's fork, that's deliberate:"
      say  "   pulling ours over it would overwrite work. Pick another folder and re-run.)" ;;
    clone)
      say "Cloning yourdoctorsonline/agentic-os into $AOS_DIR ..."
      if have gh && gh repo clone yourdoctorsonline/agentic-os "$AOS_DIR" </dev/null 2>/dev/null; then
        ok "Agentic OS installed to $AOS_DIR"; AOS_OK=1
      elif have git && GIT_TERMINAL_PROMPT=0 git clone https://github.com/yourdoctorsonline/agentic-os.git "$AOS_DIR" </dev/null 2>/dev/null; then
        ok "Agentic OS installed to $AOS_DIR"; AOS_OK=1
      else
        warn "Couldn't clone Agentic OS — it's private, so it needs your GitHub access."
        say  "  Sign in first:   gh auth login"
        say  "  Then re-run me, or clone it yourself:"
        say  "    gh repo clone yourdoctorsonline/agentic-os \"$AOS_DIR\""
        say  "  If GitHub says 'not found', ask Raihan to add you to the yourdoctorsonline org."
      fi ;;
    esac

    # ---- memory, headless (AC-YTI-005) --------------------------------------
    # Memory is what makes Claude remember across sessions. Its engine lives in the
    # same package as the web dashboard, so the package is installed and the setup
    # script is run — but the dashboard server is never started and no `centre`
    # shortcut is added. This downloads a ~400 MB model on first run and takes a few
    # minutes; it is the slowest step in the install and it only happens once.
    if [ "$AOS_OK" = "1" ] && [ -x "$AOS_DIR/scripts/setup-memory.sh" ]; then
      # ASK FIRST. `setup-memory.sh` with no flags always ends in a `memory:reindex
      # --force`, which re-embeds every source even when nothing changed — so calling it
      # unconditionally turned every re-run of this installer into a full multi-minute
      # re-index of a teammate's entire memory. That breaks the promise in this file's
      # own header ("safe to re-run: anything already done gets skipped") and AC-YTI-011.
      # `--check` only reports; it writes nothing. Caught in pre-merge review 2026-08-10.
      if ( cd "$AOS_DIR" && bash scripts/setup-memory.sh --check </dev/null >/dev/null 2>&1 ); then
        ok "Memory already set up — skipped (nothing to re-index)."
      else
        say "Setting up memory (first run downloads ~400 MB — this is the slow part)..."
        if ( cd "$AOS_DIR" && bash scripts/setup-memory.sh </dev/null >/dev/null 2>&1 ); then
          ok "Memory ready (searchable, local to this Mac, no dashboard)."
        else
          warn "Memory setup didn't finish. Everything else still works; retry with:"
          say  "    cd \"$AOS_DIR\" && bash scripts/setup-memory.sh"
        fi
      fi
    elif [ "$AOS_OK" = "1" ]; then
      warn "Memory setup script not found in $AOS_DIR — skipping."
    fi

    # ---- an EMPTY Your Doctors Online workspace (AC-YTI-021) -----------------
    # A folder to put YDO work in, with nothing in it. Deliberately NOT a clone of
    # yourdoctorsonline/your-doctors-online: that repo carries real business content
    # whose privacy rules were last reviewed by a human in July, and this installer
    # stopped depending on it on purpose. An empty shell gives somewhere obvious to
    # work without inheriting anyone's data.
    #
    # Uses the OS's own scripts/add-client.sh rather than a second implementation, so
    # the folder shape stays whatever the OS says it is, now and after any upgrade.
    if [ "$AOS_OK" = "1" ] && [ -f "$AOS_DIR/scripts/add-client.sh" ]; then
      if [ -d "$AOS_DIR/clients/your-doctors-online" ]; then
        ok "YDO workspace folder already there — skipped."
      else
        ask _YDOWS "Create an empty Your Doctors Online workspace to work in? [Y/n]" "Y"
        case "$_YDOWS" in
          [Nn]*) say "  [skip] YDO workspace — make one later with: bash scripts/add-client.sh \"Your Doctors Online\"" ;;
          *)
            if ( cd "$AOS_DIR" && bash scripts/add-client.sh "Your Doctors Online" </dev/null >/dev/null 2>&1 ); then
              ok "Empty YDO workspace ready at clients/your-doctors-online/"
              say "    It has no brand files, no projects and no memory — that is deliberate."
              say "    Open Claude Code inside it and it will offer to set the brand up."
            else
              warn "Couldn't create the YDO workspace. Everything else still works; retry with:"
              say  "    cd \"$AOS_DIR\" && bash scripts/add-client.sh \"Your Doctors Online\""
            fi ;;
        esac
      fi
    fi

    # ---- import this person's OWN past Claude Code work (AC-YTI-007) ---------
    # Report only. A real import writes summary blocks into files that are committed
    # to git, and spans every signed-in account including personal ones, so the
    # decision stays with the human. The report names each account and its count.
    if [ "$AOS_OK" = "1" ] && [ -f "$AOS_DIR/command-centre/package.json" ]; then
      say ""
      say "Your past Claude Code work can be imported into memory. Here's what's available:"
      ( cd "$AOS_DIR" && npm --prefix command-centre run memory:import-sessions -- \
          --from global --dry-run </dev/null 2>/dev/null | sed -n '/Detected sources/,/^$/p' | sed 's/^/    /' ) || true
      say "    To import, run this in $AOS_DIR:"
      say "      npm --prefix command-centre run memory:import-sessions"
    fi
  fi
fi

# ---- optional: RustDesk (remote management / remote login) ------------------
# Opt-in on every preset (default N — it's a remote-access tool). SETUP_RUSTDESK=0 skips
# with no prompt; =1 installs without asking. Fail-open.
if [ "${SETUP_RUSTDESK:-}" != "0" ] && [ "$PLATFORM" = "mac" ]; then
  step_banner "Remote management (optional)"
  if [ "${SETUP_DRYRUN:-0}" = "1" ]; then
    say "DRYRUN: would offer RustDesk (remote desktop). SETUP_RUSTDESK=0 skips, =1 auto-installs."
    say "DRYRUN: after install, would guide phone connect (prefer Tailscale IP ${TS_IP:-<tailnet>})."
  elif [ -e "/Applications/RustDesk.app" ]; then
    # Already installed: re-print the phone-connect guidance, but do NOT auto-launch the
    # GUI on every re-run (the installer is meant to be re-run freely).
    ok "RustDesk already installed."
    rustdesk_phone_guide "${TS_IP:-}"
  else
    _RD="${SETUP_RUSTDESK:-}"
    if [ -z "$_RD" ]; then
      # Plain-language consent. RustDesk is remote CONTROL, not screen sharing: whoever
      # holds the ID and password can drive this Mac as if sitting at it — read files,
      # open apps, type. That has to be said in words before the prompt, not buried in
      # a link, because the person answering may not know what "remote desktop" implies.
      say ""
      say "  ${C_BOLD}Before you answer:${C_RESET} RustDesk lets someone with the ID and password"
      say "  take FULL control of this Mac from another device — move the mouse, open"
      say "  anything, read any file you can read. It is the same access as sitting here."
      say "  It is genuinely useful (it is how you fix your own Mac from your phone), and"
      say "  it is entirely optional. Nothing else in this install depends on it."
      say ""
      say "  If you say yes: RustDesk opens and shows an ID. ${C_BOLD}Set your own permanent"
      say "  password in it${C_RESET} — do not leave the temporary one, and do not share both"
      say "  the ID and password with anyone you would not hand your unlocked laptop to."
      say ""
      ask _RD "Install RustDesk? [y/N]" "N"
    fi
    case "$_RD" in
      1|[Yy]*)
        BREW="$(brew_bin)"
        if [ -n "$BREW" ]; then
          # </dev/null so the cask install can't drain the piped script (see the Homebrew note).
          "$BREW" install --cask rustdesk </dev/null 2>&1 | sed 's/^/    /'
          if [ -e "/Applications/RustDesk.app" ]; then
            ok "RustDesk installed."
            run "opening RustDesk" open -a RustDesk
            rustdesk_phone_guide "${TS_IP:-}"
          else
            warn "Couldn't install RustDesk — get it from https://rustdesk.com/download, then re-run me."
          fi
        else
          warn "RustDesk needs Homebrew — install it from https://rustdesk.com/download instead."
        fi ;;
      *) say "  [skip] RustDesk — add it later if you want remote access." ;;
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

    # AC-YTI-016 — RUN each tool and read its exit code. A package manager reporting
    # success does not mean the command works: it can land off PATH, install a
    # versioned binary under another name, or (Playwright) install the library without
    # the browser it drives. The only trustworthy answer is to execute it.
    #
    # On failure, name the SKILLS that stop working. "ffmpeg missing" means nothing to
    # someone who has never heard of ffmpeg; "video skills won't run" does.
    # The consequence text comes from the COMMITTED map (AC-YTI-016), not from strings
    # inline here. Hardcoded consequences drift silently as the skill set changes; a
    # data file can be regenerated and diffed. If the map is missing, say so rather than
    # printing a bare tool name — an unexplained "ffmpeg failed" is useless to the
    # person reading it, who has never heard of ffmpeg.
    TOOL_MAP="$SRC/os-payload/tool-skills.map"
    tool_consequence() {
      # tool_consequence <command> -> echoes "<consequence> (<skills>)", or a fallback
      local line
      if [ -r "$TOOL_MAP" ]; then
        line="$(grep "^$1|" "$TOOL_MAP" 2>/dev/null | head -1)"
        if [ -n "$line" ]; then
          printf '%s (%s)' "$(printf '%s' "$line" | cut -d'|' -f2)" \
                           "$(printf '%s' "$line" | cut -d'|' -f3)"
          return 0
        fi
      fi
      printf 'some skills will fail (tool-skills.map not found, so I cannot say which)'
    }
    tool_check() {
      # tool_check <command> <probe-args>
      if "$1" $2 >/dev/null 2>&1; then
        check "$1 works" 1
      else
        check "$1 is NOT working — $(tool_consequence "$1")" 0
      fi
    }
    tool_check ffmpeg  "-version"
    tool_check ffprobe "-version"
    tool_check yt-dlp  "--version"
    tool_check jq      "--version"
    tool_check gh      "--version"
    tool_check node    "--version"
    tool_check python3 "--version"
    # Playwright: the library alone is not enough — probe the BROWSER it drives.
    if npx --yes playwright --version >/dev/null 2>&1; then
      check "browser automation works" 1
    else
      check "browser automation is NOT working — $(tool_consequence playwright)" 0
    fi
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
