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

**The ceiling decides — not the domain, not the verb.** A 384-generation benchmark across
engineering/marketing/operations/accounting × make/decide/check/grind found all four models
(Fable/Opus/Sonnet/Haiku) tied within <1 point on WELL-SPECIFIED, bounded tasks — classification,
small bug lists, standard decisions, reconciliation, routine copy. On those, tier is a COST lever,
not an accuracy lever: default to the cheapest that works. Tier becomes an ACCURACY lever only at a
HIGH task ceiling — large-scope review, novel/ambiguous hard reasoning, long autonomous multi-step
(Fable found 8/14 real bugs in a 1,130-line file vs Opus's 5, yet ties everyone on a 12-item bug
list). Before paying 4–5× for Fable/Opus, ask: **is THIS task at its ceiling?** If not, don't.
(Evidence: `wiki/methodology/eng-harness.md` — model-bench + the review bake-off.)

Within that, route by **output-token intensity and cognitive shape**: output tokens cost ~5× input
($10/M in vs $50/M out), so expensive models belong in LOW-output/high-judgment phases. Four verbs →
four DEFAULT models (escalate UP only at a high ceiling):

| Verb | Phase examples | Default model |
|------|----------------|---------------|
| **Decide** | intake, spec, plan, architecture, final ship judgment | **Opus** (conductor; holds full context) |
| **Make**   | Build/implementation from a complete plan (high output) | **Sonnet** (the default) |
| **Check**  | adversarial review, security/edge-case hunt, "meets spec?" | **Fable** for a LARGE / open-ended surface (whole-branch, big diff, novel code); **Sonnet/Haiku** for a BOUNDED check (small diff, short list) — they tie Fable there |
| **Grind**  | log/transcript scan, rename sweeps, parallel file reads, mechanical edits | **Haiku** |

Two-class subagent rule (do NOT set a blanket cheap subagent default): **implementers →
Sonnet/Haiku**; **reviewers/verifiers of a HIGH-ceiling surface → Fable**. A global
`CLAUDE_CODE_SUBAGENT_MODEL=sonnet` is the safe FLOOR for unnamed dispatches; per-dispatch `model:`
overrides it and always wins. Name the model in EVERY dispatch — a reviewer left on the floor for a
high-ceiling surface silently degrades the whole verify gate.

Two cost traps the benchmark surfaced:
- **Cost is per FINISHED task, not per token.** Haiku is cheapest per token but its output BALLOONS
  when unsure (≈2× on hard tasks) — cheap-tier ≠ fewest-tokens on hard work. A pricier one-shot still
  beats a cheap redo.
- **Bigger isn't better at constraints.** On tight output rules (char limits, strict formats) the
  SMALLER models were MORE compliant; Opus/Sonnet over-elaborate and blow the limit. Constrained
  output → cheaper/constrained model.

**Chain cost — a token's real price.** Output emitted at one step is paid once at that model's
output-rate, then RE-PAID at input-rate at every LATER step that still carries it in context. Two
consequences, in priority order (quantified in `projects/model-bench/chain_cost.py`):
1. **Tier-per-step by ceiling is the dominant lever.** Not over-spending the frontier tier on a
   sub-ceiling step swamps everything else — routing a BOUNDED check to Haiku instead of Fable cut a
   4-step pipeline ~40% in the chain model. Fix the per-step tier first.
2. **Compact the handoff.** Pass the next step a diff / findings / structured summary, NOT the full
   output, so a verbose step can't tax the whole chain. Matters most in long/thin chains; near-zero
   when base context already dwarfs step outputs (in a thick-context harness, feeder-terseness —
   Haiku's verbosity vs Sonnet's — is second-order noise, so cheap-per-token still wins there).

Never chat with Fable/Opus (dialogue is Sonnet's job).

## Spawn topology (economy's companion)

The depth-0 controller — this skill, run inline via the Skill tool, never dispatched
via the Agent tool — does all spawning. Implementer and reviewer subagents run at
depth-1 and CANNOT spawn further agents: Claude Code's hard depth-1 limit. So every
dev↔QA or per-task-review pairing is arranged BY the controller (implementer → then
reviewer, both depth-1), never by asking a subagent to spawn its own helper. A
subagent told to "spawn your QA" hits the ceiling and silently degrades to
self-review — the exact failure Law 1 and Phase 5 exist to prevent.
