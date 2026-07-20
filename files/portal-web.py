#!/usr/bin/env python3
"""Session Launcher — web dashboard.

A graphical portal that replicates the iOS app in the browser: session cards
(tap to open the terminal), launch a new Claude session with a folder + account
picker, and a file browser/editor. Runs ON the Mac, so no SSH keys — it drives
tmux and the filesystem locally.

Security: binds to the Tailscale IP only (tailnet-only, WireGuard-encrypted).
No password — each person's portal lives on their own single-user tailnet, so
tailnet membership already means "is the owner" (never expose via `tailscale
funnel`). Subprocess with list-args (no shell injection), 512 KB read cap.
Terminals are served by ttyd on :7681 (this app 302-redirects to it).
"""
import base64, html, json, os, re, socket, subprocess, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
LAUNCH = f"{HOME}/.claude-launcher/bin/launch-claude-session.sh"
PORT = 8090
TTYD_PORT = 7681
MAX_READ = 512_000
SEP = "\x1f"

def tailnet_ip():
    for p in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale", "tailscale"):
        try:
            out = subprocess.run([p, "ip", "-4"], capture_output=True, text=True, timeout=8)
            ip = out.stdout.strip().splitlines()[0].strip()
            if ip:
                return ip
        except Exception:
            continue
    return "127.0.0.1"

def load_env(key, path=None):
    if path is None:
        path = f"{HOME}/.claude-launcher/portal.env"
    try:
        with open(path) as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return None

TSIP = tailnet_ip()
# No basic-auth: the portal is reachable only within the owner's private,
# single-user tailnet (each teammate runs their own Tailscale account), so
# tailnet membership already equals "is the owner." A password would guard
# against a second person on the network — which this topology never has.
PW = None
TMUX = None
for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
    if os.path.exists(p):
        TMUX = p
        break
TMUX = TMUX or "tmux"

def workspace_roots():
    ws = load_env("WORKSPACE_ROOT")
    if ws and os.path.isdir(ws):
        return [ws, HOME]
    elif os.path.isdir(os.path.join(HOME, "repos")):
        return [os.path.join(HOME, "repos"), HOME]
    else:
        return [HOME]

# ---- data helpers ------------------------------------------------------------

def list_sessions():
    """Every live tmux session, most-recently-active first.

    `attached` only means a tmux client is currently on the session — it says
    nothing about whether the work inside is finished, because Claude Code sits
    at its prompt forever and never exits on its own. `idle` (seconds since the
    session last did anything) is the field that actually tells you what's
    stale, so it drives both the sort order and the age badge in the UI.
    """
    fmt = SEP.join(["#{session_name}", "#{?session_attached,1,0}",
                    "#{session_windows}", "#{session_activity}",
                    "#{session_created}", "#{pane_current_command}"])
    try:
        out = subprocess.run([TMUX, "list-sessions", "-F", fmt],
                             capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return []
    now = int(time.time())
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split(SEP)
        if len(parts) < 6:
            continue
        name, att, wins, act, created, cmd = parts[:6]
        try:
            act_i = int(act)
        except ValueError:
            act_i = now
        rows.append({"name": name, "attached": att == "1", "windows": wins,
                     "idle": max(0, now - act_i), "created": created,
                     "cmd": cmd,
                     # Claude renames its process to the version it's running
                     # ("2.1.209"), so a version-looking command is a live
                     # Claude — far more reliable than matching the name.
                     "claude": bool(re.match(r"^\d+\.\d+", cmd)) or "claude" in name.lower()})
    rows.sort(key=lambda r: r["idle"])
    return rows

def available_accounts():
    """Accounts offered in the launch sheet — auto-detected, not hardcoded.
    "default" (the plain ~/.claude login) is always first; every ~/.claude-<name>
    config dir that a teammate has logged into shows up automatically. This is
    how a per-person setup works: log in an account once and it just appears."""
    accts = ["default"]
    skip = {"launcher", "swap-backup"}
    try:
        for nm in sorted(os.listdir(HOME)):
            if nm.startswith(".claude-") and os.path.isdir(os.path.join(HOME, nm)):
                sub = nm[len(".claude-"):]
                if sub and sub not in skip and not sub.startswith("swap-backup"):
                    accts.append(sub)
    except Exception:
        pass
    return accts

DEFAULT_CWD_FILE = f"{HOME}/.claude-launcher/default-cwd"

def get_default_cwd():
    """The folder the launch sheet pre-selects. Whatever the user last ticked as
    default, else home. Not validated here — a stored path on an unmounted/locked
    volume should still show as the intended default, and the picker surfaces the
    access error if you try to browse into it."""
    try:
        with open(DEFAULT_CWD_FILE) as f:
            p = f.read().strip()
        if p:
            return p
    except Exception:
        pass
    return HOME

def set_default_cwd(path):
    path = (path or "").strip()
    if not path:
        return {"ok": False, "error": "no path"}
    try:
        with open(DEFAULT_CWD_FILE, "w") as f:
            f.write(os.path.realpath(path))
        return {"ok": True, "path": os.path.realpath(path)}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def launch_session(name, account, perm, cwd):
    name = (name or "").strip() or None
    account = account if account in available_accounts() else "default"
    perm = perm if perm in ("bypass", "auto") else "auto"
    env = dict(os.environ)
    # A folder was chosen but we can't reach it — say so instead of silently
    # launching in home. This is what a locked/unmounted external volume looks
    # like (e.g. the SSD before Full Disk Access is granted): os.path.isdir
    # swallows the PermissionError and returns False.
    if cwd:
        if not os.path.isdir(cwd):
            return {"ok": False, "error": f"Can't open folder: {cwd} — not accessible (permission or not mounted)."}
        launch_cwd = cwd
    else:
        launch_cwd = HOME
    env["LAUNCH_CWD"] = launch_cwd
    env["PATH"] = f"/opt/homebrew/bin:/usr/local/bin:{HOME}/.local/bin:" + env.get("PATH", "")
    args = ["bash", LAUNCH, account, perm]
    if name:
        args.append(name)
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=40, env=env).stdout
    except Exception as e:
        return {"ok": False, "error": str(e)}
    tmux_name = None
    for line in out.splitlines():
        if "tmux=" in line:
            for tok in line.split():
                if tok.startswith("tmux="):
                    tmux_name = tok.split("=", 1)[1]
    if tmux_name:
        return {"ok": True, "tmux": tmux_name}
    return {"ok": False, "error": out.strip() or "launch failed"}

