#!/usr/bin/env python3
"""claude_router: live HTML dashboard for the claude-max-overflow router.

Run it (no arguments): starts a small localhost server in the background (or reuses the one
already running) and opens the dashboard in your browser. The page refreshes itself every
minute; the server exits by itself once no dashboard tab has polled it for IDLE_EXIT_MIN.

What it shows: every account's live limit windows (5h / weekly / model-scoped / extra usage)
from the same /api/oauth/usage endpoint the router uses, credential health (ok/stale/dead,
token + refresh-token expiry), what `claude` would pick right now and why, pool headroom and
burn rate (from usage-history.jsonl, which the router and this dashboard append to), live
router-managed and unmanaged Claude Code sessions, in-session hops (with ping-pong detection),
keep-alive / sign-in / mirror logs, and local token usage from transcripts.

Safety: binds 127.0.0.1 only, checks the Host header (DNS rebinding) and requires a per-run
token on actions (CSRF). OAuth tokens never leave this process. Token renewal goes through the
router's own `_cof_ping` (a 1-token `claude -p` call, so Claude Code rotates under its lock);
nothing here rotates OAuth tokens itself. Stdlib only.
"""
import concurrent.futures as cf
import csv
import datetime as dt
import hashlib
import http.server
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

# ---------------- config ----------------
PORT = int(os.environ.get("COF_DASH_PORT", "8787"))
HOST = "127.0.0.1"
IDLE_EXIT_MIN = 45              # server exits after this long with no page polling it
AUTO_REFRESH_STALE = True       # renew stale overflow tokens (router's 1-token ping) so usage is readable
PING_RETRY_MIN = 30             # don't re-ping the same account more often than this
TOKEN_SCAN_DAYS = 14            # local transcript token stats window
HISTORY_DAYS = 8                # usage history sent to the page
LOG_TAIL = 60                   # lines of each log shown
USAGE_TTL = 300                 # reuse an account's usage (ours or the router's cache file) this long; the endpoint rate-limits
BACKOFF_429 = 600               # after a 429, leave that account alone this long (even on "Refresh now"): the router needs the endpoint too

HOME = Path.home()
COF_HOME = Path(os.environ.get("CLAUDE_OVERFLOW_HOME", HOME / ".claude-overflow"))
LOADER = COF_HOME / "claude-overflow.sh"
CACHE = COF_HOME / "cache"
HISTORY = COF_HOME / "usage-history.jsonl"
ACCOUNTS = COF_HOME / "accounts.tsv"
HERE = Path(__file__).resolve().parent
HTML_FILE = HERE / "cof-dashboard.html"
LAUNCHD_LABEL = "com.claude-max-overflow.keepalive"
PINGPONG_FIX = time.mktime(time.strptime("2026-09-26 02:40", "%Y-%m-%d %H:%M"))  # _cof_pick scoped-window fix landed
TOKEN_CACHE = CACHE / "dashboard-tokens.json"

CSRF = secrets.token_urlsafe(24)
_last_hit = time.time()
_lock = threading.Lock()
_ping_state = {}        # label -> {"running": bool, "last": epoch, "result": str}
_scan = {"running": False, "done_at": 0, "data": None, "error": None}
_backoff = {}           # key -> epoch until which we don't call the usage endpoint for it


# ---------------- small helpers ----------------
def now():
    return time.time()


def run(cmd, timeout=20, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 99, "", str(e)


def iso_to_epoch(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def tail(path, n=LOG_TAIL):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 200_000))
            lines = f.read().decode("utf-8", "replace").splitlines()
        return [re.sub(r"\x1b\[[0-9;]*m", "", ln) for ln in lines[-n:]]
    except OSError:
        return []


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


# ---------------- router config (authoritative: source the loader) ----------------
_cfg_cache = {"t": 0, "v": {}}


def router_config():
    if now() - _cfg_cache["t"] < 30:
        return _cfg_cache["v"]
    script = ('. "$1" >/dev/null 2>&1; for v in ${!CLAUDE_OVERFLOW_@}; do printf "%s\\t%s\\n" "$v" "${!v}"; done')
    rc, out, _ = run(["bash", "-c", script, "_", str(LOADER)], timeout=10)
    v = {}
    for ln in out.splitlines():
        if "\t" in ln:
            k, val = ln.split("\t", 1)
            v[k] = val
    _cfg_cache.update(t=now(), v=v)
    return v


def cfg_int(cfg, name, default):
    try:
        return int(cfg.get(name, default))
    except ValueError:
        return default


# ---------------- accounts + credentials (read-only replica of the loader) ----------------
def sha8(s):
    return hashlib.sha256(s.encode()).hexdigest()[:8]


def accounts():
    rows = [{"label": "primary", "dir": str(HOME / ".claude"), "cred": "Claude Code-credentials",
             "email": primary_email(), "primary": True}]
    try:
        with open(ACCOUNTS, newline="") as f:
            for r in csv.reader(f, delimiter="\t"):
                if r and r[0]:
                    r += [""] * (4 - len(r))
                    rows.append({"label": r[0], "dir": r[1], "cred": r[2], "email": r[3] or profile_email(r[1]), "primary": False})
    except OSError:
        pass
    return rows


def profile_email(d):
    try:
        return json.load(open(Path(d) / ".claude.json")).get("oauthAccount", {}).get("emailAddress", "")
    except Exception:  # noqa: BLE001
        return ""


