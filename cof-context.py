#!/usr/bin/env python3
"""claude-router context: makes every Claude Code session aware of the multi-account router.

Installed as global Claude Code hooks in ~/.claude/settings.json (one script for every event; the event
comes from the hook JSON on stdin, so there are no arguments):

  SessionStart       a short block: the router exists, which account this session runs on and whether the
                     router manages it (can hop it to another account), usage + reset times for every
                     account, pool headroom, what a new launch would pick, warnings.
  UserPromptSubmit   silent, except one line when this session's account crosses a usage band (80/90/95%),
                     drops back under 80% (a reset), or the router paused the conversation. Cache-only.
  PreToolUse         (matcher Agent|Task|Workflow) a capacity note before a fan-out when this session's
                     account is getting full: headroom on the other accounts and how to put work there
                     (`claude-on <label> -p ...`). Silent otherwise. Cache-only.

Also imported by cof-mcp.py (the `claude-router` MCP server), which reuses snapshot()/status_report().

Usage-endpoint etiquette (see the repo CLAUDE.md): shares the router's cache files and 5-minute TTL, backs
off an account for 10 minutes after a 429 (persisted in cache/ctx/ so every session honours it), and the
prompt/tool hooks never wait on the network: a stale cache is refreshed by a detached background process.
Credentials are read (Keychain / .credentials.json) only to call the usage endpoint; never printed, never
rotated. Kill switch: CLAUDE_ROUTER_CONTEXT=0 in the environment silences every hook.
"""
import concurrent.futures as cf
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ---------------- config ----------------
BANDS = (80, 90, 95)             # UserPromptSubmit speaks up when this session's account crosses one of these
FANOUT_WARN_AT = 60              # Workflow / background Agent launch: capacity note at/above this % (tightest window)
AGENT_WARN_AT = 85               # plain foreground Agent launch: only this close to the limit
NOTE_COOLDOWN_MIN = 20           # same fan-out note at most this often per session
SESSIONSTART_FETCH_TIMEOUT = 4   # SessionStart waits at most this long (s) for fresh usage
STALE_NOTE_MIN = 30              # usage older than this is labelled "as of HH:MM"
STATE_KEEP_DAYS = 3              # per-session state files older than this are pruned
OTHER_TTL = 900                  # other accounts' usage is refreshed in the background at most this often (s)
RENEW_LOGINS = True              # a stale login (expired access token) gets renewed via the router's own 1-token ping
PING_RETRY_MIN = 30              # ...at most this often per account
FAIL_RETRY_MIN = 10              # a background refresh that couldn't read usage waits this long before the next try

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cof_dashboard", HERE / "cof-dashboard.py")
D = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(D)
CTX = D.CACHE / "ctx"
KIND_ORDER = ("session", "weekly_all", "weekly_scoped")


def now():
    return time.time()


def when(ts):
    if not ts:
        return "?"
    fmt = "%H:%M" if ts - now() < 20 * 3600 else "%a %H:%M"
    return time.strftime(fmt, time.localtime(ts))


