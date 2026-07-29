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

## The gate standard — two tests before anything counts as a gate

Every check here is either **physics** (a command decides; the result is not negotiable) or **prose**
(the conductor is asked to comply). Prose fails in one direction only: toward "done". Every gap
measured in this harness on 2026-07-26 had that same sign: a watcher logging PASS while examining
almost nothing, a ship gate accepting every layer being skipped, Lane B runs shipping on template
plans, and the installer that wires the hooks printing "Setup complete." after failing to wire them.
**Figures are deliberately not quoted here — they go stale within the day.** Re-derive them:
`bash .eng-harness/runs/2026-07-26_gate-standard-law/measure.sh` (M1-M5; the snapshot it produced is
committed beside it as `measure.out`). A new check is not a gate until it passes
both tests below.

### Test 1 — could a command decide this?

If yes, it may not be a prompt. No exemption for "the protocol says so" or "the agent will remember".
Anything checkable is a script or it is debt: artifact completeness, AC traceability, phase ordering,
hook presence, quote resolution, coverage. **A rule whose enforcement depends on the cooperation of
the party it constrains is honour-based however firmly it is worded** — that includes every law in
this file, which is why the laws are backed by scripts rather than by their own severity.

### Test 2 — for judgment: what is the reference, and what happens on a delta?

Judgment gates (review, runtime, design taste) are measurable — but only when the
criteria are committed BEFORE the gate runs. Four stages, all mechanical:

1. **Pre-register** — derive criteria from the diff and the spec: every changed file, every in-scope
   AC, every risk class the surface touches (auth, data loss, injection, error paths, idempotency,
   concurrency). Generated, not authored.
2. **Mark against each** — the gate returns a row per criterion, not a free-form list. Silence on a
   criterion becomes a detectable absence instead of an invisible one.
3. **Verify the evidence** — quote-gate every finding against the file, resolve every `file:line`,
   confirm every cited AC exists. All grep.
4. **Compare to a reference, then explain the delta.** A gate with no reference is not measured.

References, cheapest first: **criteria coverage** (makes a bad gate visible) · **seeded defects**
(inject N synthetic faults, score recall, strip before merge — per-run, cheap, adversarial) ·
**mutation score** (already declared in `.zerotrust.json` at 80, inert for want of tooling) ·
**escaped defects** (attributed back to the gate that missed them — slowest, truest).

**Criteria-marking alone degrades into checkbox theatre** — a review can mark twelve criteria
"examined, no issue" and be worthless, and the checker cannot tell. Every judgment gate needs at
least one ADVERSARIAL reference.

### Corollary — a check that could not run is not a check that passed

`SKIP` means **no surface exists**, and must name the absent surface. Law 7's allowance for skipping a
whole gate covers exactly that case — it was never a licence for a capability gap. A check that *could
not run* (missing hooks, absent tooling, no baseline) is a different thing, and "the infrastructure
wasn't there" is never a passing answer.

**Status: ENFORCED since 2026-07-26** (run `verdict-split-unverifiable`). `ledger.sh` carries a fourth
verdict, `UNVERIFIABLE`, and `check` blocks on it exactly as on FAIL. **Record a capability gap as
UNVERIFIABLE** — never as SKIP, and no longer as FAIL. The skip policy is enforced in the script rather than
merely documented, and as an **allow-list**: `verify:runtime` is the only phase that may be SKIPped,
and only with a note naming the absent surface; every other required phase blocks on SKIP. The gate
also refuses to run on data it cannot trust — an unparseable ledger row, or a missing `git` (which
would stamp every row `commit:"none"` and make the staleness compare self-satisfying) both return
UNVERIFIABLE, never PASS. `watch.py verify`
exits non-zero when it finds no session ledger, so the verdict can no longer be quietly downgraded to
SKIP on the way into the ledger. Re-derive the behaviour instead of trusting this paragraph:
`python3 .claude/skills/eng-harness/scripts/test_gates.py` for the contract, and
`bash .eng-harness/runs/2026-07-26_verdict-split-unverifiable/measure.sh` for the population it was
sized against.

Its companion, which is what makes the above hold under failure: gate scripts **fail open on process,
closed on verdict** — never crash a session, never report success for a check that did not run. See
SKILL.md rule 2026-07-06 (amended).

