#!/usr/bin/env python3
"""claude-router MCP server (stdio, stdlib only): lets any Claude Code session look at the multi-account
router on demand. Registered by the claude-router plugin (plugin/.mcp.json), so every account's sessions have it.

Tools
  router_status          every account's 5h / weekly / model-scoped usage with reset times, which account this
                         session runs on and whether the router can hop it, pool headroom, burn rate + runway,
                         what a new launch would pick, warnings, and how to put work on another account.
  router_hops            the in-session hop log (account switches, pauses, sign-ins) + ping-pong bursts.
  router_open_dashboard  start/reuse the localhost dashboard (`claude_router`) and open it in the browser.

Session awareness: Claude Code starts this server with the session's environment, so CLAUDE_CONFIG_DIR /
COF_* tell it which account the calling session is on (same logic as the hooks in cof-context.py).
Usage fetches share the router's cache + 5-minute TTL and the persisted 429 backoff (see cof-context.py).
"""
import importlib.util
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cof_context", HERE / "cof-context.py")
C = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(C)
D = C.D

SERVER_VERSION = "1.0.0"
INSTRUCTIONS = (
    "claude-router: this Mac routes Claude Code across several Claude Max subscriptions (a primary account plus "
    "overflow accounts), each with its own 5-hour, weekly and model-scoped (e.g. Fable-only) usage limits. Each session "
    "gets a <claude-router> block at start (its account + usage), a note if its account gets full, and a capacity note "
    "before large fan-outs. Call router_status when the user asks about usage, limits, accounts or how much is left; "
    "before launching a big Workflow or many agents (subagents always consume the calling session's account); after a "
    "rate-limit error or an account hop; or when deciding whether to split work across accounts. To run a self-contained "
    "chunk on another account: Bash `claude-on <label> -p \"<prompt>\"` (headless, billed to that account; add "
    "--permission-mode/--allowedTools as the task needs and --output-format json for structured results), or ask the "
    "user to open a session there with `c-<label>` (`cswap` continues the latest conversation on another account). "
    "Never read, print or refresh OAuth tokens yourself, and never `bash -x` the router loader (it would trace "
    "credentials). The user's dashboard: router_open_dashboard or `claude_router` in a terminal."
)