def launch_shell(name, cwd):
    """Open a plain terminal (the user's login shell) in a tmux session — no
    Claude, no account. Same cwd-accessibility rules as launch_session: a chosen
    folder that can't be reached is an explicit error, not a silent home fallback."""
    name = (name or "").strip()
    if cwd:
        if not os.path.isdir(cwd):
            return {"ok": False, "error": f"Can't open folder: {cwd} — not accessible (permission or not mounted)."}
        run_cwd = cwd
    else:
        run_cwd = HOME
    base = re.sub(r"[^A-Za-z0-9_-]", "-", name).strip("-") if name else ""
    tmux_name = base or "shell-" + time.strftime("%H%M%S")
    uniq, n = tmux_name, 2
    while subprocess.run([TMUX, "has-session", "-t", f"={uniq}"], capture_output=True).returncode == 0:
        uniq = f"{tmux_name}-{n}"; n += 1
    shell = os.environ.get("SHELL") or "/bin/bash"
    try:
        r = subprocess.run([TMUX, "new-session", "-d", "-x", "200", "-y", "50",
                            "-s", uniq, "-c", run_cwd, shell],
                           capture_output=True, text=True, timeout=10)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if r.returncode != 0:
        return {"ok": False, "error": (r.stderr or r.stdout).strip() or "shell launch failed"}
    return {"ok": True, "tmux": uniq}

def kill_session(name):
    """Kill one session, and only that one.

    The "=" prefix forces tmux to match the name exactly. A bare -t falls back
    to prefix matching when the exact name is missing, so killing "foo" could
    take out "foo-2" instead. And tmux signals failure through its exit code,
    not an exception — the old code ignored it and reported success no matter
    what, which is why the ✕ button used to claim "Killed" while the session
    sat there untouched.
    """
    if not name:
        return {"ok": False, "error": "no session name"}
    try:
        r = subprocess.run([TMUX, "kill-session", "-t", f"={name}"],
                           capture_output=True, text=True, timeout=8)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if r.returncode != 0:
        return {"ok": False, "error": (r.stderr or r.stdout).strip() or "kill failed"}
    return {"ok": True}

def scroll_session(name, direction):
    """Scroll a session's terminal from outside it, for phones.

    A ttyd terminal on a touchscreen can't be swiped to scroll — the finger
    gesture never reaches the terminal's scrollback (with tmux mouse mode it's
    eaten as a text selection; without it, tmux owns the alternate screen so
    there's nothing for the browser to scroll). So the phone drives tmux's own
    copy-mode from the server instead: "up" enters copy mode and pages up,
    "down" pages back toward the bottom, "live" leaves copy mode to resume the
    live prompt. The change is visible to the attached ttyd client because
    copy-mode is a property of the pane, shared by every client on it.

    "=" forces an exact name match (same reason as kill_session). down/live are
    no-ops when the pane isn't in copy mode — that's the intended result (you're
    already at the bottom), so their exit code is not treated as an error; only
    a missing session is.
    """
    if not name:
        return {"ok": False, "error": "no session name"}
    if direction not in ("up", "down", "live"):
        return {"ok": False, "error": "bad direction"}
    sess = f"={name}"    # session target (exact match, like kill_session)
    pane = f"={name}:"   # pane target — the trailing ":" is required: a bare
                         # "=name" resolves as a session and copy-mode/send-keys
                         # (which want a PANE) reject it ("can't find pane").
    try:
        if subprocess.run([TMUX, "has-session", "-t", sess],
                          capture_output=True, text=True, timeout=8).returncode != 0:
            return {"ok": False, "error": "no such session"}
        if direction == "up":
            cm = subprocess.run([TMUX, "copy-mode", "-t", pane],
                                capture_output=True, text=True, timeout=8)
            if cm.returncode != 0:
                return {"ok": False, "error": (cm.stderr or cm.stdout).strip() or "scroll failed"}
            subprocess.run([TMUX, "send-keys", "-t", pane, "-X", "halfpage-up"],
                           capture_output=True, text=True, timeout=8)
        else:
            key = "halfpage-down" if direction == "down" else "cancel"
            # No-op (non-zero) when not in copy mode is fine — already live.
            subprocess.run([TMUX, "send-keys", "-t", pane, "-X", key],
                           capture_output=True, text=True, timeout=8)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    return {"ok": True}

