#!/usr/bin/env bash
# ===== ENG-HARNESS HEAL v1 =====
# Fix what CAN be fixed, then PROVE it was fixed.
#
# Three tools, deliberately separate:
#   selfcheck.sh        what is on this machine        (reads, never writes)
#   harness-doctor.sh   do the gates actually work     (reads, never writes)
#   harness-heal.sh     fix setup gaps, then re-prove  (writes — this one)
#
# Why heal is a separate script and not a `--fix` flag on the doctor: a tool
# that tests your safety equipment AND rewrites it can quietly weaken it, and
# then there is nothing independent left to catch that. Keeping them apart is
# what makes the doctor's verdict worth anything.
#
# WILL fix:     a missing / stale / drifted harness · unwired hooks · a missing
#               Python 3 — all by re-running the official installer, which is
#               idempotent and already owns that logic. Heal never hand-edits.
# will NOT fix: a gate that MISBEHAVES. That means the payload is corrupt or
#               someone modified it. Heal reinstalls clean and re-tests; if a
#               gate still misbehaves it STOPS and escalates to a human rather
#               than getting creative with your safety equipment.
#
# Never touches: your repos, your git state, your .eng-harness/ runs, or any
#                individual harness script.
#
# Exit 0 = healthy (already, or healed and re-proved)
#      1 = still broken after healing — needs a human
#      2 = could not run (offline, unsupported platform, no curl)
set -u

SETUP_URL="https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.sh"
SKILL="$HOME/.claude/skills/eng-harness"
DOC="$SKILL/scripts/harness-doctor.sh"

say()  { printf '%s\n' "$1"; }
step() { printf '\n-- %s --\n' "$1"; }
ok()   { printf '  [OK]   %s\n' "$1"; }
inf()  { printf '  %s\n' "$1"; }
wa()   { printf '  [WARN] %s\n' "$1"; }
no()   { printf '  [MISS] %s\n' "$1"; }

echo "===== ENG-HARNESS HEAL v1 ====="
echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ)  host: $(uname -s 2>/dev/null)  user: $(whoami 2>/dev/null)"

# --- platform gate ----------------------------------------------------------
# Heal delegates to the installer, so it inherits the installer's platform
# support exactly. Saying so up front beats letting the installer exit 2 from
# inside a script the user thinks is going to fix things.
case "$(uname -s 2>/dev/null)" in
  Darwin) PLAT=mac ;;
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then PLAT=wsl; else PLAT=linux; fi ;;
  MINGW*|MSYS*|CYGWIN*) PLAT=gitbash ;;
  *) PLAT=unknown ;;
esac
inf "platform: $PLAT"

if [ "$PLAT" = "gitbash" ]; then
  say ""
  no "Cannot heal from Git Bash — the installer this script drives doesn't run here."
  say ""
  say "Open PowerShell (not Git Bash) and run:"
  say ""
  say "  \$env:SL_PRESET='harness'; irm https://raw.githubusercontent.com/yourdoctorsonline/session-portal-setup/main/setup.ps1 | iex"
  say ""
  say "That sets up WSL if needed and installs inside it. Then re-run this heal"
  say "script from the Ubuntu window."
  echo "===== END HEAL ====="
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  say ""
  no "Cannot heal — curl is not available, so the installer cannot be fetched."
  echo "===== END HEAL ====="
  exit 2
fi

# --- 1. diagnose before ------------------------------------------------------
# run_doctor -> echoes the verdict word; sets DOC_RC.
DOC_RC=0
run_doctor() {
  if [ ! -f "$DOC" ]; then DOC_RC=127; echo "ABSENT"; return; fi
  DOC_OUT="$(bash "$DOC" 2>&1)"; DOC_RC=$?
  printf '%s\n' "$DOC_OUT" | grep -m1 -oE 'VERDICT: [A-Z]+' | sed 's/VERDICT: //' || echo "UNKNOWN"
}

step "1. Diagnosing"
BEFORE="$(run_doctor)"; BEFORE_RC=$DOC_RC
case "$BEFORE" in
  ABSENT) no "harness-doctor.sh not present — the harness isn't installed yet" ;;
  PASS)   ok "doctor says PASS already" ;;
  *)      no "doctor says $BEFORE (exit $BEFORE_RC)" ;;
esac

# Nothing to do is a legitimate and common outcome. Say so and stop rather than
# reinstalling for the sake of looking busy — a needless reinstall is a needless
# chance to break something that currently works.
if [ "$BEFORE" = "PASS" ]; then
  say ""
  ok "Nothing to heal. Every gate already works and already proved it can fail."
  echo "===== END HEAL ====="
  exit 0
fi

# --- 2. record the failures we are about to try to fix ----------------------
step "2. What's wrong"
if [ "$BEFORE" != "ABSENT" ]; then
  printf '%s\n' "$DOC_OUT" | grep -E '^\s+\[(FAIL|UNTESTED)\]' | head -12
  BEFORE_FAILS="$(printf '%s\n' "$DOC_OUT" | grep -cE '^\s+\[FAIL\]' || true)"
else
  inf "harness absent — everything is missing rather than broken"
  BEFORE_FAILS="?"
fi

# --- 3. back up the one file the installer edits ----------------------------
step "3. Backup"
S="$HOME/.claude/settings.json"
if [ -f "$S" ]; then
  BK="$S.pre-heal.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$S" "$BK" 2>/dev/null && ok "settings.json backed up to $(basename "$BK")" \
                            || wa "could not back up settings.json — continuing"
