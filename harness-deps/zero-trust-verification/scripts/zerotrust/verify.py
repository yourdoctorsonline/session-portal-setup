#!/usr/bin/env python3
"""zero-trust-verification — deterministic hallucination gates.

One file, stdlib only. Routes by --domain, emits ONE JSON envelope, exits 1 on REJECTED.

Premise: ignore what an agent *says*; compare its claims to on-disk / runtime artifacts.
Three tiers of trust:
  A  deterministic gate  -> auto REJECT   (exit codes, coverage, mutation, HTTP status,
                                           grep hits, OCR text, image dims)
  B  cross-model check   -> WARN (advisory) (a 2nd model disagrees with the spec)
  C  human sign-off      -> listed in `unverifiable[]` (faithfulness/quality nothing
                                           mechanical can settle)

Companion to the meta-proof-of-work skill: this is the mechanical Tier-A engine.
Full docs: .claude/skills/zero-trust-verification/SKILL.md
"""
import argparse
import fnmatch
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_THRESHOLDS = {"line": 90, "branch": 85, "mutation": 80}

# Which gates are live per tier. `none` skips everything (data/output files).
TIER_GATES = {
    "strict": {"build", "test", "coverage", "mutation", "links", "claims", "ocr", "dims", "vision"},
    "smoke":  {"build", "test", "links", "claims", "ocr", "dims"},   # no coverage/mutation reject
    "none":   set(),
}

# ---------------------------------------------------------------- config / tiers

def load_config(start):
    """Walk up from `start` for the nearest .zerotrust.json. Returns a merged config."""
    cfg = {"defaults": {"tier": "strict", **DEFAULT_THRESHOLDS}, "paths": [], "commands": {}}
    d = os.path.abspath(start if os.path.isdir(start) else (os.path.dirname(start) or "."))
    root = os.path.abspath(os.sep)
    while True:
        p = os.path.join(d, ".zerotrust.json")
        if os.path.isfile(p):
            try:
                found = json.load(open(p, encoding="utf-8"))
                cfg["defaults"].update(found.get("defaults", {}))
                cfg["paths"] = found.get("paths", [])
                cfg["commands"].update(found.get("commands", {}))
                cfg["_config_path"] = p
            except Exception as e:  # bad config must not crash the gate
                cfg["_config_error"] = f"{p}: {e}"
            break
        if d == root:
            break
        d = os.path.dirname(d)
    return cfg


def resolve_tier(target, cfg):
    """First matching path rule wins; else defaults. Returns (tier, thresholds_dict)."""
    forms = {target, os.path.normpath(target), os.path.abspath(target)}
    for rule in cfg.get("paths", []):
        pat = rule.get("match", "")
        if any(fnmatch.fnmatch(f, pat) for f in forms):
            return rule.get("tier", cfg["defaults"]["tier"]), {**cfg["defaults"], **rule}
    return cfg["defaults"]["tier"], dict(cfg["defaults"])

# ------------------------------------------------------------------- envelope

def gate(gid, source, expected, actual, passed, note=None, nxt=None):
    g = {"id": gid, "source": source, "expected": expected, "actual": actual, "pass": passed}
    if note:
        g["note"] = note
    if nxt:
        g["next"] = nxt
    return g


def envelope(domain, target, tier, gates, unverifiable=None, tier_b=None):
    gates = gates or []
    unverifiable = unverifiable or []
    tier_b = tier_b or []
    failed = [g for g in gates if g.get("pass") is False]
    if tier == "none":
        status = "SKIP"
    elif failed:
        status = "REJECTED"
    elif unverifiable or tier_b:
        status = "WARN"
    else:
        status = "PASSED"
    next_action = None
    if failed:
        steps = [g.get("next") or f'{g["id"]}: expected {g.get("expected")}, actual {g.get("actual")}' for g in failed]
        next_action = "; ".join(steps)
    return {
        "status": status,
        "domain": domain,
        "target": target,
        "tier": tier,
        "gates": gates,
        "unverifiable": unverifiable,
        "tier_b_divergence": tier_b,
        "next_action": next_action,
    }


