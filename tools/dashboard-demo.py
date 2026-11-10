#!/usr/bin/env python3
"""Run the dashboard on made-up data, without touching any real account.

    python3 tools/dashboard-demo.py

Builds a throwaway sandbox (its own $HOME with three invented accounts, a week of usage history, hops,
keep-alive runs and transcripts), points the real dashboard server at it and opens the page. Use it to see what
the dashboard looks like before installing, to work on the page, or to take screenshots that show nothing private.

Everything the dashboard would read from the machine is replaced: credentials come from sandbox files (the
Keychain is never queried), usage comes from the sandbox cache (the usage endpoint is never called), the process
list, launchd status, hostname and Claude Code version are canned, and the page's actions (add, remove, sign in,
refresh) are answered with a read-only notice.

Environment switches (none needed for normal use):
    COF_DEMO_OPEN=0     don't open a browser tab
    COF_DEMO_CHECK=1    build the sandbox, assemble the page's state once, check it, print a summary and exit
                        (the smoke test CI runs; it exercises the same code as a real dashboard request)
"""
import concurrent.futures as cf
import importlib.util
import json
import math
import os
import shutil
import sys
import tempfile
import threading
import time
import types
import webbrowser
from pathlib import Path

PORT = 8799
OPEN_BROWSER = os.environ.get("COF_DEMO_OPEN", "1") != "0"
CHECK_ONLY = os.environ.get("COF_DEMO_CHECK") == "1"

# label, email, 5h %, weekly %, model-scoped %, hours until the weekly reset,
# and the stretch of the current week (0..1 of the time elapsed so far) in which the account was in use
ACCOUNTS = [
    ("primary", "you@example.com",        22, 94, 61, 31, (0.00, 0.62)),
    ("work",    "you@work.example",       38, 41, 18, 74, (0.55, 1.00)),
    ("school",  "you@school.example",      0, 12,  3, 120, (0.30, 0.90)),
]
PREVIOUS_WEEK = {"primary": 97, "work": 58, "school": 9}   # where each account ended the week before
SCOPED_MODEL = "Fable"                                      # display name of the model-scoped weekly window
MODELS = [("claude-fable-5-2", 520_000), ("claude-opus-5-5", 210_000), ("claude-haiku-5-5", 38_000)]  # output tokens/day
HOPS = [  # days ago, HH:MM, from, event, error, to  (the target's usage in the log line comes from the curves below)
    (6, "10:42", "primary", "Stop", "-", "work"),
    (5, "15:07", "primary", "StopFailure", "rate_limit", "work"),
    (4, "11:31", "work", "Stop", "-", "school"),
    (4, "16:55", "school", "Stop", "-", "work"),
    (3, "09:48", "primary", "Stop", "-", "work"),
    (2, "14:20", "primary", "Stop", "-", "work"),
    (2, "20:03", "work", "StopFailure", "rate_limit", "school"),
    (1, "13:16", "primary", "Stop", "-", "work"),
    (0, "09:05", "primary", "Stop", "-", "work"),
]
MIRRORS = [(3, "work", "Refactor billing webhooks"), (2, "school", "Flaky integration test hunt"), (0, "work", "Migrate cron jobs to the queue")]

WEEK, DAY, HOUR = 7 * 86400, 86400, 3600
REPO = Path(__file__).resolve().parent.parent
NOW = time.time()


# ---------------- made-up usage curves (deterministic, no randomness) ----------------
def clock(t):
    """Hours of 'working day' (09:00 to 23:00 local) elapsed up to t, so curves are flat overnight."""
    local = t - time.timezone
    return (local // DAY) * 14 + min(max((local % DAY) / HOUR - 9, 0), 14)


def usage_at(label, t):
    _, _, s_now, w_now, sc_now, reset_h, (a, b) = next(r for r in ACCOUNTS if r[0] == label)
    reset = NOW + reset_h * HOUR
    start = reset - WEEK
    if t >= start:      # this week: climbs to today's value while the account was in use
        x = (clock(t) - clock(start)) / max(clock(NOW) - clock(start), 1)
        prog = min(max((x - a) / (b - a), 0), 1)
        w, in_use = w_now * prog, a < x < b
    else:               # the week before: a plain climb to where it ended
        x = (clock(t) - clock(start - WEEK)) / max(clock(start) - clock(start - WEEK), 1)
        w, in_use = PREVIOUS_WEEK[label] * min(max(x, 0), 1), True
    daytime = 9 <= ((t - time.timezone) % DAY) / HOUR < 23
    phase = ((t - NOW) % (5 * HOUR)) / (5 * HOUR)            # 5-hour windows, anchored so one ends 2 h from now
    s = (25 + 50 * abs(math.sin(t / 40000))) * phase if in_use and daytime else 0
    return round(s), round(w), round(w * sc_now / max(w_now, 1)), reset


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000000+00:00"


def stamp(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))


