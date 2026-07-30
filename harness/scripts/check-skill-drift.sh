#!/usr/bin/env bash
# Warn when the harness copies diverge. FOUR copies, ALL pairs.
#
# This guard used to compare repo<->personal only. That is exactly how the
# INSTALLED copy at ~/.claude fell a day behind with nothing reporting it, and
# how a teammate running setup.sh got yesterday's harness (2026-07-26).
#
#   repo       the checkout you are working in
#   personal   ~/.claude-personal — what this operator's sessions actually load
#   installed  ~/.claude — what setup.sh writes
#   published  the payload teammates download
#
# Absent copies are SKIPPED: a teammate has only installed+published, and a
# comparison that cannot be made is not a difference. It is not a pass either,
# which is what exit 2 is for.
#
# Exit 0 = every comparable pair was compared and matched
#      1 = drift found
#      2 = a pair could not be compared (nothing is claimed about it)
#
# Test seams: DRIFT_REPO · DRIFT_PERSONAL · DRIFT_INSTALLED · DRIFT_PUBLISHED_URL
#             DRIFT_SKIP_PUBLISHED=1 (skip the network fetch entirely)
set -u

# The repo default is resolved from the GIT ROOT, never from the cwd. A
# cwd-relative default made the verdict depend on where the guard was invoked:
# exit 1 with 12 findings from the repo root, exit 0 and silent from /tmp, same
# machine and same instant. A hook or cron calling it from elsewhere got a clean
# bill of health for a check that compared nothing.
DRIFT=0
UNVERIFIED=0
EOLONLY=0

# `${DRIFT_REPO+x}` tests whether the variable is SET, not whether it is
# non-empty: an explicit DRIFT_REPO="" is a caller saying "there is no repo copy
# here", which is different from not knowing.
if [ -n "${DRIFT_REPO+x}" ]; then
  R="$DRIFT_REPO"
else
  _root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$_root" ]; then
    R="$_root/.claude/skills/eng-harness"
  else
    # Could not determine WHERE the repo copy would be. The first version of
    # this fix set R="" here and carried on, which meant the repo pair was
    # dropped with no NOTE and no UNVERIFIED — so from any cwd outside a git
    # repo the guard still exited 0 claiming "every comparable pair matched".
    # That is the same defect the git-root resolution was meant to close, and
    # it survived a mutation because the regression test compared two runs that
    # BOTH silently dropped the repo copy.
    R=""
    echo "NOTE: repo copy not resolved — not inside a git repo and DRIFT_REPO is unset"
    UNVERIFIED=1
  fi
fi
P="${DRIFT_PERSONAL:-$HOME/.claude-personal/skills/eng-harness}"
I="${DRIFT_INSTALLED:-$HOME/.claude/skills/eng-harness}"
U_URL="${DRIFT_PUBLISHED_URL:-https://github.com/yourdoctorsonline/session-portal-setup/archive/refs/heads/main.tar.gz}"

# Every file the payload ships. check-skill-drift.sh is here on purpose: the
# guard must not be the one thing that can drift unnoticed.
FILES="SKILL.md references/laws.md references/01-intake.md references/02-spec.md
references/03-plan.md references/04-build.md references/05-verify.md
references/06-ship.md references/07-learn.md scripts/ledger.sh
scripts/scaffold-run.sh scripts/check-plan-refs.sh scripts/lesson_tripwire.py
scripts/watch.py scripts/test_gates.py scripts/check-skill-drift.sh
scripts/trigger-contract.sh scripts/test_lesson_tripwire.py scripts/selfcheck.sh
scripts/harness-doctor.sh"

