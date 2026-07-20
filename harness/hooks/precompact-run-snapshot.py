#!/usr/bin/env python3
"""PreCompact hook: snapshot the active run's state into run.md so compaction
never loses phase position (ECC PreCompact save/restore pattern). Always exit 0."""
import datetime, json, os, sys
try:
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    active = os.path.join(root, ".eng-harness", "ACTIVE_RUN")
    if not os.path.isfile(active): sys.exit(0)
    run = open(active).read().strip()
    if not run: sys.exit(0)
    rows = []
    lp = os.path.join(root, ".eng-harness", "ledger.jsonl")
    if os.path.isfile(lp):
        for line in open(lp):
            try:
                e = json.loads(line)
                if e.get("run") == run: rows.append(e)
            except Exception: pass
    rmd = os.path.join(root, ".eng-harness", "runs", run, "run.md")
    if os.path.isfile(rmd):
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        tail = "\n".join(f"- {e['phase']} {e['verdict']} @ {e.get('commit','?')} — {e.get('note','')[:80]}"
                         for e in rows[-6:]) or "- (no ledger rows yet)"
        import re as _re
        block = (f"\n## Compaction snapshot {ts}\nLast ledger rows:\n{tail}\n"
                 f"Resume: re-read this run.md + the phase reference it names.\n")
        body = open(rmd).read()
        body = _re.sub(r"\n## Compaction snapshot .*?(?=\n## |\Z)", "", body, flags=_re.DOTALL)
        open(rmd, "w").write(body + block)
except Exception:
    pass
sys.exit(0)