def ago(ts):
    m = int((now() - ts) // 60)
    return f"{m} min ago" if m < 90 else f"{m // 60} h ago"


# ---------------- router config (cached: sourcing the loader on every prompt is wasteful) ----------------
def router_cfg():
    f = CTX / "config.json"
    m = D.mtime(f)
    if m and now() - m < 600 and D.mtime(D.LOADER) and D.mtime(D.LOADER) < m:
        try:
            return json.loads(f.read_text())
        except ValueError:
            pass
    cfg = D.router_config()
    if cfg:
        CTX.mkdir(parents=True, exist_ok=True)
        tmp = f.with_suffix(f".{os.getpid()}")
        tmp.write_text(json.dumps(cfg))
        os.replace(tmp, f)
    return cfg


def thresholds(cfg):
    g = lambda n, d: D.cfg_int(cfg, n, d)  # noqa: E731
    return {"session_at": g("CLAUDE_OVERFLOW_SESSION_AT", 85), "weekly_at": g("CLAUDE_OVERFLOW_WEEKLY_AT", 92),
            "scoped_at": g("CLAUDE_OVERFLOW_SCOPED_AT", 92), "full_at": g("CLAUDE_OVERFLOW_FULL_AT", 97),
            "hop_at": g("CLAUDE_OVERFLOW_INSESSION_AT", 95),
            "insession": cfg.get("CLAUDE_OVERFLOW_INSESSION", "1") != "0",
            "proactive": cfg.get("CLAUDE_OVERFLOW_INSESSION_PROACTIVE", "1") != "0"}


# ---------------- which account is this session on ----------------
def session_account(env=None):
    """(account rows, label, managed). The label comes from CLAUDE_CONFIG_DIR (what Claude Code actually
    uses); COF_ACCOUNT only counts as 'managed' when it agrees, so a `claude -p` child that inherited a
    managed parent's env isn't mistaken for the parent."""
    env = os.environ if env is None else env
    rows = D.accounts()
    label = "primary"
    d = env.get("CLAUDE_CONFIG_DIR")
    if d:
        rd = os.path.realpath(os.path.expanduser(d))
        if rd != os.path.realpath(D.HOME / ".claude"):
            label = next((r["label"] for r in rows[1:] if os.path.realpath(os.path.expanduser(r["dir"])) == rd), None) or "unregistered"
    managed = (env.get("COF_MANAGED") == "1" and env.get("COF_ACCOUNT") == label and bool(env.get("COF_CTRL_DIR"))
               and _is_managed_claude(env.get("COF_PIDFILE")))
    return rows, label, managed


def _is_managed_claude(pidfile):
    """True when the NEAREST claude process above us is the one the managed loop recorded (hooks and MCP
    servers are children of claude, maybe via a shell). A `claude -p` started from inside a managed session
    inherits COF_MANAGED/COF_ACCOUNT, but its hooks' nearest claude is the child, so it doesn't pass."""
    try:
        want = int(Path(pidfile).read_text().strip())
    except (TypeError, OSError, ValueError):
        return False
    pid = os.getppid()
    for _ in range(8):   # status line: claude -> sh -> node tap -> sh -> bash -> python
        if pid <= 1:
            return False
        try:
            ppid, comm = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True,
                                        text=True, timeout=3).stdout.strip().split(None, 1)
        except (OSError, ValueError, subprocess.SubprocessError):
            return False
        if os.path.basename(comm) == "claude":
            return pid == want
        pid = int(ppid)
    return False


# ---------------- usage (shared cache, persisted 429 backoff) ----------------
def _backoff_file(label):
    return CTX / f"backoff-{label}"


def backoff_until(label):
    try:
        return float(_backoff_file(label).read_text())
    except (OSError, ValueError):
        return 0.0


def renew_login(label):
    """Renew a stale login the only safe way: the router's `_cof_ping` (a 1-token `claude -p` on that account, so
    Claude Code refreshes the token itself under its cross-process lock; never call the OAuth endpoint directly).
    Synchronous (callers are already detached). At most once per PING_RETRY_MIN per account. True if it ran OK."""
    if not RENEW_LOGINS:
        return False
    CTX.mkdir(parents=True, exist_ok=True)
    pf = CTX / f"ping-{label}"
    m = D.mtime(pf)
    if m and now() - m < PING_RETRY_MIN * 60:
        return False
    pf.touch()
    env = {k: v for k, v in os.environ.items() if not k.startswith("COF_")}
    rc, _out, _err = D.run(["bash", "-c", '. "$1" >/dev/null 2>&1 && _cof_ping "$2"', "_", str(D.LOADER), label],
                           timeout=120, env=env)
    try:
        with open(CTX / "renew.log", "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {label}: {'renewed' if rc == 0 else f'ping failed (exit {rc})'}\n")
    except OSError:
        pass
    return rc == 0


def account_usage(acct, ttl, fetch, timeout=8, renew=False):
    """{label, email, primary, state, u, at, err, stale}. fetch=False: cache only (state 'cached').
    A stale login is renewed inline when renew=True (background refresher), else handed to one."""
    label = acct["label"]
    rec = {"label": label, "email": acct["email"], "primary": acct["primary"], "state": "cached", "err": None}
    u, at = D.cached_usage(label)
    if fetch and not (at and now() - at < ttl):
        _src, j, st, _mig = D.resolve_cred(acct)
        if st == "stale" and renew and renew_login(label):
            _src, j, st, _mig = D.resolve_cred(acct)
        elif st == "stale" and RENEW_LOGINS:
            refresh_bg(label)
        rec["state"] = st
        if st != "ok":
            rec["err"] = f"token {st}" + (" (renewing in the background)" if st == "stale" and RENEW_LOGINS and not renew else "")
        elif now() < backoff_until(label):
            rec["err"] = f"rate-limited by the usage endpoint, retrying after {when(backoff_until(label))}"
        else:
            tok = ((j or {}).get("claudeAiOauth") or {}).get("accessToken")
            nu, nat, err = D.fetch_usage(label, tok, ttl, False, "ctx", timeout)
            if nu is not None:
                u, at = nu, nat
            else:
                rec["err"] = err
                if err and err.startswith("HTTP 429"):
                    CTX.mkdir(parents=True, exist_ok=True)
                    _backoff_file(label).write_text(str(now() + D.BACKOFF_429))
    elif fetch:
        rec["state"] = "ok"   # a fresh cache means a fetch with a valid token just happened
    rec.update(u=u, at=at, stale=bool(at and now() - at > STALE_NOTE_MIN * 60))
    return rec


