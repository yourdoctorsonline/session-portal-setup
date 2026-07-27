#!/usr/bin/env bash
# eng-harness: in-repo review ledger, keyed to commit hashes.
# (Pattern ported from gstack's review-log + readiness dashboard, moved into the
# repo so the whole team sees it — "has this been verified, and is the
# verification stale?" becomes a machine-checkable fact.)
#
# Usage:
#   ledger.sh append <run-slug> <phase> <PASS|FAIL|SKIP|UNVERIFIABLE> [note]
#   ledger.sh check  <run-slug>            # ship gate: all phases verified at current HEAD
#   ledger.sh show   [run-slug]            # human-readable history
#
# Verdicts:
#   PASS          the check ran and the surface is good
#   FAIL          the check ran and found a defect
#   SKIP          NO SURFACE EXISTS to check. Allowed on `verify:runtime` ONLY, and only
#                 with a note naming the absent surface. Every other required phase blocks
#                 on SKIP — see SKIP_ALLOWED in `check` below.
#   UNVERIFIABLE  the check COULD NOT RUN (missing hooks, absent tooling, no baseline).
#                 Blocks exactly like FAIL — "the infrastructure wasn't there" is not a
#                 passing answer. See laws.md § Corollary.
#
# Exit codes: 0 gate passes · 1 gate blocks (FAIL/UNVERIFIABLE/STALE/policy) ·
#             2 rejected input, or the gate itself could not run (UNVERIFIABLE — never a pass).
#
# Ledger file: .eng-harness/ledger.jsonl (committed).
set -euo pipefail

LEDGER=".eng-harness/ledger.jsonl"
CMD="${1:?usage: ledger.sh append|check|show ...}"

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

case "$CMD" in
  append)
    RUN="${2:?run-slug}"; PHASE="${3:?phase}"; VERDICT="${4:?PASS|FAIL|SKIP|UNVERIFIABLE}"; NOTE="${5:-}"
    # Closed verdict vocabulary. UNVERIFIABLE added 2026-07-26 (run
    # verdict-split-unverifiable): before it existed, a check that COULD NOT RUN had
    # nowhere to go but SKIP, and `check` never blocked on SKIP — so "the infrastructure
    # wasn't there" was a complete, gate-passing answer. Measured: 6 rows across 2 repos
    # already carried the word UNVERIFIABLE in their NOTE while recording SKIP.
    # Historical rows are untouched; new appends must conform.
    case "$VERDICT" in PASS|FAIL|SKIP|UNVERIFIABLE) ;; *) echo "verdict must be PASS, FAIL, SKIP, or UNVERIFIABLE" >&2; exit 2;; esac
    # Closed phase vocabulary (graphify-style enum guard): free-form names drifted
    # to 34 variants in two weeks, silently undercounting verification in any
    # cross-run analysis. Historical rows are untouched; new appends must conform.
    case "$PHASE" in
      spec|plan|build|ship|learn|verify:watch|verify:zerotrust|verify:review|verify:runtime) ;;
      *) echo "phase must be one of: spec plan build ship learn verify:watch verify:zerotrust verify:review verify:runtime (got: $PHASE)" >&2; exit 2;;
    esac
    mkdir -p .eng-harness
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
    BRANCH="$(git branch --show-current 2>/dev/null || echo none)"
    printf '{"ts":"%s","run":%s,"phase":%s,"verdict":"%s","commit":"%s","branch":%s,"note":%s}\n' \
      "$(date -u +%FT%TZ)" "$(json_escape "$RUN")" "$(json_escape "$PHASE")" "$VERDICT" \
      "$SHA" "$(json_escape "$BRANCH")" "$(json_escape "$NOTE")" >> "$LEDGER"
    echo "ledger: $RUN $PHASE $VERDICT @ $SHA"
    ;;

  check)
    RUN="${2:?run-slug}"
    [ -f "$LEDGER" ] || { echo "VERDICT: UNVERIFIABLE — no ledger at $LEDGER; the ship gate could not run" >&2; exit 2; }
    HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
    python3 - "$LEDGER" "$RUN" "$HEAD_SHA" <<'PY'
