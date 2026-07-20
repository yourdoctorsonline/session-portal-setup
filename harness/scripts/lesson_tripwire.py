#!/usr/bin/env python3
"""lesson_tripwire.py — deterministic recurring-lesson detector.

Closes the learning loop's open half: lessons get LOGGED reliably (wrap-up,
Phase 7) but nothing counts repetitions, so a lesson can recur across runs
forever without becoming a Rule. This script makes the repetition signal
mechanical: it clusters same-theme entries on a learnings page, counts them
(including explicit "(seen again YYYY-MM-DD)" stamps), and checks whether the
owning SKILL.md already has a covering Rule. Clusters with >=2 occurrences and
no covering rule are PROMOTION CANDIDATES — surfaced to the human, never
auto-applied (promotion stays user-approved).

Design constraints (per eng-harness rules 2026-07-06):
- Deterministic: token statistics only, no LLM, no network.
- Fail-open: any infrastructure error -> exit 0 with "unverifiable"; the gate
  must never brick a session. --strict exits 1 when candidates exist (for a
  future CI hook), still exit 0 on infra errors.

Usage:
    lesson_tripwire.py <learnings-page.md> [--skill-md PATH] [--json]
                       [--min-count N] [--strict]

SKILL.md resolution when --skill-md is omitted: for wiki/methodology/{name}.md,
tries .claude/skills/{name}/SKILL.md under the page's repo root, then
~/.claude-personal/skills/{name}/SKILL.md.
"""
import argparse
import json
import os
import re
import sys

DATE_RE = re.compile(r"\b(20\d{2}-\d{2}-\d{2})\b")
SEEN_RE = re.compile(r"\(seen again (20\d{2}-\d{2}-\d{2})\)")
BULLET_RE = re.compile(r"^\s*[-*]\s+(.*)")
HEADER_RE = re.compile(r"^\s*#{1,6}\s+(.*)")

# Small stopword list: common English + the harness's own ambient vocabulary,
# so clustering keys on lesson SUBSTANCE, not on words every entry contains.
STOP = set("""
the a an and or but of to in on for with without into from by as at is are was
were be been being it its this that these those not no never always any every
each which what when where who whom how why can could should would must may
might will shall do does did done doing has have had having if then than so
because before after during against between over under out up down off only
also more most less least own same other another all both few many much some
such very just even still yet again further once here there about above below
we you they he she i our your their his her them him us me my
run runs running task tasks build built building test tests testing verify
verified verification check checks checked checking use used using make made
making work works worked working need needs needed file files line lines code
skill skills harness phase lane plan spec user real one two three first second
""".split())

WORD_RE = re.compile(r"[a-z][a-z0-9_./-]{2,}")


def tokens(text):
    """Content tokens of an entry: lowercase words minus stopwords/dates."""
    text = re.sub(r"`[^`]*`", " ", text)          # strip inline code spans
    text = SEEN_RE.sub(" ", text)              # stamp syntax must never join entries
    text = DATE_RE.sub(" ", text)
    toks = set(WORD_RE.findall(text.lower()))
    return {t for t in toks if t not in STOP}


def parse_entries(md):
    """Extract dated bullet entries. An entry inherits the nearest date seen in
    its own text, else the nearest preceding header carrying a date. Multi-line
    bullets (continuation lines indented) are folded into one entry."""
    entries = []       # dicts: text, date, seen_again[]
    current_date = None
    buf = None

    def flush():
        nonlocal buf
        if buf is not None and buf["text"].strip():
            entries.append(buf)
        buf = None

    for line in md.splitlines():
        h = HEADER_RE.match(line)
        if h:
            flush()
            m = DATE_RE.search(h.group(1))
            if m:
                current_date = m.group(1)
            continue
        b = BULLET_RE.match(line)
        if b:
            flush()
            text = b.group(1)
            scan = re.sub(r"`[^`]*`", " ", text)   # a date inside a code span is a filename, not a date
            m = DATE_RE.search(scan)
            buf = {"text": text,
                   "date": (m.group(1) if m else current_date),
                   "seen_again": SEEN_RE.findall(scan)}
        elif buf is not None and line.strip() and (line.startswith("  ") or line.startswith("\t")):
            buf["text"] += " " + line.strip()
            buf["seen_again"] += SEEN_RE.findall(re.sub(r"`[^`]*`", " ", line))
        else:
            flush()
    flush()
    return [e for e in entries if e["date"]]


def cluster(entries, df_ratio=0.12, min_shared=2):
    """Star clustering: a cluster is a SEED entry plus every entry that shares
    >= min_shared RARE tokens with the seed DIRECTLY.

    Why not union-find: pairwise joins are transitive — A~B on one token pair,
    B~C on another, and a 98-entry page collapses into one mega-cluster with an
    empty shared theme (observed on the real eng-harness page). Star clustering
    forbids chaining: membership always references the seed.

    "Rare" = document frequency <= max(3, n*df_ratio). The floor of 3 matters:
    a lesson recurring 3x on a small page makes its own theme tokens frequent,
    and a plain fractional cap would exclude exactly the signal being counted.
    On large pages the join bar also rises (min_shared 3)."""
    n = len(entries)
    toks = [tokens(e["text"]) for e in entries]
    df = {}
    for ts in toks:
        for t in ts:
            df[t] = df.get(t, 0) + 1
    cap = max(3, int(n * df_ratio))
    if n >= 30:
        min_shared = max(min_shared, 3)
    rare = [{t for t in ts if df[t] <= cap} for ts in toks]

    # Anchor-based growth: strongest pairs first. A cluster's ANCHOR is the
    # rare-token set shared by its founding pair; further members must overlap
    # the ANCHOR (>=2 tokens), never just any member. This guarantees a
    # non-empty theme and makes transitive chaining structurally impossible
    # (observed failure: 87/98 entries in one theme-less mega-cluster).
    pairs = []
    for i in range(n):
        for j in range(i + 1, n):
            s = rare[i] & rare[j]
            if len(s) >= min_shared:
                pairs.append((len(s), -i, -j, i, j, s))
    pairs.sort(reverse=True)

    assigned = [False] * n
    groups = []          # (member_indices, anchor_tokens)
    for _, _, _, i, j, s in pairs:
        if assigned[i] or assigned[j]:
            continue
        g = [i, j]
        assigned[i] = assigned[j] = True
        for k in range(n):
            if not assigned[k] and len(rare[k] & s) >= 2:
                g.append(k)
                assigned[k] = True
        groups.append((sorted(g), s))
    for i in range(n):
        if not assigned[i]:
            groups.append(([i], rare[i]))
    return groups, rare


