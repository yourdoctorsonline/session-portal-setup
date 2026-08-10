#!/usr/bin/env python3
"""Zero-trust build/test gates for bash + python trees that have no npm project.

Invoked BY the engine as a per-path command, so it operates on the CURRENT DIRECTORY:
`verify.py` runs non-npm commands with cwd set to the target (verify.py handle_code), and the
target is whatever surface is being verified. Never pass it a path — the engine chooses.

    harness_checks.py syntax    bash -n every *.sh, py_compile every *.py
    harness_checks.py tests     run every test_*.py

Verdict shape follows the harness law the engine gates on (laws.md § Corollary):
  * a check that COULD NOT RUN is not a check that passed
  * an absent SURFACE is different from an absent CHECK

so `tests` distinguishes three cases:
  tests present              -> run them; non-zero if any fails
  code present, no tests     -> NON-ZERO. Unverifiable: there is code and nothing checks it.
  no code at all             -> exit 0. No surface to test; that is not a capability gap.

Stdlib only. Exit 0 = gate passes, non-zero = gate blocks. Output goes to stdout because
`run_cmd` keeps only the last 400 chars and that text becomes the operator's whole explanation.
"""
import os
import py_compile
import re
import subprocess
import sys
import tempfile

# Directories we never walk into. Vendored third-party code is not ours to fix, and a
# syntax failure there would block every run touching the tree that contains it.
SKIP_DIRS = {"_vendor", "__pycache__", ".git", "node_modules", ".venv", "venv", ".mypy_cache"}


def walk(root="."):
    """Yield files under root, skipping vendored and generated trees."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            yield os.path.join(dirpath, f)


def classify(root="."):
    """Split the tree into (test files, non-test code files).

    A `test_*.py` is NOT counted as code-under-test: a folder holding only tests has no
    surface of its own, and must not be reported as 'code with no tests'.
    """
    tests, code = [], []
    for p in walk(root):
        base = os.path.basename(p)
        if p.endswith(".py"):
            (tests if base.startswith("test_") else code).append(p)
        elif p.endswith(".sh"):
            code.append(p)
    return sorted(tests), sorted(code)



def _tests_run(output):
    """How many tests unittest reported running. Zero means nothing executed, which is
    NOT a pass — see cmd_tests. unittest prints 'Ran N test(s) in ...' on stderr."""
    m = re.search(r"^Ran (\d+) test", output, re.M)
    return int(m.group(1)) if m else 0


def cmd_syntax():
    tests, code = classify()
    checked = failures = 0
    for p in sorted(tests + code):
        if p.endswith(".sh"):
            r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
            checked += 1
            if r.returncode != 0:
                failures += 1
                print(f"SYNTAX FAIL {p}: {(r.stderr or r.stdout).strip()[:200]}")
        elif p.endswith(".py"):
            checked += 1
            try:
                # doraise=True: without it py_compile reports failure only via return value,
                # and a silent skip would make this gate incapable of failing.
                py_compile.compile(p, cfile=os.path.join(tempfile.gettempdir(), "zt_syntax.pyc"),
                                   doraise=True)
            except Exception as e:  # noqa: BLE001 — any compile error is a gate failure
                failures += 1
                print(f"SYNTAX FAIL {p}: {str(e)[:200]}")
    if failures:
        print(f"syntax: {failures} of {checked} file(s) failed")
        return 1
    print(f"syntax: {checked} file(s) OK" if checked else "syntax: no .sh/.py files here — nothing to check")
    return 0


def cmd_tests():
    tests, code = classify()

    if not tests:
        if code:
            # The Q2 decision: code exists and nothing verifies it. That is a capability
            # gap, not an absent surface, so it must not report a pass.
            print(f"tests: NO TEST SUITE for this target — {len(code)} code file(s) present, "
                  f"0 test_*.py found. Unverifiable: add a test_*.py or narrow the "
                  f".zerotrust.json rule that covers this path.")
            return 1
        # The Q3 decision: nothing to test is an absent surface, not a gap.
        print("tests: no code surface here (no .py/.sh outside tests) — nothing to verify")
        return 0

    failures, unrunnable, ran = [], [], 0
    for t in tests:
        # `python file.py` on a pytest-style file (module-level `def test_x()`, no runner)
        # DEFINES the functions and exits 0 — zero tests execute and the gate reads "passed".
        # A failing test would pass. Run through unittest so discovery is the runner's job,
        # and require positive evidence that tests actually ran.
        r = subprocess.run([sys.executable, "-m", "unittest", "-v", t],
                           capture_output=True, text=True)
        out = r.stdout + r.stderr
        if r.returncode != 0:
            failures.append((t, out.strip()[-300:]))
            continue
        n = _tests_run(out)
        if n == 0:
            # Exit 0 with nothing executed is the vacuous pass this whole gate exists to
            # prevent. It is a capability gap (this runner cannot drive that file), not a
            # pass — most often a pytest-style file with no unittest.TestCase.
            unrunnable.append(t)
        else:
            ran += n

    if failures:
        for t, tail in failures:
            print(f"TEST FAIL {t}: {tail}")
        print(f"tests: {len(failures)} of {len(tests)} suite(s) failed")
        return 1
    if unrunnable:
        for t in unrunnable:
            print(f"TEST UNRUNNABLE {t}: exits 0 but executed 0 tests — this gate runs "
                  f"suites via `python -m unittest`; a pytest-style file (no "
                  f"unittest.TestCase) defines its tests and never runs them")
        print(f"tests: {len(unrunnable)} of {len(tests)} suite(s) could not be run by this "
              f"gate — unverifiable, not passed")
        return 1
    print(f"tests: {len(tests)} suite(s) passed, {ran} test(s) executed")
    return 0


def main():
    sub = sys.argv[1] if len(sys.argv) > 1 else ""
    if sub == "syntax":
        return cmd_syntax()
    if sub == "tests":
        return cmd_tests()
    print(__doc__)
    return 2


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as exc:  # noqa: BLE001
    # Fail open on process, closed on verdict: never hand the engine a traceback, never
    # hand it a pass. Same contract as check-plan-refs.sh and ledger.sh check.
    print(f"harness_checks could not run: {exc}")
    sys.exit(2)
