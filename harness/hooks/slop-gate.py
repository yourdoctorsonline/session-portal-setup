#!/usr/bin/env python3
"""Stop hook — refuse to finish a turn whose prose carries AI tells.

Why this exists as a HOOK and not a rule in a file: the rule already existed.
It was injected into context on every single turn, read, and then broken in the
very next message — five bolded sentence-openers, a header over three lines, and
a reflexive three-bullet list. The user circled it.

That is the honour-based-check failure the harness already names: a rule whose
enforcement depends on the cooperation of the party it constrains is honour-based
however firmly it is worded. The writer cannot be the judge. So this reads what
was actually written and blocks on it.

Contract:
  exit 0  -> clean, turn ends
  exit 2  -> blocked; stderr goes back to the model, which must rewrite
  exit 0 on ANY internal error -> a broken gate must never brick a session
     (harness rule 2026-07-06: fail open on PROCESS, closed on VERDICT — the
     verdict half is that a detected tell always blocks, never warns)

Loop safety: `stop_hook_active` is set when the model is already responding to
this hook. Re-blocking then would loop forever, so it passes.
"""
import json
import os
import re
import sys

# Each rule: (id, human explanation, finder -> list of offending excerpts).
# Thresholds are deliberately above 1 where a single instance is legitimate
# style — the target is the HABIT, not one em-dash.

BANNED_WORDS = [
    "delve", "tapestry", "testament to", "in the realm of", "landscape of",
    "crucial", "pivotal", "robust", "seamless", "seamlessly", "streamline",
    "foster", "underscore", "underscores", "showcase", "showcases", "boasts",
    "myriad", "stands as", "serves as", "plays a vital role", "navigate the",
    "it's important to note", "it is important to note", "it's worth noting",
    "ever-evolving", "in conclusion", "overall,", "furthermore,", "moreover,",
    "additionally,", "when it comes to", "at the end of the day",
]


def find_banned(text):
    low = text.lower()
    return [w for w in BANNED_WORDS if w in low]


def find_bold_openers(text):
    """Paragraphs that OPEN with a bolded clause used as a lead-in.

    The single most identifiable tell in this assistant's output: every
    paragraph starting `**Some claim.** Then the explanation…`. One is fine as
    emphasis; three is a template.
    """
    hits = []
    for para in text.split("\n\n"):
        p = para.strip()
        if p.startswith(("|", ">", "```", "- ", "* ", "#")):
            continue
        m = re.match(r"\*\*([^*]{8,90})\*\*[ ,.:—-]", p)
        if m:
            hits.append(m.group(1)[:60])
    return hits


def find_not_just(text):
    pats = [
        r"[Ii]t'?s not just [^.,;]{3,40}[,—-] it'?s",
        r"[Nn]ot only [^.,;]{3,60} but also",
        r"[Ii]sn'?t just [^.,;]{3,40}[,—-] it'?s",
    ]
    return [m.group(0)[:70] for p in pats for m in re.finditer(p, text)]


def find_short_headers(text):
    """Markdown headers introducing a block too small to need one."""
    lines = text.split("\n")
    hits = []
    for i, ln in enumerate(lines):
        if not re.match(r"^#{1,4}\s+\S", ln):
            continue
        body = []
        for nxt in lines[i + 1:]:
            if re.match(r"^#{1,4}\s+\S", nxt):
                break
            body.append(nxt)
        words = len(" ".join(body).split())
        if words < 40:
            hits.append(f"{ln.strip()[:50]} ({words} words under it)")
    return hits


def find_sycophancy(text):
    head = text.strip()[:160].lower()
    for p in ["great question", "good question", "great catch", "excellent",
              "you're absolutely right", "that's a great", "happy to help"]:
        if p in head:
            return [p]
    return []


RULES = [
    ("banned-vocabulary", "AI-tell vocabulary", find_banned),
    ("bold-lead-ins", "paragraphs opening with a bolded lead-in clause", find_bold_openers),
    ("not-just-formula", "the 'it's not just X, it's Y' construction", find_not_just),
    ("header-on-a-stub", "a header over a block too short to need one", find_short_headers),
    ("opening-praise", "opening with praise instead of the answer", find_sycophancy),
]

# How many hits before a rule fires. 1 = never acceptable.
THRESHOLDS = {
    "banned-vocabulary": 1,
    "bold-lead-ins": 3,
    "not-just-formula": 1,
    "header-on-a-stub": 2,
    "opening-praise": 1,
}


def check(text):
    """-> list of (rule_id, explanation, hits). Pure; unit-testable."""
    out = []
    for rid, why, fn in RULES:
        try:
            hits = fn(text)
        except Exception:
            hits = []
        if len(hits) >= THRESHOLDS[rid]:
            out.append((rid, why, hits))
    return out


def last_assistant_text(transcript_path):
    """Text of the most recent assistant message in a JSONL transcript."""
    if not transcript_path or not os.path.isfile(transcript_path):
        return ""
    last = ""
    with open(transcript_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            msg = rec.get("message") or rec
            if msg.get("role") != "assistant":
                continue
            content = msg.get("content")
            if isinstance(content, str):
                last = content
            elif isinstance(content, list):
                parts = [c.get("text", "") for c in content
                         if isinstance(c, dict) and c.get("type") == "text"]
                if any(p.strip() for p in parts):
                    last = "\n".join(parts)
    return last


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # no input we understand — never block

    if data.get("stop_hook_active"):
        return 0  # already rewriting; blocking again would loop

    try:
        text = last_assistant_text(
            data.get("transcript_path") or data.get("transcriptPath") or ""
        )
    except Exception:
        return 0

    if not text.strip():
        return 0

    violations = check(text)
    if not violations:
        return 0

    lines = ["Your reply carries AI-writing tells the user has explicitly banned.",
             "Rewrite it before finishing. Found:", ""]
    for rid, why, hits in violations:
        shown = ", ".join(str(h) for h in hits[:4])
        lines.append(f"  [{rid}] {why} ({len(hits)}): {shown}")
    lines += [
        "",
        "Rewrite the SAME content: same facts, numbers, paths and conclusions.",
        "Drop the bolded lead-ins, cut headers over short blocks, vary sentence",
        "length, and say the thing plainly instead of announcing it first.",
    ]
    sys.stderr.write("\n".join(lines) + "\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # process failure must never brick the session