def refresh_bg(label):
    """Detached refresh of one account's usage cache (so prompt/tool hooks never wait on the network)."""
    CTX.mkdir(parents=True, exist_ok=True)
    lock = CTX / f"refresh-{label}.lock"
    m = D.mtime(lock)
    try:
        until = float(lock.read_text() or 0)   # set by a refresher that failed: don't retry before this
    except (OSError, ValueError):
        until = 0
    if (m and now() - m < 90) or now() < until:
        return
    lock.write_text("")
    try:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve())], cwd=str(D.HOME),
                         env={**os.environ, "COF_CTX_REFRESH": label}, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def windows(u):
    """{kind: {name, pct, resets}} for the router's three windows. A window whose reset time has passed
    since the fetch counts as 0% (it reset)."""
    out = {}
    for l in (u or {}).get("limits") or []:
        k = l.get("kind")
        if k not in KIND_ORDER:
            continue
        name = {"session": "5h", "weekly_all": "weekly"}.get(k) or \
            (((l.get("scope") or {}).get("model") or {}).get("display_name") or "model-scoped")
        resets = D.iso_to_epoch(l.get("resets_at"))
        pct = round(l.get("percent") or 0)
        if resets and resets < now():
            pct, resets = 0, None
        if k not in out or pct > out[k]["pct"]:
            out[k] = {"name": name, "pct": pct, "resets": resets}
    return out


def scoped_applies(model, name):
    """Does a model-scoped window (e.g. 'Fable') bind a session on `model`? Unknown model: assume yes."""
    return not model or name.lower() in model.lower()


def tightest(win, model):
    """(pct, window name) of the fullest window that applies to `model`."""
    best = (0, "5h")
    for k in KIND_ORDER:
        w = win.get(k)
        if not w or (k == "weekly_scoped" and not scoped_applies(model, w["name"])):
            continue
        if w["pct"] > best[0]:
            best = (w["pct"], w["name"])
    return best


