#!/usr/bin/env python3
"""Tests for lesson_tripwire.py — deterministic recurring-lesson detector.

Stdlib unittest only. Fixtures are synthetic but mirror the real page shape:
dated ## section headers with - bullet entries.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "lesson_tripwire.py")

PAGE = """# eng-harness — learnings

## 2026-07-03 — run-one
- **Check the deployed copy before building.** The repo file had drifted 120 lines
  behind the deployed production version; building on the repo copy shipped stale code.
- **Name subagent models explicitly.** A dispatch without a model choice silently
  inherits the expensive one.

## 2026-07-08 — run-two
- **Repo vs deployed drift again.** The cloud function in the repo was never the
  version actually deployed; verify the live deployment target, not the checkout.
- **Screenshot evidence beats prose.** Reviewers accepted a claim without a capture.

## 2026-07-15 — run-three
- **Deployed production file drifted from the repo checkout a third time** — diff
  the deployed version against the repo before any build starts.
- **Kill background jobs on teardown.** Harness teardown orphaned a watcher process.
"""

RULES_COVERING = """# Some Skill

## Rules
- 2026-07-10: Always diff the repo checkout against the deployed production version
  before building; drift between repo and deployed copies recurs.
"""

RULES_UNRELATED = """# Some Skill

## Rules
- 2026-07-01: Use tabs not spaces in Makefiles.
"""


def run_tripwire(*args):
    r = subprocess.run([sys.executable, SCRIPT, *args],
                       capture_output=True, text=True, timeout=30)
    return r


class ClusterTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.page = os.path.join(self.dir, "page.md")
        with open(self.page, "w") as f:
            f.write(PAGE)

    def _json(self, *extra):
        r = run_tripwire(self.page, "--json", *extra)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_recurring_theme_clusters_across_dates(self):
        # AC-TRIP-001: three drift entries under three dates -> one cluster of 3
        out = self._json()
        sizes = sorted(c["count"] for c in out["clusters"])
        self.assertIn(3, sizes, out)
        big = [c for c in out["clusters"] if c["count"] == 3][0]
        self.assertEqual(len(set(big["dates"])), 3)
        self.assertTrue(any("drift" in q.lower() or "deployed" in q.lower()
                            for q in big["entries"]))

    def test_unrelated_entries_do_not_cluster(self):
        # AC-TRIP-009: subagent-model, screenshot, background-job lessons stay singletons
        out = self._json()
        multi = [c for c in out["clusters"] if c["count"] >= 2]
        self.assertEqual(len(multi), 1, multi)

    def test_rule_coverage_detected(self):
        # AC-TRIP-002
        skill = os.path.join(self.dir, "SKILL_cov.md")
        with open(skill, "w") as f:
            f.write(RULES_COVERING)
        out = self._json("--skill-md", skill)
        big = [c for c in out["clusters"] if c["count"] == 3][0]
        self.assertTrue(big["covered_by_rule"])
        self.assertIn("2026-07-10", big["rule_date"])
        # Advisory semantics (L2 finding 3): coverage NEVER suppresses candidacy —
        # a false COVERED must not bury a real recurring lesson.
        self.assertTrue(big["promotion_candidate"])

    def test_no_rule_marks_candidate(self):
        # AC-TRIP-003
        skill = os.path.join(self.dir, "SKILL_unrel.md")
        with open(skill, "w") as f:
            f.write(RULES_UNRELATED)
        out = self._json("--skill-md", skill)
        big = [c for c in out["clusters"] if c["count"] == 3][0]
        self.assertFalse(big["covered_by_rule"])
        self.assertTrue(big["promotion_candidate"])

    def test_missing_page_fails_open(self):
        # AC-TRIP-004
        r = run_tripwire(os.path.join(self.dir, "nope.md"))
        self.assertEqual(r.returncode, 0)
        self.assertIn("unverifiable", (r.stdout + r.stderr).lower())

    def test_seen_again_stamps_count(self):
        # AC-TRIP-007 support: explicit stamps add to the count
        stamped = PAGE.replace(
            "- **Kill background jobs on teardown.**",
            "- **Kill background jobs on teardown.** (seen again 2026-07-16) (seen again 2026-07-18)")
        with open(self.page, "w") as f:
            f.write(stamped)
        out = self._json()
        kill = [c for c in out["clusters"] if any("background" in e.lower() for e in c["entries"])]
        self.assertTrue(kill and kill[0]["count"] >= 3, kill)

    def test_transitive_chain_does_not_merge(self):
        # Regression (L2 review): A~B share {gadget,flange}, B~C share {sprocket,widget},
        # A∩C = ∅. Union-find would chain A-B-C into one cluster; anchor clustering must not.
        chain = """# page
## 2026-07-01 — a
- The gadget flange assembly cracked under torque midweight housings.
## 2026-07-02 — b
- Refit the gadget flange after replacing the sprocket widget bearing races.
## 2026-07-03 — c
- Sprocket widget calibration drifts when ambient humidity spikes overnight.
"""
        with open(self.page, "w") as f:
            f.write(chain)
        out = self._json()
        self.assertTrue(all(c["count"] <= 2 for c in out["clusters"]), out["clusters"])

    def test_same_day_stamp_is_not_a_candidate(self):
        # Regression (L2 review): a same-day duplicate stamp raises count but spans
        # one date -> never a promotion candidate (recurrence = across days).
        page = """# page
## 2026-07-05 — only
- Rotate the frobnicator seals quarterly. (seen again 2026-07-05)
"""
        with open(self.page, "w") as f:
            f.write(page)
        out = self._json()
        self.assertEqual(len(out["clusters"]), 1, out)
        c = out["clusters"][0]
        self.assertGreaterEqual(c["count"], 2)
        self.assertFalse(c["promotion_candidate"], c)

    def test_two_token_rule_overlap_is_not_covered(self):
        # Regression (L2 review): a rule sharing only 2 generic tokens with the
        # cluster must NOT mark it COVERED (false COVERED suppresses a real
        # candidate — worse than a false candidate).
        skill = os.path.join(self.dir, "SKILL_weak.md")
        with open(skill, "w") as f:
            f.write("""# Skill

## Rules
- 2026-07-02: Tag every deployed artifact with the repo short-sha in CI metadata.
""")
        out = self._json("--skill-md", skill)
        big = [c for c in out["clusters"] if c["count"] == 3][0]
        # rule shares {deployed, repo} = 2 tokens with the drift cluster — not enough
        self.assertFalse(big["covered_by_rule"], big)
        self.assertTrue(big["promotion_candidate"])

    def test_multiline_rule_coverage(self):
        # Regression: a rule whose matching vocabulary sits on CONTINUATION lines
        # must still register as coverage (first-line-only parsing dropped it).
        skill = os.path.join(self.dir, "SKILL_multi.md")
        with open(skill, "w") as f:
            f.write("""# Skill

## Rules
- 2026-07-11: Wide rule header with no matching words at all on line one,
  but the continuation names the deployed production repo drift version
  checkout problem explicitly.
""")
        out = self._json("--skill-md", skill)
        big = [c for c in out["clusters"] if c["count"] == 3][0]
        self.assertTrue(big["covered_by_rule"], big)

    def test_malformed_bytes_fail_open(self):
        # Regression (L2 BLOCKER): undecodable bytes must not crash — exit 0.
        bad = os.path.join(self.dir, "bad.md")
        with open(bad, "wb") as f:
            f.write(b"# page\n## 2026-07-01 x\n- l\xffesson about z\xfforp drives\n")
        r = run_tripwire(bad)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
