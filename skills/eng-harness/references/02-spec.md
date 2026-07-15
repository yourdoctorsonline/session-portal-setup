# Phase 2 — Spec: the contract

Spec quality is the bottleneck of the whole pipeline (implementation is minutes;
wrong requirements are days). The spec is also the eval: every acceptance
criterion written here becomes a checkable claim at ship time.

## 1. Brainstorm to an approved design

Invoke `superpowers:brainstorming` and follow it fully: one question at a time,
2–3 approaches with a recommendation, design presented in sections, user approval
section-by-section. HARD-GATE: no code, no plan, until the user approves the
design — regardless of perceived simplicity. ("This is too simple to need a
design" is the named anti-pattern, not an exemption.)

*Fallback without superpowers:* interview the user to a written design covering
goal, approach options considered + chosen + why, scope boundaries, and risks;
get explicit approval on the written text.

## 2. Write spec.md in the run dir

Structure:

```markdown
# Spec — {run slug}
NEXT: references/03-plan.md

## Goal
{1-2 sentences, business language}

## Design (approved {date})
{the approved design, condensed — link the brainstorm doc if separate}

## Acceptance criteria
AC-{SLUG}-001: When {trigger/condition}, the system shall {observable behavior}.
AC-{SLUG}-002: ...

## NOT in scope
- {explicit exclusions}

## Open questions
- {anything unresolved — must be empty before Phase 3}
```

## 3. AC rules (the 8090 grammar + archon negotiation)

- 5–15 criteria. Each **atomic** (one behavior), **testable** (a test can be
  derived mechanically), **observable** (describes behavior, not implementation).
- Grammar: `When [trigger], the system shall [behavior]`. IDs `AC-{SLUG}-NNN`
  are permanent — later phases grep for them.
- Negotiate them adversarially before locking: for each, ask "how would this be
  tested? could two people read it differently?" — "The API works well" is the
  canonical BAD example; "When POST /login receives invalid credentials, the
  system shall return 401 within 2s without revealing which field failed" is the
  shape of a good one.
- Ambiguity found later costs a plan revision; found now it costs one sentence.
  "Could any requirement be interpreted two different ways? Pick one and make it
  explicit."

## 4. Spec self-review, then user gate

Self-review for: placeholders, internal contradictions, ACs that restate each
other, scope leaks into NOT-in-scope. Then present the spec FILE to the user.
Law 3 applies: the phase ends only on explicit approval. Lane C: approval here is
mandatory and recorded in `run.md` with the user's approving words quoted.

Record: `bash .claude/skills/eng-harness/scripts/ledger.sh append <run-slug> spec PASS "user approved"`

NEXT: `references/03-plan.md`
