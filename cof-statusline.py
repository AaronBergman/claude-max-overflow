#!/usr/bin/env python3
"""claude-router status-line segment.

Reads Claude Code's status-line JSON on stdin and prints one segment for the router, colored like the rest
of a typical status line (dim labels, yellow >= 50%, red >= 80%), e.g.

    acct:primary fable:2% pool:31%            router-managed session on primary
    acct:work(fixed) pool:31%                 not router-managed (desktop app, -p, Remote Control...)
    acct:work fable:91% pool:74% next:alt     this account is getting full: a hop would go to alt

  acct    the account this session runs on; "(fixed)" = the router can't move it to another account
  <model> the model-scoped weekly window (e.g. Fable), shown when this session uses that model or it's >= 50%
  pool    weekly usage across every account (signed-out accounts count as used up)
  next    shown when this account's tightest window is >= 80%: the account with the most room
  PAUSED  the router paused this conversation (no account has headroom)

5h/7d for this account are already in the status line from Claude Code's own `rate_limits`, so they aren't
repeated. Cache-only (the router's usage cache files); a stale cache triggers the same detached, rate-limited
background refresh as the prompt hook, so rendering never waits on the network. Prints nothing if the
router isn't set up. CLAUDE_ROUTER_CONTEXT=0 silences it.
"""
import importlib.util
import json
import os
import sys
from pathlib import Path

SHOW_SCOPED_AT = 50   # show the model-scoped window on other models too once it's this full
NEXT_AT = 80          # show where a hop would go once this account's tightest window reaches this

DIM, RESET, YELLOW, RED = "\033[2m", "\033[0m", "\033[0;33m", "\033[0;31m"


def color(p):
    return RED if p >= 80 else YELLOW if p >= 50 else DIM


def main():
    if os.environ.get("CLAUDE_ROUTER_CONTEXT", "1") == "0":
        return
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        inp = {}
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("cof_context", here / "cof-context.py")
    C = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(C)
    if not C.D.ACCOUNTS.exists():
        return
    model = (inp.get("model") or {}).get("id") or ""
    snap = C.snapshot("none", model=model or None)
    cur = snap["current"]
    if not cur:
        return
    C.refresh_stale(snap)
    parts = [f"{DIM}acct:{RESET}{snap['label']}" + ("" if snap["managed"] else f"{DIM}(fixed){RESET}")]
    if snap["paused"]:
        parts.append(f"{RED}PAUSED{RESET}")
    sc = cur["win"].get("weekly_scoped")
    if sc and ((model and C.scoped_applies(model, sc["name"])) or sc["pct"] >= SHOW_SCOPED_AT):
        parts.append(f"{color(sc['pct'])}{sc['name'].lower()}:{sc['pct']}%{RESET}")
    pool = snap["pool"].get("weekly_all")
    if pool and pool["of"] > 1:
        used = round(100 * (1 - pool["left"] / pool["of"]))
        parts.append(f"{color(used)}pool:{used}%{RESET}")
    if cur["u"] and cur["tight"][0] >= NEXT_AT:
        b = C.best_other(snap)
        parts.append(f"{DIM}next:{RESET}{b['label']}" if b else f"{RED}no-room-elsewhere{RESET}")
    sys.stdout.write(" ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001  a status line must never error
        pass
