#!/bin/bash
# backup-agentic-os.sh [REPO] — one-way snapshot backup of your agentic-os repo to
# a PRIVATE personal mirror (the `backup` remote), captured by the scheduled
# backup job. Safe by design:
#
#   - It NEVER merges and never pulls. It only force-pushes the current state to a
#     mirror that nothing else writes to, so there are no merge conflicts — ever.
#   - It NEVER touches your real branches, index, or HEAD. Uncommitted and
#     untracked work is snapshotted into a throwaway commit (via a temp index +
#     commit-tree) that lands on a dedicated `wip-backup` branch on the mirror.
#   - It only runs if a `backup` remote exists; setup wires that to your own
#     private repo, so no one else can see it.
#
# REPO defaults to <WORKSPACE_ROOT>/agentic-os (from portal.env).
set -u

REPO="${1:-}"
if [ -z "$REPO" ]; then
  WS="$(grep '^WORKSPACE_ROOT=' "$HOME/.claude-launcher/portal.env" 2>/dev/null | cut -d= -f2-)"
  REPO="${WS:-$HOME/repos}/agentic-os"
fi
[ -d "$REPO/.git" ] || exit 0
git -C "$REPO" remote get-url backup >/dev/null 2>&1 || exit 0   # not set up → no-op

# 1. Mirror committed history (all branches + tags). Force is safe: the backup
#    repo is a private mirror only this machine pushes to, so it can't diverge in
#    a way that matters — we just make it match local.
git -C "$REPO" push --force --all  backup >/dev/null 2>&1 || true
git -C "$REPO" push --force --tags backup >/dev/null 2>&1 || true

# 2. Snapshot the full working tree — tracked, staged, AND untracked (honoring
#    .gitignore) — into a commit off HEAD, WITHOUT mutating the real index/HEAD.
TMPIDX="$(mktemp "${TMPDIR:-/tmp}/aos-backup-idx.XXXXXX")"
cp "$REPO/.git/index" "$TMPIDX" 2>/dev/null || : > "$TMPIDX"
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO" add -A 2>/dev/null || true
TREE="$(GIT_INDEX_FILE="$TMPIDX" git -C "$REPO" write-tree 2>/dev/null || true)"
rm -f "$TMPIDX"
if [ -n "${TREE:-}" ]; then
  PARENT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
  BR="$(git -C "$REPO" branch --show-current 2>/dev/null || echo detached)"
  SNAP="$(git -C "$REPO" commit-tree "$TREE" ${PARENT:+-p "$PARENT"} \
            -m "wip snapshot $(date -u +%FT%TZ) on ${BR}" 2>/dev/null || true)"
  [ -n "${SNAP:-}" ] && git -C "$REPO" push --force backup "$SNAP:refs/heads/wip-backup" >/dev/null 2>&1 || true
fi
