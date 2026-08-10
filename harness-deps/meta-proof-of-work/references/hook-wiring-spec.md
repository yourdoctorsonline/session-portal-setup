# Hook-wiring spec — make proof-of-work *enforced*, not advisory

Goal: turn `meta-proof-of-work` (and the Agent Watch idea) from a behavioral skill into
**unskippable hooks**, the same way memory-capture already fires on every `Stop`.
Two hooks + a per-turn evidence ledger. Isolation is the design rule: the hooks run
*outside* the agent's control, so the agent can't fabricate the proof.

## 1. `PostToolUse` → `proof-capture.js`  (records receipts; non-blocking)
Fires after every tool runs. Matcher: `Edit|Write|MultiEdit|Bash|NotebookEdit`.
For each call, append a ground-truth record to the turn's evidence ledger:
- the tool + args (the **exact command** for Bash)
- exit code / success flag
- git delta: `git rev-parse HEAD`, `git diff --name-only`, `git status --porcelain`
- for test commands (pytest/jest/npm test…): captured exit code + tail of output
Ledger path: `.command-centre/proof-ledger/{session}-{turn}.json` (gitignored).
Output: always allow (this hook only *observes*). Cheap, deterministic, no LLM.

## 2. `Stop` → `proof-gate.js`  (the enforcement teeth)
Fires when the agent declares the turn done. Steps:
1. Scan the final assistant message for **completion/factual claims** — regex +
   keywords: `done|fixed|passing|tests? pass|committed|deployed|it works|verified|now \w+s`.
2. For each claim, reconcile against the ledger **and re-checked live ground truth**
   (Agent Watch logic): claims "committed" → is there a new SHA? "tests pass" → was a
   runner invoked + exit 0? "changed X" → does `git diff` show it? "fact" → is a
   citation present?
3. Verdict per claim: `CONFIRMED | UNVERIFIED | CONTRADICTED`.
4. **Decision:**
   - all CONFIRMED → `{"continue": true}` (let the turn end)
   - any UNVERIFIED/CONTRADICTED → `{"decision":"block","reason":"<claim> has no
     receipt / contradicts git. Produce the artifact or downgrade the claim to
     'attempted'."}` → Claude Code feeds `reason` back and the agent must resolve it.
5. Always write a verdict ledger to the transcript + surface a one-line summary.

Tunable strictness via env: `PROOF_GATE=block|warn|off` (default `warn` to start, flip
to `block` once false-positive rate is acceptable — the research warns weak checks give
24–41% false positives, so calibrate before blocking).

## 3. `SubagentStop` (optional, Gate 2)
When an adversarial "prove-it" reviewer runs as a subagent, capture its verdict into the
ledger so the `Stop` gate can require an independent confirmation for high-stakes turns.

## Isolation guards (non-negotiable, from `catching-ai-lies`)
- Re-run checks in the **hook process** (fresh subprocess), never trust pasted output.
- The reviewer/gate must not see the doer's reasoning (no self-judging → no sycophancy).
- Ignore the agent's stated confidence/honesty — only artifacts count.

## settings.json registration
```json
{ "hooks": {
    "PostToolUse": [{ "matcher": "Edit|Write|MultiEdit|Bash|NotebookEdit",
      "hooks": [{ "type": "command", "command": "node .claude/hooks/proof-capture.js" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "node .claude/hooks/proof-gate.js" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "command": "node .claude/hooks/proof-capture.js --subagent" }] }]
} }
```

## Files to create
- `.claude/hooks/proof-capture.js` — PostToolUse + SubagentStop recorder
- `.claude/hooks/proof-gate.js` — Stop reconciler/blocker
- `.gitignore` += `.command-centre/proof-ledger/`
- README/AGENTS Connected-hooks note

## Rollout
`warn` mode for ~1 week → review the verdict ledgers for false positives → tune the
claim regex + isolation → flip to `block`. Pairs with the always-on memory-capture hook.