def exit_code(env):
    return 1 if env["status"] == "REJECTED" else 0

# -------------------------------------------------------------------- helpers

def norm(s):
    return re.sub(r"\s+", " ", (s or "").lower()).strip()


def find_first(patterns, base):
    for pat in patterns:
        hits = sorted(glob.glob(os.path.join(base, pat), recursive=True))
        if hits:
            return hits[0]
    return None


def nearest_dir_with(target, marker):
    d = os.path.abspath(target if os.path.isdir(target) else (os.path.dirname(target) or "."))
    root = os.path.abspath(os.sep)
    while True:
        if os.path.exists(os.path.join(d, marker)):
            return d
        if d == root:
            return None
        d = os.path.dirname(d)


def run_cmd(cmd, cwd, timeout=1800):
    try:
        p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        tail = (p.stdout[-400:] + p.stderr[-400:]).strip().replace("\n", " ")
        return p.returncode, tail
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, str(e)

# ----------------------------------------------------------------- CODE domain

def read_mutation_score(path):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception:
        return None
    if isinstance(d, dict) and "mutationScore" in d:
        try:
            return round(float(d["mutationScore"]), 1)
        except Exception:
            return None
    files = d.get("files") if isinstance(d, dict) else None
    if isinstance(files, dict):  # Stryker schema
        killed = survived = 0
        for f in files.values():
            for m in f.get("mutants", []):
                s = m.get("status", "")
                if s in ("Killed", "Timeout"):
                    killed += 1
                elif s in ("Survived", "NoCoverage"):
                    survived += 1
        tot = killed + survived
        return round(100 * killed / tot, 1) if tot else None
    return None


