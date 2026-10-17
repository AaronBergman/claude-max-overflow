#!/bin/bash
# claude-max-overflow: in-session account switch hook (Stop + StopFailure).
#
# This runs at every turn boundary of a session that the router launched through
# its managed loop (cacct/_cof_run_managed sets COF_MANAGED=1 and the COF_* env
# below). It is INERT for any other session: the first check exits 0 immediately
# when COF_MANAGED != 1, so installing/injecting it never affects normal sessions.
#
# What it does when the current account runs out mid-conversation:
#   * StopFailure with error rate_limit|overloaded|account_on_hold  -> the account
#     hit the wall this turn; switch now.
#   * Stop (clean turn end) and the current account is at/over the in-session
#     threshold (CLAUDE_OVERFLOW_INSESSION_AT, default 95%) -> the turn just
#     finished on the last of the buffer; switch before the next turn.
# It resolves another account that has headroom (reusing the router's own
# _cof_pick), writes the target + session id into $COF_CTRL_DIR/switch, and ends
# the session with SIGTERM after a short flush delay. The managed loop in
# claude-overflow.sh sees the switch file and re-launches `--resume <session-id>`
# under the new account, so the SAME conversation continues there. If nothing has
# headroom it writes $COF_CTRL_DIR/paused and leaves the session alone (the
# conversation is intact; the user waits for a reset or runs cswap). If what is
# left is a signed-out account, it opens that account's browser sign-in right away
# (detached; the user only completes the login) and, when the pause was a hard
# rate limit, the sign-in worker moves the conversation there as soon as it lands.
#
# Env provided by the managed loop:
#   COF_MANAGED=1  COF_CTRL_DIR=<dir>  COF_ACCOUNT=<label|primary>
#   COF_PIDFILE=<file with the claude pid>  COF_LOADER=<claude-overflow.sh>
#   CLAUDE_OVERFLOW_HOME=<dir>
# Argument $1 is the event name ("Stop" or "StopFailure"); the hook JSON is on stdin.

ev="${1:-Stop}"

# --- inert unless this is a router-managed session ---
[ "${COF_MANAGED:-}" = "1" ] || exit 0
[ -n "${COF_CTRL_DIR:-}" ] || exit 0
# already decided to switch this leg? do nothing.
[ -s "$COF_CTRL_DIR/switch" ] && exit 0

in=$(cat 2>/dev/null)
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)
err=$(printf '%s' "$in" | jq -r '.error // empty' 2>/dev/null)
[ -n "$ev" ] || ev=$(printf '%s' "$in" | jq -r '.hook_event_name // "Stop"' 2>/dev/null)

# --- load the router helpers (defines _cof_pick, _cof_fetch, thresholds, etc.) ---
. "${COF_LOADER:-$HOME/.claude-overflow/claude-overflow.sh}" 2>/dev/null || exit 0
command -v _cof_pick >/dev/null 2>&1 || exit 0

cur="${COF_ACCOUNT:-primary}"

# Every decision is (a) appended to $CLAUDE_OVERFLOW_HOME/insession.log and (b) shown in the
# terminal via the hook's systemMessage, so a pause/hop is never invisible.
_ilog() { printf '%s %s %s %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$cur" "$ev" "${err:--}" "$*" >> "${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}/insession.log" 2>/dev/null; }
_say() { _ilog "$*"; jq -cn --arg m "claude-overflow: $*" '{systemMessage: $m}' 2>/dev/null; }

# --- decide whether to switch ---
want=0
need_sc=""   # "scoped": the target must also have room in the model-scoped weekly window (e.g. Fable-only)
if [ "$ev" = "StopFailure" ]; then
  case "$err" in
    rate_limit|overloaded|account_on_hold) want=1 ;;
    *) exit 0 ;;   # auth/billing/invalid/etc: another account can't fix it
  esac
  # A rate limit while this account's 5h and weekly windows still have room means the wall was a
  # model-scoped window: the next account must have room there too, or the session bounces straight back.
  if [ "$err" = "rate_limit" ]; then
    if [ "$cur" = "primary" ]; then cred=$(_cof_primary_cred); else cred=$(_cof_cred_of "$cur" 2>/dev/null); fi
    if [ -n "$cred" ] && json=$(_cof_fetch "$cred" "$cur" fresh 2>/dev/null); then
      read -r s w sc <<EOF2
$(printf '%s' "$json" | _cof_pcts)
EOF2
      : "${s:=0}" "${w:=0}" "${sc:=0}"
      full="${CLAUDE_OVERFLOW_FULL_AT:-97}"
      if [ "$s" -lt "$full" ] && [ "$w" -lt "$full" ]; then need_sc=scoped; fi
    fi
  fi
