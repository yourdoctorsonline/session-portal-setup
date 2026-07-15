#!/usr/bin/env bash
# eng-harness: in-repo review ledger, keyed to commit hashes.
# (Pattern ported from gstack's review-log + readiness dashboard, moved into the
# repo so the whole team sees it — "has this been verified, and is the
# verification stale?" becomes a machine-checkable fact.)
#
# Usage:
#   ledger.sh append <run-slug> <phase> <PASS|FAIL|SKIP> [note]
#   ledger.sh check  <run-slug>            # ship gate: all phases PASS/SKIP at current HEAD
#   ledger.sh show   [run-slug]            # human-readable history
#
# Ledger file: .eng-harness/ledger.jsonl (committed).
set -euo pipefail

LEDGER=".eng-harness/ledger.jsonl"
CMD="${1:?usage: ledger.sh append|check|show ...}"

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

case "$CMD" in
  append)
    RUN="${2:?run-slug}"; PHASE="${3:?phase}"; VERDICT="${4:?PASS|FAIL|SKIP}"; NOTE="${5:-}"
    case "$VERDICT" in PASS|FAIL|SKIP) ;; *) echo "verdict must be PASS, FAIL, or SKIP" >&2; exit 2;; esac
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
    [ -f "$LEDGER" ] || { echo "no ledger at $LEDGER" >&2; exit 1; }
    HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
    python3 - "$LEDGER" "$RUN" "$HEAD_SHA" <<'PY'
import json, sys
ledger_path, run, head = sys.argv[1], sys.argv[2], sys.argv[3]
REQUIRED = ["spec", "plan", "verify:watch", "verify:zerotrust", "verify:review", "verify:runtime"]
LANE_A_REQUIRED = ["verify:watch", "verify:zerotrust", "verify:review", "verify:runtime"]
latest = {}
for line in open(ledger_path):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("run") == run:
        latest[e.get("phase")] = e  # last write wins per phase

if not latest:
    print(f"FAIL: no ledger entries for run '{run}'", file=sys.stderr)
    sys.exit(1)

required = REQUIRED if "spec" in latest or "plan" in latest else LANE_A_REQUIRED
failures = []
stale = []
for phase in required:
    e = latest.get(phase)
    if e is None:
        failures.append(f"{phase}: no entry")
    elif e["verdict"] == "FAIL":
        failures.append(f"{phase}: FAIL ({e.get('note','')})")
    elif phase.startswith("verify:") and e["verdict"] == "PASS" and e.get("commit") != head:
        stale.append(f"{phase}: verified at {e.get('commit')} but HEAD is {head}")

for phase, e in sorted(latest.items()):
    print(f"  {phase:<18} {e['verdict']:<4} @ {e.get('commit','?')}  {e.get('note','')}")

if failures:
    print("VERDICT: FAIL —", "; ".join(failures), file=sys.stderr)
    sys.exit(1)
if stale:
    print("VERDICT: STALE —", "; ".join(stale), file=sys.stderr)
    print("commits landed after verification; re-run the affected verify layers.", file=sys.stderr)
    sys.exit(1)
print("VERDICT: PASS — all phases verified at current HEAD")
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