### Pre-registration is not gate-specific

Any open-ended work — audit, research, investigation, review — writes down what it will test BEFORE it
starts. Without a pre-registered criteria set, coverage is unverifiable: the work may have been
thorough, but nobody can tell what was *not* examined, which makes the work itself honour-based. **If
the base assumptions do not exist, ask for them before starting** — never invent them silently.
Discoveries are promoted, not absorbed: anything found mid-flight that was not in the pre-registered
set becomes its own hypothesis with its own criteria and its own verifiable outcome. That promotion
rule is load-bearing, not decoration — it is what stops the list from capping what gets found, since a
criteria list treated as exhaustive is a blinker.

Worked contrast, same day and same conductor: the harness audit ran open-ended and produced 15
findings with **no defensible completeness claim** — nobody can say what went unchecked. The review
bench pre-registered 14 defects in a sha-pinned file and produced "13/14, missing AC-005, right line
wrong mechanism." Same effort, same care; only one is a result you can act on.

### An honour-system check is a defect, not debt

If a check turns out to run on trust, it is broken by definition: redo it, do not schedule it. Debt is
deprioritised indefinitely; defects get fixed.

**Law 5 carve-out.** If the trust-based check sits outside the current run's scope, do not fix it
inline — that is scope creep, and Law 5 forbids it. Document it in the run dir and promote it to its
own run before the session ends. "Defect, not debt" governs how it is *classified and queued*; it is
never a licence to widen the diff you are already in.

### Uniform application — no partial pipelines, no per-repo variation

Every run in every repo executes the full pipeline. A repo where "some aspects aren't wired" is not a
lighter-weight repo — it is a repo silently accumulating unverified flaws, and its output quality
degrades with each one. **Proof never scales with stakes.** Lane *ceremony* (spec/plan depth) may
scale, but only by the pre-declared gated rule in `01-intake.md`, and every lane — Lane A included —
owes all four verify layers. A missing capability in the environment is a BLOCKING condition fixed at
intake (see the Corollary above): never a lane, never a skip.

Adversarial review is therefore always on, always emits proof (findings quote-resolved against the
file, mapped to ACs, one row per pre-registered criterion), and **the conductor inspects the proof,
not the summary.** A reviewer's report is a claim set; reading it is not verification. On 2026-07-26 a
reviewer cited the correct line for a different mechanism — caught only because the quotes were
checked against the source, and scored as a miss.

### The criteria lists are never finished

You cannot prove a criteria list complete; unknown unknowns are real. That is not a licence to keep
prose gates — it makes each list a living artifact with its own loop: **every defect that escapes
without a matching criterion becomes a new criterion.**

## Model routing (economy, not law)

### The roster — exact IDs and what they cost

Prices are per 1M tokens, input / output. Verified against the `claude-api` skill's model table
on 2026-07-24; re-check there before quoting a price or writing an ID into code.

| Tier | Model ID | $/1M in | $/1M out | Context |
|------|----------|---------|----------|---------|
| **Fable 5** — most capable | `claude-fable-5` | $10 | $50 | 1M |
| **Opus 4.8** — top Opus | `claude-opus-4-8` | $5 | $25 | 1M |
| **Sonnet 5** | `claude-sonnet-5` | $3 *(intro $2 through 2026-08-31)* | $15 *(intro $10)* | 1M |
| **Haiku 4.5** | `claude-haiku-4-5` | $1 | $5 | 200K |

**There is no "Opus 5."** The top Opus is **4.8**; the most capable tier overall is **Fable 5**.
A plan, prompt, or config that names `claude-opus-5` is naming a model that does not exist — it
will fail the request, not silently downgrade. When this harness says "Opus" unqualified it means
Opus 4.8; "Fable" means Fable 5; "Sonnet" means Sonnet 5; "Haiku" means Haiku 4.5.