def primary_email():
    try:
        return json.load(open(HOME / ".claude.json")).get("oauthAccount", {}).get("emailAddress", "")
    except Exception:  # noqa: BLE001
        return ""


def creds_json(src):
    """The stored credential JSON for a source (file path or Keychain service). Never returned to the page."""
    if not src:
        return None
    if src.startswith("/"):
        try:
            return json.load(open(src))
        except Exception:  # noqa: BLE001
            return None
    rc, out, _ = run(["security", "find-generic-password", "-w", "-s", src], timeout=8)
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def cred_state(j):
    o = (j or {}).get("claudeAiOauth")
    if not o:
        return "dead"
    ms = now() * 1000
    if o.get("accessToken") and (o.get("expiresAt") or 0) - 60000 > ms:
        return "ok"
    rte = o.get("refreshTokenExpiresAt") or 0
    if o.get("refreshToken") and (rte == 0 or rte > ms):
        return "stale"
    return "dead"


def resolve_cred(acct):
    """Like _cof_cred_of, but never rewrites accounts.tsv. Returns (source, json, state, migrated_from)."""
    j = creds_json(acct["cred"])
    st = cred_state(j)
    if st != "dead" or acct["primary"]:
        return acct["cred"], j, st, None
    for alt in (f"Claude Code-credentials-{sha8(acct['dir'])}", f"{acct['dir']}/.credentials.json"):
        if alt == acct["cred"]:
            continue
        ja = creds_json(alt)
        sa = cred_state(ja)
        if sa != "dead":
            return alt, ja, sa, acct["cred"]
    return acct["cred"], j, st, None


# ---------------- usage ----------------
def pcts(u):
    def mx(kind):
        vals = [l.get("percent") or 0 for l in (u.get("limits") or []) if l.get("kind") == kind]
        return round(max(vals)) if vals else 0
    return mx("session"), mx("weekly_all"), mx("weekly_scoped")


def append_history(key, u, src):
    s, w, sc = pcts(u)
    ex = u.get("extra_usage") or {}
    rec = {"t": int(now()), "k": key, "s": s, "w": w, "sc": sc,
           "sr": iso_to_epoch((u.get("five_hour") or {}).get("resets_at")),
           "wr": iso_to_epoch((u.get("seven_day") or {}).get("resets_at")),
           "x": ex.get("used_credits"), "src": src}
    rec = {k: (int(v) if isinstance(v, float) and k in ("sr", "wr") else v) for k, v in rec.items()}
    try:
        with open(HISTORY, "a") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except OSError:
        pass


def fetch_usage(key, token, ttl, force, src="dash", timeout=8):
    """Same endpoint, headers and cache file as the loader's _cof_fetch. `src` tags the history record
    (cof-context.py reuses this with "ctx")."""
    cache = CACHE / f"usage-{key}.json"
    m = mtime(cache)
    if not force and m and now() - m < ttl:
        try:
            return json.load(open(cache)), m, None
        except ValueError:
            pass
    try:   # a 429 seen by any caller (cof-context.py hooks/MCP persist theirs here) counts for everyone
        _backoff[key] = max(_backoff.get(key, 0), float((CACHE / "ctx" / f"backoff-{key}").read_text()))
    except (OSError, ValueError):
        pass
    if now() < _backoff.get(key, 0):
        return None, None, f"HTTP 429, backing off until {time.strftime('%H:%M', time.localtime(_backoff[key]))}"
    if force and m and now() - m < 30:      # "Refresh now" right after someone else fetched: that's fresh enough
        try:
            return json.load(open(cache)), m, None
        except ValueError:
            pass
    if not token:
        return None, None, "no access token"
    req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage", headers={
        "Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json", "User-Agent": "claude-max-overflow-dashboard"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode()
    except urllib.error.HTTPError as e:
        if e.code == 429:
            _backoff[key] = now() + BACKOFF_429
            try:
                (CACHE / "ctx").mkdir(parents=True, exist_ok=True)
                (CACHE / "ctx" / f"backoff-{key}").write_text(str(_backoff[key]))
            except OSError:
                pass
        return None, None, f"HTTP {e.code}"
    except Exception as e:  # noqa: BLE001
        return None, None, type(e).__name__
    try:
        u = json.loads(body)
    except ValueError:
        return None, None, "bad JSON"
    if "limits" not in u:
        return None, None, "no limits in response"
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = cache.with_suffix(f".json.{src}{os.getpid()}")
    tmp.write_text(body + "\n")
    os.replace(tmp, cache)
    append_history(key, u, src)
    return u, now(), None


def cached_usage(key):
    cache = CACHE / f"usage-{key}.json"
    try:
        return json.load(open(cache)), mtime(cache)
    except Exception:  # noqa: BLE001
        return None, None


# ---------------- token renewal / sign-in via the router itself ----------------
def ping(label):
    with _lock:
        st = _ping_state.setdefault(label, {})
        if st.get("running"):
            return
        st.update(running=True, last=now(), result="running")

    def work():
        rc, out, err = run(["bash", "-c", '. "$1" >/dev/null 2>&1 && _cof_ping "$2"', "_", str(LOADER), label], timeout=120)
        with _lock:
            _ping_state[label].update(running=False, result="ok" if rc == 0 else f"failed (exit {rc})", done=now())
    threading.Thread(target=work, daemon=True).start()


LABEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,24}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
RESERVED = {"primary", "login", "all"}   # login = _cof_pick's sentinel, all = `claude-overflow login all`


def add_account(label, email):
    """Register a new overflow account via the router's own _cof_add, then open its browser sign-in."""
    label, email = (label or "").strip(), (email or "").strip()
    if not LABEL_RE.match(label):
        return {"ok": False, "error": "Label: 1-24 letters, digits, _ or -."}
    if label.lower() in RESERVED:
        return {"ok": False, "error": f"'{label}' is reserved."}
    rows = accounts()
    if label in {a["label"] for a in rows}:
        return {"ok": False, "error": f"There's already an account called '{label}'."}
    if email and not EMAIL_RE.match(email):
        return {"ok": False, "error": "That email doesn't look right."}
    for a in rows:
        if email and a["email"] and a["email"].lower() == email.lower():
            return {"ok": False, "error": f"{email} is already in the router as '{a['label']}'."}
    rc, out, err = run(["bash", "-c", '. "$1" >/dev/null 2>&1 && _cof_add "$2" "$3" </dev/null', "_",
                        str(LOADER), label, email], timeout=60)
    log = re.sub(r"\x1b\[[0-9;]*m", "", (out + err)).strip()
    if rc != 0 or label not in {a["label"] for a in accounts()}:
        return {"ok": False, "error": "Registering failed.", "log": log}
    signin = start_login(label)
    return {"ok": True, "label": label, "signin": signin, "log": log}


def remove_account(label):
    """Unregister a signed-out overflow account (the profile dir is kept, same as `claude-overflow remove`)."""
    rows = {a["label"]: a for a in accounts()}
    a = rows.get(label)
    if not a or a["primary"]:
        return {"ok": False, "error": "unknown account"}
    if resolve_cred(a)[2] != "dead":
        return {"ok": False, "error": f"'{label}' is signed in; remove it from a terminal instead: claude-overflow remove {label}"}
    rc, out, err = run(["bash", "-c", '. "$1" >/dev/null 2>&1 && claude-overflow remove "$2" </dev/null', "_", str(LOADER), label], timeout=30)
    return {"ok": rc == 0 and label not in {x["label"] for x in accounts()}, "log": (out + err).strip()}


def start_login(label):
    rc, out, err = run(["bash", "-c", '. "$1" >/dev/null 2>&1 && _cof_login_bg "$2" dashboard force', "_", str(LOADER), label], timeout=20)
    return rc == 0


# ---------------- logs ----------------
HOP_RE = re.compile(r"^(\S+ \S+) (\S+) (\S+) (\S+): (.*)$")


def parse_insession():
    events = []
    for ln in tail(COF_HOME / "insession.log", 5000):
        m = HOP_RE.match(ln)
        if not m:
            continue
        ts, acct, ev, err, msg = m.groups()
        t = time.mktime(time.strptime(ts, "%Y-%m-%d %H:%M:%S"))
        kind, target, reason = "other", None, msg
        sm = re.match(r"switch -> (\S+) \((.*)\)$", msg)
        if sm:
            kind, target, reason = "switch", sm.group(1), sm.group(2)
        elif msg.startswith("paused"):
            kind = "paused"
        elif "sign-in" in msg:
            kind = "signin"
        events.append({"t": t, "from": acct, "event": ev, "error": None if err == "-" else err,
                       "kind": kind, "to": target, "reason": reason, "trigger": "wall" if ev == "StopFailure" else "proactive"})
    # ping-pong: per account pair, >= 4 hops back and forth with < 15 min between consecutive ones
    # (concurrent sessions interleave in the log, so look at each pair's hops on their own)
    sw = [e for e in events if e["kind"] == "switch"]
    pairs = {}
    for e in sw:
        pairs.setdefault(tuple(sorted((e["from"], e["to"]))), []).append(e)
    bursts = []
    for pair, hops in pairs.items():
        i = 0
        while i < len(hops):
            j = i
            while j + 1 < len(hops) and hops[j + 1]["t"] - hops[j]["t"] < 900:
                j += 1
            group = hops[i:j + 1]
            if len(group) >= 4 and len({e["from"] for e in group}) == 2:
                bursts.append({"start": group[0]["t"], "end": group[-1]["t"], "count": len(group),
                               "accounts": list(pair), "sample_reason": group[0]["reason"]})
                for e in group:
                    e["thrash"] = True
            i = j + 1
    bursts.sort(key=lambda b: b["start"])
    return events, bursts