else
  inf "no settings.json yet — the installer will create one"
fi

# --- 4. heal, by re-running the official installer --------------------------
# Deliberately delegated. The installer already owns idempotent payload copy,
# hook wiring and python bootstrap; reimplementing any of that here would give
# two implementations that drift, and the heal path would be the untested one.
step "4. Healing (re-running the installer, harness preset only)"
inf "SETUP_PRESET=harness — skill + hooks only, no portal, no tailscale, no remote access"
TMP="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/heal.$$")"
if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$TMP/setup.sh" "$SETUP_URL" 2>/dev/null; then
  say ""
  no "Could not download the installer — offline, or the URL is unreachable."
  inf "$SETUP_URL"
  rm -rf "$TMP" 2>/dev/null
  echo "===== END HEAL ====="
  exit 2
fi
ok "installer downloaded ($(wc -l < "$TMP/setup.sh" | tr -d ' ') lines, sha256 $(shasum -a 256 "$TMP/setup.sh" 2>/dev/null | cut -c1-16))"

SETUP_PRESET=harness bash "$TMP/setup.sh" >"$TMP/install.log" 2>&1
INST_RC=$?
if [ "$INST_RC" -eq 0 ]; then
  ok "installer finished cleanly"
else
  wa "installer exited $INST_RC — last lines:"
  tail -6 "$TMP/install.log" | sed 's/^/      /'
fi
rm -rf "$TMP" 2>/dev/null

# --- 5. prove it ------------------------------------------------------------
# A healing script that does not re-verify is just hope with a progress bar.
step "5. Re-proving (running the doctor again)"
AFTER="$(run_doctor)"; AFTER_RC=$DOC_RC

# --- 6. report --------------------------------------------------------------
step "6. Result"
inf "before: $BEFORE    after: $AFTER"

if [ "$AFTER" = "PASS" ]; then
  say ""
  ok "HEALED — every gate now works and proved it can fail."
  echo "===== END HEAL ====="
  exit 0
fi

if [ "$AFTER" = "ABSENT" ]; then
  say ""
  no "Install did not land — harness-doctor.sh still isn't there."
  inf "Run the installer by hand and send the output:"
  inf "  SETUP_PRESET=harness bash <(curl -fsSL $SETUP_URL)"
  echo "===== END HEAL ====="
  exit 1
fi

# Remaining failures after a CLEAN reinstall. Split them, because the two
# classes need completely different responses and lumping them together is how
# a real tamper/corruption gets mistaken for a missing dependency.
REMAIN="$(printf '%s\n' "$DOC_OUT" | grep -E '^\s+\[FAIL\]' || true)"

# The empty guard is load-bearing, not defensive padding. `printf '%s\n' ""`
# emits ONE EMPTY LINE, and `grep -cv <pattern>` counts that empty line as a
# non-match — so with zero failures the classifier scored GATEBAD=1 and
# escalated "a gate is misbehaving" on a machine where nothing had failed at
# all. Reachable in practice: a PARTIAL verdict (untested items, no failures)
# produces exactly this empty REMAIN.
if [ -z "$REMAIN" ]; then
  ENVGAP=0; GATEBAD=0
else
  ENVGAP="$(printf '%s\n' "$REMAIN" | grep -ciE 'python|not installed' || true)"
  GATEBAD="$(printf '%s\n' "$REMAIN" | grep -civE 'python|not installed' || true)"
fi

# PARTIAL with no failures is the honest end state for a machine missing an
# interpreter: nothing is broken, some gates are simply unverified here.
# Reporting that as a heal failure would be as wrong as reporting it as success.
if [ "$AFTER" = "PARTIAL" ] && [ "${GATEBAD:-0}" -eq 0 ] && [ "${ENVGAP:-0}" -eq 0 ]; then
  say ""
  ok "HEALED as far as this machine allows — nothing is broken."
  wa "Some gates could not be TESTED here (no working Python 3), so their health"
  wa "is unknown rather than good. Install Python 3 and re-run for a full verdict."
  case "$PLAT" in
    mac)       inf "  brew install python3" ;;
    wsl|linux) inf "  sudo apt-get install -y python3" ;;
  esac
  echo "===== END HEAL ====="
  exit 0
fi

say ""
if [ "${GATEBAD:-0}" -gt 0 ]; then
  no "STOPPING — $GATEBAD gate(s) still MISBEHAVE after a clean reinstall."
  printf '%s\n' "$REMAIN" | grep -ivE 'python|not installed' | head -8
  say ""
  inf "This is past what a script should touch. A gate that misbehaves on a"
  inf "freshly-installed payload means the payload itself is wrong, or the"
  inf "harness was modified locally. Heal will not rewrite gate code to make a"
  inf "test go green — that is how you end up with a gate that passes and"
  inf "protects nothing."
  inf "Send this whole output to Raihan."
fi

if [ "${ENVGAP:-0}" -gt 0 ]; then
  say ""
  wa "$ENVGAP remaining failure(s) are environment gaps, not broken gates:"
  printf '%s\n' "$REMAIN" | grep -iE 'python|not installed' | head -6
  case "$PLAT" in
    mac) inf "Fix: brew install python3   (then re-run this script)" ;;
    wsl|linux) inf "Fix: sudo apt-get install -y python3   (then re-run this script)" ;;
  esac
fi

echo "===== END HEAL ====="
exit 1
