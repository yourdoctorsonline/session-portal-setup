# Phase 5 — Verify: four stacked layers

Each layer catches what the previous one structurally cannot. Run all four (skip
with `[SKIP] — reason` only where a layer has no surface, e.g. no UI → no visual
runtime pass). Record every layer in the ledger.

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
If no session file exists (hooks not wired), mark `[SKIP] — watcher not installed`
and rely on Layers 1–3.

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

**Route reviewers to Fable** (`model: 'fable'`) — finding what's broken is where the
frontier reasoner earns its rate, its output is tiny (findings, not code), and it won a
head-to-head bake-off on real review work (most real bugs, fewest false positives,
cheapest per bug — `wiki/methodology/eng-harness.md`). Give reviewers an **output-only
discipline: return findings (file:line + quote + severity + failure scenario), never
rewritten code** — that keeps the expensive tier cheap and forces the fix back onto the
Sonnet build step.

- **Do Not Trust the Report** — the reviewer treats implementer reports as
  unverified claims and verifies them against the diff and the action ledger
  (give the reviewer the watch JSONL path as ground truth).
- **Quote gate** — every finding must cite the verbatim motivating line
  (`file:line` + the exact text). A finding that can't quote its line is
  suppressed, not reported. No invented confidence.

Two verdicts per task, kept separate: **Spec compliance** vs the AC IDs
(Missing / Extra / Misunderstood — over-building is a failure too) and **Code
quality** (Critical / Important / Nice-to-have). Critical or Important → fix →
mandatory re-review. Loop until zero blocking findings. Lane C: final whole-branch
review on Fable + security pass (OWASP basics, secrets scan).
`meta-proof-of-work` Gate 2 satisfies the final adversarial pass where installed.

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
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:watch  PASS|FAIL|SKIP "note"
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:zerotrust PASS|FAIL|SKIP "note"
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:review PASS|FAIL "rounds: N"
bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> verify:runtime PASS|FAIL|SKIP "note"
```

All four recorded (PASS or justified SKIP) → NEXT: `references/06-ship.md`