def handle_code(target, tier, thr, cfg, run=False):
    active = TIER_GATES.get(tier, set())
    base = target if os.path.isdir(target) else (os.path.dirname(target) or ".")
    gates, unver = [], []

    # build / typecheck + test — only when explicitly asked to execute (--run)
    if run and ("build" in active or "test" in active):
        for key in ("build", "test"):
            if key not in active:
                continue
            # Commands resolve global-then-rule, merged PER KEY: a path rule may override
            # `test` and still inherit the global `build`. `resolve_tier` already folds the
            # matched rule into `thr` ({**defaults, **rule}), so the value was always
            # arriving here — nothing read it, and every non-npm surface in the repo got an
            # npm command it could not run. (2026-07-26, run zerotrust-harness-scripts-rule.)
            cmds = {**(cfg.get("commands") or {}), **(thr.get("commands") or {})}
            cmd = cmds.get(key)
            if not cmd:
                unver.append(f"no `{key}` command in .zerotrust.json commands — {key} gate skipped")
                continue
            cwd = nearest_dir_with(target, "package.json") or base if "npm" in cmd or "npx" in cmd else base
            rc, tail = run_cmd(cmd, cwd)
            gates.append(gate(f"{key}_exit", cmd, 0, rc, rc == 0,
                              nxt=None if rc == 0 else f"{key} failed (exit {rc}): {tail[:160]}"))
    elif "build" in active or "test" in active:
        unver.append("build/test not executed — pass --run to enforce exit-code gates")

    # coverage (Istanbul coverage-summary.json OR coverage.py coverage.json)
    if "coverage" in active:
        cov = find_first(["coverage/coverage-summary.json", "**/coverage-summary.json"], base)
        covpy = find_first(["coverage.json", "**/coverage.json"], base) if not cov else None
        if cov:
            try:
                t = json.load(open(cov, encoding="utf-8"))["total"]
                line = round(t["lines"]["pct"], 1)
                branch = round(t["branches"]["pct"], 1)
                gates.append(gate("line_coverage", os.path.relpath(cov), thr["line"], line, line >= thr["line"],
                                  nxt=None if line >= thr["line"] else f"line coverage +{round(thr['line'] - line, 1)}pp"))
                gates.append(gate("branch_coverage", os.path.relpath(cov), thr["branch"], branch, branch >= thr["branch"],
                                  nxt=None if branch >= thr["branch"] else f"branch coverage +{round(thr['branch'] - branch, 1)}pp"))
            except Exception as e:
                unver.append(f"coverage-summary.json unreadable: {e}")
        elif covpy:
            try:
                t = json.load(open(covpy, encoding="utf-8"))["totals"]
                line = round(t.get("percent_covered", 0), 1)
                nb, cb = t.get("num_branches", 0), t.get("covered_branches", 0)
                gates.append(gate("line_coverage", os.path.relpath(covpy), thr["line"], line, line >= thr["line"],
                                  nxt=None if line >= thr["line"] else f"line coverage +{round(thr['line'] - line, 1)}pp"))
                if nb:
                    branch = round(100 * cb / nb, 1)
                    gates.append(gate("branch_coverage", os.path.relpath(covpy), thr["branch"], branch, branch >= thr["branch"]))
            except Exception as e:
                unver.append(f"coverage.json unreadable: {e}")
        else:
            unver.append("no coverage artifact — run coverage first (e.g. `npx c8 npm test`, `coverage json`); coverage gate skipped")

    # mutation — the tautological-smoke-test detector
    if "mutation" in active:
        mut = find_first(["reports/mutation/mutation.json", "**/mutation.json",
                          "mutation-summary.json", "**/mutation-summary.json"], base)
        score = read_mutation_score(mut) if mut else None
        if score is not None:
            line_cov = next((g["actual"] for g in gates if g["id"] == "line_coverage"), None)
            tautological = line_cov is not None and line_cov >= thr["line"] and score < thr["mutation"]
            gates.append(gate("mutation_score", os.path.relpath(mut), thr["mutation"], score, score >= thr["mutation"],
                              note="TAUTOLOGICAL_SMOKE_TEST" if tautological else None,
                              nxt=None if score >= thr["mutation"] else
                              f"tests run code but don't catch changes — raise asserts: mutation {score}->{thr['mutation']}"))
        elif mut is None:
            unver.append("no mutation report — run Stryker (`npx stryker run`) / mutmut; mutation gate skipped")

    return envelope("code", target, tier, gates, unver)

# ----------------------------------------------------------------- DOCS domain

URL_RE = re.compile(r"https?://[^\s<>()\[\]\"'`]+")


def http_status(url, method="HEAD"):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "zerotrust/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return getattr(r, "status", None) or r.getcode()
    except urllib.error.HTTPError as e:
        if method == "HEAD" and e.code in (403, 405, 501):
            return http_status(url, "GET")   # some servers refuse HEAD
        return e.code
    except Exception:
        return 0   # DNS failure / timeout / connection refused


def url_verdict(code, url=None):
    if code == 200:
        return "ok"
    if 400 <= code < 500 and code not in (401, 403, 429):
        # bare origins (scheme+host, no path) are cited as HOSTS (preconnect/CSP/
        # DNS refs), not pages — a root 404 with DNS+TLS+HTTP all answering means
        # the host is alive, not that the reference is fabricated. Same false-
        # REJECT class as template placeholders (2026-07-06); hit 2026-07-21 on
        # fonts.googleapis.com quoted from a live page's preconnect markup.
        if url is not None and re.match(r"^https?://[^/]+/?$", url):
            return "unverifiable"
        return "dead"          # 404/410/... -> broken or fabricated
    return "unverifiable"      # 401/403/429 (bot/paywall) or 5xx/0 (transient) -> WARN, never fail


