# Phase 6 — Ship

Shipping is an audit, not a ceremony. "Code that handles a deliverable is not the
deliverable."

## 1. Plan-completion audit → audit.md

Go item-by-item through plan.md tasks AND spec.md ACs. Classify each:

| Class | Meaning | Proof required |
|-------|---------|----------------|
| DIFF-VERIFIABLE | provable from this repo's diff/tests | cite the commit/file/test |
| CROSS-REPO | lives in another repo/system you can read | run the check (`[ -f path ]`, API call), paste result |
| EXTERNAL-STATE | can't be verified from here (DNS, a human's inbox, a dashboard) | name the manual check the user must do |

Honesty rules: an item is DONE only if its deliverable exists — related code
shipping is not the deliverable. "I don't want to check" is not EXTERNAL-STATE.
Each EXTERNAL-STATE item gets **individual** user confirmation — never a blanket
"confirm all?". If the audit itself errors, that's a FAIL, not a pass-by-default.

## 2. The ledger gate (deterministic)

```bash
bash .claude/skills/eng-harness/scripts/ledger.sh check <run-slug>
```

Verifies every phase recorded a PASS (or justified SKIP) and that verify-layer
verdicts are at the current HEAD — commits after verification make verdicts stale
(exit 1). Stale = re-run the affected layers. This replaces "I reviewed it
earlier" with a machine-checkable fact.

## 3. Merge

Follow the repo's branch flow (`ops-new-feature` finish / PR per branching
policy). Lane C: explicit human approval on the PR before merge, recorded in
`run.md`. CI runs zero-trust where wired. After merge: re-run the test suite on
the target branch; a green merge is a claim like any other.

## 4. Docs + release

Shipped behavior that contradicts docs is a bug: run `document-release` (installed)
after merge. Version cuts go through `ops-release`.

Record: `bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> ship PASS "merged <sha>"`

NEXT: `references/07-learn.md`

## Chat paste contract (token discipline)

When reporting ship results to the user, paste ONLY: (1) the one-line AC summary
(N met / M total), (2) residual risks or skips, (3) EXTERNAL-STATE items awaiting
human confirmation. Never the full AC table, full diffs, or full logs — those
live in the run dir; link the path instead. (ECC PreCompact/summary-contract
pattern, adopted 2026-07-20.)