def parse_keepalive():
    lines = tail(COF_HOME / "keepalive.log", 400)
    runs = []
    for ln in lines:
        m = re.match(r"^(\S+ \S+) (\S+?): (.*)$", ln)
        if m:
            runs.append({"t": time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")), "label": m.group(2), "msg": m.group(3)})
    return runs


def launchd_status():
    rc, out, _ = run(["launchctl", "print", f"gui/{os.getuid()}/{LAUNCHD_LABEL}"], timeout=5)
    if rc != 0:
        return {"installed": False}
    def grab(key):
        m = re.search(rf"^\s*{re.escape(key)} = (.*)$", out, re.M)
        return m.group(1).strip() if m else None
    iv = grab("run interval")
    return {"installed": True, "state": grab("state"), "runs": grab("runs"), "last_exit": grab("last exit code"),
            "interval_s": int(iv.split()[0]) if iv else None}


def mirrors():
    out = []
    try:
        with open(COF_HOME / "mirrors.tsv", newline="") as f:
            for r in csv.reader(f, delimiter="\t"):
                if len(r) >= 4:
                    out.append({"session": r[0], "url": "https://claude.ai/code/session_" + r[1][4:] if r[1].startswith("cse_") else r[1],
                                "label": r[2], "when": r[3], "title": (r[4] if len(r) > 4 else "").strip()})
    except OSError:
        pass
    return out[-30:]


# ---------------- sessions ----------------
def sessions(acct_rows):
    """Live Claude Code processes: which account each runs on and whether the router manages it."""
    dir2label = {a["dir"].rstrip("/"): a["label"] for a in acct_rows}
    rc, out, _ = run(["ps", "-Eww", "-Ao", "pid=,ppid=,lstart=,command="], timeout=10)
    procs = []
    for ln in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\w{3} \w{3}\s+\d+ \d\d:\d\d:\d\d \d{4})\s+(.*)$", ln)
        if not m:
            continue
        pid, ppid, lstart, cmd = m.groups()
        exe = cmd.split(" ", 1)[0]
        base = exe.rsplit("/", 1)[-1]
        if not (base == "claude" or re.search(r"/claude/versions/[\d.]+$", exe)):
            continue
        args_env = cmd
        env = dict(re.findall(r"(?:^| )(COF_ACCOUNT|COF_CTRL_DIR|COF_MANAGED|CLAUDE_CONFIG_DIR|CLAUDE_CODE_ENTRYPOINT|TMUX)=(\S*)", args_env))
        # command line proper = up to the first ENV=... token that ps -E appended
        argv = re.split(r" (?=[A-Za-z_][A-Za-z0-9_]*=)", cmd, maxsplit=1)[0]
        if " remote-control" in argv:
            kind = "rc-daemon"          # the Remote Control supervisor (spawns remote sessions)
        elif "--sdk-url" in argv:
            kind = "remote"             # a Remote Control / claude.ai-driven session
        elif re.search(r"(^| )(-p|--print)( |$)", argv):
            kind = "print"              # headless one-shot (scripts, the router's token pings)
        else:
            kind = "interactive"
        label = env.get("COF_ACCOUNT") or dir2label.get(env.get("CLAUDE_CONFIG_DIR", "").rstrip("/"), "primary" if not env.get("CLAUDE_CONFIG_DIR") else env.get("CLAUDE_CONFIG_DIR"))
        try:
            started = time.mktime(time.strptime(lstart, "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            started = None
        procs.append({"pid": int(pid), "ppid": int(ppid), "started": started, "account": label,
                      "managed": env.get("COF_MANAGED") == "1", "ctrl": env.get("COF_CTRL_DIR"),
                      "entry": env.get("CLAUDE_CODE_ENTRYPOINT"), "tmux": bool(env.get("TMUX")), "kind": kind,
                      "args": re.sub(r"--settings \{.*?cof-insession-hook.*?\}\]\}\]\}\}", "--settings <router hook>", " ".join(argv.split()[1:]))[:160]})
    if procs:
        rc, out, _ = run(["lsof", "-a", "-d", "cwd", "-p", ",".join(str(p["pid"]) for p in procs), "-Fpn"], timeout=10)
        cwd, cur = {}, None
        for ln in out.splitlines():
            if ln.startswith("p"):
                cur = int(ln[1:])
            elif ln.startswith("n") and cur:
                cwd[cur] = ln[1:]
        for p in procs:
            p["cwd"] = cwd.get(p["pid"], "").replace(str(HOME), "~")
            if p["ctrl"]:
                paused = (Path(p["ctrl"]) / "paused")
                try:
                    txt = paused.read_text().strip()
                except OSError:
                    txt = ""
                p["paused"] = txt or None
    # leftover control dirs (session gone without cleanup)
    tmp = Path(os.environ.get("TMPDIR", "/tmp"))
    stale_ctrl = 0
    for d in tmp.glob("cof.*"):
        try:
            pid = int((d / "pid").read_text().strip() or 0)
        except (OSError, ValueError):
            pid = 0
        if not pid or not _alive(pid):
            stale_ctrl += 1
    procs.sort(key=lambda p: p["started"] or 0, reverse=True)
    return procs, stale_ctrl


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ---------------- local transcript token stats (incremental, background) ----------------
def _scan_file(path_str):
    days = {}
    seen = set()
    try:
        with open(path_str, "rb") as f:
            for raw in f:
                if b'"usage"' not in raw or b'"assistant"' not in raw:
                    continue
                try:
                    o = json.loads(raw)
                except ValueError:
                    continue
                if o.get("type") != "assistant":
                    continue
                msg = o.get("message") or {}
                u = msg.get("usage") or {}
                key = (msg.get("id"), o.get("requestId"))
                if key in seen:
                    continue
                seen.add(key)
                model = msg.get("model") or "?"
                if model == "<synthetic>":
                    continue
                ts = o.get("timestamp") or ""
                day = ts[:10]
                if not day:
                    continue
                # local day
                ep = iso_to_epoch(ts)
                if ep:
                    day = time.strftime("%Y-%m-%d", time.localtime(ep))
                d = days.setdefault(day, {}).setdefault(model, [0, 0, 0, 0, 0])
                d[0] += u.get("input_tokens") or 0
                d[1] += u.get("cache_creation_input_tokens") or 0
                d[2] += u.get("cache_read_input_tokens") or 0
                d[3] += u.get("output_tokens") or 0
                d[4] += 1
    except OSError:
        pass
    return days


def token_scan():
    with _lock:
        if _scan["running"]:
            return
        _scan["running"] = True

    def work():
        try:
            cutoff = now() - TOKEN_SCAN_DAYS * 86400
            try:
                cache = json.load(open(TOKEN_CACHE))
            except Exception:  # noqa: BLE001
                cache = {}
            files = []
            for p in (HOME / ".claude" / "projects").rglob("*.jsonl"):
                try:
                    stt = p.stat()
                except OSError:
                    continue
                if stt.st_mtime >= cutoff:
                    files.append((str(p), stt.st_size, stt.st_mtime))
            todo = [f for f in files if (c := cache.get(f[0])) is None or c["size"] != f[1] or c["mtime"] != f[2]]
            with cf.ProcessPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
                for (path, size, mt), res in zip(todo, ex.map(_scan_file, [t[0] for t in todo], chunksize=8)):
                    cache[path] = {"size": size, "mtime": mt, "days": res}
            keep = {f[0] for f in files}
            cache = {k: v for k, v in cache.items() if k in keep}
            tmp = TOKEN_CACHE.with_suffix(".tmp")
            tmp.write_text(json.dumps(cache))
            os.replace(tmp, TOKEN_CACHE)
            first = time.strftime("%Y-%m-%d", time.localtime(cutoff + 86400))
            agg = {}
            sessions_per_day = {}
            for path, c in cache.items():
                for day, models in c["days"].items():
                    if day < first:
                        continue
                    sessions_per_day.setdefault(day, set()).add(path)
                    for model, v in models.items():
                        a = agg.setdefault(day, {}).setdefault(model, [0, 0, 0, 0, 0])
                        for i in range(5):
                            a[i] += v[i]
            with _lock:
                _scan.update(data={"days": agg, "sessions": {d: len(s) for d, s in sessions_per_day.items()},
                                   "files": len(files), "rescanned": len(todo), "window_days": TOKEN_SCAN_DAYS},
                             done_at=now(), error=None)
        except Exception as e:  # noqa: BLE001
            with _lock:
                _scan["error"] = repr(e)
        finally:
            with _lock:
                _scan["running"] = False
    threading.Thread(target=work, daemon=True).start()


# ---------------- history ----------------
def history():
    cutoff = now() - HISTORY_DAYS * 86400
    out = []
    try:
        with open(HISTORY) as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 8_000_000))
            if size > 8_000_000:
                f.readline()
            for ln in f:
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if r.get("t", 0) >= cutoff:
                    out.append(r)
    except OSError:
        pass
    # the hop log records the target account's usage at each hop: real router readings, use them as samples too
    for e in parse_insession()[0]:
        m = re.search(r"session (\d+)% weekly (\d+)%", e["reason"] or "")
        if e["kind"] == "switch" and m and e["t"] >= cutoff and e["to"]:
            out.append({"t": e["t"], "k": e["to"], "s": int(m.group(1)), "w": int(m.group(2)), "sc": None, "src": "hoplog"})
    out.sort(key=lambda r: r["t"])
    # thin: keep at most one sample per account per 2 minutes
    thin, last = [], {}
    for r in out:
        if r["t"] - last.get(r["k"], 0) >= 120:
            thin.append(r)
            last[r["k"]] = r["t"]
    return thin


def burn_rates(hist, window_h=24):
    """%-points of the weekly window consumed per hour, per account, over the trailing window."""
    cutoff = now() - window_h * 3600
    by = {}
    for r in hist:
        by.setdefault(r["k"], []).append(r)
    res = {}
    for k, rs in by.items():
        rs = [r for r in rs if r["t"] >= cutoff]
        used, span = 0.0, 0.0
        for a, b in zip(rs, rs[1:]):
            d = b["w"] - a["w"]
            # resets_at jitters by a second between fetches: same window if within an hour
            if d >= 0 and (not a.get("wr") or not b.get("wr") or abs(a["wr"] - b["wr"]) < 3600):
                used += d
        if len(rs) >= 2:
            span = (rs[-1]["t"] - rs[0]["t"]) / 3600
        res[k] = {"used": used, "span_h": span, "samples": len(rs)}
    # pool pace: every account's weekly %-points consumed in the window, over the longest observed span
    span = max((r["span_h"] for r in res.values()), default=0)
    pool = {"used": sum(r["used"] for r in res.values()), "span_h": span, "window_h": window_h}
    pool["per_day"] = pool["used"] / span * 24 if span >= 2 else None
    return {"accounts": res, "pool": pool}


# ---------------- router decision (read-only replica of _cof_pick) ----------------
def simulate_pick(accts, cfg):
    S, W, SC, FULL = (cfg_int(cfg, "CLAUDE_OVERFLOW_SESSION_AT", 85), cfg_int(cfg, "CLAUDE_OVERFLOW_WEEKLY_AT", 92),
                      cfg_int(cfg, "CLAUDE_OVERFLOW_SCOPED_AT", 92), cfg_int(cfg, "CLAUDE_OVERFLOW_FULL_AT", 97))
    steps = []
    prim = accts[0]
    if prim["pcts"] is None:
        return {"pick": "primary", "reason": "usage check failed (router falls back to primary)", "steps": steps}
    s, w, sc = prim["pcts"]
    tripped = [txt for hit, txt in ((s >= S, f"5h {s}% >= {S}"), (w >= W, f"weekly {w}% >= {W}"), (sc >= SC, f"scoped {sc}% >= {SC}")) if hit]
    if not tripped:
        return {"pick": "primary", "reason": f"primary has headroom (5h {s}%, weekly {w}%, scoped {sc}%)", "steps": steps}
    steps.append(f"primary skipped: {', '.join(tripped)}")
    # only the model-scoped window tripped: the overflow account needs room there too (same rule as _cof_pick)
    need_sc = s < S and w < W
    if need_sc:
        steps.append("only the model-scoped window is over, so the next account needs room in it too")
    blind = dead = None
    for a in accts[1:]:
        if a["state"] == "dead":
            steps.append(f"{a['label']}: signed out")
            dead = dead or a["label"]
            continue
        if a["pcts"] is None or a["usage_stale"]:
            steps.append(f"{a['label']}: usage unreadable (token {a['state']})")
            blind = blind or a["label"]
            continue
        s, w, sc = a["pcts"]
        if s < FULL and w < FULL and (not need_sc or sc < FULL):
            return {"pick": a["label"], "reason": f"overflow: 5h {s}%, weekly {w}%" + (f", scoped {sc}%" if need_sc else ""), "steps": steps}
        steps.append(f"{a['label']}: full (5h {s}%, weekly {w}%{f', scoped {sc}%' if need_sc else ''})")
    if blind:
        return {"pick": blind, "reason": "blind (usage unreadable; Claude Code renews the token on launch)", "steps": steps}
    if dead:
        return {"pick": "login", "reason": f"only signed-out accounts left ({dead}): sign-in window opens", "steps": steps}
    return {"pick": "primary", "reason": "all accounts near limits" + (" (incl. the model-scoped window)" if need_sc else ""), "steps": steps}


# ---------------- state assembly ----------------
KNOWN_WINDOWS = {"five_hour", "seven_day", "extra_usage", "limits", "spend", "seven_day_breakdown", "member_dashboard_available"}


def other_windows(u):
    out = []
    for k, v in (u or {}).items():
        if k in KNOWN_WINDOWS or not isinstance(v, dict) or "utilization" not in v:
            continue
        out.append({"key": k, "utilization": v.get("utilization"), "resets_at": iso_to_epoch(v.get("resets_at")),
                    "limit_dollars": v.get("limit_dollars"), "used_dollars": v.get("used_dollars"),
                    "remaining_dollars": v.get("remaining_dollars")})
    return out


def account_state(a, cfg, force):
    src, j, st, migrated = resolve_cred(a)
    o = (j or {}).get("claudeAiOauth") or {}
    ttl = max(USAGE_TTL, cfg_int(cfg, "CLAUDE_OVERFLOW_TTL", 60))
    u, fetched_at, err = (None, None, None)
    if st == "ok":
        u, fetched_at, err = fetch_usage(a["label"], o.get("accessToken"), ttl, force)
    usage_stale = False
    if u is None:
        u, fetched_at = cached_usage(a["label"])
        usage_stale = u is not None
        if err is None and st != "ok":
            err = f"token {st}"
    rec = {"label": a["label"], "email": a["email"], "dir": a["dir"].replace(str(HOME), "~"), "primary": a["primary"],
           "cred_source": src, "cred_store": "file" if src.startswith("/") else "keychain", "migrated_from": migrated,
           "state": st, "expires_at": (o.get("expiresAt") or 0) / 1000 or None,
           "refresh_expires_at": (o.get("refreshTokenExpiresAt") or 0) / 1000 or None,
           "subscription": o.get("subscriptionType"), "tier": o.get("rateLimitTier"),
           "fetched_at": fetched_at, "fetch_error": err, "usage_stale": usage_stale,
           "ping": dict(_ping_state.get(a["label"], {})),
           "login_inflight": _alive(int((CACHE / f"login-{a['label']}.pid").read_text().strip() or 0)) if (CACHE / f"login-{a['label']}.pid").exists() else False,
           "pcts": None}
    if u:
        rec["pcts"] = list(pcts(u))
        rec["limits"] = [{"kind": l.get("kind"), "percent": l.get("percent"), "severity": l.get("severity"),
                          "resets_at": iso_to_epoch(l.get("resets_at")), "active": l.get("is_active"),
                          "scope": ((l.get("scope") or {}).get("model") or {}).get("display_name")} for l in u.get("limits") or []]
        ex = u.get("extra_usage") or {}
        rec["extra"] = {k: ex.get(k) for k in ("is_enabled", "monthly_limit", "used_credits", "utilization", "currency",
                                               "disabled_reason", "spend_limit_reached")}
        rec["breakdown"] = (u.get("seven_day_breakdown") or {}).get("rows")
        rec["other_windows"] = other_windows(u)
    # renew stale tokens ourselves (through the router's own ping) so usage becomes readable
    if AUTO_REFRESH_STALE and st == "stale" and not a["primary"]:
        ps = _ping_state.get(a["label"], {})
        if not ps.get("running") and now() - ps.get("last", 0) > PING_RETRY_MIN * 60:
            ping(a["label"])
            rec["ping"] = {"running": True, "result": "running", "last": now()}
    return rec


def health(accts, cfg, ka, kalog, procs, stale_ctrl, bursts, pick):
    checks = []
    def add(level, title, detail=""):
        checks.append({"level": level, "title": title, "detail": detail})
    for f in ("claude-overflow.sh", "cof-insession-hook.sh"):
        p = COF_HOME / f
        add("good" if p.exists() else "critical", f"{f} installed", str(p.resolve()) if p.exists() else "missing: re-run setup.sh")
    if not ka.get("installed"):
        add("serious", "keep-alive not installed", "claude-overflow install-keepalive")
    else:
        last = max((r["t"] for r in kalog), default=None)
        iv = ka.get("interval_s") or 43200
        ok = last and now() - last < iv * 1.25
        add("good" if ok else "warning", "keep-alive running on schedule" if ok else "keep-alive overdue",
            f"last run {time.strftime('%a %H:%M', time.localtime(last)) if last else 'never'}, every {iv // 3600}h, {ka.get('runs')} runs, last exit {ka.get('last_exit')}")
    for a in accts:
        if a["state"] == "dead":
            add("critical", f"{a['label']} is signed out", "sign-in opens at your next launch; or use the Sign in button")
        elif a.get("refresh_expires_at") and a["refresh_expires_at"] - now() < 3 * 86400:
            add("warning", f"{a['label']} refresh token expires soon", time.strftime("%a %b %d %H:%M", time.localtime(a["refresh_expires_at"])))
        if a.get("migrated_from"):
            add("warning", f"{a['label']} login moved credential stores", f"accounts.tsv says {a['migrated_from']}, live login is in {a['cred_source']}; the router self-heals this on next use")
    seen = {}
    for a in accts:
        e = (a.get("email") or "").lower()
        if e and a["state"] != "dead":
            seen.setdefault(e, []).append(a["label"])
    for e, labels in seen.items():
        if len(labels) > 1:
            add("critical", f"{' and '.join(labels)} are signed into the same account ({e})",
                "they share one set of limits, so the router's headroom math double-counts it; sign one of them into a different account or remove it")
    unmanaged = [p for p in procs if p["kind"] in ("interactive", "remote") and not p["managed"]]
    if unmanaged:
        add("info", f"{len(unmanaged)} live session(s) not router-managed",
            "they stay on the account they started on and can't hop when it runs out (Remote Control sessions, or launched outside the `claude` wrapper)")
    if bursts:
        recent = bursts[-1]
        total = sum(b["count"] for b in bursts)
        after_fix = [b for b in bursts if b["end"] > PINGPONG_FIX]
        detail = (f"latest: {recent['count']} hops between {' and '.join(recent['accounts'])} on "
                  + time.strftime("%b %d %H:%M", time.localtime(recent["start"])) + ". ")
        if after_fix:
            add("serious", f"ping-pong hops since the 2026-09-26 fix: {len(after_fix)} burst(s)",
                detail + "The model-scoped-window fix didn't cover this case; check the hop reasons in the table below.")
        else:
            add("info", f"past ping-pong: {len(bursts)} burst(s), {total} hops back and forth, all before the 2026-09-26 fix",
                detail + "Cause (fixed): a hop triggered by a model-scoped window (e.g. Fable) could pick an account that was also out "
                         "for that model. The picker now requires room in that window when it's what ran out.")
    if stale_ctrl:
        add("info", f"{stale_ctrl} leftover control dir(s) in $TMPDIR", "sessions that ended without the loop's cleanup (terminal closed); harmless")
    benign, other = [], []
    for label in ["primary"] + [a["label"] for a in accts[1:]]:
        err = CACHE / f"ping-{label}.err"
        if err.exists() and err.stat().st_size:
            txt = err.read_text()[:300].strip()
            (benign if "Permission allow rule" in txt else other).append((label, txt))
    for label, txt in other:
        add("warning", f"last token ping for {label} printed an error", txt)
    if benign:
        add("info", f"token pings print a harmless settings warning ({', '.join(l for l, _ in benign)})", benign[0][1])
    return checks


def state(force=False):
    cfg = router_config()
    rows = accounts()
    with cf.ThreadPoolExecutor(max_workers=len(rows)) as ex:
        accts = list(ex.map(lambda a: account_state(a, cfg, force), rows))
    hist = history()
    events, bursts = parse_insession()
    kalog = parse_keepalive()
    ka = launchd_status()
    procs, stale_ctrl = sessions(rows)
    pick = simulate_pick(accts, cfg)
    burn = burn_rates(hist)
    if not _scan["running"] and now() - _scan["done_at"] > 600:
        token_scan()
    last_mark = (CACHE / "last")
    return {
        "now": now(), "host": socket.gethostname(),
        "config": {k: v for k, v in cfg.items() if k not in ("CLAUDE_OVERFLOW_HOME",)},
        "accounts": accts, "pick": pick, "burn": burn, "history": hist,
        "hops": events[-300:], "bursts": bursts,
        "keepalive": {"launchd": ka, "log": kalog[-40:]},
        "login_log": tail(COF_HOME / "login.log", 30), "login_browser_log": tail(CACHE / "login-browser.log", 10),
        "mirrors": mirrors(), "sessions": procs, "stale_ctrl": stale_ctrl,
        "last_launch": {"label": last_mark.read_text().strip() if last_mark.exists() else None, "at": mtime(last_mark)},
        "claude_version": claude_version(),
        "tokens": {"running": _scan["running"], "done_at": _scan["done_at"], "error": _scan["error"], "data": _scan["data"]},
        "health": health(accts, cfg, ka, kalog, procs, stale_ctrl, bursts, pick),
        "csrf": CSRF,
    }


_ver = {"t": 0, "v": None}


def claude_version():
    if now() - _ver["t"] > 600:
        rc, out, _ = run(["bash", "-c", "command claude --version 2>/dev/null | head -1"], timeout=15)
        _ver.update(t=now(), v=out.strip() or None)
    return _ver["v"]


# ---------------- HTTP ----------------
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "cof-dashboard"

    def log_message(self, fmt, *args):
        pass

    def _host_ok(self):
        h = (self.headers.get("Host") or "").lower()
        return h in (f"127.0.0.1:{PORT}", f"localhost:{PORT}")

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global _last_hit
        if not self._host_ok():
            return self._send(403, '{"error":"bad host"}')
        _last_hit = now()
        path = self.path.split("?", 1)[0]
        if path == "/":
            try:
                return self._send(200, HTML_FILE.read_bytes(), "text/html")
            except OSError:
                return self._send(500, f"missing {HTML_FILE}", "text/plain")
        if path == "/api/ping":
            return self._send(200, json.dumps({"app": "cof-dashboard", "pid": os.getpid()}))
        if path == "/api/state":
            force = "fresh=1" in self.path
            try:
                return self._send(200, json.dumps(state(force), default=str))
            except Exception as e:  # noqa: BLE001
                return self._send(500, json.dumps({"error": repr(e)}))
        self._send(404, '{"error":"not found"}')

    def do_POST(self):
        global _last_hit
        if not self._host_ok() or self.headers.get("X-COF-Token") != CSRF:
            return self._send(403, '{"error":"forbidden"}')
        _last_hit = now()
        m = re.match(r"^/api/(refresh|login)/([A-Za-z0-9_.-]+)$", self.path)
        if m:
            action, label = m.groups()
            if label not in {a["label"] for a in accounts()} or label == "primary" and action == "login":
                return self._send(400, '{"error":"unknown account"}')
            if action == "refresh":
                with _lock:
                    _ping_state.pop(label, None)
                ping(label)
                return self._send(200, '{"ok":true}')
            return self._send(200, json.dumps({"ok": start_login(label)}))
        if self.path == "/api/add":
            try:
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(min(n, 4096)) or b"{}")
            except ValueError:
                return self._send(400, '{"error":"bad JSON"}')
            return self._send(200, json.dumps(add_account(body.get("label"), body.get("email"))))
        m = re.match(r"^/api/remove/([A-Za-z0-9_-]+)$", self.path)
        if m:
            return self._send(200, json.dumps(remove_account(m.group(1))))
        if self.path == "/api/rescan-tokens":
            with _lock:
                _scan["done_at"] = 0
            token_scan()
            return self._send(200, '{"ok":true}')
        if self.path == "/api/quit":
            self._send(200, '{"ok":true}')
            threading.Thread(target=lambda: (time.sleep(0.3), os._exit(0)), daemon=True).start()
            return
        self._send(404, '{"error":"not found"}')


