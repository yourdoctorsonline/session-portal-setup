---
name: eng-harness
description: >
  The agentic engineering conductor — MANDATORY entry point for ALL software
  development. Invoke BEFORE writing or changing any code, whenever the user wants
  to build, code, script, fix, refactor, automate, review, or ship software of any
  size: apps, features, APIs, tools, scripts, automations, cloud functions, hooks,
  pipelines, bug fixes — even one-file "quick" changes (a fast lane handles small
  work; size is never a reason to skip) and even if they don't name the skill.
  Also invoke when resuming work that has an .eng-harness/runs/ folder. Routes
  spec → plan → build → verify → ship with deterministic anti-hallucination gates,
  and hands debugging to systematic-debugging/investigate internally when the fix
  will change code. Does NOT trigger for questions/explanations with no code
  change intended, or marketing/content work.
---

# Engineering Harness

One conductor for building software right the first time. It does not reimplement
methodology — it routes through installed skills (superpowers, gstack reviews,
zero-trust-verification) and grounds every phase transition in a check the model
cannot talk its way past. Two goals, in priority order: (1) no false claims —
every "done" is backed by captured evidence; (2) one-pass quality — ambiguity
dies in spec/plan, not in revision rounds.

## Outcome

- Working, verified software on a feature branch, merged via the repo's normal flow
- A committed evidence trail: `.eng-harness/runs/{YYYY-MM-DD}_{slug}/` (lane decision,
  spec with AC IDs, plan, per-task reports with RED/GREEN test output, completion audit)
- A committed review ledger: `.eng-harness/ledger.jsonl` (phase, verdict, commit hash) —
  team-visible, staleness-checkable
- A gitignored action ledger: `.eng-harness/watch/*.jsonl` (what actually ran, captured
  by hooks) — the said-vs-did ground truth
- Learnings appended to `wiki/methodology/eng-harness.md`

## Context Needs

| File | Load level | Purpose |
|------|-----------|---------|
| `wiki/methodology/eng-harness.md` | full | Prior-run learnings — read before Phase 1 |
| `references/laws.md` | full, every run | The cross-cutting iron laws |
| `references/0N-*.md` | one at a time | Phase protocol — read at phase entry, not from memory |

## Dependencies

| Skill | Required? | What it provides | Without it |
|-------|-----------|------------------|------------|
| superpowers (plugin) | yes | brainstorming, writing-plans, subagent-driven-development, TDD, verification-before-completion, worktrees | Run the phase protocols inline from the reference files — degraded but functional |
| zero-trust-verification | yes | deterministic Tier-A gates (exit codes, coverage, claims manifest) | Phase 5 layer 1 falls back to manually run build/test commands with pasted output |
| plan-eng-review (gstack) | recommended | engineering plan review + complexity smell gate | Self-review the plan against `references/03-plan.md` checklist |
| design-consultation / design-review / qa (gstack) | UI work only | design system, visual QA with screenshots | Skip design stage; note the gap in run.md |
| meta-proof-of-work | recommended | Gate-2 adversarial prove-it review before merge | Phase 5 layer 2 reviewers only |
| ops-new-feature / ops-release | recommended | branch + merge + release mechanics | Manual git per the repo's branching policy |

## Skill Relationships

