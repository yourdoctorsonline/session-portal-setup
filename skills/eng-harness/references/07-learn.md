# Phase 7 — Learn

The harness compounds or it decays. Five minutes here buys the next run its
head start.

## 1. Retro (short, honest)

Answer in `run.md` under `## Retro`:
- What did the plan get wrong (anything discovered during build that the plan
  should have contained)?
- Which gate caught something real? Which gate was noise?
- Any watcher false positives (exact phrases)?
- Plan-vs-delivered gaps (promised but cut, delivered but unplanned)?

## 2. Write learnings

Append to `wiki/methodology/eng-harness.md`:
- dated bullet per real lesson under `## Learnings`
- plan-vs-delivered gaps under `## Plan-delivery gaps` (these are the strongest
  predictor of next run's blind spots)
- watcher false positives under `## Watcher tuning` (feeds regex re-tuning)

Codebase-specific gotchas discovered during build go to the PROJECT's own docs or
wiki, not this skill's page.

## 3. Close the run

- `run.md` frontmatter/status → `complete`, date, final commit sha.
- `bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> learn PASS "closed"`
- The run dir stays committed — it is the team's evidence that the work was done
  right, and the raw material for tuning the harness.

## 4. Feedback

Ask the user: "How did this land? Any adjustments?" — log the answer to the wiki
page. If they flag a harness-behavior problem, ALSO fix SKILL.md `## Rules` now
(Self-Update), not at wrap-up.