TOOLS = [
    {"name": "router_status",
     "description": "Live usage of every Claude Max account in the router (5h, weekly, model-scoped windows, reset times), "
                    "which account this session runs on and whether it can be hopped, pool headroom, burn rate and "
                    "runway, the account a new launch would pick, warnings, and how to put work on another account. "
                    "Cheap: reuses a shared 5-minute cache.",
     "inputSchema": {"type": "object", "properties": {
         "fresh": {"type": "boolean", "description": "Re-read usage that is more than a minute old (default: reuse up to 5 minutes)."}},
         "additionalProperties": False}},
    {"name": "router_hops",
     "description": "Recent in-session account switches, pauses and sign-ins from the router's log, with ping-pong detection.",
     "inputSchema": {"type": "object", "properties": {
         "hours": {"type": "number", "description": "How far back to look (default 48)."}}, "additionalProperties": False}},
    {"name": "router_open_dashboard",
     "description": "Start (or reuse) the router's localhost dashboard and open it in the user's browser.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
]


def fmt_time(ts):
    return C.when(ts) if ts else "?"


def status_report(fresh=False):
    snap = C.snapshot("all", model=None, timeout=8) if not fresh else _fresh_snapshot()
    th, lines = snap["th"], []
    lines.append(f"claude-router status at {time.strftime('%a %H:%M')}. This session: {snap['label']}, "
                 + C.hop_sentence(snap))
    lines.append("")
    lines.append("Accounts (% of each window used, reset time):")
    for a in snap["accounts"]:
        head = f"- {a['label']}" + (f" <{a['email']}>" if a["email"] else "") + (" [this session]" if a["label"] == snap["label"] else "")
        lines.append(head)
        lines.append("    " + C.acct_line(a).split(": ", 1)[-1])
        meta = []
        if a["at"]:
            meta.append(f"read {C.ago(a['at'])}")
        if a["state"] not in ("ok", "cached"):
            meta.append(f"login {a['state']}")
        if a["err"] and a["state"] != "dead":
            meta.append(f"last check: {a['err']}")
        ex = (a["u"] or {}).get("extra_usage") or {}
        if ex.get("is_enabled"):
            meta.append(f"extra usage ON ({ex.get('utilization') or 0:.0f}% of monthly credit used): past the limits it bills")
        if meta:
            lines.append("    (" + "; ".join(meta) + ")")
    if snap["pool"]:
        lines.append("")
        lines.append("Pool headroom (accounts' worth left): "
                     + ", ".join(f"{p['name']} {p['left']:.1f} of {p['of']}" for p in snap["pool"].values()))
    pick = snap["pick"]
    lines.append(f"A new `claude` launch would pick: {pick['pick']} ({pick['reason']})")
    try:
        burn = D.burn_rates(D.history())
        pool = burn["pool"]
        if pool.get("per_day"):
            left = sum(max(0, 100 - a["win"]["weekly_all"]["pct"]) for a in snap["accounts"]
                       if a["state"] != "dead" and "weekly_all" in a["win"])
            per = ", ".join(f"{k} {v['used']:.0f}" for k, v in sorted(burn["accounts"].items(), key=lambda kv: -kv[1]["used"]) if v["used"])
            runway = left / pool["per_day"] if pool["per_day"] else None
            resets = [a["win"]["weekly_all"]["resets"] for a in snap["accounts"]
                      if a["state"] != "dead" and a["win"].get("weekly_all", {}).get("resets")]
            last_reset_d = (max(resets) - time.time()) / 86400 if resets else None
            if runway is None:
                pace = "."
            elif last_reset_d is not None and runway > last_reset_d:
                pace = f". At that pace the {left} points left outlast every account's weekly reset (the last is in {last_reset_d:.1f} days)."
            else:
                pace = f". At that pace the {left} points left last ~{runway:.1f} days."
            lines.append(f"Burn (last {pool['window_h']}h): {pool['used']:.0f} weekly %-points across the pool over {pool['span_h']:.0f}h"
                         f" (~{pool['per_day']:.0f}/day{'; ' + per if per else ''})" + pace)
    except Exception as e:  # noqa: BLE001
        lines.append(f"(burn rate unavailable: {e!r})")
    warns = C.warnings(snap)
    if warns:
        lines.append("")
        lines += ["Heads-up: " + w for w in warns]
    lines.append("")
    lines.append(f"Router thresholds: a launch skips primary at 5h >= {th['session_at']}%, weekly >= {th['weekly_at']}%, "
                 f"model-scoped >= {th['scoped_at']}%; an overflow account counts as full at {th['full_at']}%; a managed "
                 f"session hops at {th['hop_at']}%" + ("" if th["insession"] else " (in-session hopping is OFF)") + ".")
    b = C.best_other(snap)
    lines.append("Splitting work: subagents and workflows always run on this session's account. For a self-contained chunk "
                 f"on another account run `claude-on <label> -p \"<prompt>\"` in Bash"
                 + (f" (most room now: {b['label']})" if b else "")
                 + "; for interactive work ask the user to start a session there (`c-<label>`, or `cswap` to continue the "
                 "latest conversation on another account).")
    return "\n".join(lines)


def _fresh_snapshot():
    orig = D.USAGE_TTL
    D.USAGE_TTL = 60
    try:
        return C.snapshot("all", model=None, timeout=8)
    finally:
        D.USAGE_TTL = orig


def hops_report(hours=48):
    events, bursts = D.parse_insession()
    cutoff = time.time() - hours * 3600
    ev = [e for e in events if e["t"] >= cutoff]
    lines = [f"Router hop log, last {hours:g}h: {len(ev)} event(s)."]
    for e in ev[-60:]:
        t = time.strftime("%a %H:%M", time.localtime(e["t"]))
        if e["kind"] == "switch":
            lines.append(f"- {t} {e['from']} -> {e['to']} ({e['trigger']}{', ' + e['error'] if e['error'] else ''}): {e['reason']}")
        else:
            lines.append(f"- {t} {e['from']} {e['kind']}: {e['reason']}")
    recent = [b for b in bursts if b["end"] >= cutoff]
    if recent:
        lines.append("Ping-pong bursts (>= 4 hops back and forth within 15 min):")
        for b in recent:
            lines.append(f"- {time.strftime('%a %H:%M', time.localtime(b['start']))}: {b['count']} hops between "
                         f"{' and '.join(b['accounts'])} ({'before' if b['end'] < D.PINGPONG_FIX else 'AFTER'} the 2026-09-26 scoped-window fix)")
    return "\n".join(lines)


def open_dashboard():
    p = subprocess.run([sys.executable, str(HERE / "cof-dashboard.py")], capture_output=True, text=True, timeout=30,
                       stdin=subprocess.DEVNULL)
    return (p.stdout + p.stderr).strip() or f"exit {p.returncode}"


def call(name, args):
    if name == "router_status":
        return status_report(bool(args.get("fresh")))
    if name == "router_hops":
        return hops_report(float(args.get("hours") or 48))
    if name == "router_open_dashboard":
        return open_dashboard()
    raise KeyError(name)


def reply(mid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": mid}
    msg["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            reply(None, error={"code": -32700, "message": "parse error"})
            continue
        mid, method, params = req.get("id"), req.get("method"), req.get("params") or {}
        if mid is None:          # notification (initialized, cancelled, ...)
            continue
        if method == "initialize":
            reply(mid, {"protocolVersion": params.get("protocolVersion") or "2025-06-18",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "claude-router", "version": SERVER_VERSION},
                        "instructions": INSTRUCTIONS})
        elif method == "ping":
            reply(mid, {})
        elif method == "tools/list":
            reply(mid, {"tools": TOOLS})
        elif method == "tools/call":
            try:
                text, is_err = call(params.get("name"), params.get("arguments") or {}), False
            except KeyError:
                reply(mid, error={"code": -32602, "message": f"unknown tool {params.get('name')}"})
                continue
            except Exception as e:  # noqa: BLE001
                text, is_err = f"claude-router error: {e!r}", True
            reply(mid, {"content": [{"type": "text", "text": text}], "isError": is_err})
        elif method in ("resources/list", "prompts/list"):
            reply(mid, {method.split("/")[0]: []})
        else:
            reply(mid, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