else
  # Stop: proactive. Only when enabled and the current account is at/over the
  # in-session threshold (so the buffer got used to finish this turn first).
  [ "${CLAUDE_OVERFLOW_INSESSION_PROACTIVE:-1}" = "1" ] || exit 0
  if [ "$cur" = "primary" ]; then cred=$(_cof_primary_cred); else cred=$(_cof_cred_of "$cur" 2>/dev/null); fi
  [ -n "$cred" ] || exit 0
  json=$(_cof_fetch "$cred" "$cur" fresh 2>/dev/null) || exit 0
  read -r s w sc <<EOF2
$(printf '%s' "$json" | _cof_pcts)
EOF2
  : "${s:=0}" "${w:=0}" "${sc:=0}"
  at="${CLAUDE_OVERFLOW_INSESSION_AT:-95}"
  if [ "$s" -ge "$at" ] || [ "$w" -ge "$at" ] || [ "$sc" -ge "$at" ]; then want=1; fi
  [ "$sc" -ge "$at" ] && need_sc=scoped
fi
[ "$want" = "1" ] || exit 0

# --- resolve a different account that has headroom (router's own picker) ---
line=$(_cof_pick "$cur" "$need_sc" 2>/dev/null)
tab=$(printf '\t')
pick=${line%%"$tab"*}
reason=${line#*"$tab"}

bad=0
case "$pick" in ""|login|"$cur") bad=1 ;; esac
case "$reason" in "all accounts near limits"*|"usage-check-failed") bad=1 ;; esac
if [ "$bad" = "0" ] && [ "$pick" != "primary" ]; then
  [ "$(_cof_cred_state "$(_cof_cred_of "$pick" 2>/dev/null)")" = "dead" ] && bad=1
fi

# "wall": this turn died on a hard limit (the session is unusable until it moves);
# "proactive": the turn finished fine, the account is just nearly out.
trig=proactive; [ "$ev" = "StopFailure" ] && trig=wall

if [ "$bad" = "1" ]; then
  if [ "$pick" = "login" ]; then
    # Only signed-out accounts are left. Open their sign-in now (detached; the user just
    # completes it). The worker gets this session's control dir: on a hard limit it moves
    # the conversation over the moment the login lands; otherwise the next turn boundary does.
    opened=""
    for l in $(printf '%s' "$reason" | tr ',' ' '); do
      COF_LOGIN_CTRL="$COF_CTRL_DIR" COF_LOGIN_SID="$sid" _cof_login_bg "$l" insession force && opened="${opened:+$opened, }$l"
    done
    printf '%s\nsign-in needed: %s\n' "$trig" "$reason" > "$COF_CTRL_DIR/paused" 2>/dev/null
    if [ -n "$opened" ]; then
      if [ "$trig" = "wall" ]; then
        _cof_notify "Claude overflow: $cur hit its limit" "Sign-in window opened for: $opened. Finish it and this conversation moves there by itself."
        _say "paused on \"$cur\" (hard limit; other accounts full, $reason signed out). A browser sign-in window is open for $opened: finish it and this conversation moves there by itself, then resend your prompt."
      else
        _cof_notify "Claude overflow: $cur is nearly out" "Sign-in window opened for: $opened. Finish it and the conversation hops there at the next turn."
        _say "\"$cur\" is nearly out and the other accounts are full or signed out ($reason). A browser sign-in window is open for $opened: finish it and the conversation hops there at the next turn."
      fi
    else
      _cof_notify "Claude overflow: paused on $cur" "No account has headroom; $reason need sign-in (claude-overflow login <label>). The conversation is intact."
      _say "paused on \"$cur\": no account has headroom and $reason need sign-in (run: claude-overflow login <label>, then resend your prompt)."
    fi
    exit 0
  fi
  preason="${reason:-no account with headroom}"
  printf '%s\n%s\n' "$trig" "$preason" > "$COF_CTRL_DIR/paused" 2>/dev/null
  _cof_notify "Claude overflow: paused on $cur" "No account has headroom ($preason). The conversation is intact; wait for a reset or run cswap."
  _say "paused on \"$cur\": $preason. The conversation is intact; wait for a reset or run cswap."
  exit 0
fi

# The pool is draining: any other signed-out account gets its sign-in opened too (cooldown-limited),
# so it is ready by the time this next account runs out.
_cof_login_dead_bg insession "$cur" "$pick" >/dev/null 2>&1

# --- request the switch and end the session so the managed loop resumes elsewhere ---
_ilog "switch -> $pick ($reason)"
printf '%s\n%s\n%s\n' "$pick" "$sid" "$reason" > "$COF_CTRL_DIR/switch" 2>/dev/null
cpid=$(cat "$COF_PIDFILE" 2>/dev/null)
if [ -n "$cpid" ]; then
  d="${CLAUDE_OVERFLOW_INSESSION_KILL_DELAY:-1}"
  # detached so it outlives this hook; SIGTERM lets Claude Code exit cleanly and
  # flush the transcript, then the loop takes over.
  nohup bash -c "sleep $d; kill -TERM $cpid 2>/dev/null" >/dev/null 2>&1 &
fi
exit 0