def snapshot(fetch="all", env=None, model=None, timeout=8):
    """Everything the hooks and the MCP server say. fetch: 'all' (refresh stale caches now), 'none' (cache only)."""
    rows, label, managed = session_account(env)
    cfg = router_cfg()
    th = thresholds(cfg)
    ttl = max(D.USAGE_TTL, D.cfg_int(cfg, "CLAUDE_OVERFLOW_TTL", 60))
    with cf.ThreadPoolExecutor(max_workers=len(rows)) as ex:
        accts = list(ex.map(lambda a: account_usage(a, ttl, fetch == "all", timeout), rows))
    # credential states: learned on full snapshots, remembered for the cache-only hooks
    sf = CTX / "cred-states.json"
    try:
        known = json.loads(sf.read_text())
    except (OSError, ValueError):
        known = {}
    if fetch == "all":
        known.update({a["label"]: a["state"] for a in accts if a["state"] != "cached"})
        CTX.mkdir(parents=True, exist_ok=True)
        tmp = sf.with_suffix(f".{os.getpid()}")
        tmp.write_text(json.dumps(known))
        os.replace(tmp, sf)
    else:
        for a in accts:
            if known.get(a["label"]) == "dead" and not (a["at"] and a["at"] > (D.mtime(sf) or 0)):
                a["state"] = "dead"
    for a in accts:
        a["win"] = windows(a["u"])
        a["tight"] = tightest(a["win"], model)
    live = [a for a in accts if a["state"] != "dead" and a["u"]]
    pool = {}
    for k in KIND_ORDER:
        vals = [max(0, 100 - a["win"][k]["pct"]) / 100 for a in live if k in a["win"]]
        if vals:
            name = next(a["win"][k]["name"] for a in live if k in a["win"])
            pool[k] = {"name": name, "left": sum(vals), "of": len(accts)}
    pick_in = [{"label": a["label"], "state": "ok" if a["state"] == "cached" else a["state"],
                "pcts": [a["win"].get(k, {}).get("pct", 0) for k in KIND_ORDER] if a["u"] else None,
                "usage_stale": False} for a in accts]
    try:
        pick = D.simulate_pick(pick_in, cfg)
    except Exception as e:  # noqa: BLE001
        pick = {"pick": "?", "reason": repr(e), "steps": []}
    ctrl = (env or os.environ).get("COF_CTRL_DIR")
    try:   # the managed loop pre-creates an empty `paused` each leg; the hook writes a reason into it
        paused = bool(managed and ctrl and os.path.getsize(os.path.join(ctrl, "paused")) > 0)
    except OSError:
        paused = False
    e = env or os.environ
    api_key = next((k for k in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN") if e.get(k)), None)
    return {"label": label, "managed": managed, "paused": paused, "model": model, "accounts": accts, "api_key": api_key,
            "current": next((a for a in accts if a["label"] == label), None), "pool": pool, "pick": pick,
            "th": th, "t": now()}


# ---------------- text ----------------
def acct_line(a, resets=True):
    if a["state"] == "dead":
        return f"{a['label']}: signed out (needs browser sign-in)"
    if not a["u"]:
        return f"{a['label']}: usage unknown ({a['err'] or 'no data yet'})"
    parts = []
    for k in KIND_ORDER:
        w = a["win"].get(k)
        if w:
            parts.append(f"{w['name']} {w['pct']}%" + (f" (resets {when(w['resets'])})" if resets and w["resets"] else ""))
    s = f"{a['label']}: " + " | ".join(parts)
    if a["stale"]:
        s += f" [as of {when(a['at'])}]"
    return s


def best_other(snap):
    """The other live account with the most room (lowest tightest window), or None."""
    cands = [a for a in snap["accounts"] if a["label"] != snap["label"] and a["state"] != "dead" and a["u"]
             and a["tight"][0] < snap["th"]["full_at"]]
    return min(cands, key=lambda a: a["tight"][0]) if cands else None


def hop_sentence(snap):
    th = snap["th"]
    if snap["managed"] and th["insession"]:
        when_txt = f"at {th['hop_at']}% on any window or on a rate-limit error" if th["proactive"] else "on a rate-limit error"
        return (f"router-managed: {when_txt} the router ends this session at the next turn boundary and resumes the same "
                f"conversation on another account (background agents/workflows still running at that moment are lost).")
    return ("NOT router-managed (a headless `-p` run, the desktop app, Remote Control, or launched outside the `claude` "
            "wrapper): it stays on this account and simply stops at the limit.")


def warnings(snap):
    th, cur, out = snap["th"], snap["current"], []
    if snap["paused"]:
        out.append("the router PAUSED this conversation: no account has headroom (wait for a reset, or the user can sign in another account).")
    if cur and cur["u"]:
        pct, name = cur["tight"]
        if pct >= BANDS[0]:
            w = next((w for w in cur["win"].values() if w["name"] == name), {})
            out.append(f"this session's account ({snap['label']}) is at {name} {pct}%"
                       + (f", resets {when(w.get('resets'))}" if w.get("resets") else "")
                       + f"; the hop threshold is {th['hop_at']}%. Keep big fan-outs small or put them on another account.")
    elif cur:
        out.append(f"no usage reading for this session's account ({cur['err'] or 'no data yet'}).")
    live = [a for a in snap["accounts"] if a["state"] != "dead" and a["u"]]
    if live and all(a["tight"][0] >= 90 for a in live):
        resets = sorted((w["resets"], a["label"], w["name"]) for a in live for w in a["win"].values() if w["resets"])
        out.append("every account is at 90%+ somewhere; next resets: "
                   + ", ".join(f"{l} {n} {when(t)}" for t, l, n in resets[:3]) + ".")
    dead = [a["label"] for a in snap["accounts"] if a["state"] == "dead"]
    if dead:
        out.append(f"signed out: {', '.join(dead)} (the user can sign in from the dashboard or `claude-overflow login <label>`).")
    if snap.get("api_key"):
        out.append(f"{snap['api_key']} is set in this session's environment, so it may be billing the API instead of a "
                   "subscription (the router's own launches unset it); the limits above then don't constrain it.")
    if snap["label"] == "unregistered":
        out.append("this session's CLAUDE_CONFIG_DIR isn't a registered router account.")
    return out


def session_start_text(snap):
    accts = snap["accounts"]
    prim = accts[0]
    names = f"primary {prim['email'] or ''}".strip() + ", overflow " + ", ".join(a["label"] for a in accts[1:])
    scoped = next((a["win"]["weekly_scoped"]["name"] for a in accts if "weekly_scoped" in a["win"]), None)
    lines = [
        "<claude-router>",
        f"This Mac routes Claude Code across {len(accts)} Claude Max subscriptions (the \"claude-router\" / claude-max-overflow tool: "
        f"{names}). Each has its own 5-hour and weekly usage limits" + (f", plus a weekly {scoped}-only window" if scoped else "") + ".",
        f"This session runs on {snap['label']}, " + hop_sentence(snap),
        f"Usage (% used, as of {when(snap['t'])}):",
    ]
    lines += ["  " + acct_line(a) for a in accts]
    pool = snap["pool"]
    if pool:
        lines.append("Pool headroom (accounts' worth left): " + ", ".join(f"{p['name']} {p['left']:.1f} of {p['of']}" for p in pool.values())
                     + f". A new `claude` launch would pick: {snap['pick']['pick']}.")
    for w in warnings(snap):
        lines.append("Heads-up: " + w)
    lines.append("Before a large fan-out (Workflow, many agents), weigh it against this account's headroom; subagents always run on "
                 "this session's account. To put a self-contained chunk on another account: `claude-on <label> -p \"<prompt>\"` in Bash "
                 "(headless, that account's quota). Live detail: MCP tool router_status (claude-router server); dashboard: `claude_router`.")
    lines.append("</claude-router>")
    return "\n".join(lines)


def fanout_note(snap, what):
    cur, th = snap["current"], snap["th"]
    pct, name = cur["tight"]
    others = [a for a in snap["accounts"] if a["label"] != snap["label"]]
    txt = (f"claude-router capacity check before this {what}: this session runs on {snap['label']}, now at {name} {pct}% "
           f"({acct_line(cur)}). ")
    if snap["managed"] and th["insession"]:
        txt += (f"At {th['hop_at']}% the router moves this conversation to another account at the next turn end, which restarts "
                "the session: background agents/workflows still running then are lost. ")
    else:
        txt += "This session isn't router-managed, so it just stops at the limit. "
    txt += "Other accounts: " + "; ".join(acct_line(a, resets=False) for a in others) + ". "
    b = best_other(snap)
    if b:
        txt += (f"If this won't fit in {snap['label']}'s remaining ~{100 - pct}% of the {name} window: make it smaller or batch it "
                f"with results checkpointed to files, or run self-contained shards on {b['label']} (most room) with "
                f"`claude-on {b['label']} -p \"<prompt>\"`, or tell the user to continue in a new session there (`c-{b['label']}`).")
    else:
        txt += "No other account has room either: keep it small, or wait for the next reset."
    return txt


# ---------------- per-session state ----------------
def state_path(sid):
    return CTX / f"sess-{''.join(c for c in (sid or 'none') if c.isalnum() or c in '-_')[:80]}.json"


def load_state(sid):
    try:
        return json.loads(state_path(sid).read_text())
    except (OSError, ValueError):
        return {}


def save_state(sid, st):
    CTX.mkdir(parents=True, exist_ok=True)
    p = state_path(sid)
    tmp = p.with_suffix(f".{os.getpid()}")
    tmp.write_text(json.dumps(st))
    os.replace(tmp, p)


def prune_states():
    cutoff = now() - STATE_KEEP_DAYS * 86400
    for p in CTX.glob("sess-*.json"):
        if (D.mtime(p) or now()) < cutoff:
            try:
                p.unlink()
            except OSError:
                pass


def refresh_stale(snap):
    """Background-refresh whichever accounts' usage is old: this session's after USAGE_TTL, the others after
    OTHER_TTL. Known signed-out accounts are skipped (only a browser sign-in helps them)."""
    for a in snap["accounts"]:
        if a["state"] == "dead":
            continue
        ttl = D.USAGE_TTL if a["label"] == snap["label"] else OTHER_TTL
        if a["at"] is None or now() - a["at"] > ttl:
            refresh_bg(a["label"])


def band_of(pct):
    return max([b for b in BANDS if pct >= b], default=0)


# ---------------- hook entry points ----------------
def emit(event, text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}))