def days_ago(n, hhmm):
    d = time.localtime(NOW - n * DAY)
    h, m = map(int, hhmm.split(":"))
    t = time.mktime((d.tm_year, d.tm_mon, d.tm_mday, h, m, 0, 0, 0, -1))
    return min(t, NOW - 600)


def usage_payload(label):
    _, _, s, w, sc, reset_h, _ = next(r for r in ACCOUNTS if r[0] == label)
    wr, sr = NOW + reset_h * HOUR, NOW + 2 * HOUR
    sev = lambda p: "critical" if p >= 90 else "warning" if p >= 75 else "normal"  # noqa: E731
    return {
        "five_hour": {"utilization": float(s), "resets_at": iso(sr)},
        "seven_day": {"utilization": float(w), "resets_at": iso(wr)},
        "extra_usage": {"is_enabled": False, "monthly_limit": None, "used_credits": None, "utilization": None,
                        "currency": None, "disabled_reason": None, "spend_limit_reached": False},
        "limits": [
            {"kind": "session", "group": "session", "percent": s, "severity": sev(s), "resets_at": iso(sr), "scope": None, "is_active": s > 0},
            {"kind": "weekly_all", "group": "weekly", "percent": w, "severity": sev(w), "resets_at": iso(wr), "scope": None, "is_active": True},
            {"kind": "weekly_scoped", "group": "weekly", "percent": sc, "severity": sev(sc), "resets_at": iso(wr),
             "scope": {"model": {"id": None, "display_name": SCOPED_MODEL}, "surface": None}, "is_active": sc > 0},
        ],
        "seven_day_breakdown": {"rows": [{"key": "claude_code", "display_name": "Claude Code", "percent": 86},
                                         {"key": "chat", "display_name": "Chats", "percent": 11},
                                         {"key": "cowork", "display_name": "Cowork", "percent": 0},
                                         {"key": "other", "display_name": "Other", "percent": 3}]},
    }


