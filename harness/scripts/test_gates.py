#!/usr/bin/env python3
"""Tests for the gate verdict contract — ledger.sh and watch.py.

Covers run 2026-07-26_verdict-split-unverifiable (AC-VSU-001..009):
  * UNVERIFIABLE is a legal fourth verdict and blocks the ship gate
  * per-layer skip policy (watch/zerotrust/review may never SKIP; runtime needs a note)
  * no retroactive breakage for PASS/FAIL/SKIP-only runs
  * process fails open (no crash, no traceback) / verdict fails closed (never exit 0)

Stdlib unittest only, mirroring test_lesson_tripwire.py. Each test runs the real
scripts via subprocess inside a throwaway git repo, because ledger.sh resolves
`.eng-harness/ledger.jsonl` RELATIVE to the cwd and stamps rows with `git rev-parse`.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER_SH = os.path.join(HERE, "ledger.sh")
WATCH_PY = os.path.join(HERE, "watch.py")
DRIFT_SH = os.path.join(HERE, "check-skill-drift.sh")

RUN = "test-run"
ALL_VERIFY = ["verify:watch", "verify:zerotrust", "verify:review", "verify:runtime"]


def _git(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)


class GateTestCase(unittest.TestCase):
    """Base: a throwaway git repo per test, so rows never touch the real ledger."""

    def setUp(self):
        self.repo = tempfile.mkdtemp(prefix="gates-")
        _git(self.repo, "init", "-q")
        # A commit must exist or `git rev-parse --short HEAD` yields "none" and the
        # staleness comparison in `check` stops meaning anything.
        _git(self.repo, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-q", "--allow-empty", "-m", "base")
        self.addCleanup(shutil.rmtree, self.repo, True)

    # -- helpers ---------------------------------------------------------
    def append(self, phase, verdict, note=None, run=RUN):
        cmd = ["bash", LEDGER_SH, "append", run, phase, verdict]
        if note is not None:
            cmd.append(note)
        return subprocess.run(cmd, cwd=self.repo, capture_output=True, text=True)

    def check(self, run=RUN):
        return subprocess.run(["bash", LEDGER_SH, "check", run],
                              cwd=self.repo, capture_output=True, text=True)

    def rows(self):
        p = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        if not os.path.isfile(p):
            return []
        out = []
        for line in open(p):
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    def seed_full_pass(self, lane_bc=True, skip=()):
        """Seed a run that passes `check` today. `skip` omits phases the test will set itself."""
        if lane_bc:
            for ph in ("spec", "plan"):
                if ph not in skip:
                    self.append(ph, "PASS", "seeded")
        for ph in ALL_VERIFY:
            if ph not in skip:
                self.append(ph, "PASS", "seeded")

    def assertNoTraceback(self, r):
        self.assertNotIn("Traceback", r.stdout + r.stderr,
                         "gate crashed with a traceback — process must fail open")

    # -- anti-vacuity helpers --------------------------------------------
    # Both exist because a review (2026-07-26, R2-F3/F4) mutation-tested this suite and
    # found six tests that stayed green when SKIP was made unwritable, and every
    # phase-naming assertion staying green when the phase name was stripped from the
    # failure message. Assertions must distinguish the behaviour under test from an
    # unrelated way of reaching the same exit code.

    def assert_landed(self, a, phase, verdict):
        """The append must have SUCCEEDED with this verdict — otherwise a later
        `check` failure means 'no entry', not the policy this test claims to pin."""
        self.assertEqual(a.returncode, 0, f"append was rejected, test proves nothing: {a.stderr}")
        got = [r_.get("verdict") for r_ in self.rows() if r_.get("phase") == phase]
        self.assertEqual(got[-1:], [verdict],
                         f"expected a {verdict} row for {phase}, ledger has {got}")

    def verdict_line(self, r):
        """The VERDICT: line only. `check` prints every phase in its row listing, so
        asserting a phase name against full stdout is satisfied unconditionally."""
        for stream in (r.stderr or "", r.stdout or ""):
            for ln in stream.splitlines():
                if ln.startswith("VERDICT:"):
                    return ln
        return ""

    def assert_blocked_naming(self, r, phase, because=None):
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        v = self.verdict_line(r)
        self.assertIn(phase, v, f"VERDICT line must name the failing phase; got: {v!r}")
        if because:
            self.assertIn(because, v, f"VERDICT line must state the reason; got: {v!r}")
        self.assertNoTraceback(r)


class TestAppendVocabulary(GateTestCase):
    """AC-VSU-001 — UNVERIFIABLE is a legal verdict."""

    def test_01_append_unverifiable_is_accepted(self):
        r = self.append("verify:watch", "UNVERIFIABLE", "hooks not wired")
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = self.rows()
        self.assertEqual(len(rows), 1, "expected exactly one row")
        self.assertEqual(rows[0]["verdict"], "UNVERIFIABLE")
        self.assertEqual(rows[0]["phase"], "verify:watch")

    def test_02_append_bogus_verdict_still_rejected(self):
        """Regression: widening the vocabulary must not open it."""
        r = self.append("verify:watch", "BOGUS", "nope")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertEqual(self.rows(), [], "a rejected verdict must not write a row")


class TestCheckBlocksUnverifiable(GateTestCase):
    """AC-VSU-002 — UNVERIFIABLE blocks the ship gate and names the phase."""

    def test_03_unverifiable_blocks_and_names_phase(self):
        self.seed_full_pass(skip=("verify:watch",))
        a = self.append("verify:watch", "UNVERIFIABLE", "no session ledger")
        self.assert_landed(a, "verify:watch", "UNVERIFIABLE")
        r = self.check()
        self.assert_blocked_naming(r, "verify:watch", because="UNVERIFIABLE")


class TestPerLayerSkipPolicy(GateTestCase):
    """AC-VSU-003/004/005 — which layers may SKIP, and on what terms."""

    def test_04_watch_skip_blocks(self):
        self.seed_full_pass(skip=("verify:watch",))
        a = self.append("verify:watch", "SKIP", "watcher not installed")
        self.assert_landed(a, "verify:watch", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "verify:watch", because="SKIP not permitted")

    def test_05_zerotrust_skip_blocks(self):
        self.seed_full_pass(skip=("verify:zerotrust",))
        a = self.append("verify:zerotrust", "SKIP", "no build artifacts")
        self.assert_landed(a, "verify:zerotrust", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "verify:zerotrust", because="SKIP not permitted")

    def test_06_review_skip_blocks_on_lane_bc(self):
        """A spec or plan row present => Lane B/C => review may not be skipped."""
        self.seed_full_pass(skip=("verify:review",))
        a = self.append("verify:review", "SKIP", "small change, self-reviewed")
        self.assert_landed(a, "verify:review", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "verify:review", because="SKIP not permitted")

    def test_07_review_skip_blocks_on_lane_a_too(self):
        """laws.md 'Uniform application': every lane, Lane A included, owes all four layers."""
        self.seed_full_pass(lane_bc=False, skip=("verify:review",))
        a = self.append("verify:review", "SKIP", "lane A")
        self.assert_landed(a, "verify:review", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "verify:review", because="SKIP not permitted")

    def test_08_runtime_skip_with_note_is_allowed(self):
        self.seed_full_pass(skip=("verify:runtime",))
        self.append("verify:runtime", "SKIP", "no UI surface on this change")
        r = self.check()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_09_runtime_skip_without_note_blocks(self):
        self.seed_full_pass(skip=("verify:runtime",))
        a = self.append("verify:runtime", "SKIP")       # no note argument at all
        self.assert_landed(a, "verify:runtime", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "verify:runtime", because="requires a note")

    def test_09b_runtime_skip_with_whitespace_note_blocks(self):
        self.seed_full_pass(skip=("verify:runtime",))
        a = self.append("verify:runtime", "SKIP", "   ")
        self.assert_landed(a, "verify:runtime", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "verify:runtime", because="requires a note")


class TestNoRetroactiveBreakage(GateTestCase):
    """AC-VSU-006 — PASS/FAIL/SKIP-only runs behave as before, except where 003-005 bite."""

    def test_10_all_pass_at_head_still_passes(self):
        self.seed_full_pass()
        r = self.check()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PASS", r.stdout)

    def test_10b_fail_still_blocks(self):
        self.seed_full_pass(skip=("verify:review",))
        a = self.append("verify:review", "FAIL", "2 defects open")
        self.assert_landed(a, "verify:review", "FAIL")
        r = self.check()
        # because= must not be "FAIL": every blocked line starts "VERDICT: FAIL —", so it
        # would match no matter what the reason said (round-2 finding F3).
        self.assert_blocked_naming(r, "verify:review", because="2 defects open")

    def test_10c_missing_phase_still_blocks(self):
        self.seed_full_pass(skip=("verify:runtime",))
        r = self.check()
        self.assert_blocked_naming(r, "verify:runtime", because="no entry")

    def test_10d_offenum_historical_phases_are_ignored_not_fatal(self):
        """57 rows with retired phase names exist in the real ledger; they must stay inert."""
        self.seed_full_pass()
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        with open(led, "a") as fh:
            fh.write(json.dumps({"ts": "2026-07-10T00:00:00Z", "run": RUN,
                                 "phase": "verify:adversarial", "verdict": "SKIP",
                                 "commit": "deadbee", "branch": "x", "note": ""}) + "\n")
        r = self.check()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class TestFailOpenProcessFailClosedVerdict(GateTestCase):
    """AC-VSU-008 — internal errors never crash and never pass."""

    def test_11_malformed_row_is_unverifiable_not_a_pass(self):
        """AC-VSU-008 names 'malformed row'. This test previously asserted exit 0,
        pinning the NON-compliant behaviour (review finding R2-F2)."""
        self.seed_full_pass()
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        with open(led, "a") as fh:
            fh.write("{not json at all\n")
        r = self.check()
        self.assertNoTraceback(r)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("UNVERIFIABLE", self.verdict_line(r))

    def test_11b_torn_write_cannot_resurrect_an_older_pass(self):
        """The dangerous shape of R2-F2: a FAIL row torn mid-write was silently dropped,
        the earlier PASS for that phase became 'latest', and a BLOCKED run reported PASS."""
        self.seed_full_pass()
        a = self.append("verify:watch", "FAIL", "real defect found")
        self.assert_landed(a, "verify:watch", "FAIL")
        self.assertEqual(self.check().returncode, 1, "precondition: FAIL must block")
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        text = open(led).read().rstrip("\n").split("\n")
        text[-1] = text[-1][:len(text[-1]) // 2]          # tear the FAIL row
        open(led, "w").write("\n".join(text) + "\n")
        r = self.check()
        self.assertEqual(r.returncode, 2,
                         "corruption must never convert a blocked run into a pass")
        self.assertNoTraceback(r)

    def test_11c_required_row_without_a_verdict_field_blocks(self):
        """R1-F2: bracket access on a field-less row raised KeyError. A row whose verdict
        cannot be read is corrupt data and can never be treated as passing."""
        self.seed_full_pass(skip=("verify:runtime",))
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        with open(led, "a") as fh:
            fh.write(json.dumps({"ts": "2026-07-26T00:00:00Z", "run": RUN,
                                 "phase": "verify:runtime", "commit": "x"}) + "\n")
        r = self.check()
        # Pin the branch, not merely "blocked": reverting the fix makes the outer handler
        # catch a KeyError and exit 2, which a bare assertNotEqual(0) cannot distinguish
        # from the intended exit-1 "no verdict field" verdict (round-2 finding F4).
        self.assert_blocked_naming(r, "verify:runtime", because="no verdict field")

    def test_11e_unrecognized_verdict_string_blocks(self):
        """Round-2 finding F1: a verdict outside the vocabulary fell through every branch,
        counted as satisfied, AND dodged staleness forever (the staleness branch tests
        verdict == "PASS"). Unreachable via `append`; reachable via a bad merge resolution."""
        self.seed_full_pass()
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        with open(led, "a") as fh:
            fh.write(json.dumps({"ts": "2026-01-01T00:00:00Z", "run": RUN,
                                 "phase": "verify:review", "verdict": "PASSED",
                                 "commit": "0000000", "branch": "x", "note": ""}) + "\n")
        r = self.check()
        self.assert_blocked_naming(r, "verify:review", because="unrecognized verdict")

    def test_11f_non_dict_and_phaseless_rows_are_named_as_malformed(self):
        """Round-2 finding F7: these blocked, but via the outer handler with messages like
        \"'int' object has no attribute 'get'\" — unactionable for an operator."""
        for payload in ("42", json.dumps({"ts": "x", "run": RUN, "verdict": "PASS"})):
            with self.subTest(payload=payload[:20]):
                self.setUp()
                self.seed_full_pass()
                led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
                with open(led, "a") as fh:
                    fh.write(payload + "\n")
                r = self.check()
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                v = self.verdict_line(r)
                self.assertIn("unparseable row", v, f"must name the row as malformed; got {v!r}")
                self.assertIn("line(s)", v, f"must name WHICH line; got {v!r}")
                self.assertNoTraceback(r)

    def test_11d_offenum_row_without_a_verdict_stays_inert(self):
        """AC-VSU-006: retired-phase rows must not block an otherwise-clean run, even
        when malformed in shape (they are not in REQUIRED)."""
        self.seed_full_pass()
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        with open(led, "a") as fh:
            fh.write(json.dumps({"ts": "2026-07-10T00:00:00Z", "run": RUN,
                                 "phase": "verify:mechanical", "commit": "old"}) + "\n")
        r = self.check()
        self.assertNoTraceback(r)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_12_unreadable_ledger_is_unverifiable_not_a_pass(self):
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            self.skipTest("[SKIP] running as root — chmod 000 does not deny reads")
        self.seed_full_pass()
        led = os.path.join(self.repo, ".eng-harness", "ledger.jsonl")
        os.chmod(led, 0o000)
        self.addCleanup(os.chmod, led, 0o644)
        r = self.check()
        self.assertEqual(r.returncode, 2,
                         "gate-could-not-run is exit 2, distinct from exit 1 = gate blocked")
        self.assertIn("UNVERIFIABLE", self.verdict_line(r))
        self.assertNoTraceback(r)


