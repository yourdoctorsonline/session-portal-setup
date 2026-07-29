#!/usr/bin/env bash
# ===== AGENTIC-OS SELF-CHECK v2 =====
# Read-only. Mutates nothing. Every line of output is passed through a secret
# scrubber before it is printed, so this is safe to paste into a chat channel.
#
# v2 changes vs v1 (each one caused a bad reading on a real teammate machine):
#   - secret scrubber: v1 printed a live GitHub PAT embedded in a git remote URL
#   - python resolution: v1 read the Windows Store stub as a working "python3"
#   - drift disambiguation: v1 reported 18 files DRIFT for a pure line-ending diff
#   - git fetch never prompts: v1 could hang forever on a credential prompt
#   - UV counter: v1 emitted a raw shell error when the string was absent
#   - wider workspace search + platform honesty
set -u

# ---------------------------------------------------------------------------
# Secret scrubber. main() is piped through this, so nothing bypasses it.
# ---------------------------------------------------------------------------
scrub() {
  sed -E \
    -e 's#(https?://)[^/@[:space:]]+@#\1<CREDENTIAL-REDACTED>@#g' \
    -e 's#(github_pat_|ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_]{8,}#\1<REDACTED>#g' \
    -e 's#(glpat-)[A-Za-z0-9_-]{8,}#\1<REDACTED>#g' \
    -e 's#(xox[baprs]-)[A-Za-z0-9-]{8,}#\1<REDACTED>#g' \
    -e 's#AKIA[0-9A-Z]{16}#AKIA<REDACTED>#g' \
    -e 's#(sk-|sk-ant-)[A-Za-z0-9_-]{16,}#\1<REDACTED>#g'
}

ok(){ printf '  [OK]   %s\n' "$1"; }
no(){ printf '  [MISS] %s\n' "$1"; }
wa(){ printf '  [WARN] %s\n' "$1"; }
inf(){ printf '  %s\n' "$1"; }

# Machine-readable rollup, appended to as we go, printed at the end.
SUMMARY=""
add(){ SUMMARY="${SUMMARY}${1}=${2} "; }

main() {

echo "===== AGENTIC-OS SELF-CHECK v2 ====="

# --- 0. environment ---------------------------------------------------------
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME_S" in
  Darwin)             PLAT="mac" ;;
  MINGW*|MSYS*|CYGWIN*) PLAT="windows-gitbash" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then PLAT="wsl"; else PLAT="linux"; fi ;;
  *)                  PLAT="unsupported" ;;
esac

echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ)  host: $UNAME_S $(uname -r 2>/dev/null | cut -d. -f1-2)  user: $(whoami 2>/dev/null)"
echo "platform: $PLAT   bash: ${BASH_VERSION:-?}   git: $(git --version 2>/dev/null | cut -d' ' -f3)"
add plat "$PLAT"

# Python resolution. The Windows Store ships a `python3` shim that exists on
# PATH but prints "Python was not found..." instead of a version. v1 read that
# message with `cut -d' ' -f2` and reported the python version as "was".
PY=""; PYV="none"
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  v="$("$c" -V 2>/dev/null || true)"
  case "$v" in
    Python\ 3*) PY="$c"; PYV="${v#Python }"; break ;;
  esac
done
if [ -z "$PY" ] && command -v py >/dev/null 2>&1; then
  v="$(py -3 -V 2>/dev/null || true)"
  case "$v" in Python\ 3*) PY="py -3"; PYV="${v#Python }" ;; esac
fi
if [ -n "$PY" ]; then
  echo "python3: $PYV  (via: $PY)"
else
  echo "python3: NOT AVAILABLE — no working Python 3 on PATH"
  [ "$PLAT" = "windows-gitbash" ] && echo "         (Windows: this is usually the Microsoft Store alias, not a real Python)"
fi
add python "${PYV}"

if [ "$PLAT" = "windows-gitbash" ]; then
  echo
  wa "You are in Git Bash (MINGW). The installer does NOT support Git Bash —"
  wa "it targets macOS and Windows-via-WSL2 only. A harness found here was not"
  wa "put here by the supported path, and hooks wired here may not be the ones"
  wa "your Claude Code session actually loads. Report this line to Raihan."
fi

# --- 1. which Claude config is live -----------------------------------------
echo; echo "-- 1. which Claude config is live --"
inf "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset, so ~/.claude is live>}"
LIVE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
inf "live config dir: $LIVE"