def rules_block(skill_md_text):
    """Return the text of the ## Rules section (to first following ## or EOF)."""
    m = re.search(r"^##\s+Rules\s*$(.*?)(?=^##\s|\Z)", skill_md_text,
                  re.MULTILINE | re.DOTALL)
    return m.group(1) if m else ""


def rule_entries(block):
    """Rules are multi-line bullets; fold indented continuation lines into the
    entry (first-line-only parsing dropped most of a rule's vocabulary and
    broke coverage matching — found on the first live promotion round)."""
    out = []
    for line in block.splitlines():
        b = BULLET_RE.match(line)
        if b:
            m = DATE_RE.search(b.group(1))
            out.append({"text": b.group(1), "date": m.group(1) if m else ""})
        elif out and line.strip() and (line.startswith("  ") or line.startswith("\t")):
            out[-1]["text"] += " " + line.strip()
    return out


def resolve_skill_md(page_path):
    name = os.path.splitext(os.path.basename(page_path))[0]
    probe = os.path.abspath(page_path)
    root = None
    d = os.path.dirname(probe)
    while d and d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, ".claude")):
            root = d
            break
        d = os.path.dirname(d)
    cands = []
    if root:
        cands.append(os.path.join(root, ".claude", "skills", name, "SKILL.md"))
    cands.append(os.path.expanduser(f"~/.claude-personal/skills/{name}/SKILL.md"))
    for c in cands:
        if os.path.isfile(c):
            return c
    return None


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("page")
    ap.add_argument("--skill-md")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--min-count", type=int, default=2)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args(argv)

    try:
        with open(args.page, encoding="utf-8", errors="replace") as f:
            md = f.read()
    except OSError as e:
        print(f"unverifiable: cannot read page ({e})")
        return 0

    skill_md = args.skill_md or resolve_skill_md(args.page)
    rules = []
    if skill_md:
        try:
            with open(skill_md, encoding="utf-8", errors="replace") as f:
                rules = rule_entries(rules_block(f.read()))
        except OSError:
            rules = []
    rule_toks = [(r, tokens(r["text"])) for r in rules]

    entries = parse_entries(md)
    if not entries:
        print("unverifiable: no dated entries found on page")
        return 0

    groups, rare = cluster(entries)
    clusters = []
    for g, anchor in groups:
        count = len(g) + sum(len(entries[i]["seen_again"]) for i in g)
        if count < args.min_count:
            continue
        shared = anchor
        covered, rdate = False, ""
        for r, rt in rule_toks:
            if len(shared & rt) >= 3:
                covered, rdate = True, r["date"]
                break
        dates = sorted({entries[i]["date"] for i in g}
                       | {d for i in g for d in entries[i]["seen_again"]})
        # Recurrence means ACROSS runs/days: a cluster confined to one date is
        # one session's notes, not a repeating lesson — never a candidate.
        clusters.append({
            "count": count,
            "dates": dates,
            "entries": [entries[i]["text"][:160] for i in g],
            "theme_tokens": sorted(shared)[:8],
            "covered_by_rule": covered,   # advisory hint, never suppresses
            "rule_date": rdate,
            "promotion_candidate": (len(dates) >= 2),
        })
    clusters.sort(key=lambda c: -c["count"])

    result = {"page": args.page, "skill_md": skill_md or "",
              "entries_scanned": len(entries), "clusters": clusters,
              "candidates": sum(1 for c in clusters if c["promotion_candidate"])}

    if args.json:
        print(json.dumps(result, indent=1))
    else:
        print(f"lesson-tripwire: {len(entries)} dated entries on {os.path.basename(args.page)}")
        if not clusters:
            print("  no recurring lessons at min-count "
                  f"{args.min_count} — nothing to promote.")
        for c in clusters:
            if c["promotion_candidate"] and c["covered_by_rule"]:
                mark = ("PROMOTION CANDIDATE — likely covered by rule "
                        + c["rule_date"] + "; CONFIRM it actually covers this")
            elif c["promotion_candidate"]:
                mark = "PROMOTION CANDIDATE — no covering rule"
            elif c["covered_by_rule"]:
                mark = "single-day, likely covered by rule " + c["rule_date"]
            else:
                mark = "single-day cluster — one session's notes, not a recurrence"
            print(f"\n  x{c['count']}  [{', '.join(c['dates'])}]  {mark}")
            print(f"      theme: {', '.join(c['theme_tokens'])}")
            for e in c["entries"]:
                print(f"      - {e}")
        if result["candidates"]:
            print(f"\n  {result['candidates']} candidate(s): promote to the owning "
                  "SKILL.md ## Rules (user-approved) or add a dated decline note.")

    if args.strict and result["candidates"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
