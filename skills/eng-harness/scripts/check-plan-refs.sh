#!/usr/bin/env bash
# eng-harness: plan staleness gate (pattern ported from archon confirm-plan).
# Mechanically verifies every file the plan cites actually exists, and that
# cited line ranges are within the file. A MISSING reference = hallucinated or
# stale plan context = exit 1 (hard stop: revise the plan, don't "fix during
# implementation"). Exit 2 = the checker itself failed (UNVERIFIABLE — check
# refs manually; never treat as a pass).
#
# Usage: check-plan-refs.sh <plan.md> [repo-root]
# Recognized reference shapes:
#   SOURCE: path/to/file.ext:12-40      (Patterns-to-Mirror headers)
#   `path/to/file.ext`                  (backticked paths with an extension)
#   | path/to/file.ext | 12-40 |        (Mandatory Reading table rows)
#
# Bash here is only a launcher: macOS ships bash 3.2, so the logic lives in
# stdlib Python (already a harness dependency via watch.py / ledger.sh).
set -uo pipefail

PLAN="${1:?usage: check-plan-refs.sh <plan.md> [repo-root]}"
ROOT="${2:-.}"

python3 - "$PLAN" "$ROOT" <<'PY'
import os, re, sys

def main():
    plan_path, root = sys.argv[1], sys.argv[2]
    if not os.path.isfile(plan_path):
        print(f"plan not found: {plan_path}", file=sys.stderr)
        return 2
    text = open(plan_path, encoding="utf-8", errors="replace").read()

    refs = {}  # (path, lines) -> planned(bool) ; ordered dedup

    def add(path, lines="", planned=False):
        path = path.strip()
        if not path or path.startswith("http") or "*" in path or "{" in path:
            return
        # __TOKEN__ placeholders (e.g. __HOME__/...) are template content, not refs
        if "__" in path:
            return
        key = (path, lines.strip())
        # a hard (non-planned) mention anywhere wins over a planned one
        refs[key] = refs.get(key, True) and planned

    # SOURCE: path[:start-end] — always hard-checked (cited existing code)
    for m in re.finditer(r"SOURCE:\s*([A-Za-z0-9_./-]+?)(?::(\d+(?:-\d+)?))?(?=[\s`)\]]|$)", text):
        add(m.group(1), m.group(2) or "")

    # backticked paths containing a slash and an extension. A "NEW" marker
    # earlier on the same line means the plan CREATES this file (planned
    # output, allowed to not exist yet) rather than citing it as context.
    for line in text.splitlines():
        for m in re.finditer(r"`([A-Za-z0-9_./-]+/[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,8})`", line):
            planned = re.search(r"\bNEW\b", line[:m.start()]) is not None
            add(m.group(1), planned=planned)

    # markdown table rows: | path | lines |
    for line in text.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if not cells or "/" not in cells[0] or "." not in os.path.basename(cells[0]):
            continue
        lines = cells[1] if len(cells) > 1 and re.fullmatch(r"\d+(-\d+)?", cells[1] or "") else ""
        add(cells[0], lines)

    ok = drifted = missing = planned_n = 0
    for (path, lines), planned in refs.items():
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            if planned:
                print(f"PLANNED  {path} (created by this plan)")
                planned_n += 1
            else:
                print(f"MISSING  {path}")
                missing += 1
            continue
        if lines:
            end = int(lines.split("-")[-1])
            total = sum(1 for _ in open(full, encoding="utf-8", errors="replace"))
            if end > total:
                print(f"DRIFTED  {path}:{lines} (file has {total} lines)")
                drifted += 1
                continue
        print(f"OK       {path}" + (f":{lines}" if lines else ""))
        ok += 1

    print("---")
    print(f"refs: {ok} ok, {drifted} drifted, {missing} missing, {planned_n} planned")
    if missing:
        print("VERDICT: FAIL — plan cites files that do not exist. Revise the plan.", file=sys.stderr)
        return 1
    if drifted:
        print("VERDICT: WARN — line ranges drifted; re-read those files and refresh the plan's snippets.", file=sys.stderr)
        return 0
    if not refs:
        print("VERDICT: WARN — no file references found in the plan; a plan with no Mandatory Reading or Patterns-to-Mirror is suspicious.", file=sys.stderr)
        return 0
    print("VERDICT: PASS")
    return 0

try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as e:
    print(f"VERDICT: UNVERIFIABLE — checker error: {e}. Verify plan refs manually.", file=sys.stderr)
    sys.exit(2)
PY
