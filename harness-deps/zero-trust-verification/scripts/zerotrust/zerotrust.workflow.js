export const meta = {
  name: 'zero-trust-verify',
  description: 'Deterministic build → verify → fix → re-verify gate over a list of targets',
  whenToUse: 'After a fan-out builds or edits multiple files, to gate each on Tier-A artifacts before merge.',
  phases: [
    { title: 'Build' },
    { title: 'Verify' },
    { title: 'Fix' },
  ],
}

// Pass targets as Workflow args: [{ "path": "command-centre/src/lib/x.ts", "domain": "code" }, ...]
// Each item flows build → verify independently (pipeline: no barrier). A REJECTED verdict
// routes the exact metric delta to a fix agent, then re-verifies. The schema-validated JSON
// IS the barrier — an agent cannot "talk past" a failing gate.

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['status', 'target', 'gates'],
  properties: {
    status: { enum: ['REJECTED', 'WARN', 'PASSED', 'SKIP'] },
    domain: { type: 'string' },
    target: { type: 'string' },
    tier: { type: 'string' },
    gates: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'pass'],
        properties: {
          id: { type: 'string' }, source: { type: 'string' },
          expected: {}, actual: {}, pass: { type: 'boolean' },
          note: { type: 'string' }, next: { type: 'string' },
        },
      },
    },
    unverifiable: { type: 'array', items: { type: 'string' } },
    tier_b_divergence: { type: 'array' },
    next_action: { type: ['string', 'null'] },
  },
}

const targets = Array.isArray(args) ? args : []
if (!targets.length) {
  log('no targets — pass args: [{path, domain}, ...]')
}

const verifyCmd = (t) =>
  `Run exactly: python3 scripts/zerotrust/verify.py --domain ${t.domain || 'auto'} --path ${JSON.stringify(t.path)} --run\n`
  + `Return ONLY the JSON the command prints on stdout. Do not summarize or add prose.`

const results = await pipeline(
  targets,

  // Build/edit stage — your real builder agent goes here. Placeholder keeps the gate honest:
  // it does NOT fabricate success; verify decides.
  (t) => agent(`Ensure ${t.path} is built and its tests/artifacts are up to date. Do not claim success — the next stage verifies.`,
    { label: `build:${t.path}`, phase: 'Build' }),

  // Verify stage — deterministic. The validated envelope is the barrier.
  (_built, t) => agent(verifyCmd(t), { label: `verify:${t.path}`, phase: 'Verify', schema: VERIFY_SCHEMA }),

  // Fix stage — only runs for REJECTED; re-verifies after the fix.
  (v, t) => {
    if (!v || v.status !== 'REJECTED') return v
    const failing = (v.gates || []).filter((g) => g.pass === false)
    return agent(
      `zero-trust REJECTED ${t.path}. Close these Tier-A gates, do not work around them:\n`
      + JSON.stringify(failing, null, 2) + `\nnext_action: ${v.next_action}`,
      { label: `fix:${t.path}`, phase: 'Fix' },
    ).then(() => agent(verifyCmd(t), { label: `reverify:${t.path}`, phase: 'Verify', schema: VERIFY_SCHEMA }))
  },
)

const clean = results.filter(Boolean)
const rejected = clean.filter((r) => r.status === 'REJECTED')
const warned = clean.filter((r) => r.status === 'WARN')
log(`zero-trust: ${clean.length - rejected.length}/${clean.length} passed · ${rejected.length} REJECTED · ${warned.length} WARN`)

return {
  passed: rejected.length === 0,
  rejected: rejected.map((r) => ({ target: r.target, next_action: r.next_action })),
  warn: warned.map((r) => ({ target: r.target, unverifiable: r.unverifiable })),
  all: clean,
}
