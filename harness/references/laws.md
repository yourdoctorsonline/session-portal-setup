# The Laws — cross-cutting, binding in every phase

These are not style preferences. Each one exists because a real agent failure mode
was observed and named across the harnesses this skill was distilled from
(superpowers, gstack, archon, 8090, agentwatch — see
`projects/briefs/agentic-engineering-harness/2026-07-06_harness-study.md`).
Violating the letter of a law is violating the law.

## 1. Fresh evidence — no claim without proof in THIS message

You may not state that anything works, passes, builds, or is complete unless you ran
the proving command in the current message and read its full output. Evidence from
earlier in the session is stale the moment code changes.

The rationalizations, pre-answered:

| The thought | The reality |
|---|---|
| "Should work now" | RUN IT. |
| "I'm confident" | Confidence is not evidence. |
| "I already tested earlier" | Code changed since then. Test again. |
| "It's a trivial change" | Trivial changes break production. |
| "The test file looks right" | Looking is not running. |
| "I'll note it as probably fine" | "Probably" in a completion claim is a lie with hedging. |

Claiming work is complete without verification is dishonesty, not efficiency.

## 2. Exit codes decide, not narration

Anything a command can report — tests, builds, lint, file existence, PR state,
coverage — is decided by running the command and reading the exit code/output.
Never summarize what a check "would" say. Never let a subagent's prose stand in
for a command result: require the pasted output.

## 3. Approval semantics

A phase that requires user approval advances ONLY when the user's latest message
explicitly approves. Questions are not approval. Feedback is not approval.
Enthusiasm ("looks interesting!") is not approval. Silence is not approval.
When in doubt, ask: "Approve, or should I adjust?"

## 4. Root cause before fix, three strikes then escalate

No fix without a confirmed root cause (route to `superpowers:systematic-debugging`
or `investigate`). A regression test must fail without the fix and pass with it.
After 3 failed fix hypotheses, STOP — this is a wrong-architecture signal, not a
fourth hypothesis. Take it to the human.

## 5. Scope containment

Implement only what the plan says. Pre-existing failures and unrelated breakage are
documented in the run dir and reported — never fixed in this run, never used as
cover for scope creep. The plan's NOT-Building list is a fence, not a suggestion.
If scope genuinely must change, update spec + plan first, with user approval.

## 6. Disk over memory

The run dir is the state; the conversation is not. At every phase entry, re-read the
phase reference file and the run artifacts (spec.md, plan.md, progress) from disk —
your memory of instructions read 100k tokens ago is lossy, and compaction can strike
at any time. Artifacts route the pipeline: each phase's output file names the next
phase at the top ("NEXT: …"), so any fresh session can resume correctly.

## 7. Skips are visible

Every checklist item in the run dir is either checked with evidence or marked
`[SKIP] — <reason>` on the same line. A silent omission is treated as a false claim.
Skipping a whole gate (e.g., no UI stage on a backend change) is fine — write the
one-line reason.

## Model routing (economy, not law)

Mechanical steps (transcription-grade implementation from a complete plan, log
scanning) → cheapest model that works. Judgment steps (final review, adversarial
verify, architecture) → the most capable model available. State the model choice in
each subagent dispatch; a dispatch that omits it silently inherits the expensive one.

## Spawn topology (economy's companion)

The depth-0 controller — this skill, run inline via the Skill tool, never dispatched
via the Agent tool — does all spawning. Implementer and reviewer subagents run at
depth-1 and CANNOT spawn further agents: Claude Code's hard depth-1 limit. So every
dev↔QA or per-task-review pairing is arranged BY the controller (implementer → then
reviewer, both depth-1), never by asking a subagent to spawn its own helper. A
subagent told to "spawn your QA" hits the ceiling and silently degrades to
self-review — the exact failure Law 1 and Phase 5 exist to prevent.
