#!/usr/bin/env python3
"""merge-gate.py — PreToolUse(Bash) hook: the ship gate becomes physics.

ECC-pattern adoption (block-no-verify.js): when a merge-class git command runs
while an eng-harness run is ACTIVE, the ledger ship-gate must pass first.
Exit 2 = block (stderr shown to the model); exit 0 = allow.

Fail-open contract (harness rule 2026-07-06): infra errors (no ledger.sh, no
git, unreadable files) warn and ALLOW. The only block is a real FAIL/STALE
verdict from ledger.sh check. Drift check is warn-only v1.
"""
import json
import os
import re
import subprocess
import sys

# Matches merge-class commands at a command position (start, after ;|&, or a
# NEWLINE - multi-line Bash scripts are the norm), tolerating a path prefix,
# command/env-var prefixes, and git options before the verb. Quoted spans are
# stripped first so message text cannot false-block. DELIBERATE SCOPE: pull is
# NOT gated - mid-run feature-branch pulls are legitimate; this gate exists for
# the merge-to-main moment (review finding 4, 2026-07-20).
MERGE_RE = re.compile(
    r"(?:^|[;&|\n]\s*)(?:\w+=\S+\s+)*(?:command\s+)?(?:\S*/)?"
    r"(?:git(?:\s+-[^\s]+|\s+-C\s+\S+)*\s+merge\b|gh\s+pr\s+merge\b)")

def strip_quotes(cmd):
    return re.sub(r"'[^']*'|\"[^\"]*\"", " ", cmd)

def main():
    # Whole parse fail-open: ANY unexpected input allows (review finding 5).
    try:
        data = json.load(sys.stdin)
        if not isinstance(data, dict) or data.get("tool_name") != "Bash":
            return 0
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
    except Exception:
        return 0
    if not MERGE_RE.search(strip_quotes(cmd)):
        return 0

    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    active = os.path.join(root, ".eng-harness", "ACTIVE_RUN")
    if not os.path.isfile(active):
        return 0
    try:
        run = open(active).read().strip()
    except OSError:
        return 0
    if not run:
        return 0

    ledger = os.path.join(root, ".claude", "skills", "eng-harness", "scripts", "ledger.sh")
    if not os.path.isfile(ledger):
        # Team-installer layout: the skill lives at the USER level, not vendored in
        # the project. Fall back there so the gate still enforces for teammates.
        user_ledger = os.path.expanduser(
            "~/.claude/skills/eng-harness/scripts/ledger.sh")
        if os.path.isfile(user_ledger):
            ledger = user_ledger
        else:
            print(f"merge-gate: ledger.sh missing (project + user) — allowing "
                  f"(fail-open). Active run: {run}", file=sys.stderr)
            return 0
    try:
        r = subprocess.run(["bash", ledger, "check", run], capture_output=True,
                           text=True, timeout=30, cwd=root)
    except Exception as e:
        print(f"merge-gate: check errored ({e}) — allowing (fail-open).", file=sys.stderr)
        return 0

    # Warn-only drift check (item 6) rides along on every gated merge.
    drift = os.path.join(root, ".claude", "skills", "eng-harness", "scripts",
                         "check-skill-drift.sh")
    if os.path.isfile(drift):
        try:
            d = subprocess.run(["bash", drift], capture_output=True, text=True,
                               timeout=20, cwd=root)
            if d.returncode != 0:
                print("merge-gate WARN (non-blocking): " + (d.stdout + d.stderr).strip(),
                      file=sys.stderr)
        except Exception:
            pass

    if r.returncode != 0:
        print(f"merge-gate BLOCK: run '{run}' is ACTIVE and its ship gate fails:\n"
              f"{(r.stdout + r.stderr).strip()}\n"
              f"Complete the missing phases (or close the run via Phase 7, which "
              f"clears .eng-harness/ACTIVE_RUN) before merging.", file=sys.stderr)
        return 2
    return 0

if __name__ == "__main__":
    sys.exit(main())
