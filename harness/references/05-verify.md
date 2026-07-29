# Phase 5 — Verify: four stacked layers

Each layer catches what the previous one structurally cannot. Run all four. Record every
layer in the ledger.

**`SKIP` and `UNVERIFIABLE` are different verdicts and the ship gate treats them differently.**
`SKIP` means NO SURFACE EXISTS to check — no UI → no visual runtime pass — and must name the
absent surface. `UNVERIFIABLE` means the check COULD NOT RUN: hooks not wired, tooling absent,
no baseline. A capability gap is never a SKIP, and `ledger.sh check` blocks on UNVERIFIABLE
exactly as it blocks on FAIL (laws.md § Corollary).

The skip policy is an **allow-list**, not a deny-list: `verify:runtime` is the ONLY phase that may be
SKIPped, and only with a note naming the absent surface. Every other required phase — `spec`, `plan`,
`verify:watch`, `verify:zerotrust`, `verify:review` — blocks on SKIP. (It was a deny-list for one
commit; review found that `spec` and `plan` had been left exempt by omission, so a run with no
approved spec shipped by writing SKIP. A deny-list silently exempts whatever nobody remembered to
add.)

## Layer 0 — Said-vs-did (the action ledger)

```bash
python3 .claude/skills/eng-harness/scripts/watch.py verify
```

Diffs the session's completion claims against the hook-captured action ledger
(`.eng-harness/watch/*.jsonl`). Catches the lies that produce no artifact: "tests
pass" when no test command ran; a test that ran red narrated as green; claimed
commits that never happened. v1 is warn-mode — a HIGH flag doesn't block the
session, but it DOES block this phase: treat any HIGH flag as a FAIL, produce the
missing evidence (actually run the thing), and re-verify.
If no session file exists, `watch.py verify` prints `VERDICT: UNVERIFIABLE` and exits 2: the
check could not run because hooks are not wired. Record it as exactly that —
`ledger.sh append <run-slug> verify:watch UNVERIFIABLE "hooks not wired in this repo"` — which
BLOCKS the ship gate. It is not a skip, and Layers 1–3 do not substitute for it. Wire the hooks
(a capability gap is fixed at intake — laws.md § Uniform application), then re-run.

## Layer 1 — Mechanical (zero-trust)

Run `zero-trust-verification` on the changed surface (build/typecheck/test exit
codes, coverage where wired, claims-manifest for docs). Its envelope is the
verdict: REJECTED = loop back to Build, no exceptions, no "but it's actually
fine." *Fallback without zero-trust:* run build + full test suite + lint yourself
and paste outputs into `run.md`.

## Layer 2 — Adversarial review (judgment)

Dispatch reviewer subagent(s) per superpowers:requesting-code-review with two
hardening rules. Reviewers are dispatched by the depth-0 controller, never by an
implementer subagent (depth-1 can't spawn — see `04-build.md` § Spawn topology).
This holds if review ever moves per-task into Phase 4: still controller-driven.

**Route reviewers by the SURFACE's ceiling** (`model:` per dispatch — an unnamed dispatch silently
runs at the ambient default: Sonnet where `CLAUDE_CODE_SUBAGENT_MODEL` is set, otherwise the
conductor's own Opus. Never leave a reviewer unnamed). For a LARGE or open-ended surface —
whole-branch review, a big/novel diff, a security or edge-case hunt over real code — use
**Fable 5** (`claude-fable-5`): that's where the frontier reasoner earns its rate (it found 8/14
real bugs in a 1,130-line file vs Opus's 5, fewest false positives, cheapest per bug —
`wiki/methodology/eng-harness.md`). For a BOUNDED check — a small diff, a short list, a single
function — a cheaper reviewer (**Sonnet 5**, or **Haiku 4.5** for the mechanical part) ties Fable at
a fraction of the cost (384-gen model-bench: all tiers within <1 point on bounded checks). Don't
reflexively spend Fable on every review; spend it where the surface is big enough to have a real
ceiling. Either way, give reviewers an **output-only discipline: return findings (file:line + quote
+ severity + failure scenario), never rewritten code** — that keeps the tier cheap and forces the
fix back onto the Sonnet 5 build step.

**Fable refusal fallback — an empty review is UNRUN, never PASS.** Fable 5 runs safety classifiers
over research biology and MOST cybersecurity content and can refuse. The refusal arrives as HTTP 200 with
`stop_reason: "refusal"` — not an error — so a refused reviewer subagent returns **nothing,
silently**, and this layer reads as "no findings found." A security pass is the likeliest review to
trip it and the worst one to lose. So: **a reviewer that returns no findings AND no quoted lines is
treated as UNRUN.** Re-dispatch the identical review on **Opus 4.8** (`claude-opus-4-8` — the only
supported fallback target *at launch*; expansion expected, so re-check before hard-coding it), note
the swap in `run.md`, and only then read the result. Where the API
call is yours to write, declare it up front instead: `betas: ["server-side-fallback-2026-06-01"]` +
`fallbacks: [{"model": "claude-opus-4-8"}]` (fallbacks are not automatic — a request without them
just stops). **Record the reviewer's model in the `verify:review` ledger row** — that row is the only
after-the-fact evidence of which tier actually reviewed, and of any Fable→Opus swap.
Opus 4.8 keeps final judgment regardless: reviewers find, the conductor decides.

  (give the reviewer the watch JSONL path as ground truth).
- **Quote gate** — every finding must cite the verbatim motivating line
  (`file:line` + the exact text). A finding that can't quote its line is
  suppressed, not reported. No invented confidence.

Two verdicts per task, kept separate: **Spec compliance** vs the AC IDs
(Missing / Extra / Misunderstood — over-building is a failure too) and **Code
quality** (Critical / Important / Nice-to-have). Critical or Important → fix →
mandatory re-review. Loop until zero blocking findings. Lane C: final whole-branch
review on Fable 5 + security pass (OWASP basics, secrets scan) — the security pass
is the one most likely to hit a `cyber` refusal, so apply the Opus 4.8 fallback
above rather than accepting a silent empty result.

## Layer 3 — Runtime (tests pass ≠ feature works)

Drive the actual software end-to-end on the affected flows: `verify` skill, or
`qa` / `playwright-e2e` for web UI (screenshot evidence, before/after pairs), or
manual run for CLIs/scripts with pasted transcript. Walk each AC against the
running system and mark it met/unmet in `audit.md` as you go.

## Record

**FAIL rows are mandatory (no silent fix cycles).** The moment any layer rejects —
a HIGH watch flag, a zero-trust REJECT, blocking review findings, a runtime
failure — append a FAIL row with the finding BEFORE starting the fix cycle, then
append the PASS after re-verification. A fix cycle must appear in the ledger as a
FAIL→PASS pair; two PASS rows hide the catch and make the ledger unfalsifiable
(230 rows, 0 FAILs was the historical result — a survivorship artifact, not a
quality record).

```bash
# SKIP is legal ONLY on verify:runtime, and only with a note naming the absent surface.
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:watch  PASS|FAIL|UNVERIFIABLE "note"
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:zerotrust PASS|FAIL|UNVERIFIABLE "note"
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:review PASS|FAIL|UNVERIFIABLE "rounds: N"
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:runtime PASS|FAIL|SKIP|UNVERIFIABLE "note"
```

All four recorded, none of them UNVERIFIABLE → NEXT: `references/06-ship.md`
(`verify:runtime SKIP` with a note is the one permitted skip.) Prove it, don't assert it:
`bash .claude/skills/eng-harness/scripts/ledger.sh check <run-slug>` must exit 0.