def list_dir(path):
    path = os.path.realpath(path or workspace_roots()[0])
    if not os.path.isdir(path):
        return {"error": f"Not a folder: {path}"}
    entries = []
    try:
        for nm in sorted(os.listdir(path), key=lambda s: s.lower()):
            full = os.path.join(path, nm)
            try:
                is_dir = os.path.isdir(full)
            except OSError:
                is_dir = False
            entries.append({"name": nm, "path": full, "dir": is_dir})
    except PermissionError:
        return {"error": "Permission denied."}
    entries.sort(key=lambda e: (not e["dir"], e["name"].lower()))
    parent = os.path.dirname(path.rstrip("/")) or "/"
    return {"path": path, "parent": parent, "entries": entries}

def read_file(path):
    path = os.path.realpath(path)
    if not os.path.isfile(path):
        return {"error": "Not a file."}
    try:
        if os.path.getsize(path) > MAX_READ:
            return {"error": f"File too large (>{MAX_READ // 1000} KB) for the editor."}
        with open(path, "rb") as f:
            data = f.read()
        if b"\x00" in data[:8192]:
            return {"error": "Binary file — can't edit as text."}
        return {"path": path, "content": data.decode("utf-8", errors="replace")}
    except Exception as e:
        return {"error": str(e)}

def write_file(path, content):
    path = os.path.realpath(path)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def repos():
    out = []
    for root in workspace_roots():
        if root == HOME:
            out.append({"name": "~ (home)", "path": HOME})
            continue
        try:
            for nm in sorted(os.listdir(root), key=lambda s: s.lower()):
                full = os.path.join(root, nm)
                if os.path.isdir(full) and not nm.startswith("."):
                    out.append({"name": nm, "path": full})
        except Exception:
            pass
    return out

# ---- HTTP --------------------------------------------------------------------