**The ceiling decides — not the domain, not the verb.** A 384-generation benchmark across
engineering/marketing/operations/accounting × make/decide/check/grind found all four models
(Fable/Opus/Sonnet/Haiku) tied within <1 point on WELL-SPECIFIED, bounded tasks — classification,
small bug lists, standard decisions, reconciliation, routine copy. On those, tier is a COST lever,
not an accuracy lever: default to the cheapest that works. Tier becomes an ACCURACY lever only at a
HIGH task ceiling — large-scope review, novel/ambiguous hard reasoning, long autonomous multi-step
(Fable found 8/14 real bugs in a 1,130-line file vs Opus's 5, yet ties everyone on a 12-item bug
list). Before paying 4–5× for Fable/Opus, ask: **is THIS task at its ceiling?** If not, don't.
(Evidence: `wiki/methodology/eng-harness.md` — model-bench + the review bake-off.)

Within that, route by **output-token intensity and cognitive shape**: output tokens cost **5× input
at every tier** (Fable $10→$50, Opus $5→$25, Sonnet $3→$15, Haiku $1→$5), so expensive models belong
in LOW-output/high-judgment phases. Four verbs → four DEFAULT models (escalate UP only at a high
ceiling):

| Verb | Phase examples | Default model | Escalate to |
|------|----------------|---------------|-------------|
| **Decide** | intake, spec, plan, architecture, final ship judgment | **Opus 4.8** (conductor; holds full context) | **Fable 5** — planning ONLY, and only for a genuinely novel / wide-solution-space problem |
| **Make**   | Build/implementation from a complete plan (high output) | **Sonnet 5** at `effort: low` | Sonnet 5 at higher effort before you change tier |
| **Check**  | adversarial review, security/edge-case hunt, "meets spec?" | **Fable 5** for a LARGE / open-ended surface (whole-branch, big diff, novel code); **Sonnet 5 / Haiku 4.5** for a BOUNDED check (small diff, short list) — they tie Fable there | — (Fable IS the ceiling; on refusal fall BACK to Opus 4.8, below) |
| **Grind**  | log/transcript scan, rename sweeps, parallel file reads, mechanical edits | **Haiku 4.5** — trivial, high-volume work only | Sonnet 5 the moment the task stops being mechanical |

**The conductor and the planner are ONE seat — Opus 4.8.** The planner is not a separately
swappable model: Phase 3 runs INLINE in the conductor (this skill, depth-0, via the Skill tool),
because planning needs the full accumulated context — spec, repo reads, user constraints — that a
fresh subagent does not have. So "use Fable for planning" is not a `model:` flag you can set; it
means the human moves the whole conductor onto Fable 5 for that run, or the conductor dispatches a
scoped Fable *design-options* subagent and keeps the plan-writing itself. Do that only for a
genuinely novel / wide-solution-space problem (unfamiliar architecture, no prior art in-repo, real
branching in the approach). Routine feature planning stays on Opus 4.8 — the bench found no
accuracy gap on well-specified planning, only a 2× bill.

**Verbosity is an EFFORT knob, not a model choice.** If output is too long, too hedged, or too
tool-chatty, lower `effort` (`low` / `medium` / `high` / `xhigh` / `max`) — lower effort means fewer
and more-consolidated tool calls, less preamble, terser confirmations. Do NOT reach for a smaller
model to get terser output: you lose accuracy to buy a formatting change you could have had for
free. Build subagents default to **Sonnet 5 at `effort: low`**; raise the effort before you raise
the tier. (`opts.effort` on Workflow `agent()`; `output_config.effort` on the API.)

exits non-zero when it finds no session ledger, so the verdict can no longer be quietly downgraded to
SKIP on the way into the ledger. Re-derive the behaviour instead of trusting this paragraph:
`python3 .claude/skills/eng-harness/scripts/test_gates.py` for the contract, and
`bash .eng-harness/runs/2026-07-26_verdict-split-unverifiable/measure.sh` for the population it was
sized against.

Its companion, which is what makes the above hold under failure: gate scripts **fail open on process,
closed on verdict** — never crash a session, never report success for a check that did not run. See
SKILL.md rule 2026-07-06 (amended).

### Pre-registration is not gate-specific