def on_session_start(inp):
    sid, model = inp.get("session_id"), inp.get("model")
    if isinstance(model, dict):
        model = model.get("id") or model.get("display_name")
    snap = snapshot("all", model=model, timeout=SESSIONSTART_FETCH_TIMEOUT)
    cur = snap["current"]
    st = {"label": snap["label"], "model": model, "notes": {},
          "band": band_of(cur["tight"][0]) if cur and cur["u"] else None, "paused": snap["paused"]}
    save_state(sid, st)
    prune_states()
    emit("SessionStart", session_start_text(snap))


def on_prompt(inp):
    sid = inp.get("session_id")
    st = load_state(sid)
    snap = snapshot("none", model=st.get("model"))
    cur = snap["current"]
    if not cur:
        return
    refresh_stale(snap)
    msgs = []
    if snap["paused"] and not st.get("paused"):
        msgs.append("claude-router: the router PAUSED this conversation because no account has headroom; it stays on "
                    f"{snap['label']} until a window resets or another account is signed in.")
    st["paused"] = snap["paused"]
    if cur["u"]:
        pct, name = cur["tight"]
        band, prev = band_of(pct), st.get("band")
        if prev is not None and st.get("label") == snap["label"]:
            if band > prev:
                b = best_other(snap)
                msgs.append(f"claude-router: this session's account ({snap['label']}) is now at {name} {pct}% "
                            f"({acct_line(cur)}). " + hop_sentence(snap)
                            + (f" Most room elsewhere: {acct_line(b)}." if b else " No other account has room."))
            elif band < prev and band < BANDS[0] <= prev:
                msgs.append(f"claude-router: {snap['label']} has room again ({acct_line(cur)}).")
        st["band"], st["label"] = band, snap["label"]
    save_state(sid, st)
    if msgs:
        emit("UserPromptSubmit", " ".join(msgs))