PAGE = r"""<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>Session Launcher</title>
<style>
:root{--bg:#0f0e0d;--panel:#1a1817;--panel2:#221f1d;--line:#2e2a27;--ink:#efe9e2;--mut:#9a8f84;--accent:#e0556a;--accent2:#c53b52;--good:#63c07a;--warn:#e0a955}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{max-width:100%;overflow-x:hidden}
img,pre,textarea,input,select{max-width:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;padding-bottom:env(safe-area-inset-bottom)}
header{position:sticky;top:0;background:rgba(15,14,13,.86);backdrop-filter:blur(12px);border-bottom:1px solid var(--line);padding:14px 16px calc(14px);display:flex;align-items:center;gap:10px;z-index:10;padding-top:calc(14px + env(safe-area-inset-top))}
header h1{font-size:19px;margin:0;font-weight:700;letter-spacing:-.01em}
header .dot{width:9px;height:9px;border-radius:50%;background:var(--good);box-shadow:0 0 8px var(--good)}
.tabs{display:flex;gap:4px;padding:10px 12px;position:sticky;top:57px;background:var(--bg);z-index:9}
.tab{flex:1;text-align:center;padding:9px;border-radius:10px;background:var(--panel);color:var(--mut);font-weight:600;font-size:14px;border:1px solid transparent}
.tab.on{background:var(--accent);color:#fff}
main{padding:8px 12px 40px;max-width:720px;margin:0 auto}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin:10px 0;display:flex;align-items:center;gap:12px;cursor:pointer;transition:.12s}
.card:active{transform:scale(.99);background:var(--panel2)}
.card .ic{font-size:20px;width:26px;text-align:center;flex:0 0 auto}
.card .body{flex:1 1 auto;min-width:0}
.card .nm{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card .sub{font-size:12.5px;color:var(--mut)}
.card .chev{color:var(--mut);flex:0 0 auto}
.pill{font-size:11px;padding:2px 8px;border-radius:20px;font-weight:600;flex:0 0 auto;white-space:nowrap}
.pill.att{background:rgba(99,192,122,.16);color:var(--good)}
.pill.idle{background:#2a2724;color:var(--mut)}
/* 44px minimum so the kill button is actually hittable with a thumb — the old
   bare "✕" glyph was ~10px, so taps landed on the card and opened the terminal
   instead of killing the session. */
.card .act{flex:0 0 auto;min-width:44px;min-height:44px;display:flex;align-items:center;justify-content:center;
  padding:0 13px;border-radius:10px;border:1px solid var(--line);background:var(--panel2);
  color:var(--ink);font:600 14px/1 inherit;font-family:inherit}
.card .act:active{background:var(--line)}
.card .act.kill{width:44px;padding:0;color:var(--accent);font-size:17px}
.sub .live{color:var(--good)}
.sub .warn{color:var(--warn)}
/* Folder-picker row in the launch sheet (replaces the old flat dropdown) + the
   quick-jump chips inside the picker. */
.pickrow{display:flex;align-items:center;gap:10px;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:12px;cursor:pointer}
.pickrow:active{background:var(--line)}
.pickrow .ic{flex:0 0 auto;font-size:17px}
.pickrow .pth{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;direction:rtl;text-align:left;font:13px/1.4 ui-monospace,Menlo,monospace}
.pickrow .go{color:var(--accent);font-weight:600;font-size:13px;flex:0 0 auto}
.pchips{display:flex;gap:6px;flex-wrap:wrap;margin:4px 0 8px}
.pchips .chip{padding:8px 12px;border-radius:18px;background:var(--panel2);border:1px solid var(--line);color:var(--ink);font-weight:600;font-size:13px}
.pchips .chip:active{background:var(--line)}
.fab{position:fixed;right:18px;bottom:calc(20px + env(safe-area-inset-bottom));width:56px;height:56px;border-radius:50%;background:var(--accent);color:#fff;border:none;font-size:28px;box-shadow:0 6px 20px rgba(224,85,106,.45);z-index:20}
.muted{color:var(--mut);font-size:14px;text-align:center;padding:30px 10px}
.crumb{font:12.5px/1.5 ui-monospace,Menlo,monospace;color:var(--mut);padding:6px 4px;word-break:break-all}
label{display:block;font-size:13px;color:var(--mut);margin:14px 0 5px;font-weight:600}
input,select,textarea{width:100%;background:var(--panel2);color:var(--ink);border:1px solid var(--line);border-radius:10px;padding:12px;font-size:16px;font-family:inherit}
textarea{font:13px/1.5 ui-monospace,Menlo,monospace;min-height:52vh;resize:vertical;white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word}
.seg{display:flex;gap:6px;flex-wrap:wrap}.seg button{flex:1 1 90px;min-width:0;padding:11px;border-radius:10px;background:var(--panel2);color:var(--mut);border:1px solid var(--line);font-weight:600;font-size:14px}
.seg button.on{background:var(--accent);color:#fff;border-color:var(--accent)}
/* Type buttons carry a subtext line, so stack them */
#l_kind button{display:flex;flex-direction:column;gap:3px;align-items:center;padding:11px 10px;line-height:1.2}
.bsub{font-size:11px;font-weight:500;opacity:.82;white-space:normal;text-align:center}
.lhint{font-weight:400;font-size:11px;color:var(--mut);opacity:.85}
.btn{display:block;width:100%;padding:14px;border-radius:12px;background:var(--accent);color:#fff;border:none;font-size:16px;font-weight:700;margin-top:20px}
.btn.sec{background:var(--panel2);color:var(--ink);border:1px solid var(--line)}
.sheet{position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:30;display:none}
.sheet.on{display:block}
.sheet .inner{position:absolute;left:0;right:0;bottom:0;background:var(--bg);border-radius:20px 20px 0 0;border-top:1px solid var(--line);max-height:92vh;overflow:auto;padding:8px 16px calc(24px + env(safe-area-inset-bottom))}
.sheet .grab{width:38px;height:5px;border-radius:3px;background:var(--line);margin:8px auto 4px}
.sheet h2{font-size:18px;margin:6px 0 2px}
.editbar{display:flex;gap:8px;align-items:flex-start;margin:6px 0}
.editbar .fn{flex:1;min-width:0;font:12px/1.4 ui-monospace,Menlo,monospace;color:var(--mut);word-break:break-all;overflow-wrap:anywhere}
.small{font-size:12px;color:var(--mut)}
.toast{position:fixed;left:50%;transform:translateX(-50%);bottom:90px;background:var(--panel2);border:1px solid var(--line);color:var(--ink);padding:10px 16px;border-radius:24px;z-index:40;opacity:0;transition:.2s;font-size:14px}
.toast.on{opacity:1}
</style></head><body>
<header><span class="dot"></span><h1>Session Launcher</h1></header>
<div class="tabs"><div class="tab on" data-t="sessions" onclick="tab('sessions')">Sessions</div><div class="tab" data-t="files" onclick="tab('files')">Files</div></div>
<main id="main"></main>
<button class="fab" id="fab" onclick="openLaunch()">+</button>
<div class="sheet" id="sheet"><div class="inner" id="sheetInner"></div></div>
<div class="sheet" id="psheet"><div class="inner" id="psheetInner"></div></div>
<div class="toast" id="toast"></div>
<script>
const $=s=>document.querySelector(s);let view='sessions',cwd=null,repoList=[];
const HOME_DIR=__HOME__, WS_DIR=__WS__, AOS_DIR=__AOS__;   // injected server-side for picker chips
let pcur=null;                            // folder picker's current browse path
function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('on');setTimeout(()=>t.classList.remove('on'),1800)}
async function api(p,o){const r=await fetch(p,o);if(!r.ok)throw new Error(await r.text());return r.json()}
function esc(s){return (s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function tab(t){view=t;document.querySelectorAll('.tab').forEach(e=>e.classList.toggle('on',e.dataset.t===t));$('#fab').style.display=t==='sessions'?'':'none';render()}
async function render(){view==='sessions'?renderSessions():renderFiles()}
function age(s){if(s<90)return'active now';if(s<3600)return Math.round(s/60)+'m idle';
  if(s<86400)return Math.round(s/3600)+'h idle';return Math.round(s/86400)+'d idle'}
async function renderSessions(){
  const m=$('#main');m.innerHTML='<div class="muted">Loading…</div>';
  try{const s=await api('/api/sessions');
    if(!s.length){m.innerHTML='<div class="muted">No sessions yet. Tap + to start one.</div>';return}
    m.innerHTML=s.map(x=>{const stale=x.idle>=3600;
      return `<div class="card" data-n="${esc(x.name)}">
      <div class="ic">${x.claude?'✦':'▹'}</div>
      <div class="body"><div class="nm">${esc(x.name)}</div>
        <div class="sub"><span class="${stale?'warn':'live'}">${age(x.idle)}</span> · ${x.windows} window${x.windows==='1'?'':'s'}${x.attached?' · attached':''}</div></div>
      <button class="act" data-a="open">Open</button>
      <button class="act kill" data-a="kill" aria-label="Kill session ${esc(x.name)}">✕</button></div>`}).join('');
  }catch(e){m.innerHTML='<div class="muted">Couldn\'t load sessions.<br>'+esc(e.message)+'</div>'}
}
// Delegated, so the session name rides in a data- attribute instead of being
// interpolated into an inline onclick — names with quotes or & used to produce
// a broken handler (or silently kill the wrong thing).
$('#main').addEventListener('click',e=>{
  const card=e.target.closest('.card[data-n]');if(!card)return;
  const btn=e.target.closest('[data-a]');
  if(btn&&btn.dataset.a==='kill'){killS(card.dataset.n);return}
  openTerm(card.dataset.n);
});
function openTerm(n){location.href='/term?s='+encodeURIComponent(n)}
async function killS(n){
  if(!confirm('Kill session '+n+'?'))return;
  try{const r=await api('/api/kill',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:n})});
    if(r&&r.ok===false){toast('Kill failed: '+(r.error||'unknown'));return}
    toast('Killed '+n);render();
  }catch(e){toast('Kill failed: '+e.message)}
}
async function renderFiles(){
  const m=$('#main');m.innerHTML='<div class="muted">Loading…</div>';
  try{const d=await api('/api/ls?path='+encodeURIComponent(cwd||''));cwd=d.path;
    let h=`<div class="crumb">${esc(d.path)}</div>`;
    h+=`<div class="card" onclick="cwd='${esc(d.parent).replace(/'/g,"\\'")}';render()"><div class="ic">↰</div><div class="body"><div class="nm">..</div><div class="sub">up one folder</div></div></div>`;
    h+=d.entries.map(e=>e.dir
      ?`<div class="card" onclick="cwd='${esc(e.path).replace(/'/g,"\\'")}';render()"><div class="ic">📁</div><div class="body"><div class="nm">${esc(e.name)}</div></div><span class="chev">›</span></div>`
      :`<div class="card" onclick="openFile('${esc(e.path).replace(/'/g,"\\'")}')"><div class="ic">📄</div><div class="body"><div class="nm">${esc(e.name)}</div></div><span class="chev">›</span></div>`).join('');
    m.innerHTML=h;
  }catch(e){m.innerHTML='<div class="muted">'+esc(e.message)+'</div>'}
}
async function openFile(p){
  try{const d=await api('/api/read?path='+encodeURIComponent(p));
    if(d.error){toast(d.error);return}
    sheet(`<h2>Edit</h2><div class="editbar"><div class="fn">${esc(d.path)}</div></div>
      <textarea id="ed" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea>
      <button class="btn" onclick="saveFile('${esc(p).replace(/'/g,"\\'")}')">Save</button>
      <button class="btn sec" onclick="closeSheet()">Close</button>`);
    $('#ed').value=d.content;
  }catch(e){toast(e.message)}
}
async function saveFile(p){const c=$('#ed').value;try{await api('/api/write',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({path:p,content:c})});toast('Saved ✓')}catch(e){toast('Save failed: '+e.message)}}
async function openLaunch(){
  let accts=['default'];try{accts=(await api('/api/accounts')).accounts||accts}catch(e){}
  let def=HOME_DIR;try{def=(await api('/api/default-cwd')).path||def}catch(e){}
  const acctBtns=accts.map((a,i)=>`<button class="${i===0?'on':''}" data-v="${esc(a)}" onclick="segpick(this)">${esc(a)}</button>`).join('');
  sheet(`<h2>New session</h2>
    <label>Type</label><div class="seg" id="l_kind">
      <button class="on" data-v="claude" onclick="segpick(this);kindPick()">✦ Claude<span class="bsub">to run your sessions</span></button>
      <button data-v="shell" onclick="segpick(this);kindPick()">▹ Plain shell<span class="bsub">for terminal commands that aren't allowed in the Claude app</span></button></div>
    <label>Name <span class="lhint">(your sessions show up under this name in the Claude app)</span></label><input id="l_name" placeholder="my task" autocapitalize="off">
    <label>Folder to run in <span class="lhint">(keep it agentic-os unless your task needs a different folder)</span></label>
    <div class="pickrow" onclick="openFolderPicker()"><span class="ic">📁</span><span class="pth" id="l_cwd_label">${esc(def)}</span><span class="go">Browse ›</span></div>
    <input type="hidden" id="l_cwd" value="${esc(def)}">
    <div id="l_claudeonly">
      <label>Account</label><div class="seg" id="l_acct">${acctBtns}</div>
      <label>Permissions</label><div class="seg" id="l_perm">
        <button class="on" data-v="auto" onclick="segpick(this)">auto</button>
        <button data-v="bypass" onclick="segpick(this)">bypass</button></div>
      <div class="small" style="margin-top:8px">"default" is your main Claude sign-in; other accounts you added appear by name.</div>
    </div>
    <button class="btn" id="l_go" onclick="doLaunch()">Launch &amp; open</button>
    <button class="btn sec" onclick="closeSheet()">Cancel</button>`);
}
// Plain shell needs no account/permissions — hide them and relabel the button.
function kindPick(){
  const shell=segval('l_kind')==='shell';
  const co=$('#l_claudeonly'); if(co)co.style.display=shell?'none':'';
  $('#l_go').textContent=shell?'Open shell':'Launch & open';
}
function segpick(b){[...b.parentNode.children].forEach(x=>x.classList.remove('on'));b.classList.add('on')}
function segval(id){const e=$('#'+id+' .on');return e?e.dataset.v:''}
async function doLaunch(){
  const kind=segval('l_kind')||'claude';
  const label=kind==='shell'?'Open shell':'Launch & open';
  const body={kind:kind,name:$('#l_name').value,cwd:$('#l_cwd').value,account:segval('l_acct'),perm:segval('l_perm')};
  $('#l_go').textContent=kind==='shell'?'Opening…':'Launching…';$('#l_go').disabled=true;
  try{const r=await api('/api/launch',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
    if(r.ok){location.href='/term?s='+encodeURIComponent(r.tmux)}else{toast(r.error||'failed');$('#l_go').textContent=label;$('#l_go').disabled=false}
  }catch(e){toast(e.message);$('#l_go').textContent=label;$('#l_go').disabled=false}
}
function sheet(h){$('#sheetInner').innerHTML='<div class="grab"></div>'+h;$('#sheet').classList.add('on')}
function closeSheet(){$('#sheet').classList.remove('on')}
$('#sheet').addEventListener('click',e=>{if(e.target.id==='sheet')closeSheet()});

// ---- folder picker: a Finder-style browser stacked over the launch sheet ----
function openFolderPicker(){pcur=($('#l_cwd')&&$('#l_cwd').value)||HOME_DIR;$('#psheet').classList.add('on');renderPicker()}
function closePicker(){$('#psheet').classList.remove('on')}
async function renderPicker(){
  const box=$('#psheetInner');
  box.innerHTML='<div class="grab"></div><h2>Choose folder</h2><div class="muted">Loading…</div>';
  let d;try{d=await api('/api/ls?path='+encodeURIComponent(pcur||''));}catch(e){d={error:e.message};}
  const chips=[['✦ agentic-os',AOS_DIR],['🏠 Home',HOME_DIR],['💾 Volumes','/Volumes'],['📦 Workspace',WS_DIR]]
    .map(c=>`<button class="chip" data-p="${esc(c[1])}">${esc(c[0])}</button>`).join('');
  const cur=d.path||pcur;
  let list;
  if(d.error){
    list=`<div class="muted">🔒 ${esc(d.error)}<div class="small" style="margin-top:6px">If this is an external drive, the launcher may need Full Disk Access to browse it (System Settings → Privacy &amp; Security → Full Disk Access).</div></div>`;
  }else{
    pcur=d.path;
    const dirs=(d.entries||[]).filter(e=>e.dir);
    list=`<div class="card" data-p="${esc(d.parent)}"><div class="ic">↰</div><div class="body"><div class="nm">..</div><div class="sub">up one folder</div></div></div>`
      +(dirs.length?'':'<div class="small" style="padding:8px 4px">No sub-folders here — you can still use this folder.</div>')
      +dirs.map(e=>`<div class="card" data-p="${esc(e.path)}"><div class="ic">📁</div><div class="body"><div class="nm">${esc(e.name)}</div></div><span class="chev">›</span></div>`).join('');
  }
  box.innerHTML=`<div class="grab"></div><h2>Choose folder</h2>
    <div class="pchips">${chips}</div>
    <div class="crumb">${esc(cur)}</div>
    <div id="plist">${list}</div>
    <button class="btn" onclick="pickFolder()">Use this folder</button>
    <button class="btn sec" onclick="setDefaultFolder()">★ Set as default</button>
    <button class="btn sec" onclick="closePicker()">Cancel</button>`;
}
function pickFolder(){if($('#l_cwd'))$('#l_cwd').value=pcur;if($('#l_cwd_label'))$('#l_cwd_label').textContent=pcur;closePicker()}
async function setDefaultFolder(){
  try{const r=await api('/api/default-cwd',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({path:pcur})});
    if(r&&r.ok===false){toast('Couldn\'t set default: '+(r.error||''));return}
    toast('Default set ✓');pickFolder();
  }catch(e){toast('Couldn\'t set default')}
}
// Delegated: chips and folder cards carry the path in data-p, so no path is ever
// interpolated into an inline handler (that was the '..'-card apostrophe bug).
$('#psheet').addEventListener('click',e=>{
  if(e.target.id==='psheet'){closePicker();return}
  const el=e.target.closest('[data-p]');
  if(el){pcur=el.dataset.p;renderPicker()}
});
render();
</script></body></html>"""

