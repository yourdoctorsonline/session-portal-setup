---
name: zero-trust-verification
description: >-
  Deterministic, non-bypassable gate that catches AI hallucinations by ignoring what
  an agent SAYS and comparing its claims to on-disk / runtime artifacts. Three domains
  — CODE (build/typecheck exit codes, coverage, mutation score = tautological-test
  detector), DOCS/RESEARCH (live dead-link check, claims-manifest grounded by grep),
  VISUAL (OCR text presence, image dims, a Tier-B second-model cross-check). Emits one
  strict JSON envelope with exact metric deltas; exits 1 on REJECTED. Wires into CI
  (PR required check), a session Stop-hook, and the Workflow tool's pipeline()/parallel().
  The mechanical engine behind meta-proof-of-work. Triggers on: "verify this", "zero
  trust", "catch hallucinations", "gate this", "prove the coverage/tests/citations",
  "check this image/doc/module", "before merge", "did it actually meet the spec".
---

# zero-trust-verification — trust artifacts, not assertions

**Premise:** a claim is not reality. An agent's "tests pass / it works / this citation is
real / the mockup matches" is an assertion, and assertions are exactly where hallucinations
hide. This skill never grades the assertion. It extracts the **objective artifact** the
assertion is *about* and compares mechanically. Companion to [[meta-proof-of-work]] (that
skill sets the *policy* — no claim without a receipt; this one is the *runnable engine* that
produces the receipt and the pass/fail).

## The one rule that makes it deterministic

You can only *deterministically* catch a hallucination when there is a machine-checkable
ground truth to compare against. So every check is tagged with its tier:

| Tier | What it is | Verdict |
|---|---|---|
| **A — deterministic** | claim vs on-disk/runtime artifact (exit code, coverage number, HTTP status, grep hit, OCR text, image dims) | auto **REJECTED** |
| **B — cross-model** | a *second* model disagrees with the spec (the vision cross-check). Fallible — you're checking one model with another | **WARN**, route to human |
| **C — human** | faithfulness/quality nothing mechanical can settle | listed in `unverifiable[]` |

The power move is pushing everything possible into Tier A, and — critically — **listing what
it could NOT prove in `unverifiable[]`**. That residue list is the honesty: it stops the gate
from implying "all clear" on things it never checked.

## Invocation

```
python3 scripts/zerotrust/verify.py --domain <code|docs|visual|auto> --path <PATH> [flags]
```
Flags: `--run` execute the configured build/test commands · `--spec <file>` expected-text for
the visual OCR gate · `--no-net` skip link checks · `--no-vision` skip the Tier-B check ·
`--selftest` prove the gate logic (run this in CI). Exit code: **1 = REJECTED**, else 0.

## The three domain handlers

**CODE** — `coverage-summary.json` (Istanbul) or `coverage.json` (coverage.py) parsed for
line/branch %. Mutation report (`mutation.json`, Stryker or `{"mutationScore":N}`) parsed for
kill-rate. **High coverage + low mutation = `TAUTOLOGICAL_SMOKE_TEST`** (tests run the code but
assert nothing) → REJECT. With `--run`, also runs `commands.build`/`commands.test` and gates on
exit code. No artifact present → the gate is SKIPPED and noted in `unverifiable[]`, never a
false REJECT.

**DOCS/RESEARCH** — extracts every URL and checks live HTTP (via Python `urllib`, because
`curl`/`wget` are denied in settings.json). Only permanent 4xx (404/410) = dead → REJECT;
403/429/5xx/timeout = `unverifiable` (bot-block/paywall/transient), never a false fail. Where a
path sets `require_claims:true`, it demands a `<doc>.claims.json` sidecar mapping each claim to
`{anchor, source}` and **greps the anchor string in the source file** — fabricated citations die
here. (It proves the source *contains* the anchor, not that it *supports* the claim — that last
step is Tier C.)

**VISUAL** — `tesseract` OCR extracts embedded text, normalized-matched against `--spec` (catches
typos / missing CTA / garbled headline). `sips` reads dimensions. Tier-B: routes the image to
`commands.vision` (your `codex exec`) with a Program-of-Thought template forcing a JSON of object
labels+counts, compared to `<img>.expect.json`. A mismatch is **advisory WARN, not a reject** —
it's a second model, itself fallible. For UI you *own* (React), prefer deterministic Playwright
DOM counts over OCR+vision.

## Output contract (every domain, same shape)

```json
{ "status": "REJECTED", "domain": "code", "target": "…/mailbox.ts", "tier": "strict",
  "gates": [ {"id":"line_coverage","source":"coverage/coverage-summary.json",
              "expected":90,"actual":74,"pass":false,"next":"line coverage +16pp"} ],
  "unverifiable": ["no mutation report — mutation gate skipped"],
  "tier_b_divergence": [],
  "next_action": "line coverage +16pp" }
```
`status`: `REJECTED` (a Tier-A gate failed) · `WARN` (only unverifiable/Tier-B) · `PASSED` · `SKIP`
(tier `none`). No markdown, no prose — a fixing agent debugs the delta directly.

## Config — `.zerotrust.json` (walked up from the target)

Per-path **tiers** stop false rejects: `strict` (all gates) for `command-centre/src/lib/**`,
`smoke` (no coverage/mutation reject) for scripts, `none` (skip) for `projects/**` data outputs.
`require_claims:true` opts a path into citation-grounding. `commands` supplies build/test/vision.
Thresholds (`line`/`branch`/`mutation`) are per-path, never hardcoded in the engine.

## Three enforcement points (this is the "non-bypassable" part)

A skill alone is advisory. Real teeth come from wiring the same CLI into:
1. **CI required check** — `.github/workflows/zero-trust.yml` runs `--selftest` + gates changed
   files on every PR to `main`. Hard block on merge (branch protection already requires CI).
2. **Session Stop-hook** — `.claude/hooks/zerotrust-stop.js` blocks ending a session while a
   changed file is REJECTED. Fail-open on its own errors.
3. **Workflow pipeline** — `scripts/zerotrust/zerotrust.workflow.js`: a REJECTED status throws
   and routes the delta to a fix agent, then re-verifies.

## Prerequisites & graceful degradation

`python3` (present), `sips` (macOS, present), `codex` (present) — optional: `tesseract`
(`brew install tesseract`) for the OCR gate. Any missing tool → that gate is **skipped and noted
in `unverifiable[]`, never a crash or false REJECT** (a gate that fails because a tool is absent
is itself a hallucination). Learnings: `wiki/methodology/zero-trust-verification.md`.