# --- 2. harness installed? --------------------------------------------------
echo; echo "-- 2. harness installed? --"
H="$HOME/.claude/skills/eng-harness"
HARNESS=no
if [ -d "$H" ]; then
  HARNESS=yes; ok "harness present at $H"
  # `grep -c` prints 0 AND exits 1 when there are no matches, so v1's
  # `|| echo 0` appended a SECOND zero -> "0\n0" -> "integer expression
  # expected" printed into the report. `|| true` is the correct guard.
  UV="$(grep -c UNVERIFIABLE "$H/scripts/ledger.sh" 2>/dev/null || true)"
  case "$UV" in ''|*[!0-9]*) UV=0 ;; esac
  if [ "$UV" -gt 0 ]; then ok "ledger.sh knows UNVERIFIABLE ($UV) = 2026-07-26 or newer"
  else no "NO UNVERIFIABLE in ledger.sh = harness payload is STALE"; fi
  [ -f "$H/scripts/test_gates.py" ]        && ok "test_gates.py present"        || no "test_gates.py MISSING (stale payload)"
  [ -f "$H/scripts/check-skill-drift.sh" ] && ok "check-skill-drift.sh present" || no "check-skill-drift.sh MISSING (stale)"
  inf "harness dir date: $(date -r "$H/scripts" +%Y-%m-%d 2>/dev/null || echo unknown)"
else
  no "harness NOT installed — step 1 did not complete; show me its output"
fi
add harness "$HARNESS"

# --- 3. harness self-tests --------------------------------------------------
echo; echo "-- 3. do the harness's own tests pass here? --"
TESTS=skipped
if [ ! -f "$H/scripts/test_gates.py" ]; then
  wa "skipped — harness not installed"
elif [ -z "$PY" ]; then
  TESTS=nopython
  no "CANNOT RUN — no working Python 3. This is an environment gap, not a"
  no "     harness failure. The harness needs Python 3 for its gates."
else
  T="$($PY "$H/scripts/test_gates.py" 2>&1 | tail -3 | tr '\n' ' ')"
  case "$T" in
    *OK*)  TESTS=pass; ok "test_gates.py: $T" ;;
    *)     TESTS=fail; no "test_gates.py: $T" ;;
  esac
fi
add tests "$TESTS"

# --- 4. hooks wired into the LIVE config ------------------------------------
echo; echo "-- 4. hooks wired into the LIVE config? --"
S="$LIVE/settings.json"
HOOKS=no
if [ -f "$S" ]; then
  MG=0; PC=0
  grep -q "merge-gate.py" "$S" 2>/dev/null && MG=1
  grep -q "precompact-run-snapshot.py" "$S" 2>/dev/null && PC=1
  [ "$MG" = 1 ] && ok "merge-gate wired in $S"   || no "merge-gate NOT wired in $S"
  [ "$PC" = 1 ] && ok "precompact wired"          || no "precompact NOT wired"
  [ "$MG" = 1 ] && [ "$PC" = 1 ] && HOOKS=yes
  if [ "$LIVE" != "$HOME/.claude" ]; then
    wa "installer writes ~/.claude/settings.json but LIVE is $LIVE — hooks may not fire"
  fi
else
  no "no settings.json at $S"
fi
add hooks "$HOOKS"

# --- 5. payload drift, with line-ending disambiguation ----------------------
# v1 reported "DRIFT" for a copy whose CONTENT was identical and whose only
# difference was CRLF vs LF. That reads as "your install is broken" when the
# real answer is "your install is fine, the line endings differ". We compare
# twice: byte-exact, then again with CR stripped.
echo; echo "-- 5. am I on the current published payload? --"
DRIFTSTATE=skipped
PUB_URL="https://github.com/yourdoctorsonline/session-portal-setup/archive/refs/heads/main.tar.gz"
if [ "$HARNESS" != "yes" ]; then
  wa "skipped — harness not installed"
elif ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  DRIFTSTATE=notools; wa "skipped — curl or tar unavailable"
else
  TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/aosdrift.$$")"
  mkdir -p "$TMPD" 2>/dev/null || true
  if curl -fsSL --connect-timeout 5 --max-time 45 -o "$TMPD/p.tar.gz" "$PUB_URL" 2>/dev/null \
     && tar -xzf "$TMPD/p.tar.gz" -C "$TMPD" 2>/dev/null; then
    PUBH="$(find "$TMPD" -maxdepth 3 -type d -name harness 2>/dev/null | head -1)"
    if [ -z "$PUBH" ]; then
      DRIFTSTATE=nopayload; wa "could not compare — published archive has no harness/ dir"
    else
      BYTE=0; CONTENT=0; TOTAL=0; MISSING=0; CONTENT_LIST=""
      # Walk the published file list; it is the authority on what should exist.
      while IFS= read -r rel; do
        TOTAL=$((TOTAL+1))
        a="$H/$rel"; b="$PUBH/$rel"
        if [ ! -f "$a" ]; then MISSING=$((MISSING+1)); continue; fi
        if ! cmp -s "$a" "$b"; then
          BYTE=$((BYTE+1))
          if diff -q <(tr -d '\r' < "$a") <(tr -d '\r' < "$b") >/dev/null 2>&1; then
            : # identical once CR is stripped -> line-ending only
          else
            CONTENT=$((CONTENT+1)); CONTENT_LIST="${CONTENT_LIST}      $rel
"
          fi
        fi
      done <<EOF