# /term wrapper: full-bleed iframe over ttyd that reconnects itself. ttyd's own
# "Press ⏎ to Reconnect" overlay only listens for a keyboard Enter — dead on
# phones — so the wrapper reloads the iframe whenever the page comes back after
# sleep/lock (visibilitychange/focus, gated to real absences) or the network
# returns ('online'). Enter still works inside the iframe on desktop.
TERM_PAGE = """<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>__TITLE__</title>
<style>
html,body{margin:0;height:100%;background:#0f0e0d}
iframe{border:0;width:100%;height:100%;display:block}
/* Floating back-to-sessions control. Opening a terminal replaces the whole
   screen with ttyd's iframe; on a phone PWA there's no browser chrome, so this
   is the only way back to the session list. Sits in the top-left safe area,
   above the iframe, semi-transparent so it doesn't cover the terminal. */
#back{position:fixed;top:calc(8px + env(safe-area-inset-top));left:calc(8px + env(safe-area-inset-left));
  z-index:10;display:flex;align-items:center;gap:5px;height:38px;padding:0 14px 0 11px;
  border-radius:19px;background:rgba(26,24,23,.82);backdrop-filter:blur(8px);
  border:1px solid #2e2a27;color:#efe9e2;font:600 14px/1 -apple-system,system-ui,sans-serif;
  text-decoration:none;-webkit-tap-highlight-color:transparent}
#back:active{background:rgba(46,42,39,.92)}
#back .a{font-size:17px;line-height:1}
/* Scroll controls. A ttyd terminal can't be swiped to scroll on a phone, so
   these drive tmux copy-mode server-side (POST /api/scroll). Right-edge,
   vertically centred, same semi-transparent pill language as #back so they
   don't obscure the terminal. Touch targets are 46px. */
#scroll{position:fixed;right:calc(8px + env(safe-area-inset-right));top:50%;transform:translateY(-50%);
  z-index:10;display:flex;flex-direction:column;gap:8px}
#scroll button{width:46px;height:46px;border-radius:23px;border:1px solid #2e2a27;
  background:rgba(26,24,23,.82);backdrop-filter:blur(8px);color:#efe9e2;font-size:20px;line-height:1;
  display:flex;align-items:center;justify-content:center;-webkit-tap-highlight-color:transparent;cursor:pointer}
#scroll button:active{background:rgba(46,42,39,.92)}
#scroll .live{font-size:11px;font-weight:700;letter-spacing:.3px}
/* Orientation note shown every time the terminal opens so folks aren't lost:
   keep working here OR carry on from the Claude app. Auto-fades after 15s; "Got
   it" clears it for this view (it returns next time a session is opened). */
#hint{position:fixed;left:12px;right:12px;bottom:calc(14px + env(safe-area-inset-bottom));z-index:11;
  max-width:560px;margin:0 auto;display:flex;align-items:center;gap:10px;
  background:rgba(26,24,23,.94);backdrop-filter:blur(10px);border:1px solid #2e2a27;border-radius:14px;
  padding:12px 14px;font:500 13px/1.45 -apple-system,system-ui,sans-serif;color:#efe9e2;
  box-shadow:0 8px 28px rgba(0,0,0,.45);transition:opacity .4s}
#hint.gone{opacity:0;pointer-events:none}
#hint b{color:#e0556a}
#hintx{flex:0 0 auto;background:#e0556a;color:#fff;border:none;border-radius:10px;padding:9px 13px;font:600 13px/1 inherit}
#hintx:active{background:#c53b52}
</style>
</head><body>
<a id="back" href="/" aria-label="Back to sessions"><span class="a">‹</span>Sessions</a>
<iframe id="t" src="__SRC__" allow="clipboard-read;clipboard-write"></iframe>
<div id="scroll">
  <button data-d="up" aria-label="Scroll up">▲</button>
  <button data-d="live" class="live" aria-label="Jump to live">LIVE</button>
  <button data-d="down" aria-label="Scroll down">▼</button>
</div>
<div id="hint"><span>✦ Your session is live. Keep working right here in the terminal, or carry it on from the <b>Claude app</b> on your phone or computer — it's the same session, wherever you pick it up.</span><button id="hintx">Got it</button></div>
<script>
// Show the orientation note EVERY time a terminal is opened (no "remember" —
// dismissing just clears it for this view; it returns on the next session open).
(function(){var h=document.getElementById('hint');if(!h)return;
  function hide(){h.classList.add('gone');setTimeout(function(){h.style.display='none'},420)}
  document.getElementById('hintx').addEventListener('click',hide);
  setTimeout(hide,15000);
})();
// Scroll controls: a phone can't swipe a ttyd terminal, so these ask the server
// to drive tmux copy-mode for THIS session (name injected below). Fire-and-forget.
(function(){var SESS=__NAME__,box=document.getElementById('scroll');if(!box||!SESS)return;
  box.addEventListener('click',function(e){
    var b=e.target.closest('button[data-d]');if(!b)return;
    fetch('/api/scroll',{method:'POST',headers:{'content-type':'application/json'},
      body:JSON.stringify({name:SESS,dir:b.dataset.d})}).catch(function(){});
  });
})();
var f=document.getElementById('t'),away=0,last=0;
// Every iframe reload makes ttyd spawn a fresh PTY, and ttyd 1.7.7 leaks the
// descriptor. Reloading on blur/focus (which fire when you merely tap into the
// terminal, or when a notification slides past) churned through hundreds of
// PTYs a day and eventually hit the FD ceiling — at which point every terminal
// died on arrival. So: only visibilitychange, only after a real absence, and
// never more than once per 10s.
function reconnect(){var t=Date.now();if(t-last<10000)return;last=t;f.src=f.src}
document.addEventListener('visibilitychange',function(){
  if(document.hidden){away=Date.now();return}
  if(away&&Date.now()-away>60000)reconnect();
  away=0;
});
window.addEventListener('online',reconnect);
</script></body></html>"""