def serve():
    srv = http.server.ThreadingHTTPServer((HOST, PORT), Handler)

    def idle_watch():
        while True:
            time.sleep(30)
            if now() - _last_hit > IDLE_EXIT_MIN * 60:
                os._exit(0)
    threading.Thread(target=idle_watch, daemon=True).start()
    token_scan()
    srv.serve_forever()


def running_instance():
    try:
        with urllib.request.urlopen(f"http://{HOST}:{PORT}/api/ping", timeout=1.5) as r:
            return json.loads(r.read()).get("app") == "cof-dashboard"
    except Exception:  # noqa: BLE001
        return False


def main():
    if os.environ.get("COF_DASH_SERVE") == "1":
        return serve()
    url = f"http://{HOST}:{PORT}/"
    if not running_instance():
        with socket.socket() as s:
            if s.connect_ex((HOST, PORT)) == 0:
                sys.exit(f"claude_router: port {PORT} is taken by something else (set COF_DASH_PORT to use another)")
        log = open(COF_HOME / "dashboard.log", "a")
        subprocess.Popen([sys.executable, str(Path(__file__).resolve())], env={**{k: v for k, v in os.environ.items() if not k.startswith("COF_")}, "COF_DASH_SERVE": "1",
                              **({"COF_DASH_PORT": os.environ["COF_DASH_PORT"]} if "COF_DASH_PORT" in os.environ else {})},
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, cwd=str(HOME))
        for _ in range(50):
            if running_instance():
                break
            time.sleep(0.1)
        else:
            sys.exit(f"claude_router: server did not start; see {COF_HOME / 'dashboard.log'}")
        print(f"claude_router: dashboard running at {url} (exits {IDLE_EXIT_MIN} min after the last open tab closes)")
    else:
        print(f"claude_router: dashboard already running at {url}")
    webbrowser.open(url)


if __name__ == "__main__":
    main()
