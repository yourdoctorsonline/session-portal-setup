# Phase 1 — Intake: pick the lane

Ceremony must match stakes (Google's spectrum: vibe ↔ structured ↔ agentic). The
lane decision is the most rationalization-prone moment in the whole pipeline —
agents talk themselves into the fast lane — so the decision itself is gated and
written down.

## 1. Classify

| Lane | Criteria (ALL must hold) | Pipeline |
|------|--------------------------|----------|
| **A — quick fix** | ≤2 files touched · no new behavior (fix/typo/config/copy change) · no schema/API/auth/payment surface · reversible in one revert | Steps 4→5 only (build + verify). Laws still fully apply. |
| **B — feature** (default) | anything not A or C | Full pipeline, Steps 2–7 |
| **C — critical** | touches payments, auth, user data, production infra, or anything client-facing at YDO scale | Full pipeline + mandatory human approval at spec AND pre-merge + security pass in Phase 5 |

When torn between two lanes, take the higher one. The cost asymmetry is brutal:
an over-ceremonied fix wastes minutes; an under-ceremonied feature wastes days.

## 2. Scaffold the run

```bash
bash .claude/skills/eng-harness/scripts/scaffold-run.sh <slug> <A|B|C>
```

- Creates `.eng-harness/runs/{YYYY-MM-DD}_{slug}/` with `run.md`, `spec.md`,
  `plan.md`, `tasks/`, `audit.md` templates.
- **Refuses to overwrite an existing run** — that refusal is evidence-tamper
  protection, not an inconvenience. To resume, open the existing `run.md` and go
  to the phase it records.

## 3. Justify the lane in run.md

Write 1–3 lines: the lane, why, and the file-count/behavior/surface facts that
support it. This is a claim like any other — it will be audited at ship time
against the actual diff.

## 4. Automatic promotion

If during ANY later phase the work exceeds the lane (Lane A touching a 3rd file,
Lane B suddenly touching auth), STOP, promote in `run.md` with a dated note, and
enter the missing phases before continuing. Promotion is free; discovering at ship
time that a "quick fix" rewrote the login flow is not.

## 5. Branch

Lane B/C: create the feature branch per the repo's branching policy
(`ops-new-feature` where installed; otherwise branch off the working branch
manually). Lane A: the repo's quick-fix flow (`/new-feature --quick` here).

NEXT: Lane A → `references/04-build.md`. Lane B/C → `references/02-spec.md`.
