#!/usr/bin/env bash
# ===== ENG-HARNESS DOCTOR v1 =====
# Does every phase gate actually WORK on this machine, right now?
#
# selfcheck.sh answers "is the harness installed and current".
# test_gates.py answers "does the ledger gate + drift guard behave correctly".
# Neither answers "can this machine run the whole pipeline" — this does.
#
# Every check is BIDIRECTIONAL. A gate is only reported working if it was shown
# to PASS when it should and FAIL when it should. That is the harness's own law
# ("a check that cannot fail is not a check") applied to the harness itself:
# a doctor that only ever tests the happy path would report a permanently-open
# gate as healthy.
#
# Runs entirely in a throwaway sandbox. Your real .eng-harness/ is never touched.
# Read-only with respect to the repo you invoke it from.
#
# Exit 0 = every gate proved working · 1 = a gate is broken · 2 = could not test
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; NA=0; UNT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
na()   { NA=$((NA+1));     printf '  [ -- ] %s\n' "$1"; }
# UNTESTED is deliberately NOT a FAIL and deliberately NOT a pass. It mirrors the
# harness's own fourth verdict, UNVERIFIABLE: the environment lacks something the
# check needs (an interpreter), so the gate's health is UNKNOWN here. Calling that
# FAIL tells a teammate their gates are broken when the real answer is "install
# Python"; calling it PASS hides a genuinely unverified gate. Both are lies.
# A MISSING HARNESS FILE stays a FAIL — that is a broken install, not an
# environment gap.
unt()  { UNT=$((UNT+1));   printf '  [UNTESTED] %s\n' "$1"; }
head_() { printf '\n-- %s --\n' "$1"; }

SANDBOX="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/hdoctor.$$")"
mkdir -p "$SANDBOX" 2>/dev/null || { echo "cannot create sandbox"; exit 2; }
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

# A sandbox repo: ledger.sh keys verdicts to commit hashes, so it needs real git.
git init -q "$SANDBOX/repo" 2>/dev/null
cd "$SANDBOX/repo" || exit 2
git config user.email d@d.local; git config user.name doctor
echo seed > seed.txt; git add seed.txt; git commit -qm seed 2>/dev/null

PY=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  case "$("$c" -V 2>/dev/null)" in Python\ 3*) PY="$c"; break ;; esac
done

echo "===== ENG-HARNESS DOCTOR v1 ====="
echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ)   harness: $HERE"
echo "python3: ${PY:-NONE}   sandbox: $SANDBOX"

# --- preflight: am I actually sitting inside an installed harness? -----------
# Copied somewhere on its own and run, EVERY sibling script is absent, every
# gate check reports [FAIL], and the verdict reads "9 gates are not working —
# a gate that cannot block is not a gate". That conclusion is wrong and it is
# wrong in the dangerous direction: it sends the reader off to fix gates that
# are fine, when the real answer is "the harness is not here".
#
# Same misreport shape as calling a line-ending difference a payload drift.
# The harness's own corollary applies to the doctor too: a check that COULD NOT
# RUN is not a check that FAILED. So this exits 2 (could-not-test), never 1.
MISSING_CORE=""
for _s in ledger.sh scaffold-run.sh check-plan-refs.sh watch.py; do
  [ -f "$HERE/$_s" ] || MISSING_CORE="$MISSING_CORE $_s"
done
if [ -n "$MISSING_CORE" ]; then
  printf '\n'
  echo "CANNOT TEST — no installed harness next to this script."
  echo "  looked in: $HERE"
  echo "  missing:  ${MISSING_CORE# }"
  printf '\n'
  echo "This script tests the harness's OWN gates, so it has to run from inside"
  echo "the installed harness rather than on its own:"
  printf '\n'
  echo "  bash ~/.claude/skills/eng-harness/scripts/harness-doctor.sh"
  printf '\n'
  echo "If that path doesn't exist, the harness isn't installed yet — run the"
  echo "installer first. This is a setup gap, not a broken gate. Reporting it as"
  echo "FAIL would send you to fix gates that are fine."
  echo "===== END DOCTOR ====="
  exit 2
fi

# ---------------------------------------------------------------- Phase 1 ----
head_ "Phase 1 — Intake (scaffold-run.sh)"
if [ ! -f "$HERE/scaffold-run.sh" ]; then
  bad "scaffold-run.sh not installed"