def on_pretool(inp):
    tool, ti = inp.get("tool_name") or "", inp.get("tool_input") or {}
    sid = inp.get("session_id")
    st = load_state(sid)
    model = st.get("model")
    if tool == "Workflow":
        what, thr = "workflow", FANOUT_WARN_AT
        if "fable" in json.dumps(ti).lower():
            model = "fable"
    elif tool in ("Agent", "Task"):
        bg = bool(ti.get("run_in_background"))
        what, thr = ("background agent" if bg else "agent"), (FANOUT_WARN_AT if bg else AGENT_WARN_AT)
        if "fable" in str(ti.get("model") or "").lower():
            model = "fable"
    else:
        return
    snap = snapshot("none", model=model)
    cur = snap["current"]
    if not cur or not cur["u"]:
        return
    refresh_stale(snap)
    pct = cur["tight"][0]
    if pct < thr:
        return
    key = f"{what}:{band_of(pct) or thr}"
    notes = st.setdefault("notes", {})
    if now() - notes.get(key, 0) < NOTE_COOLDOWN_MIN * 60:
        return
    notes[key] = now()
    save_state(sid, st)
    emit("PreToolUse", fanout_note(snap, what))


def main():
    label = os.environ.get("COF_CTX_REFRESH")
    if label:   # detached background refresh (see refresh_bg)
        rows = D.accounts()
        acct = next((r for r in rows if r["label"] == label), None)
        if acct:
            cfg = router_cfg()
            rec = account_usage(acct, max(D.USAGE_TTL, D.cfg_int(cfg, "CLAUDE_OVERFLOW_TTL", 60)), True, renew=True)
            if rec["err"]:
                (CTX / f"refresh-{label}.lock").write_text(str(now() + FAIL_RETRY_MIN * 60))
            if rec["state"] != "cached":   # remember the login state for the cache-only readers
                sf = CTX / "cred-states.json"
                try:
                    known = json.loads(sf.read_text())
                except (OSError, ValueError):
                    known = {}
                known[label] = rec["state"]
                tmp = sf.with_suffix(f".{os.getpid()}")
                tmp.write_text(json.dumps(known))
                os.replace(tmp, sf)
        return
    if os.environ.get("CLAUDE_ROUTER_CONTEXT", "1") == "0":
        return
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    ev = inp.get("hook_event_name")
    try:
        {"SessionStart": on_session_start, "UserPromptSubmit": on_prompt, "PreToolUse": on_pretool}.get(ev, lambda _i: None)(inp)
    except Exception as e:  # noqa: BLE001  never break a session over this
        try:
            CTX.mkdir(parents=True, exist_ok=True)
            with open(CTX / "errors.log", "a") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {ev}: {e!r}\n")
        except OSError:
            pass


if __name__ == "__main__":
    main()
