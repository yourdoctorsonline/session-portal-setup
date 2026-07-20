#!/usr/bin/env bash
# eng-harness: session trigger contract, injected by a SessionStart hook on
# startup|resume|clear|compact (superpowers pattern — the rule is re-injected
# after compaction so it can never fall out of context). Keep this SHORT: it
# rides in every session's context window.
cat <<'EOF'
<eng-harness-contract>
Software-development trigger rule: if this session involves building, coding, scripting, fixing, refactoring, automating, reviewing, or shipping ANY software, invoke the eng-harness skill BEFORE writing or changing code. Even a 1% chance it applies means invoke it. Size is never a reason to skip — eng-harness routes small fixes down a fast lane (Lane A). Work with an existing .eng-harness/runs/ folder always resumes through eng-harness.
</eng-harness-contract>
EOF
