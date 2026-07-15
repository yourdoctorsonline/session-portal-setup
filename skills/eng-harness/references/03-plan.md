# Phase 3 — Plan: one-pass or don't start

A plan is good when a stranger with zero codebase context could implement from it
alone. Every gap in the plan becomes a guess in the build, and every guess is a
revision cycle.

## 1. Write the plan (superpowers:writing-plans + the one-pass extras)

Invoke `superpowers:writing-plans`. Its baseline rules apply (bite-sized tasks,
exact file paths, complete code in steps, no placeholders — "TBD" and "add
appropriate error handling" are plan failures). Layer on the archon extras:

- **Mandatory Reading table** — files + line ranges the implementer must read, with
  one line on why each matters.
- **Patterns to Mirror** — verbatim snippets copy-pasted from THIS codebase with
  `SOURCE: path/to/file.py:120-146` headers. Actual code, not invented. If no
  similar pattern exists in the codebase, say so explicitly — that's load-bearing
  information.
- **NOT Building** — the scope fence, copied forward from spec.md and extended
  with implementation-level exclusions.
- **Per task:** which `AC-*` IDs it satisfies · `MIRROR:` (which pattern) ·
  `GOTCHA:` (known trap) · `VALIDATE:` (the exact command that proves this task,
  with expected output).
- **Interfaces block** per task (Consumes/Produces exact signatures) so isolated
  implementers can't drift apart.
- **Plan header** (self-routing): first lines of plan.md are
  `NEXT: references/04-build.md` and `> For agentic workers: execute via
  superpowers:subagent-driven-development or superpowers:executing-plans.`

## 1b. The minimalism ladder (always on — plan the least code)

Before committing an approach for any task, walk this ladder top-down and stop at
the first rung that satisfies the AC. It runs on **every** task — there is no
intensity setting, no lite/full/ultra mode to tune. The best diff is no diff.

1. **Does it need to exist at all?** Can the AC be met without building this?
2. **Already in the codebase?** Grep first, reuse the existing function/component/
   util (this is the Patterns-to-Mirror search doing double duty).
3. **Stdlib / language builtin?** Prefer it over a hand-rolled version.
4. **Native to the platform/framework already in use?**
5. **An already-installed dependency?** No NEW dependency without explicit user
   approval.
6. **One line / a few lines inline?** Don't build an abstraction for a single caller.
7. **Only then: build the minimum** the AC demands — nothing it doesn't
   (over-building is a spec failure, caught again at Phase 5 Layer 2).

**Never on the chopping block:** input validation, data-loss handling, security,
accessibility, and the task's tests (TDD stands). Minimalism trims *scope and
cleverness*, never *safety*.

This is the plan-time companion to Law 5 (scope containment) and the §3 complexity
smell gate: the ladder picks the smallest correct approach; the smell gate catches
it when a plan blew past small. Ladder shape adapted from the "lazy senior
developer" decision ladder (ponytail).

## 2. The No Prior Knowledge Test

Read the plan as a stranger: could someone implement this using ONLY the plan and
the files it names? Every "well, they'd also need to know X" → add X. Score
one-pass confidence 1–10 in the plan footer; below 8, fix the plan, not the score.

## 3. Plan review

- `plan-eng-review` (installed): run it. Its complexity smell gate is binding —
  a plan touching >8 files or adding >2 new classes/services triggers a mandatory
  stop: propose the minimal version first, let the user choose.
- UI surface? Run `design-consultation` (if no DESIGN.md exists) and
  `plan-design-review`.
- Lane C: also a security pass over the plan (authn/z, data exposure, injection
  surfaces, secrets handling).

## 4. The staleness gate (deterministic — hard stop)

```bash
bash .claude/skills/eng-harness/scripts/check-plan-refs.sh .eng-harness/runs/<run>/plan.md
```

It mechanically verifies every file the plan cites exists (and warns on line-range
drift). Exit 1 = the plan references something that isn't there = a hallucinated or
stale reference. STOP and revise the plan. Never "fix it during implementation" —
that is exactly the moment invented context enters the build.

Record: `bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> plan PASS "refs verified, review done"`

NEXT: `references/04-build.md`