import json, sys

REQUIRED = ["spec", "plan", "verify:watch", "verify:zerotrust", "verify:review", "verify:runtime"]
LANE_A_REQUIRED = ["verify:watch", "verify:zerotrust", "verify:review", "verify:runtime"]

# Per-layer skip policy (2026-07-26, run verdict-split-unverifiable).
# SKIP means "NO SURFACE EXISTS" and must name the absent surface. Exactly ONE required
# phase has such a case — verify:runtime (no UI -> no visual pass) — so the policy is an
# allow-list, not a deny-list:
#   verify:watch      absent session ledger = hooks not wired = gap -> UNVERIFIABLE
#   verify:zerotrust  absent tooling/config = gap -> UNVERIFIABLE
#   verify:review     every diff can be read; laws.md "Uniform application" — every
#                     lane, Lane A included, owes all four layers
#   spec / plan       "no spec was written" is not an absent surface; on Lane B/C the
#                     presence of the row IS what makes it Lane B/C. Review finding
#                     R1-F1: as a deny-list these two fell through every branch, so a
#                     SKIP with no note shipped while UNVERIFIABLE on the same phase
#                     blocked. An allow-list cannot have that shape.
SKIP_ALLOWED = ("verify:runtime",)


def main():
    ledger_path, run, head = sys.argv[1], sys.argv[2], sys.argv[3]

    # Verdict fails closed: with no git we cannot establish verification freshness at
    # all — every row stamps commit "none", "none" == "none" defeats the staleness
    # compare, and the gate would report PASS having verified nothing. Review finding
    # R2-F1; "missing git" is named in AC-VSU-008.
    if head == "none":
        print("VERDICT: UNVERIFIABLE — no resolvable HEAD (git missing, or a repo with no "
              "commits yet), so verification freshness cannot be established for any row",
              file=sys.stderr)
        print("Fix the gate and re-check; this is never a pass.", file=sys.stderr)
        return 2

    latest = {}
    malformed = []
    for lineno, line in enumerate(open(ledger_path), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            # A corrupt row cannot be attributed to a run, so it cannot be ruled out
            # that it was THIS run's blocking FAIL. Review finding R2-F2: silently
            # dropping a torn write let an older PASS resurface as "latest" and turned
            # a blocked run into an exit-0 pass. "malformed row" is named in AC-VSU-008.
            malformed.append(lineno)
            continue
        # Round-2 finding F7: a valid-JSON non-dict line, or a dict with no usable phase,
        # previously slipped past this counter and surfaced from the outer handler as
        # "'int' object has no attribute 'get'" / "'<' not supported between NoneType and
        # str". Both blocked (safe direction) but told the operator nothing actionable.
        # They are malformed rows in the sense AC-VSU-008 means, so name them as such.
        if not isinstance(e, dict) or not isinstance(e.get("phase"), str):
            malformed.append(lineno)
            continue
        if e.get("run") == run:
            latest[e["phase"]] = e  # last write wins per phase

    if malformed:
        shown = ", ".join(str(n) for n in malformed[:20])
        more = "" if len(malformed) <= 20 else f" (+{len(malformed) - 20} more)"
        print(f"VERDICT: UNVERIFIABLE — {len(malformed)} unparseable row(s) in {ledger_path} "
              f"at line(s) {shown}{more}; the gate cannot trust its own data", file=sys.stderr)
        print("Repair or delete those line(s), then re-check. This is never a pass.",
              file=sys.stderr)
        return 2

    if not latest:
        print(f"FAIL: no ledger entries for run '{run}'", file=sys.stderr)
        return 1

    required = REQUIRED if "spec" in latest or "plan" in latest else LANE_A_REQUIRED
    VALID = ("PASS", "FAIL", "SKIP", "UNVERIFIABLE")
    failures = []
    stale = []
    for phase in required:
        e = latest.get(phase)
        note = (e.get("note") or "").strip() if e else ""
        # .get() not [] — a required-phase row missing its verdict field is corrupt data,
        # which must reach the "unreadable verdict" branch below rather than raise
        # (R1-F2). A missing verdict can never be treated as passing.
        verdict = e.get("verdict") if e else None
        if e is None:
            failures.append(f"{phase}: no entry")
        elif verdict is None:
            failures.append(f"{phase}: row has no verdict field — corrupt entry")
        elif verdict not in VALID:
            # Round-2 finding F1: without this the elif-chain had no else, so any verdict
            # string outside the vocabulary fell through EVERY branch and the phase counted
            # as satisfied — and because the staleness branch tests `verdict == "PASS"`, such
            # a row also dodged staleness at every future HEAD. `append` cannot produce one
            # (the vocabulary guard exits 2), but a merge-conflict resolution or foreign
            # tooling editing the committed ledger can.
            failures.append(f"{phase}: unrecognized verdict {verdict!r} — corrupt entry; "
                            f"legal verdicts are PASS, FAIL, SKIP, UNVERIFIABLE")
        elif verdict == "FAIL":
            failures.append(f"{phase}: FAIL ({note})")
        elif verdict == "UNVERIFIABLE":
            failures.append(f"{phase}: UNVERIFIABLE ({note}) — a check that could not run "
                            f"is not a check that passed")
        elif verdict == "SKIP" and phase not in SKIP_ALLOWED:
            failures.append(f"{phase}: SKIP not permitted — no no-surface case exists for "
                            f"this phase; if the check could not run, record UNVERIFIABLE")
        elif verdict == "SKIP" and not note:
            failures.append(f"{phase}: SKIP requires a note naming the absent surface")
        elif phase.startswith("verify:") and verdict == "PASS" and e.get("commit") != head:
            stale.append(f"{phase}: verified at {e.get('commit')} but HEAD is {head}")

    # .get() throughout: this loop walks EVERY row for the run, including retired
    # off-enum phases the gate promises to keep inert (AC-VSU-006). Review finding
    # R1-F2: bracket access here turned a field-less unrelated row into a gate block.
    for phase, e in sorted(latest.items()):
        print(f"  {phase:<18} {e.get('verdict','?'):<12} @ {e.get('commit','?')}  {e.get('note','')}")

    if failures:
        print("VERDICT: FAIL —", "; ".join(failures), file=sys.stderr)
        return 1
    if stale:
        print("VERDICT: STALE —", "; ".join(stale), file=sys.stderr)
        print("commits landed after verification; re-run the affected verify layers.", file=sys.stderr)
        return 1
    print("VERDICT: PASS — all phases verified at current HEAD")
    return 0


# Process fails open, verdict fails closed (SKILL.md rule 2026-07-06, amended 2026-07-26).
# The gate never crashes a session with a traceback; it also never reports success when it
# could not actually run. Same contract as check-plan-refs.sh.
try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as exc:
    print(f"VERDICT: UNVERIFIABLE — ship gate could not run: {exc}", file=sys.stderr)
    print("Fix the gate and re-check; this is never a pass.", file=sys.stderr)
    sys.exit(2)
PY
    ;;

  show)
    RUN="${2:-}"
    [ -f "$LEDGER" ] || { echo "no ledger at $LEDGER"; exit 0; }
    if [ -n "$RUN" ]; then grep -F "\"run\": \"$RUN\"" "$LEDGER" 2>/dev/null || grep -F "\"run\":\"$RUN\"" "$LEDGER" || true
    else cat "$LEDGER"; fi
    ;;

  *) echo "unknown command: $CMD (append|check|show)" >&2; exit 2 ;;
esac