def find_claims_manifest(target):
    d = os.path.dirname(target) or "."
    stem = os.path.basename(target).rsplit(".", 1)[0]
    for cand in (os.path.join(d, stem + ".claims.json"), os.path.join(d, "claims-manifest.json")):
        if os.path.isfile(cand):
            return cand
    return None


def handle_docs(target, tier, thr, cfg, check_net=True):
    active = TIER_GATES.get(tier, set())
    gates, unver = [], []
    text = open(target, encoding="utf-8", errors="replace").read()

    # dead-link gate (live HTTP, no curl — curl is denied in settings.json)
    if "links" in active:
        if not check_net:
            unver.append("network link-check skipped (--no-net)")
        else:
            # template/placeholder URLs ({id}, <slug>, $VAR, ...) are not links —
            # following them yields guaranteed-404 false REJECTs (hit 2026-07-06
            # on a docs.google.com/.../{id}/export memory-log entry)
            urls = sorted({m.rstrip(".,);") for m in URL_RE.findall(text)
                           if not re.search(r"[{}<>]|\$[A-Z_]", m)})
            dead = []
            for u in urls:
                v = url_verdict(http_status(u), u)
                if v == "dead":
                    dead.append(u)
                elif v == "unverifiable":
                    unver.append(f"link unverifiable (bot-block/paywall/transient): {u}")
            gates.append(gate("dead_links", "live HTTP", 0, len(dead), len(dead) == 0,
                              nxt=None if not dead else f"fix/remove dead links: {', '.join(dead[:5])}"))

    # claims-manifest grounding — opt-in per path (require_claims:true)
    if "claims" in active and thr.get("require_claims"):
        man = find_claims_manifest(target)
        if not man:
            stem = os.path.basename(target).rsplit(".", 1)[0]
            gates.append(gate("claims_manifest", "sidecar json", "present", "absent", False,
                              nxt=f"create {stem}.claims.json: [{{\"claim\":..,\"anchor\":\"exact substring\",\"source\":\"path or DOI\"}}]"))
        else:
            try:
                claims = json.load(open(man, encoding="utf-8"))
            except Exception as e:
                claims = []
                gates.append(gate("claims_manifest", os.path.relpath(man), "valid json", "parse error", False, nxt=str(e)))
            missing = []
            for c in claims:
                anchor = (c.get("anchor") or "").strip()
                src = c.get("source", "")
                if not anchor or not src:
                    missing.append({"anchor": anchor or "(empty)", "why": "missing anchor/source"})
                    continue
                if src.startswith("http") or src.upper().startswith("DOI:"):
                    unver.append(f"external source {src} — existence is checkable, faithfulness is human sign-off: \"{anchor[:60]}\"")
                    continue
                srcpath = src if os.path.isabs(src) else os.path.join(os.path.dirname(target), src)
                if not os.path.isfile(srcpath):
                    missing.append({"anchor": anchor, "why": f"source not found: {src}"})
                elif norm(anchor) not in norm(open(srcpath, encoding="utf-8", errors="replace").read()):
                    missing.append({"anchor": anchor, "why": f"anchor absent from {src}"})
            if claims:
                previews = "; ".join('"' + str(m.get("anchor", "?"))[:40] + '"' for m in missing[:5])
                gates.append(gate("claim_anchors", "grep in source", 0, len(missing), len(missing) == 0,
                                  nxt=None if not missing else f"{len(missing)} claim(s) not grounded: {previews}"))

    return envelope("docs", target, tier, gates, unver)

# --------------------------------------------------------------- VISUAL domain

POT_PROMPT = (
    "Program-of-Thought. Look ONLY at the image file at {image}. Do not infer intent or "
    "guess. Return ONLY compact JSON: {{\"labels\":[...],\"counts\":{{\"buttons\":N,"
    "\"text_blocks\":N,\"images\":N}}}}. No prose, no markdown."
)