# --- the published copy: ONE archive request, not one per file ---------------
# N independent fetches can straddle a push and produce a mixed-commit
# comparison — the same defect logged against collect-logs.sh's self_heal.
#
# Timeouts are deliberately tight: merge-gate.py invokes this script with
# subprocess timeout=20, and a fetch bounded at 60 could blow that, raising
# TimeoutExpired into a bare `except Exception: pass` — silently skipping the
# check under exactly the network conditions it exists to survive.
U=""
if [ "${DRIFT_SKIP_PUBLISHED:-0}" != "1" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  if [ -n "$U_URL" ] \
     && curl -fsSL --connect-timeout 5 --max-time 12 -o "$TMP/p.tar.gz" -- "$U_URL" 2>/dev/null \
     && tar -xzf "$TMP/p.tar.gz" -C "$TMP" 2>/dev/null; then
    U="$(find "$TMP" -maxdepth 2 -type d -name harness 2>/dev/null | head -1)"
    if [ -z "$U" ]; then
      echo "NOTE: published comparison not performed — the payload carries no harness/ dir"
      UNVERIFIED=1
    fi
  else
    echo "NOTE: published comparison not performed — could not fetch ${U_URL:-<empty url>}"
    UNVERIFIED=1
  fi
fi

# --- collect the copies that actually exist ---------------------------------
COPY_NAMES=()
COPY_DIRS=()
add_copy() {
  [ -n "$2" ] && [ -d "$2" ] || return 0
  COPY_NAMES+=("$1")
  COPY_DIRS+=("$2")
}
add_copy repo      "$R"
add_copy personal  "$P"
add_copy installed "$I"
add_copy published "$U"

# cmp_pair LABEL_A DIR_A LABEL_B DIR_B
# A tracked file present in one copy and ABSENT from the other is drift, not a
# silent skip. The old form required the file on BOTH sides before comparing,
# so a copy missing a file wholesale reported clean — which is the motivating
# incident's own shape: the installed and published copies had no test_gates.py
# at all, and the guard called them fine.
cmp_pair() {
  local la="$1" da="$2" lb="$3" db="$4" f ea eb
  for f in $FILES; do
    # `! -L` as well as `-f`: the PUBLISHED copy comes from an archive we did
    # not author. tar legitimately CREATES symlinks (it only refuses to extract
    # THROUGH one), so a crafted payload can ship harness/SKILL.md as a symlink
    # to any local path — `-f` follows it and `cmp` then compares that file,
    # turning the guard into a one-bit-per-filename oracle over readable files.
    # A symlink is therefore "not present", which reports MISSING: fail-closed.
    # This is tar-independent — GNU tar creates symlinks the same way.
    ea=0; eb=0
    [ -f "$da/$f" ] && [ ! -L "$da/$f" ] && ea=1
    [ -f "$db/$f" ] && [ ! -L "$db/$f" ] && eb=1
    if [ "$ea" = "1" ] && [ "$eb" = "1" ]; then
      if ! cmp -s "$da/$f" "$db/$f"; then
        # Byte-differing is not the same as content-differing. A Windows
        # checkout stores identical CONTENT with CRLF endings, and this
        # byte-exact compare reported EVERY text file as drifted — 18 of 18 on
        # a teammate's machine whose payload was in fact current. The false
        # positive has a distinctive signature (all files rather than a few),
        # and its real cost was teaching readers to ignore the guard.
        #
        # So: re-compare with CR stripped. Identical => cosmetic, reported as a
        # NOTE and NOT counted as drift. Still different => real drift, as before.
        if cmp -s <(tr -d '\r' < "$da/$f") <(tr -d '\r' < "$db/$f"); then
          echo "NOTE: $f differs only by line endings between $la and $lb (content identical)"
          EOLONLY=$((EOLONLY + 1))
        else
          echo "DRIFT: $f differs between $la and $lb"
          DRIFT=1
        fi
      fi
    elif [ "$ea" = "1" ]; then
      echo "DRIFT: $f present in $la, MISSING from $lb"
      DRIFT=1
    elif [ "$eb" = "1" ]; then
      echo "DRIFT: $f present in $lb, MISSING from $la"
      DRIFT=1
    fi
  done
}

# ALL pairs, not repo-anchored. Anchoring every comparison on the repo copy meant
# installed<->published was never compared — and that is the ONE pair a
# single-install teammate has, i.e. the exact population this guard ships for.
_n=${#COPY_NAMES[@]}
_i=0
while [ "$_i" -lt "$_n" ]; do
  _j=$((_i + 1))
  while [ "$_j" -lt "$_n" ]; do
    cmp_pair "${COPY_NAMES[$_i]}" "${COPY_DIRS[$_i]}" "${COPY_NAMES[$_j]}" "${COPY_DIRS[$_j]}"
    _j=$((_j + 1))
  done
  _i=$((_i + 1))
done

# Fewer than two copies means nothing was compared at all. Reporting 0 there
# would be "clean" for a check that never ran.
if [ "$_n" -lt 2 ]; then
  echo "NOTE: no comparison performed — only $_n harness copy present"
  UNVERIFIED=1
fi

# Line-ending-only differences are reported but do NOT change the verdict: the
# content matched, so there is nothing to re-install. Printed after the pair
# loop so the count is a single line rather than N scattered NOTEs.
if [ "$EOLONLY" -gt 0 ]; then
  echo "NOTE: $EOLONLY file(s) differ ONLY by line endings (CRLF vs LF) — cosmetic, not drift."
  echo "NOTE: to stop this recurring, ship a .gitattributes carrying '* text=auto eol=lf'."
fi

# A definite finding outranks an unperformed one, and both are printed either
# way — the NOTEs above are not swallowed by an exit-1 return.
[ "$DRIFT" = "1" ] && exit 1
[ "$UNVERIFIED" = "1" ] && exit 2
exit 0