Any open-ended work — audit, research, investigation, review — writes down what it will test BEFORE it
starts. Without a pre-registered criteria set, coverage is unverifiable: the work may have been
thorough, but nobody can tell what was *not* examined, which makes the work itself honour-based. **If
the base assumptions do not exist, ask for them before starting** — never invent them silently.
Discoveries are promoted, not absorbed: anything found mid-flight that was not in the pre-registered
set becomes its own hypothesis with its own criteria and its own verifiable outcome. That promotion
rule is load-bearing, not decoration — it is what stops the list from capping what gets found, since a
criteria list treated as exhaustive is a blinker.

Worked contrast, same day and same conductor: the harness audit ran open-ended and produced 15
findings with **no defensible completeness claim** — nobody can say what went unchecked. The review
bench pre-registered 14 defects in a sha-pinned file and produced "13/14, missing AC-005, right line
wrong mechanism." Same effort, same care; only one is a result you can act on.

### An honour-system check is a defect, not debt

If a check turns out to run on trust, it is broken by definition: redo it, do not schedule it. Debt is
deprioritised indefinitely; defects get fixed.

**Law 5 carve-out.** If the trust-based check sits outside the current run's scope, do not fix it
inline — that is scope creep, and Law 5 forbids it. Document it in the run dir and promote it to its
own run before the session ends. "Defect, not debt" governs how it is *classified and queued*; it is
never a licence to widen the diff you are already in.

### Uniform application — no partial pipelines, no per-repo variation

Every run in every repo executes the full pipeline. A repo where "some aspects aren't wired" is not a
lighter-weight repo — it is a repo silently accumulating unverified flaws, and its output quality
degrades with each one. **Proof never scales with stakes.** Lane *ceremony* (spec/plan depth) may
scale, but only by the pre-declared gated rule in `01-intake.md`, and every lane — Lane A included —
owes all four verify layers. A missing capability in the environment is a BLOCKING condition fixed at
intake (see the Corollary above): never a lane, never a skip.

Adversarial review is therefore always on, always emits proof (findings quote-resolved against the
file, mapped to ACs, one row per pre-registered criterion), and **the conductor inspects the proof,
not the summary.** A reviewer's report is a claim set; reading it is not verification. On 2026-07-26 a
reviewer cited the correct line for a different mechanism — caught only because the quotes were
checked against the source, and scored as a miss.

### The criteria lists are never finished

You cannot prove a criteria list complete; unknown unknowns are real. That is not a licence to keep
prose gates — it makes each list a living artifact with its own loop: **every defect that escapes
without a matching criterion becomes a new criterion.**

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
Sonnet 5 / Haiku 4.5**; **reviewers/verifiers of a HIGH-ceiling surface → Fable 5**. A global
`CLAUDE_CODE_SUBAGENT_MODEL=sonnet` is a safe FLOOR for unnamed dispatches **where it is actually
set** (see § What is actually ENFORCED — it is not set in this repo, and unset means subagents
inherit Opus); per-dispatch `model:` overrides it and always wins. Name the model in EVERY dispatch —
a reviewer left on the ambient default for a high-ceiling surface silently degrades the whole verify
gate.

**Fable 5 can REFUSE — always name a fallback.** Fable runs safety classifiers over research
biology and most cybersecurity work. A refusal comes back as **HTTP 200** with
`stop_reason: "refusal"` and a `stop_details.category` such as `cyber`, `bio`,
`reasoning_extraction`, `frontier_llm`, or `null` — **these are examples, not a closed set**; the
public docs carry the full category table, so never `switch`/`match` on these five alone or assert
that an unlisted value is malformed. Pre-output the refusal is empty and unbilled; mid-stream it is
partial and billed.
It is NOT an error, so a refused reviewer subagent returns **nothing, silently**, and the verify
gate reads as "no findings" — a clean-looking pass that was never performed. This is exactly the
failure Law 1 exists to catch: an empty review is not a passing review. Two defenses, use both:
1. **Declare the API fallback** where the call is yours to make — `betas: ["server-side-fallback-2026-06-01"]`
   plus `fallbacks: [{"model": "claude-opus-4-8"}]`. `claude-opus-4-8` is the only supported
   fallback target at launch. Fallbacks are **not automatic**: a request without them just stops.
   The parameter is rejected on the Batches API and unavailable on Bedrock / Vertex / Foundry —
   there, register the client-side `BetaRefusalFallbackMiddleware` instead.