class TestApprovalPhasesCannotBeSkipped(GateTestCase):
    """R1-F1: spec/plan were in neither skip tuple, so SKIP fell through every branch
    and shipped, while UNVERIFIABLE on the same phase blocked. The policy is now an
    allow-list, so no required phase can acquire that shape by omission."""

    def test_15_spec_skip_blocks(self):
        self.seed_full_pass(skip=("spec",))
        a = self.append("spec", "SKIP")
        self.assert_landed(a, "spec", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "spec", because="SKIP not permitted")

    def test_16_plan_skip_blocks(self):
        self.seed_full_pass(skip=("plan",))
        a = self.append("plan", "SKIP", "no plan written")
        self.assert_landed(a, "plan", "SKIP")
        r = self.check()
        self.assert_blocked_naming(r, "plan", because="SKIP not permitted")

    def test_17_only_runtime_may_skip(self):
        """The allow-list, stated as a property rather than case-by-case."""
        for phase in ("spec", "plan", "verify:watch", "verify:zerotrust", "verify:review"):
            with self.subTest(phase=phase):
                self.setUp()
                self.seed_full_pass(skip=(phase,))
                a = self.append(phase, "SKIP", "some reason")
                self.assert_landed(a, phase, "SKIP")
                self.assertEqual(self.check().returncode, 1, f"{phase} SKIP must block")


