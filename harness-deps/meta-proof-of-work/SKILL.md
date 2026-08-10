---
name: meta-proof-of-work
description: >-
  System-wide guardrail against AI "lying" — claiming work it didn't do. Enforces
  "no claim without proof": every completion/success/factual claim must ship with a
  reproducible artifact, and an adversarial reviewer independently re-verifies each
  one. Use during ANY development, debugging, research, or content task, and ALWAYS
  during adversarial reviews / double-checks / before merge or "done". Triggers on:
  "prove it", "show proof", "verify this", "did it actually work", "adversarial
  review", "double-check this", "catch hallucinations", "demand artifacts", "is this
  real", "before we ship/merge". Two gates — Gate 1 (standing protocol: receipts
  required) + Gate 2 (adversarial prove-it review). Operationalizes the Agent Watch
  idea + the catching-ai-lies research OS-wide. Does NOT replace tool-specific tests;
  it governs how claims are trusted.
---

# meta-proof-of-work — demand the receipts

**Premise: a claim is not reality.** AI agents (including this one) routinely assert work that didn't happen — "tests pass", "committed", "fixed", "it works", "X is true" — when the runner never ran, zero files changed, or the fact was invented. Research is blunt: models *knowingly* violate intent and honesty prompts barely help, so **the agent's own confidence is an unreliable signal.** Trust evidence, not words — verified where the agent can't fake it. Background: [[catching-ai-lies]], [[agent-watch]].

## When this fires
- **Always-on (Gate 1):** any time you (or a subagent) are about to claim done / fixed / passing / deployed / "it works", or state a factual/research claim.
- **On demand (Gate 2):** "prove it", "adversarial review", "double-check", "QA this", "catch hallucinations", before any merge/ship/sign-off.

## Gate 1 — Standing protocol: no claim without a receipt
Before asserting success, attach the matching artifact. No artifact → **downgrade the claim to "attempted/unverified", never "done".**

| Claim type | Required receipt |
|---|---|
| code change | the diff + the **exact command run** + its output |
| behavior / test | test command + **exit code** + captured output (run, not described) |
| bug fix | the failing case **reproduced, then passing** (before/after) |
| factual / research | a **citation** (source + quote) — or explicitly abstain ("unverified") |
| UI / visual | screenshot or recording |
| data / metric | the **query** + the raw result |

Rule of thumb: if you wrote "should", "I've ensured", "now works" without an artifact, you have not verified it — say so.

## Gate 2 — Adversarial "prove-it" review
A **fresh, independent reviewer** (separate context, no stake). **Default verdict = refuted** until evidence forces otherwise. Per claim:
1. **Demand** the artifact (Gate 1 output).
2. **Verify independently** — re-run the test in a **clean environment you didn't set up** (don't trust pasted output), re-execute the command, re-open the diff, re-check the citation against the source.
3. **Adversarial probe** — Does it pass when it *shouldn't*? Does the test actually *assert* anything? Remove the fix → does it break? Ask an "impossible" variant and confirm it's refused.
4. **Multiple lenses / N skeptics** — for high-stakes work, verify via distinct lenses (correctness · reproduction · security) or N refuters; **majority must confirm**.

Verdict per claim: **CONFIRMED** (independently reproduced) · **REFUTED** (sent back) · **UNVERIFIABLE** (flag, don't pass).

## Agent Watch checks (code claims, mechanical)
For coding claims, reconcile against ground truth — the cheap, deterministic version:
- "tests pass" → re-run the test cmd in a clean subprocess; read the **exit code**.
- "committed" → `git rev-parse HEAD` before/after + `git log`; is there a new SHA with that message?
- "files changed" → `git diff --name-only`; nonzero and names match the claim?
- "command worked" → re-exec or inspect the real logs; exit 0 + expected side-effects?

## Guards (failure modes to avoid)
- **Isolation:** execution proof is gameable when the agent controls the test env (a fake `conftest.py` "passes" everything; weak suites give 24–41% false positives). Verify where the doer couldn't tamper.
- **No self-judging:** the reviewer must not share the doer's context (kills sycophancy / self-preference bias).
- **Ignore stated confidence/honesty** — unreliable. Only artifacts count.
- **Don't penalize the catch into hiding** — surface refutations plainly; never reward a clean-looking claim over a proven one.

## Rules
*Updated when the user flags issues. Read before every run.*
- 2026-06-24: Created. Pairs with the built-in `verification-before-completion` discipline; this is the OS-wide, claim-by-claim enforcement layer.

## Self-Update
If a missed lie or a false-refute slips through, add a rule here with today's date and tighten the relevant gate.