**Upstream:** none — this is the entry point for build work.
**Downstream / orchestrated:** everything in Dependencies, plus `investigate` or
`superpowers:systematic-debugging` (invoked mid-build on any bug), `verify` /
`playwright-e2e` (runtime proof), `document-release` (post-ship docs).
**Trigger boundaries:** `ops-new-feature` alone handles bare branch mechanics ("start
a branch") — eng-harness wraps it when the ask is to *build something*. Pure
debugging with no new deliverable goes to `investigate` directly.

## Before You Start

1. Read `references/laws.md` now. The laws bind every phase.
2. Read `wiki/methodology/eng-harness.md` (create from template if missing).
3. Check for an existing run: `ls .eng-harness/runs/` — if one matches this work,
   resume it at the phase its `run.md` records. Never start a duplicate run.
4. Check `SKILL.local.md` in this folder — if present, its rules override this file.

## Step 1: Intake — pick the lane

Read `references/01-intake.md` and execute it in full. Do not work from memory.

Classify the ask into a lane — **A quick-fix / B feature (default) / C critical** —
run `scripts/scaffold-run.sh <slug> <lane>` to create the evidence dir, and write the
lane justification into `run.md`. The lane decision is itself gated: claiming Lane A
for work that touches >2 files or adds behavior is an automatic promotion to B.

## Step 2: Spec — the contract

Read `references/02-spec.md` and execute it in full. (Lane A skips to Step 4.)

Run `superpowers:brainstorming` to an approved design, then write `spec.md` with
5–15 acceptance criteria in the AC grammar (`AC-{SLUG}-NNN: When [trigger], the
system shall [behavior]`). The ACs are the completion truth source for every later
gate. User approves the spec file before Phase 3 — questions or feedback are NOT
approval.

## Step 3: Plan — one-pass or don't start

Read `references/03-plan.md` and execute it in full.

Write the plan with `superpowers:writing-plans` PLUS the one-pass extras (verbatim
Patterns-to-Mirror with `SOURCE: file:lines`, NOT-Building fence, per-task
`VALIDATE:` command, No Prior Knowledge Test). Review with `plan-eng-review` where
installed. Then the deterministic gate: `scripts/check-plan-refs.sh <run-dir>/plan.md`
— any MISSING reference is a hard stop; revise the plan, never "fix it during
implementation."

## Step 4: Build — evidence or it didn't happen

Read `references/04-build.md` and execute it in full.

Execute via `superpowers:subagent-driven-development` (or executing-plans inline for
Lane A / tiny plans) in a worktree with a clean test baseline. TDD iron law. Each
task writes its report + RED/GREEN output to `tasks/task-N.md` in the run dir.
Statuses come from the closed vocabulary: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT
/ BLOCKED — nothing else.

## Step 5: Verify — four stacked layers

Read `references/05-verify.md` and execute it in full.

Layer 0 said-vs-did (`scripts/watch.py verify` against the action ledger), Layer 1
mechanical (zero-trust-verification), Layer 2 adversarial review (Do-Not-Trust-the-
Report reviewers + quote gate, two verdicts per task), Layer 3 runtime (drive the
real app; screenshots). Record each layer's verdict:
`scripts/ledger.sh append <run> verify:<layer> <PASS|FAIL|SKIP|UNVERIFIABLE>`.
`UNVERIFIABLE` = the check could not run; it BLOCKS the ship gate exactly like FAIL. `SKIP`
is legal on `verify:runtime` only, and only with a note naming the absent surface — every
other required phase blocks on it. Full rules in `references/05-verify.md`.

## Step 6: Ship

Read `references/06-ship.md` and execute it in full.

Plan-completion audit (every plan item + every AC classified DIFF-VERIFIABLE /
CROSS-REPO / EXTERNAL-STATE, per-item human confirmation for unverifiables) →
`ledger.sh check` gate (all verify layers PASS at current HEAD) → merge via the
repo's branch flow → `document-release` for docs.

## Step 7: Learn

Read `references/07-learn.md` and execute it in full.

Retro → append learnings + plan-vs-delivered gaps to `wiki/methodology/eng-harness.md`.
Close the run (`run.md` status: complete). Ask: "How did this land? Any adjustments?"

## The Laws (summary — full text in references/laws.md)

1. **Fresh evidence** — no completion claim without running the proving command in
   the current message and reading its output.
2. **Exit codes decide** — never narrate a result a command can report.
3. **Approval semantics** — questions/feedback/silence ≠ approval.
4. **Root cause first** — 3 failed fixes = stop, escalate to the human.
5. **Scope containment** — in-scope only; unrelated breakage documented, not fixed.
6. **Disk over memory** — state lives in the run dir; re-read at phase entry.
7. **Skips are visible** — `[SKIP]` + written reason, never silent omission.

## Rules

- 2026-07-06: v1 gates are warn-first per the rollout ramp — `watch.py` and hooks
  never block a session; deterministic REJECTs (zero-trust, check-plan-refs,
  ledger check) DO stop the pipeline. Revisit blocking Stop-hook after 2 weeks of
  false-positive data.
- 2026-07-06 (amended 2026-07-26): Gate scripts fail open on PROCESS, closed on
  VERDICT. **Process:** an error inside gate infrastructure must never crash, hang, or
  brick a session — catch it, report it, no traceback. **Verdict:** a gate that could
  not run must never emit a passing exit code; it reports `UNVERIFIABLE`, which blocks
  the ship gate exactly as FAIL does. The original wording ("reports `unverifiable`,
  not FAIL" alongside "must never block a deploy") became self-contradictory the moment
  UNVERIFIABLE became a blocking verdict — "the infrastructure wasn't there" is not a
  pass. Session-lifecycle hooks are the exemption and always exit 0 (`watch.py
  stop-hook`, `watch.py capture`): they must never brick a session. Reference
  implementations: `check-plan-refs.sh` and `ledger.sh check`. Proof:
  `scripts/test_gates.py`.
- 2026-07-09: Spawn topology — the depth-0 controller does all subagent spawning;
  implementers/reviewers are depth-1 and can't spawn further (Claude Code hard
  limit). Never instruct a subagent to spawn its own QA/reviewer — it silently
  degrades to self-review. Per-task review must stay controller-driven (implementer
  → then reviewer per task). See `references/04-build.md` + `references/laws.md`.
- 2026-07-12: Minimalism ladder — every task walks a fixed reuse-before-build ladder
  at plan time (03-plan.md § 1b), applied again at build time (04-build.md). It is
  ALWAYS ON — deliberately no lite/full/ultra intensity modes (user: intensity
  scales are confusing and leak over-engineering into output anyway). Safety
  (validation, data-loss, security, a11y, tests) is never trimmed. Shape adapted
  from ponytail's "lazy senior developer" ladder.
- 2026-07-19: Lesson tripwire — Phase 7 (07-learn.md § 2b) runs
  `scripts/lesson_tripwire.py` on the learnings page after appending. Every
  PROMOTION CANDIDATE (same lesson on ≥2 distinct dates, no covering Rule) must be
  either proposed to the user as a new Rule or declined with a dated note on the
  page — never silently ignored. Promotion is user-approved, never automatic.
  Origin: harness×graphify study takeaway #3 — the same lesson was logged 6+ times
  without ever becoming a Rule because detection depended on a human noticing.
- 2026-07-19: Verify external state fresh — before planning or executing against ANY
  external or deployed state (prod files, live pages, deployed functions, remote
  config, handoff briefs), verify it fresh at plan/build entry. A prior description
  is an inferred premise, not evidence; treat every unverified claim about external
  state — including your own past notes and run artifacts — as wrong until re-read.
  Promoted by tripwire (recurred 4+ distinct days, incl. the 264-line portal drift).
- 2026-07-19: Adversarial review is never skippable on Lane B/C — a normal "just
  cut a build" release included. Review has repeatedly found defects that green
  tests missed (canonical case: 9 found, some safety-critical, behind 258 passing
  tests). Promoted by tripwire (recurred 6 days).
- 2026-07-26: A check that cannot fail is not a check. Every assertion — in a test OR
  in a verification script — must be shown to fail when the property it checks is
  false. Any spy/capture needs an explicit vacuity guard that FAILS when it captured
  nothing, and a string assertion must not span a source line wrap. Promoted by
  tripwire (recurred 3+ dates in 3 disguises: a bounds check reading the constant it
  guards; a guard test that never ran the guard; a runtime spy wired to the wrong
  method so three assertions passed against the empty string). The same session then
  hit the wrap-brittleness case twice more while fixing it.
- 2026-07-26: A dispatched reviewer that has not returned is UNRUN, not passed — and a
  SLOW reviewer is not a dead one. Wait, or state the wait, before concluding a gate
  produced nothing. Record which lenses actually ran, and never report criteria
  coverage as if it were an adversarial reference. Origin: 3 of 4 reviewers plus all 3
  re-dispatches were declared non-delivering; all 6 returned late, the seeded control
  scored 9/9, and the run shipped a real AC bypass in the gap it left.
- 2026-07-26: Merged is not deployed, and deployed is not enabled. Before reporting any
  change as live, verify the three separately against the running system: the merge, the
  deployed artifact, and the feature flag / env var. Origin: a swap merged to main while
  the live service still ran pre-swap code with the flag unset — three gates, one done.
- 2026-07-19: Every run needs at least one REAL runtime proof — real model, real
  device or client, past-CDN origin check. Unit and mock evidence is structurally
  blind to model/contract bugs; a small runtime fix pass beats a clean skip.
  Promoted by tripwire (recurred 6 days).
- 2026-07-27: **An internally-consistent check is not a correct one.** A system checking
  its own homework always gives itself full marks. Before reporting any check as PASSED,
  **name the independent thing it was compared against** — a source the code under test does
  not produce or control (the vendor's own billing figure, a separate system's records, a
  human-verified fixture). If the honest answer is "nothing outside the system", report the
  check as WEAK, never as green. Two distinct failure shapes, both seen in one run:
  (a) the reference is derived from the artifact being checked (a reconciliation that summed
  `$data` to build the number it compared `$data` against — it can never fail); (b) the check
  is real but measures the wrong property, and passing it *feels* like validation (a
  landing-page inference whose spend total matched the ad account to the cent while misfiling
  ~85% of that spend into the wrong bucket — the total was right, the distribution was wrong).
  Shape (b) is the dangerous one: it produces a confident green tick. What broke it was an
  outside source — user registration records showing where clicks actually landed.
  Promoted by tripwire and **approved by the user 2026-07-27** (recurred 2026-07-10,
  2026-07-16, 2026-07-26, 2026-07-27 — twice in the last run alone).

## Self-Update

If the user flags an issue with how the harness ran — wrong lane call, missing gate,
noisy check, bad format — update the `## Rules` section in this SKILL.md immediately
with a dated correction. If the issue is a false positive in `watch.py` claim
detection, record the exact phrase in `wiki/methodology/eng-harness.md` under
`## Watcher tuning` so patterns get re-tuned on real data.

## Troubleshooting

- **`watch.py verify` says "no session found"** — hooks not wired in this repo, or
  the session predates install. Run `python3 .claude/skills/eng-harness/scripts/watch.py selftest`
  to prove the detector works, and check `.claude/settings.json` hooks.
- **`check-plan-refs.sh` flags a path that exists** — the plan cited it with a line
  range that drifted. Re-read the file, update the plan's snippet, re-run.
- **`ledger.sh check` fails after a rebase** — verdicts are keyed to commit hashes;
  re-run the verify layers on the new HEAD. That is the point, not a bug.
- **superpowers not installed** — each reference file carries a minimal inline
  fallback protocol; the harness degrades, it never silently skips.