2. **Re-dispatch on empty** where you can't set betas (Agent / Workflow dispatches). A reviewer that
   returns no findings AND no quoted lines is treated as UNRUN, not as PASS — re-dispatch the same
   review on **Opus 4.8** and record the swap in `run.md`.

The fallback model can refuse too — a `refusal` on the *final* response means the whole chain
declined. Two empties in a row is not a third dispatch: it is a **human escalation**, and the run
records the layer as `FAIL — review refused, unverified`, never as a skip.

Security review is the highest-value review this harness runs and the likeliest to trip `cyber`, so
this fallback is load-bearing, not theoretical. **Opus 4.8 keeps final judgment either way** — the
conductor weighs the findings and calls the verdict; Fable is a finder, never the decider.


### Uniform application — no partial pipelines, no per-repo variation

Every run in every repo executes the full pipeline. A repo where "some aspects aren't wired" is not a
lighter-weight repo — it is a repo silently accumulating unverified flaws, and its output quality
degrades with each one. **Proof never scales with stakes.** Lane *ceremony* (spec/plan depth) may
scale, but only by the pre-declared gated rule in `01-intake.md`, and every lane — Lane A included —
owes all four verify layers. A missing capability in the environment is a BLOCKING condition fixed at
intake (see the Corollary above): never a lane, never a skip.

Adversarial review is therefore always on, always emits proof (findings quote-resolved against the
file, mapped to ACs, one row per pre-registered criterion), and **the conductor inspects the proof,
not the summary.** A reviewer's report is a claim set; reading it is not verification. On 2026-07-26 a
reviewer cited the correct line for a different mechanism — caught only because the quotes were
checked against the source, and scored as a miss.

### The criteria lists are never finished

You cannot prove a criteria list complete; unknown unknowns are real. That is not a licence to keep
prose gates — it makes each list a living artifact with its own loop: **every defect that escapes
without a matching criterion becomes a new criterion.**

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

### What is actually ENFORCED (and what is only prose)

Everything above is **prose the conductor follows** — nothing in this section is checked by code.
There is no gate that fails a run for routing a high-ceiling review to Haiku. Only two mechanical
pins exist, and **both live in the operator's personal `~/.claude/settings.json`, NOT in this repo**:

| Pin | Where | Value | What it really does |
|-----|-------|-------|---------------------|
| Main-loop model | `~/.claude/settings.json:8` | `"model": "opus[1m]"` | Puts the conductor on Opus with the 1M context window. Treat the `[1m]` suffix as a **routing identifier, not a portable public model ID** — re-verify it after any model generation change rather than assuming it follows the newest Opus by itself. |
| Subagent floor | `~/.claude/settings.json:107` | `"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"` | Default for dispatches that do not name a model. A per-dispatch `model:` always wins. |

**The floor is NOT portable — check before you rely on it.** This repo's own
`.claude/settings.json` sets neither pin (its only `env` key is
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`). When `CLAUDE_CODE_SUBAGENT_MODEL` is unset, subagents
**inherit the conductor's model — Opus, not Sonnet.** So on a clone, a teammate's machine, or any
client workspace without that personal dotfile, an unnamed dispatch is an *Opus* dispatch at $5/$25,
the exact opposite of the cheap-floor assumption (a known open gap —
`context/memory/2026-07-21.aos.md:1546`). Verify with
`grep -n CLAUDE_CODE_SUBAGENT_MODEL ~/.claude/settings.json` at run start; if it is absent, the floor
is Opus and every unnamed dispatch is overspending.

Either way the conclusion is the same and it is the one that matters: **name `model:` on EVERY
dispatch.** Every Fable, Sonnet, or Haiku seat in the table above only happens if you write it on
that specific dispatch — forget it and the subagent quietly runs at whatever the ambient default is,
which is Sonnet on this machine and Opus everywhere else. That is the one rule here that would
benefit from a real pin rather than prose, and today cannot have one: Claude Code has no per-seat
model config, only the global default plus per-dispatch overrides. Until it does, the enforcement is
the Phase 5 ledger — record the reviewer's model in the `verify:review` row, so a mis-tiered review
on a high-ceiling surface is visible after the fact instead of invisible forever.

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
