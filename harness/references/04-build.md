# Phase 4 — Build: evidence or it didn't happen

Small atomic units, fresh context per unit, test-first, and a written evidence
trail per task. The implementer's report is a claim set — later layers verify it —
so the report must carry its own proof.

## 1. Isolate

Work in a git worktree (`superpowers:using-git-worktrees`) or the run's feature
branch. Run the FULL test suite before the first change and record the baseline in
`run.md` — every later failure must be attributable to this run's work. A dirty
baseline is documented, not fixed (Law 5).

## 2. Execute

- **Lane B/C default:** `superpowers:subagent-driven-development` — fresh
  implementer subagent per task, reading ONLY the plan task + named files.
- **Lane A / tiny plans (≤2 tasks):** `superpowers:executing-plans` inline.
- **Minimalism ladder applies here too:** implement the smallest approach the plan
  chose (03-plan.md § 1b) — reuse / stdlib / native / one-line before building. If
  the plan's approach turns out non-minimal, that's `NEEDS_CONTEXT` back to the
  plan, not a licence to add cleverness at build time.
- TDD iron law per task: failing test first (RED), watch it fail, implement
  (GREEN), refactor. No production code without a failing test first. Code
  written before its test is deleted, not kept as "reference".

> **Spawn topology (depth-1 ceiling).** The depth-0 controller (this skill, run
> inline — never dispatched via the Agent tool) does ALL spawning. Implementer
> subagents run at depth-1 and CANNOT spawn further agents — Claude Code's hard
> limit. Never instruct an implementer to "spawn its own QA/reviewer": that hits
> the ceiling and silently degrades to self-review, defeating the point of an
> independent check. If you ever interleave per-task review into this phase
> (instead of batching it into Phase 5), keep it **controller-driven**: the
> controller dispatches implementer → then reviewer per task, both depth-1. See
> `laws.md` § Spawn topology.

## 3. Per-task evidence — tasks/task-N.md

Each task's report in the run dir must contain:

```markdown
# Task N — {title}
Status: DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED
ACs: AC-{SLUG}-003, AC-{SLUG}-007

## RED
$ {test command}
{relevant failing output — pasted, before implementation}

## GREEN
$ {test command}
{relevant passing output — pasted, after}

## VALIDATE
$ {the plan's VALIDATE command}
{output}

## Files touched
- path/one.ts
## Concerns / skips
- [SKIP] {item} — {reason}   (only if any)
```

No RED section = the test was never watched failing = the task is not DONE.

## 4. Status vocabulary and responses

Statuses are closed: **DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED.**
Controller responses are prescribed: NEEDS_CONTEXT → supply the missing context or
fix the plan; BLOCKED → resolve or escalate to the user; DONE_WITH_CONCERNS → the
concern goes to Phase 5 review explicitly. Never re-dispatch the same task to the
same setup unchanged and hope.

## 5. Mid-build failures

Any bug found here routes through Law 4: root cause first
(`superpowers:systematic-debugging` / `investigate`), regression test that fails
without the fix, three strikes then escalate. One commit per task/fix; bisectable
history; commit messages reference the task number.

NEXT: `references/05-verify.md`