$(cd "$PUBH" && find . -type f \( -name '*.md' -o -name '*.sh' -o -name '*.py' \) 2>/dev/null | sed 's#^\./##' | sort)
EOF
      inf "compared $TOTAL published files against $H"
      if [ "$MISSING" -gt 0 ]; then no "$MISSING published file(s) MISSING from your install"; fi
      if [ "$BYTE" -eq 0 ] && [ "$MISSING" -eq 0 ]; then
        DRIFTSTATE=clean; ok "installed copy matches the published payload exactly"
      elif [ "$CONTENT" -eq 0 ] && [ "$MISSING" -eq 0 ]; then
        DRIFTSTATE=eol-only
        ok "CONTENT MATCHES the published payload — your install is current"
        wa "$BYTE/$TOTAL files differ only by line endings (CRLF vs LF)."
        wa "Cosmetic. Nothing to fix. v1 of this script reported this as DRIFT."
      else
        DRIFTSTATE=real
        no "REAL DRIFT — $CONTENT/$TOTAL file(s) differ in content:"
        printf '%s' "$CONTENT_LIST" | head -10
        [ "$BYTE" -gt "$CONTENT" ] && wa "(a further $((BYTE-CONTENT)) differ only by line endings — ignore those)"
      fi
    fi
  else
    DRIFTSTATE=offline; wa "could not compare — could not fetch the published payload (offline or no access)"
  fi
  rm -rf "$TMPD" 2>/dev/null || true
fi
add drift "$DRIFTSTATE"

# --- 6. agentic-os checkout -------------------------------------------------
# git must never prompt. A private remote with no cached credential will sit
# on an interactive password prompt forever, which is what truncated one v1
# report mid-section.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=echo
export GCM_INTERACTIVE=never

echo; echo "-- 6. agentic-os checkout --"
AOS_BRANCH="n/a"
if [ -d .git ]; then
  ORIGIN="$(git remote get-url origin 2>/dev/null || echo none)"
  inf "origin: $ORIGIN"
  case "$ORIGIN" in
    *@*)            wa "origin URL contains an embedded credential — it has been REDACTED above." ;;
  esac
  case "$ORIGIN" in
    *simonc602*)    wa "origin points at the UPSTREAM TEMPLATE, not your own fork." ;;
  esac
  # `git rev-parse --abbrev-ref HEAD` on a repo with no commits prints "HEAD"
  # to stdout AND exits non-zero, so a naive `|| echo unknown` yields the
  # two-line value "HEAD\nunknown". Take the first line, then sanity-check it.
  AOS_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | head -1)"
  [ -z "$AOS_BRANCH" ] || [ "$AOS_BRANCH" = "HEAD" ] && AOS_BRANCH="${AOS_BRANCH:-unknown}"
  git rev-parse HEAD >/dev/null 2>&1 || AOS_BRANCH="no-commits"
  inf "branch: $AOS_BRANCH  head: $(git log -1 --format='%h %cs' 2>/dev/null | head -1)"
  inf "local edits: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')  skills: $(ls -1d .claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')"
else
  wa "not in a git checkout — re-run from your agentic-os folder"
fi
add aosbranch "$AOS_BRANCH"

# --- 7. your-doctors-online checkout ----------------------------------------
echo; echo "-- 7. your-doctors-online checkout --"
YDO=""
for c in "$HOME/your-doctors-online" \
         "$PWD/clients/your-doctors-online" \
         "$PWD/../your-doctors-online" \
         "$HOME/agentic-os/clients/your-doctors-online" \
         "$HOME/my-agentic-os/clients/your-doctors-online"; do
  [ -d "$c/.git" ] && { YDO="$c"; break; }
done
# Bounded fallback search — v1 gave up after three fixed paths and reported
# "NOT FOUND" on a machine where it simply lived somewhere else.
if [ -z "$YDO" ]; then
  YDO="$(find "$HOME" -maxdepth 5 -type d -name 'your-doctors-online' 2>/dev/null | head -1)"
  [ -n "$YDO" ] && [ ! -d "$YDO/.git" ] && YDO=""
fi
YDOSTATE=missing
if [ -n "$YDO" ]; then
  YDOSTATE=found
  ok "found at $YDO"
  inf "head: $(git -C "$YDO" log -1 --format='%h %cs' 2>/dev/null)  branch: $(git -C "$YDO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if git -C "$YDO" fetch -q origin 2>/dev/null; then
    inf "behind origin by: $(git -C "$YDO" rev-list --count HEAD..@{u} 2>/dev/null || echo '?')"
  else
    wa "could not fetch origin (no credential or offline) — 'behind' unknown"
  fi
  EDITS="$(git -C "$YDO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  inf "local edits: $EDITS"
  if [ "${EDITS:-0}" -gt 0 ]; then
    inf "  modified/untracked:"
    git -C "$YDO" status --porcelain 2>/dev/null | head -10 | sed 's/^/      /'
  fi
else
  no "your-doctors-online NOT found (searched ~, ./clients, .., and ~ to depth 5)"
fi
add ydo "$YDOSTATE"

echo; echo "SUMMARY: $SUMMARY"
echo "===== END SELF-CHECK ====="
}

main 2>&1 | scrub