def term_page(name):
    src = f"http://{TSIP}:{TTYD_PORT}/?arg={urllib.parse.quote(name or '', safe='')}"
    return (TERM_PAGE
            .replace("__SRC__", html.escape(src, quote=True))
            .replace("__TITLE__", html.escape(name or "Session"))
            .replace("__NAME__", json.dumps(name or "")))

class H(BaseHTTPRequestHandler):
    def _auth(self):
        if not PW:
            return True
        hdr = self.headers.get("Authorization", "")
        if hdr.startswith("Basic "):
            try:
                user, pw = base64.b64decode(hdr[6:]).decode().split(":", 1)
                if user == "portal" and pw == PW:
                    return True
            except Exception:
                pass
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Session Launcher"')
        self.end_headers()
        return False

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("content-length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def log_message(self, *a):
        pass

    def do_GET(self):
        if not self._auth():
            return
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            # Inject the machine's own paths so the folder picker's quick-jump
            # chips (Home / Volumes / Workspace / agentic-os) know where to point
            # without an extra round-trip.
            ws = load_env("WORKSPACE_ROOT") or os.path.join(HOME, "repos")
            # Best guess at the agentic-os folder so non-technical users get a
            # one-tap chip instead of hunting for a path: WORKSPACE_ROOT/agentic-os
            # if it's there, else the saved default folder, else the workspace.
            aos = os.path.join(ws, "agentic-os")
            if not os.path.isdir(aos):
                dc = get_default_cwd()
                aos = dc if dc and dc != HOME else ws
            page = (PAGE.replace("__HOME__", json.dumps(HOME))
                        .replace("__WS__", json.dumps(ws))
                        .replace("__AOS__", json.dumps(aos)))
            body = page.encode()
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif u.path == "/api/sessions":
            self._json(list_sessions())
        elif u.path == "/api/repos":
            self._json({"repos": repos()})
        elif u.path == "/api/accounts":
            self._json({"accounts": available_accounts()})
        elif u.path == "/api/default-cwd":
            self._json({"path": get_default_cwd()})
        elif u.path == "/api/ls":
            self._json(list_dir(q.get("path", [""])[0]))
        elif u.path == "/api/read":
            self._json(read_file(q.get("path", [""])[0]))
        elif u.path == "/term":
            name = q.get("s", [""])[0]
            body = term_page(name).encode()
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        if not self._auth():
            return
        u = urllib.parse.urlparse(self.path)
        try:
            b = self._body()
        except Exception:
            return self._json({"ok": False, "error": "bad body"}, 400)
        if u.path == "/api/launch":
            if b.get("kind") == "shell":
                self._json(launch_shell(b.get("name"), b.get("cwd")))
            else:
                self._json(launch_session(b.get("name"), b.get("account"), b.get("perm"), b.get("cwd")))
        elif u.path == "/api/default-cwd":
            self._json(set_default_cwd(b.get("path", "")))
        elif u.path == "/api/kill":
            self._json(kill_session(b.get("name", "")))
        elif u.path == "/api/scroll":
            self._json(scroll_session(b.get("name", ""), b.get("dir", "")))
        elif u.path == "/api/write":
            self._json(write_file(b.get("path", ""), b.get("content", "")))
        else:
            self._json({"error": "not found"}, 404)

if __name__ == "__main__":
    bind = TSIP if TSIP != "127.0.0.1" else "0.0.0.0"
    print(f"Session Launcher web dashboard on http://{bind}:{PORT}  (tmux={TMUX}, pw={'set' if PW else 'NONE'})")
    ThreadingHTTPServer((bind, PORT), H).serve_forever()