def image_dims(path):
    if shutil.which("sips"):
        try:
            out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                                 capture_output=True, text=True, timeout=20).stdout
            w = re.search(r"pixelWidth:\s*(\d+)", out)
            h = re.search(r"pixelHeight:\s*(\d+)", out)
            if w and h:
                return int(w.group(1)), int(h.group(1))
        except Exception:
            pass
    return None


def ocr_text(path):
    try:
        return subprocess.run(["tesseract", path, "stdout"], capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return ""


def load_expect(target):
    p = target.rsplit(".", 1)[0] + ".expect.json"
    if os.path.isfile(p):
        try:
            return json.load(open(p, encoding="utf-8"))
        except Exception:
            return None
    return None


def vision_crosscheck(target, cfg):
    """Tier-B advisory: a 2nd model reports object counts; we compare to <img>.expect.json."""
    tmpl = (cfg.get("commands") or {}).get("vision")
    if not tmpl:
        return {"error": "commands.vision not set in .zerotrust.json (Tier-B is advisory anyway)"}
    prompt = POT_PROMPT.format(image=os.path.abspath(target))
    cmd = tmpl.replace("{image}", shlex.quote(os.path.abspath(target))).replace("{prompt}", shlex.quote(prompt))
    try:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=180).stdout
        m = re.search(r"\{.*\}", out, re.S)
        if not m:
            return {"error": "vision model returned no JSON"}
        got = json.loads(m.group(0))
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}
    exp = load_expect(target)
    if not exp:
        return {"observed": got, "note": "no <img>.expect.json to compare — recorded only"}
    diffs = []
    for k, v in (exp.get("counts") or {}).items():
        seen = (got.get("counts") or {}).get(k)
        if seen != v:
            diffs.append(f"{k}: spec {v}, vision saw {seen}")
    if diffs:
        return {"divergence": {"source": "vision-crosscheck", "mismatches": diffs,
                               "note": "ADVISORY — a 2nd model disagrees with spec; human confirm, not an auto-reject"}}
    return {"observed": got}


def handle_visual(target, tier, thr, cfg, spec_path=None, use_vision=True):
    active = TIER_GATES.get(tier, set())
    gates, unver, tier_b = [], [], []

    if "dims" in active:
        dims = image_dims(target)
        if dims:
            unver.append(f"image is {dims[0]}x{dims[1]}px (add expected dims to spec to gate on it)")
        else:
            unver.append("could not read image dimensions (sips/identify unavailable)")

    if "ocr" in active:
        if shutil.which("tesseract") is None:
            unver.append("tesseract not installed — OCR text gate skipped (`brew install tesseract`)")
        elif spec_path and os.path.isfile(spec_path):
            got = ocr_text(target)
            required = [ln.strip() for ln in open(spec_path, encoding="utf-8", errors="replace") if ln.strip()]
            missing = [r for r in required if norm(r) not in norm(got)]
            gates.append(gate("ocr_text_present", "tesseract OCR", 0, len(missing), len(missing) == 0,
                              nxt=None if not missing else f"text missing/garbled in image: {', '.join(missing[:5])}"))
        else:
            unver.append("no --spec text file — OCR gate needs the expected strings")

    if "vision" in active and use_vision:
        vc = vision_crosscheck(target, cfg)
        if vc.get("error"):
            unver.append(f"vision cross-check unavailable: {vc['error']}")
        elif vc.get("divergence"):
            tier_b.append(vc["divergence"])
        elif vc.get("note"):
            unver.append(f"vision: {vc['note']}")

    return envelope("visual", target, tier, gates, unver, tier_b)

# -------------------------------------------------------------------- routing

def detect_domain(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".md", ".markdown", ".txt"):
        return "docs"
    if ext in (".png", ".jpg", ".jpeg", ".webp", ".gif"):
        return "visual"
    return "code"

# ------------------------------------------------------------------- selftest