# ---------------- the sandbox ----------------
def build_sandbox():
    box = Path(tempfile.gettempdir()).resolve() / "claude-max-overflow-demo"
    shutil.rmtree(box, ignore_errors=True)
    home = box / "home"
    cof = home / ".claude-overflow"
    (cof / "cache").mkdir(parents=True)
    (home / ".claude" / "projects").mkdir(parents=True)
    (box / "keychain").mkdir()

    for f in ("claude-overflow.sh", "cof-insession-hook.sh"):
        shutil.copy(REPO / f, cof / f)

    cred = {"claudeAiOauth": {"accessToken": "demo-not-a-token", "refreshToken": "demo-not-a-token",
                              "expiresAt": int((NOW + 6 * HOUR) * 1000), "refreshTokenExpiresAt": int((NOW + 24 * DAY) * 1000),
                              "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}
    rows = []
    for label, email, *_ in ACCOUNTS:
        if label == "primary":
            (home / ".claude.json").write_text(json.dumps({"oauthAccount": {"emailAddress": email}}))
            (home / ".claude" / ".credentials.json").write_text(json.dumps(cred))              # where Linux keeps it
            (box / "keychain" / "Claude Code-credentials.json").write_text(json.dumps(cred))   # stands in for the Keychain
        else:
            d = cof / "profiles" / label
            d.mkdir(parents=True)
            (d / ".claude.json").write_text(json.dumps({"oauthAccount": {"emailAddress": email}}))
            (d / ".credentials.json").write_text(json.dumps(cred))
            rows.append(f"{label}\t{d}\t{d / '.credentials.json'}\t{email}")
        (cof / "cache" / f"usage-{label}.json").write_text(json.dumps(usage_payload(label)))
    (cof / "accounts.tsv").write_text("\n".join(rows) + "\n")
    (cof / "cache" / "last").write_text("work\n")

    with open(cof / "usage-history.jsonl", "w") as f:        # a sample every 20 minutes for 8 days
        t = NOW - 8 * DAY
        while t < NOW:
            for label, *_ in ACCOUNTS:
                s, w, sc, wr = usage_at(label, t)
                wr = wr if t >= wr - WEEK else wr - WEEK
                f.write(json.dumps({"t": int(t), "k": label, "s": s, "w": w, "sc": sc, "sr": None, "wr": int(wr),
                                    "x": None, "src": "router"}, separators=(",", ":")) + "\n")
            t += 1200
        for label, _, s, w, sc, reset_h, _ in ACCOUNTS:      # ...ending on exactly what the page shows now
            f.write(json.dumps({"t": int(NOW), "k": label, "s": s, "w": w, "sc": sc, "sr": int(NOW + 2 * HOUR),
                                "wr": int(NOW + reset_h * HOUR), "x": None, "src": "router"}, separators=(",", ":")) + "\n")

    with open(cof / "insession.log", "w") as f:
        for n, hhmm, src, event, err, dst in HOPS:
            t = days_ago(n, hhmm)
            s, w, _, _ = usage_at(dst, t)
            f.write(f"{stamp(t)} {src} {event} {err}: switch -> {dst} (overflow: session {s}% weekly {w}%)\n")

    with open(cof / "keepalive.log", "w") as f:
        for k in range(6, 0, -1):
            for label, *_ in ACCOUNTS[1:]:
                f.write(f"{stamp(NOW - k * 12 * HOUR + 1800)} {label}: ok\n")

    (cof / "login.log").write_text(f"{stamp(NOW - 9 * DAY)} school: signed in as you@school.example\n")
    with open(cof / "mirrors.tsv", "w") as f:
        for i, (n, label, title) in enumerate(MIRRORS):
            f.write(f"00000000-0000-4000-8000-{i:012d}\tcse_demo{i:02d}\t{label}\t"
                    f"{time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(days_ago(n, '18:30')))}\t{title} · via {label}\n")

    proj = home / ".claude" / "projects" / "-home-you-code-api"   # transcripts, for the tokens-per-day chart
    proj.mkdir()
    for d in range(14):
        day = NOW - d * DAY
        busy = 0.55 + 0.45 * abs(math.sin(d * 1.3))             # some days busier than others
        for k in range(2 + d % 3):
            lines = []
            for j, (model, out) in enumerate(MODELS):
                n = int(out * busy / (2 + d % 3))
                lines.append(json.dumps({"type": "assistant", "requestId": f"req_demo_{d}_{k}_{j}", "timestamp": iso(min(day, NOW - 60)).replace("+00:00", "Z"),
                                         "message": {"id": f"msg_demo_{d}_{k}_{j}", "model": model,
                                                     "usage": {"input_tokens": n // 9, "cache_creation_input_tokens": n * 3,
                                                               "cache_read_input_tokens": n * 40, "output_tokens": n}}}))
            (proj / f"00000000-0000-4000-9000-{d:06d}{k:06d}.jsonl").write_text("\n".join(lines) + "\n")
    return box, home, cof


def load_dashboard(box, home, cof):
    for k in list(os.environ):                                # nothing from the real router leaks into the demo
        if k.startswith(("CLAUDE_OVERFLOW_", "COF_")) or k in ("CLAUDE_CONFIG_DIR", "CLAUDE_ACCOUNT"):
            del os.environ[k]
    os.environ.update(HOME=str(home), CLAUDE_OVERFLOW_HOME=str(cof), COF_DASH_PORT=str(PORT))
    spec = importlib.util.spec_from_file_location("cof_dashboard", REPO / "cof-dashboard.py")
    D = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(D)
    assert D.HOME == home and D.COF_HOME == cof, "the dashboard is not looking at the sandbox"

    real_creds = D.creds_json

    def creds_json(src):                                      # file sources are sandbox files; "Keychain" ones are canned
        if not src:
            return None
        if src.startswith("/"):
            return real_creds(src) if src.startswith(str(box)) else None
        try:
            return json.loads((box / "keychain" / f"{src}.json").read_text())
        except (OSError, ValueError):
            return None

    def fetch_usage(key, token, ttl, force, src="dash", timeout=8):   # the cache is the only source: no network
        u, m = D.cached_usage(key)
        return u, m, None if u else "no demo data"

    def sessions(_rows):
        base = {"ppid": 1, "ctrl": None, "entry": "cli", "tmux": False, "paused": None}
        procs = [
            {**base, "pid": 48211, "account": "work", "managed": True, "kind": "interactive", "cwd": "~/code/api",
             "started": NOW - 50 * 60, "args": "--settings <router hook>"},
            {**base, "pid": 47102, "account": "work", "managed": True, "kind": "interactive", "cwd": "~/code/web",
             "started": NOW - 3 * HOUR, "args": "--resume 00000000-0000-4000-9000-000001000000 --settings <router hook>"},
            {**base, "pid": 46377, "account": "primary", "managed": False, "kind": "remote", "cwd": "~/notes",
             "started": NOW - 5 * HOUR, "args": "--sdk-url <claude.ai session>"},
            {**base, "pid": 48530, "account": "school", "managed": False, "kind": "print", "cwd": "~/code/api",
             "started": NOW - 40, "args": '-p "summarize the changelog since the last release"'},
        ]
        return procs, 0

    # the transcript scan uses a process pool, which can't pickle a module loaded by file path: use threads here
    D.cf = types.SimpleNamespace(ProcessPoolExecutor=cf.ThreadPoolExecutor, ThreadPoolExecutor=cf.ThreadPoolExecutor)
    D.creds_json = creds_json
    D.fetch_usage = fetch_usage
    D.sessions = sessions
    D.ping = lambda label: None
    D.launchd_status = lambda: {"installed": True, "state": "not running", "runs": "14", "last_exit": "0", "interval_s": 43200}
    D.claude_version = lambda: "2.1.0 (Claude Code)"
    D.socket.gethostname = lambda: "demo-machine"

    real_state = D.state

    def state(force=False):                                   # show the sandbox's home as a plain /home/you
        return json.loads(json.dumps(real_state(force), default=str).replace(str(home), "/home/you"))
    D.state = state

    real_post = D.Handler.do_POST

    def do_post(self):
        if self.path in ("/api/quit", "/api/rescan-tokens"):
            return real_post(self)
        self._send(200, json.dumps({"ok": False, "error": "demo data: this page is read-only"}))
    D.Handler.do_POST = do_post
    return D


def check(D):
    D.token_scan()
    for _ in range(100):
        if D._scan["done_at"] or D._scan["error"]:
            break
        time.sleep(0.1)
    st = D.state()
    problems = []
    want = {r[0]: [r[2], r[3], r[4]] for r in ACCOUNTS}
    got = {a["label"]: a["pcts"] for a in st["accounts"]}
    if got != want:
        problems.append(f"account usage {got} != {want}")
    if any(a["state"] != "ok" for a in st["accounts"]):
        problems.append("an account is not signed in: " + ", ".join(f"{a['label']}={a['state']}" for a in st["accounts"]))
    if st["pick"]["pick"] != "work":
        problems.append(f"pick {st['pick']} (expected work: primary is past its weekly threshold)")
    if len(st["hops"]) != len(HOPS):
        problems.append(f"{len(st['hops'])} hops parsed, expected {len(HOPS)}")
    if not st["config"].get("CLAUDE_OVERFLOW_WEEKLY_AT"):
        problems.append("no router config (sourcing the loader in bash failed)")
    if not (st["tokens"]["data"] or {}).get("days"):
        problems.append(f"no token stats ({st['tokens']['error']})")
    if any(c["level"] in ("critical", "serious") for c in st["health"]):
        problems.append("health: " + "; ".join(c["title"] for c in st["health"] if c["level"] in ("critical", "serious")))
    print(f"accounts {got}; pick {st['pick']['pick']} ({st['pick']['reason']}); {len(st['history'])} history samples; "
          f"{len(st['hops'])} hops; {len(st['health'])} health checks")
    for p in problems:
        print("FAIL " + p)
    print("demo state: " + ("FAILED" if problems else "ok"))
    return 1 if problems else 0


def main():
    box, home, cof = build_sandbox()
    D = load_dashboard(box, home, cof)
    if CHECK_ONLY:
        rc = check(D)
        shutil.rmtree(box, ignore_errors=True)
        sys.exit(rc)
    url = f"http://127.0.0.1:{PORT}/"
    print(f"demo dashboard (made-up data) at {url}   Ctrl-C to stop; sandbox: {box}")
    if OPEN_BROWSER:
        threading.Timer(0.6, webbrowser.open, [url]).start()
    try:
        D.serve()
    except KeyboardInterrupt:
        pass
    finally:
        shutil.rmtree(box, ignore_errors=True)


if __name__ == "__main__":
    main()
