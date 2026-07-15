#!/usr/bin/env bash
# eng-harness: scaffold a run evidence directory.
# Usage: scaffold-run.sh <slug> <A|B|C>
# Refuses to overwrite an existing run — evidence-tamper protection (pattern
# ported from 8090 software-factory-harness init-wo-execution.sh).
set -euo pipefail

SLUG="${1:?usage: scaffold-run.sh <slug> <A|B|C>}"
LANE="${2:?usage: scaffold-run.sh <slug> <A|B|C>}"
case "$LANE" in A|B|C) ;; *) echo "lane must be A, B, or C" >&2; exit 2;; esac

# slug hygiene: kebab-case only, no path tricks
if ! printf '%s' "$SLUG" | grep -Eq '^[a-z0-9][a-z0-9-]{1,60}$'; then
  echo "slug must be kebab-case: [a-z0-9-], got: $SLUG" >&2; exit 2
fi

DATE="$(date +%F)"
RUN_DIR=".eng-harness/runs/${DATE}_${SLUG}"

if [ -e "$RUN_DIR" ]; then
  echo "REFUSING to overwrite existing run: $RUN_DIR" >&2
  echo "Resume it instead — open $RUN_DIR/run.md and continue at the phase it records." >&2
  exit 1
fi

mkdir -p "$RUN_DIR/tasks"

cat > "$RUN_DIR/run.md" <<EOF
# Run — ${SLUG}
NEXT: references/0$([ "$LANE" = "A" ] && echo "4-build" || echo "2-spec").md
status: active
lane: ${LANE}
created: ${DATE}
branch: (fill at branch creation)

## Lane justification
(1-3 lines: why lane ${LANE} — file count, behavior surface, risk surface.
Audited at ship time against the actual diff.)

## Baseline
(test-suite result before first change)

## Promotions
(dated notes if the lane changes mid-run)

## Retro
(filled in Phase 7)
EOF

cat > "$RUN_DIR/spec.md" <<EOF
# Spec — ${SLUG}
NEXT: references/03-plan.md
status: draft

## Goal

## Design (approved: )

## Acceptance criteria
AC-$(printf '%s' "$SLUG" | tr 'a-z-' 'A-Z_' | cut -c1-12)-001: When , the system shall .

## NOT in scope
-

## Open questions
-
EOF

cat > "$RUN_DIR/plan.md" <<EOF
# Plan — ${SLUG}
NEXT: references/04-build.md
> For agentic workers: execute via superpowers:subagent-driven-development or superpowers:executing-plans.
status: draft
one-pass-confidence: /10

## Mandatory Reading
| File | Lines | Why |
|------|-------|-----|

## Patterns to Mirror
<!-- verbatim snippets with SOURCE: path:start-end headers -->

## NOT Building
-

## Tasks
### Task 1 —
ACs:
MIRROR:
GOTCHA:
VALIDATE:
EOF

cat > "$RUN_DIR/audit.md" <<EOF
# Ship audit — ${SLUG}
status: pending

| Item | Class (DIFF/CROSS-REPO/EXTERNAL) | Verdict | Proof |
|------|----------------------------------|---------|-------|
EOF

echo "created $RUN_DIR (lane $LANE)"
echo "  run.md spec.md plan.md audit.md tasks/"