def selftest():
    # tautological note
    g = gate("mutation_score", "x", 80, 31, False, note="TAUTOLOGICAL_SMOKE_TEST")
    assert g["pass"] is False and g["note"] == "TAUTOLOGICAL_SMOKE_TEST"
    # status logic
    assert envelope("code", "t", "strict", [gate("a", "s", 1, 1, True)])["status"] == "PASSED"
    assert envelope("code", "t", "strict", [gate("a", "s", 90, 74, False)])["status"] == "REJECTED"
    assert envelope("code", "t", "strict", [gate("a", "s", 1, 1, True)], ["u"])["status"] == "WARN"
    assert envelope("code", "t", "none", [gate("a", "s", 90, 0, False)])["status"] == "SKIP"
    # exit-code mapping
    assert exit_code(envelope("c", "t", "strict", [gate("a", "s", 1, 2, False)])) == 1
    assert exit_code(envelope("c", "t", "strict", [gate("a", "s", 1, 1, True)])) == 0
    # url classification: only permanent 4xx is "dead"
    assert url_verdict(404) == "dead" and url_verdict(410) == "dead"
    assert url_verdict(403) == "unverifiable" and url_verdict(429) == "unverifiable"
    assert url_verdict(503) == "unverifiable" and url_verdict(0) == "unverifiable"
    assert url_verdict(200) == "ok"
    # anchor grounding is a normalized substring test
    assert norm("Hello   WORLD\n") == "hello world"
    assert norm("The sky is Blue") in norm("... the SKY is   blue, everyone knows ...")
    assert norm("cats purr") not in norm("dogs bark loudly")
    # mutation score compute from Stryker schema
    stryker = {"files": {"a.ts": {"mutants": [{"status": "Killed"}, {"status": "Survived"},
                                              {"status": "Killed"}, {"status": "Timeout"}]}}}
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(stryker, fh)
        mp = fh.name
    assert read_mutation_score(mp) == 75.0   # (killed2+timeout1)/(4) = 75
    os.unlink(mp)
    # tier resolution: first match wins
    cfg = {"defaults": {"tier": "strict", **DEFAULT_THRESHOLDS},
           "paths": [{"match": "scripts/*", "tier": "smoke"}, {"match": "*", "tier": "none"}]}
    assert resolve_tier("scripts/x.py", cfg)[0] == "smoke"
    assert resolve_tier("other.py", cfg)[0] == "none"
    print("selftest OK")
    return 0

# ----------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="zero-trust-verification deterministic gate")
    ap.add_argument("--domain", choices=["code", "docs", "visual", "auto"], default="auto")
    ap.add_argument("--path")
    ap.add_argument("--spec", help="expected-text file for the visual OCR gate")
    ap.add_argument("--run", action="store_true", help="execute configured build/test commands")
    ap.add_argument("--no-net", action="store_true", help="skip live link checks")
    ap.add_argument("--no-vision", action="store_true", help="skip the Tier-B vision cross-check")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.path:
        ap.error("--path is required (or use --selftest)")
    if not os.path.exists(args.path):
        print(json.dumps({"status": "REJECTED", "target": args.path,
                          "next_action": "path does not exist"}, indent=2))
        return 1

    domain = detect_domain(args.path) if args.domain == "auto" else args.domain
    cfg = load_config(args.path)
    tier, thr = resolve_tier(args.path, cfg)

    if domain == "code":
        env = handle_code(args.path, tier, thr, cfg, run=args.run)
    elif domain == "docs":
        env = handle_docs(args.path, tier, thr, cfg, check_net=not args.no_net)
    else:
        env = handle_visual(args.path, tier, thr, cfg, spec_path=args.spec, use_vision=not args.no_vision)

    if cfg.get("_config_error"):
        env["unverifiable"].append(f"config error: {cfg['_config_error']}")
    print(json.dumps(env, indent=2))
    return exit_code(env)


if __name__ == "__main__":
    sys.exit(main())