else
  if bash "$HERE/scaffold-run.sh" doctor-probe B >/dev/null 2>&1 \
     && [ -f .eng-harness/runs/*doctor-probe/run.md ] 2>/dev/null; then
    ok "creates a run dir with its templates"
  else
    # glob may not expand; check by find instead
    if find .eng-harness/runs -name run.md 2>/dev/null | grep -q .; then
      ok "creates a run dir with its templates"
    else
      bad "did NOT create a run dir"
    fi
  fi
  # The negative half: re-scaffolding the same slug must be REFUSED. That refusal
  # is evidence-tamper protection — if it silently overwrote, a failing run could
  # be erased and re-run clean.
  if bash "$HERE/scaffold-run.sh" doctor-probe B >/dev/null 2>&1; then
    bad "OVERWROTE an existing run — evidence-tamper protection is broken"
  else
    ok "refuses to overwrite an existing run (tamper protection)"
  fi
  # And it must reject a bad lane rather than inventing one.
  if bash "$HERE/scaffold-run.sh" doctor-probe2 Z >/dev/null 2>&1; then
    bad "accepted an invalid lane 'Z'"
  else
    ok "rejects an invalid lane"
  fi
fi

# ---------------------------------------------------------------- Phase 2 ----
head_ "Phase 2 — Spec (human approval gate)"
na "no script to exercise — approval is a human gate by design"

# ---------------------------------------------------------------- Phase 3 ----
head_ "Phase 3 — Plan (check-plan-refs.sh)"
if [ ! -f "$HERE/check-plan-refs.sh" ]; then
  bad "check-plan-refs.sh not installed"
elif [ -z "$PY" ]; then
  unt "not tested here — no working Python 3 (this gate needs it)"
else
  mkdir -p pl
  printf 'real content\nline two\nline three\n' > pl/real.txt
  printf '# Plan\n\nSOURCE: pl/real.txt:1-3\n' > pl/good.md
  printf '# Plan\n\nSOURCE: pl/DOES-NOT-EXIST.txt:1-3\n' > pl/bad.md
  if bash "$HERE/check-plan-refs.sh" pl/good.md . >/dev/null 2>&1; then
    ok "accepts a plan whose file references resolve"
  else
    bad "rejected a plan whose references are VALID (false positive)"
  fi
  if bash "$HERE/check-plan-refs.sh" pl/bad.md . >/dev/null 2>&1; then
    bad "ACCEPTED a plan citing a nonexistent file — staleness gate is open"
  else
    ok "rejects a plan citing a nonexistent file"
  fi
fi

# ---------------------------------------------------------------- Phase 4 ----
head_ "Phase 4 — Build (TDD discipline)"
if find .eng-harness/runs -type d -name tasks 2>/dev/null | grep -q .; then
  ok "run scaffold provides tasks/ for per-task RED/GREEN evidence"
else
  bad "no tasks/ dir in the scaffold — per-task evidence has nowhere to go"
fi
na "test-first discipline itself is prose, enforced by review not by script"

# ---------------------------------------------------------------- Phase 5 ----
head_ "Phase 5 — Verify (ledger.sh)"
L="$HERE/ledger.sh"
ledger_reset() { rm -f .eng-harness/ledger.jsonl; }
gate() { bash "$L" check "$1" >/dev/null 2>&1; }
if [ ! -f "$L" ]; then
  bad "ledger.sh not installed"
elif [ -z "$PY" ]; then
  # Determinable, not merely untestable — so this is a FAIL, not UNTESTED.
  # ledger.sh shells out to python3 twice (json_escape, and the check parser).
  # With no interpreter, `append` writes a malformed row and `check` then cannot
  # parse it. Measured behaviour: it returns UNVERIFIABLE, i.e. it fails CLOSED.
  # Worth stating both halves — "broken" and "unsafe" are different, and only
  # one of them is true here.
  bad "ship gate NON-FUNCTIONAL here — ledger.sh needs Python 3 and none is installed"
  na "  (it fails CLOSED — refuses to pass rather than waving work through, so"
  na "   nothing unsafe ships; but no run can COMPLETE until Python 3 is present)"
else
  R=doctor-probe
  # (a) all four layers PASS -> gate passes
  ledger_reset
  for p in verify:watch verify:zerotrust verify:review verify:runtime; do
    bash "$L" append "$R" "$p" PASS "doctor" >/dev/null 2>&1
  done
  gate "$R" && ok "all layers PASS at HEAD -> gate PASSES" \
             || bad "all layers PASS but gate did not pass"

  # (b) a FAIL must block
  ledger_reset
  bash "$L" append "$R" verify:watch FAIL "doctor" >/dev/null 2>&1
  for p in verify:zerotrust verify:review verify:runtime; do
    bash "$L" append "$R" "$p" PASS "doctor" >/dev/null 2>&1
  done
  gate "$R" && bad "a FAIL verdict did NOT block the gate" \
             || ok "a FAIL verdict blocks the gate"

  # (c) UNVERIFIABLE must block exactly like FAIL — this is the loophole the
  #     fourth verdict was added to close ("the tooling wasn't there" is not a pass)
  ledger_reset
  bash "$L" append "$R" verify:zerotrust UNVERIFIABLE "doctor" >/dev/null 2>&1
  for p in verify:watch verify:review verify:runtime; do
    bash "$L" append "$R" "$p" PASS "doctor" >/dev/null 2>&1
  done
  gate "$R" && bad "UNVERIFIABLE did NOT block — the capability-gap loophole is open" \
             || ok "UNVERIFIABLE blocks the gate (capability gap != pass)"

  # (d) SKIP is legal ONLY on runtime, and only with a note
  ledger_reset
  bash "$L" append "$R" verify:watch SKIP "doctor" >/dev/null 2>&1
  for p in verify:zerotrust verify:review verify:runtime; do
    bash "$L" append "$R" "$p" PASS "doctor" >/dev/null 2>&1
  done
  gate "$R" && bad "SKIP on verify:watch was allowed — skip allow-list is open" \
             || ok "SKIP on a non-runtime phase blocks"

  ledger_reset
  for p in verify:watch verify:zerotrust verify:review; do
    bash "$L" append "$R" "$p" PASS "doctor" >/dev/null 2>&1
  done
  bash "$L" append "$R" verify:runtime SKIP "no UI surface in this change" >/dev/null 2>&1
  gate "$R" && ok "SKIP on verify:runtime WITH a note is allowed" \
             || bad "a legal runtime SKIP was blocked (false positive)"

  # (e) closed vocabulary — a made-up verdict must be refused at write time
  if bash "$L" append "$R" verify:review PROBABLY_FINE "doctor" >/dev/null 2>&1; then
    bad "accepted an invented verdict — vocabulary is not closed"
  else
    ok "refuses an invented verdict (closed vocabulary)"
  fi
  ledger_reset
fi

head_ "Phase 5 — Verify (watch.py, said-vs-did)"
if [ ! -f "$HERE/watch.py" ]; then
  bad "watch.py not installed"
elif [ -z "$PY" ]; then
  unt "not tested here — no working Python 3"
else
  # With no session ledger there is nothing to compare, and that must be
  # non-zero: a silent zero here would let "never ran" read as "verified".
  if ( cd "$SANDBOX" && "$PY" "$HERE/watch.py" verify >/dev/null 2>&1 ); then
    bad "watch verify returned 0 with NO session — 'never ran' reads as verified"
  else
    ok "watch verify is non-zero with no session ledger"
  fi
  # The stop-hook path must ALWAYS exit 0 — a session-lifecycle hook that can
  # fail would brick the session it is supposed to observe.
  if echo '{}' | "$PY" "$HERE/watch.py" stop-hook >/dev/null 2>&1; then
    ok "stop-hook exits 0 (cannot brick a session)"
  else
    bad "stop-hook exited non-zero — it can brick a session"
  fi
fi

# ---------------------------------------------------------------- Phase 6 ----
head_ "Phase 6 — Ship (merge-gate hook)"
MG="$HOME/.claude/hooks/merge-gate.py"
if [ ! -f "$MG" ]; then
  bad "merge-gate.py not installed — merges are ungated"
elif [ -z "$PY" ]; then
  unt "not tested here — merge-gate is Python, and the ledger it consults needs Python too"
else
  mkdir -p .eng-harness
  mg() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
           | "$PY" "$MG" >/dev/null 2>&1; }
  R=doctor-probe
  echo "$R" > .eng-harness/ACTIVE_RUN

  # failing ledger + a merge command -> must BLOCK (exit 2)
  ledger_reset
  bash "$L" append "$R" verify:watch FAIL "doctor" >/dev/null 2>&1
  if mg "git merge feature-x"; then
    bad "allowed a merge while the ship gate was FAILING"
  else
    ok "blocks 'git merge' when the ship gate fails"
  fi

  # passing ledger -> must ALLOW
  ledger_reset
  for p in verify:watch verify:zerotrust verify:review verify:runtime; do
    bash "$L" append "$R" "$p" PASS "doctor" >/dev/null 2>&1
  done
  if mg "git merge feature-x"; then
    ok "allows 'git merge' once the ship gate passes"
  else
    bad "blocked a merge even though the gate PASSES (false positive)"
  fi

  # a non-merge command must never be gated
  ledger_reset
  bash "$L" append "$R" verify:watch FAIL "doctor" >/dev/null 2>&1
  if mg "git status"; then
    ok "leaves non-merge commands alone"
  else
    bad "gated 'git status' — the hook is over-matching"
  fi
  rm -f .eng-harness/ACTIVE_RUN
  ledger_reset
fi

head_ "Phase 6 — Ship (precompact hook)"
PC="$HOME/.claude/hooks/precompact-run-snapshot.py"
if [ ! -f "$PC" ]; then
  bad "precompact-run-snapshot.py not installed — run position is lost on compaction"
elif [ -z "$PY" ]; then
  unt "not tested here — no working Python 3"
else
  if echo '{}' | "$PY" "$PC" >/dev/null 2>&1; then
    ok "precompact hook exits 0 (never blocks compaction)"
  else
    bad "precompact hook exited non-zero — it can break compaction"
  fi
fi

# ---------------------------------------------------------------- Phase 7 ----
head_ "Phase 7 — Learn (lesson_tripwire.py)"
TW="$HERE/lesson_tripwire.py"
if [ ! -f "$TW" ]; then
  bad "lesson_tripwire.py not installed — repeat lessons never become rules"
elif [ -z "$PY" ]; then
  unt "not tested here — no working Python 3"
else
  # Recurrence is deliberately defined as spanning DISTINCT DAYS — a lesson
  # written twice in one session is one session's notes, not a pattern. So the
  # fixture must use two different dates and must NOT carry a "(seen again X)"
  # stamp that collapses both onto the same day.
  cat > lessons.md <<'EOF'
# Learnings

## 2026-01-01 — run one
- Forgot to check the deployed artifact before claiming it was live.

## 2026-02-02 — run two
- Forgot to check the deployed artifact before claiming it was live.
EOF
  printf '# Skill\n\n## Rules\n- 2020-01-01: an unrelated rule about something else\n' > skill-norule.md
  OUT="$("$PY" "$TW" lessons.md --skill-md skill-norule.md --json 2>&1 || true)"
  case "$OUT" in
    *'"promotion_candidate": true'*|*'"promotion_candidate":true'*)
      ok "flags a lesson recurring across two days with no covering rule" ;;
    *)
      bad "did NOT flag a lesson recurring across two days (loop stays open)" ;;
  esac

  # The negative half: a single-day cluster must NOT be promoted, or every
  # session's own notes would become a rule proposal and the signal would drown.
  cat > lessons-oneday.md <<'EOF'
# Learnings

## 2026-03-03 — one run
- Rotate the frobnicator seals quarterly.
- Rotate the frobnicator seals quarterly again.
EOF
  OUT2="$("$PY" "$TW" lessons-oneday.md --skill-md skill-norule.md --json 2>&1 || true)"
  case "$OUT2" in
    *'"promotion_candidate": true'*|*'"promotion_candidate":true'*)
      bad "promoted a SINGLE-DAY cluster — every session's notes would become a rule" ;;
    *)
      ok "does not promote a single-day cluster (recurrence must span days)" ;;
  esac
fi

# ---------------------------------------------------------------- wiring ----
head_ "Wiring — are the hooks actually registered?"
LIVE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
S="$LIVE/settings.json"
if [ -f "$S" ]; then
  grep -q "merge-gate.py" "$S" 2>/dev/null \
    && ok "merge-gate registered in $S" || bad "merge-gate NOT registered — the ship gate is advisory only"
  grep -q "precompact-run-snapshot.py" "$S" 2>/dev/null \
    && ok "precompact registered" || bad "precompact NOT registered"
else
  bad "no settings.json at $S — no hooks can fire"
fi

head_ "The harness's own test suites"
if [ -z "$PY" ]; then
  unt "not tested here — no working Python 3"
else
  for t in test_gates.py test_lesson_tripwire.py; do
    if [ ! -f "$HERE/$t" ]; then bad "$t not installed"; continue; fi
    R2="$("$PY" "$HERE/$t" 2>&1 | tail -3 | tr '\n' ' ')"
    case "$R2" in
      *OK*) ok "$t: $R2" ;;
      *)    bad "$t: $R2" ;;
    esac
  done
fi

# ---------------------------------------------------------------- verdict ----
printf '\n'
echo "checks passed: $PASS   failed: $FAIL   untested: $UNT   not-applicable: $NA"
# Three-way verdict, and the middle one is the point. A real failure outranks an
# untested one; an untested one must never be folded into PASS, or "we couldn't
# check" becomes "it's fine" — the exact loophole the harness closed with its
# fourth verdict.
if [ "$FAIL" -gt 0 ]; then
  echo "VERDICT: FAIL — $FAIL gate(s) are not working. A gate that cannot block is not a gate."
  echo "===== END DOCTOR ====="
  exit 1
elif [ "$UNT" -gt 0 ]; then
  echo "VERDICT: PARTIAL — nothing is broken, but $UNT gate(s) could not be tested"
  echo "         on this machine (no working Python 3). Those gates are UNKNOWN here,"
  echo "         not healthy. Install Python 3 and re-run for a full verdict."
  echo "===== END DOCTOR ====="
  exit 2
else
  echo "VERDICT: PASS — every gate proved it works AND proved it can fail"
  echo "===== END DOCTOR ====="
  exit 0
fi