class TestGitlessEnvironment(GateTestCase):
    """R2-F1: with no git, every row stamps commit 'none', 'none' == 'none' defeats the
    staleness compare, and the gate reported PASS having verified nothing.
    'missing git' is named in AC-VSU-008."""

    def _gitless_env(self):
        shim = os.path.join(self.repo, "fakebin")
        os.makedirs(shim, exist_ok=True)
        g = os.path.join(shim, "git")
        with open(g, "w") as fh:
            fh.write("#!/bin/sh\nexit 127\n")
        os.chmod(g, 0o755)
        return dict(os.environ, PATH=shim + os.pathsep + os.environ["PATH"])

    def test_18_check_without_git_is_unverifiable_not_a_pass(self):
        self.seed_full_pass()                       # seeded WITH git, real commits
        env = self._gitless_env()
        r = subprocess.run(["bash", LEDGER_SH, "check", RUN],
                           cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0,
                            "no git means freshness is unknowable — never a pass")
        self.assertIn("UNVERIFIABLE", self.verdict_line(r))
        self.assertNoTraceback(r)

    def test_18b_gitless_end_to_end_never_passes(self):
        """The full R2-F1 scenario: append AND check both gitless, so every row is
        commit 'none' and the staleness compare is self-satisfying."""
        env = self._gitless_env()
        for ph in ("spec", "plan") + tuple(ALL_VERIFY):
            subprocess.run(["bash", LEDGER_SH, "append", RUN, ph, "PASS", "ok"],
                           cwd=self.repo, env=env, capture_output=True, text=True)
        r = subprocess.run(["bash", LEDGER_SH, "check", RUN],
                           cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertNoTraceback(r)


class TestWatchVerdict(unittest.TestCase):
    """AC-VSU-009 — watch.py's no-session path; AC-VSU-008 hook exemption."""

    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="gates-watch-")
        self.addCleanup(shutil.rmtree, self.proj, True)
        self.env = dict(os.environ, CLAUDE_PROJECT_DIR=self.proj)

    def test_13_verify_without_session_is_unverifiable_and_nonzero(self):
        r = subprocess.run([sys.executable, WATCH_PY, "verify"],
                           cwd=self.proj, env=self.env, capture_output=True, text=True)
        self.assertIn("VERDICT: UNVERIFIABLE", r.stdout)
        self.assertEqual(r.returncode, 2,
                         "exit 2 = could not run, kept distinct from exit 1 = caught a lie")
        self.assertNotIn("Traceback", r.stdout + r.stderr)

    def test_14_stop_hook_always_exits_zero(self):
        """Session-lifecycle hooks are the AC-VSU-008 exemption: never brick a session."""
        r = subprocess.run([sys.executable, WATCH_PY, "stop-hook"],
                           input="{}", cwd=self.proj, env=self.env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_14b_stop_hook_exits_zero_on_garbage_stdin(self):
        r = subprocess.run([sys.executable, WATCH_PY, "stop-hook"],
                           input="not json", cwd=self.proj, env=self.env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class DriftGuardTests(unittest.TestCase):
    """check-skill-drift.sh across four copies (run 2026-07-26_installer-payload-sync).

    The guard compared repo<->personal only, which is how the INSTALLED copy at
    ~/.claude fell a day behind with nothing reporting it. Exit contract:
    0 = every comparable pair clean · 1 = drift · 2 = a pair could not be compared.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drift-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _copy(self, name, skill_md="base\n"):
        """A minimal harness copy: only the tracked files that exist are compared."""
        d = os.path.join(self.tmp, name)
        os.makedirs(os.path.join(d, "references"), exist_ok=True)
        os.makedirs(os.path.join(d, "scripts"), exist_ok=True)
        with open(os.path.join(d, "SKILL.md"), "w") as fh:
            fh.write(skill_md)
        return d

    def _run(self, repo=None, personal=None, installed=None,
             published_url=None, skip_published=True):
        env = dict(os.environ)
        env["DRIFT_REPO"] = repo or "/nonexistent-repo"
        env["DRIFT_PERSONAL"] = personal or "/nonexistent-personal"
        env["DRIFT_INSTALLED"] = installed or "/nonexistent-installed"
        if skip_published:
            env["DRIFT_SKIP_PUBLISHED"] = "1"
        else:
            env["DRIFT_SKIP_PUBLISHED"] = "0"
            env["DRIFT_PUBLISHED_URL"] = published_url or ""
        return subprocess.run(["bash", DRIFT_SH], capture_output=True, text=True,
                              env=env, cwd=self.tmp)

    def test_20_absent_copies_are_skipped_not_drift(self):
        """Two present + one absent: the absent one is silent, not a finding.

        This used to assert exit 0 with a SINGLE copy present, which encoded
        "nothing to compare == clean". It does not: with fewer than two copies
        nothing is compared at all, and that is exit 2 (see test_30).
        """
        r = self._run(repo=self._copy("a"), personal=self._copy("b"),
                      installed=None)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("DRIFT:", r.stdout)

    def test_21_identical_copies_are_clean(self):
        r = self._run(repo=self._copy("a"), personal=self._copy("b"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("DRIFT:", r.stdout)

    def test_22_differing_copies_exit_1_and_name_the_file(self):
        r = self._run(repo=self._copy("a", "one\n"),
                      personal=self._copy("b", "two\n"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("SKILL.md", r.stdout)
        self.assertIn("personal", r.stdout)

    def test_23_installed_copy_is_compared(self):
        """The pair that was invisible before this run."""
        r = self._run(repo=self._copy("a", "one\n"),
                      installed=self._copy("c", "three\n"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("installed", r.stdout)

    def test_24_unfetchable_published_exits_2_not_0(self):
        r = self._run(repo=self._copy("a"), skip_published=False,
                      published_url="http://127.0.0.1:1/nope.tar.gz")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("not performed", r.stdout + r.stderr)

    def test_25_local_drift_still_reported_when_published_unfetchable(self):
        """Drift (1) outranks unverified (2); both must still be visible."""
        r = self._run(repo=self._copy("a", "one\n"),
                      personal=self._copy("b", "two\n"),
                      skip_published=False,
                      published_url="http://127.0.0.1:1/nope.tar.gz")
        self.assertIn("DRIFT:", r.stdout)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_27_non_repo_pairs_are_compared(self):
        """installed<->published is the ONLY pair a teammate has. R1-C1."""
        r = self._run(repo=None,
                      personal=self._copy("p", "one\n"),
                      installed=self._copy("i", "two\n"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("personal", r.stdout)
        self.assertIn("installed", r.stdout)

    def test_28_a_missing_tracked_file_is_drift_not_silence(self):
        """A copy lacking a file wholesale used to report clean. R1-C3."""
        a = self._copy("a", "same\n")
        b = self._copy("b", "same\n")
        with open(os.path.join(a, "scripts", "test_gates.py"), "w") as fh:
            fh.write("real\n")
        r = self._run(repo=a, personal=b)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("MISSING", r.stdout)
        self.assertIn("test_gates.py", r.stdout)

    def test_29_repo_default_does_not_depend_on_cwd(self):
        """Same state, two cwds, same verdict. R1-C2."""
        env = dict(os.environ)
        env["DRIFT_SKIP_PUBLISHED"] = "1"
        for key in ("DRIFT_REPO", "DRIFT_PERSONAL", "DRIFT_INSTALLED"):
            env.pop(key, None)
        here = subprocess.run(["bash", DRIFT_SH], capture_output=True, text=True,
                              env=env, cwd=os.path.dirname(HERE))
        away = subprocess.run(["bash", DRIFT_SH], capture_output=True, text=True,
                              env=env, cwd=tempfile.gettempdir())
        self.assertEqual(here.returncode, away.returncode,
                         "verdict changed with cwd:\n" + here.stdout + "\n---\n" + away.stdout)

    def test_30_fewer_than_two_copies_is_unverified_not_clean(self):
        r = self._run(repo=self._copy("solo"))
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("no comparison performed", r.stdout)

    def test_31_every_pair_is_reported_not_just_repo_anchored(self):
        """Three mutually-differing copies must yield all THREE pair labels.

        test_27 could not catch a mutation that anchors on the first PRESENT
        copy rather than on `repo` — with repo absent, personal becomes index 0
        and the anchored form still finds personal<->installed. Naming each pair
        explicitly is what pins it.
        """
        r = self._run(repo=self._copy("r", "one\n"),
                      personal=self._copy("p", "two\n"),
                      installed=self._copy("i", "three\n"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("between repo and personal", r.stdout)
        self.assertIn("between repo and installed", r.stdout)
        self.assertIn("between personal and installed", r.stdout)

    def _bare_env(self):
        env = dict(os.environ)
        env["DRIFT_SKIP_PUBLISHED"] = "1"
        for key in ("DRIFT_REPO", "DRIFT_PERSONAL", "DRIFT_INSTALLED"):
            env.pop(key, None)
        return env

    def test_32_repo_copy_resolves_from_inside_the_repo(self):
        """Run from inside the checkout, the repo copy must actually resolve."""
        r = subprocess.run(["bash", DRIFT_SH], capture_output=True, text=True,
                           env=self._bare_env(), cwd=os.path.dirname(HERE))
        self.assertNotIn("repo copy not resolved", r.stdout + r.stderr)

    def test_33_unresolvable_repo_copy_is_unverified_not_clean(self):
        """Outside any git repo the repo pair is UNKNOWN, and unknown != clean.

        This is the half of the cwd fix that was missed: R was set to "" and the
        run carried on to exit 0, so the original 'verdict depends on the
        invoking directory' defect was still reachable from any non-repo cwd.
        """
        r = subprocess.run(["bash", DRIFT_SH], capture_output=True, text=True,
                           env=self._bare_env(), cwd=self.tmp)
        self.assertIn("repo copy not resolved", r.stdout + r.stderr)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_26_both_on_disk_copies_of_the_guard_are_identical(self):
        """The drift guard must not be the thing that drifts."""
        personal = os.path.expanduser(
            "~/.claude-personal/skills/eng-harness/scripts/check-skill-drift.sh")
        if not os.path.isfile(personal):
            self.skipTest("no personal copy on this host")
        with open(DRIFT_SH, "rb") as a, open(personal, "rb") as b:
            self.assertEqual(a.read(), b.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
