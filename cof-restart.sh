#!/bin/bash
# claude-max-overflow: /restart. Ends the current Claude Code session and resumes the SAME
# conversation right away, on the same account, in the same terminal. Useful for picking up anything
# Claude Code only reads at startup: settings.json, hooks, plugins, MCP servers, CLAUDE.md, a newly
# installed CLI version.
#
# It reuses the in-session switch protocol (see cof-insession-hook.sh): write
# "<account>\n<session-id>\nrestart" into $COF_CTRL_DIR/switch and SIGTERM claude. The managed loop
# in claude-overflow.sh (_cof_run_managed) sees the switch file and re-launches
# `--resume <session-id>` with the original launch flags. Only router-managed sessions have that
# loop, so anywhere else this changes nothing and prints the manual resume command instead.
#
# Called by ~/.claude/commands/restart.md as a `!` pre-command, so it runs before the model does:
# on success claude is gone before the prompt is sent (no turn, no usage); otherwise stdout (a
# "Not restarted: ..." line) becomes the prompt and the model relays it.
# $1 = ${CLAUDE_SESSION_ID} as substituted by Claude Code; CLAUDE_CODE_SESSION_ID is the fallback.

sid="$1" found=""
case "$sid" in ""|*'$'*|*'{'*) sid="${CLAUDE_CODE_SESSION_ID:-}" ;; esac

nope() {
  printf 'Not restarted: %s\n' "$1"
  [ -n "$found" ] && printf 'To restart by hand: /exit, then run: claude --resume %s\n' "$sid"
  exit 0
}

[ -n "$sid" ] || nope "couldn't tell which conversation this is (no session id)."

# A session with no messages yet has no transcript, and --resume would just fail.
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
for f in "$cfg"/projects/*/"$sid".jsonl; do [ -s "$f" ] && { found="$f"; break; }; done
[ -n "$found" ] || nope "this conversation has no saved messages yet, so there is nothing to resume. Send a message first (or just /exit)."

if [ "${COF_MANAGED:-}" != "1" ] || [ -z "${COF_CTRL_DIR:-}" ] || [ ! -d "$COF_CTRL_DIR" ]; then
  nope "this session wasn't launched through the claude-overflow loop (an interactive \`claude\` from your shell), so nothing would relaunch it after it exits."
fi
cpid=$(cat "${COF_PIDFILE:-$COF_CTRL_DIR/pid}" 2>/dev/null)
[ -n "$cpid" ] || nope "the router's pid file for this session is empty."
# COF_* env is inherited by nested sessions (e.g. a `claude -p` run from the Bash tool), so only act
# when the managed claude is the session running this command: claude sets CLAUDE_PID for its children.
[ -z "${CLAUDE_PID:-}" ] || [ "$CLAUDE_PID" = "$cpid" ] || nope "this is a nested Claude Code session, not the one the router launched."
kill -0 "$cpid" 2>/dev/null || nope "claude (pid $cpid) isn't running."
[ -s "$COF_CTRL_DIR/switch" ] && nope "an account switch is already in progress for this session."

printf '%s\n%s\n%s\n' "${COF_ACCOUNT:-primary}" "$sid" "restart" > "$COF_CTRL_DIR/switch" 2>/dev/null \
  || nope "couldn't write the switch request ($COF_CTRL_DIR/switch)."
# Immediate, not delayed like the hook's: no turn is running, so there is nothing to flush, and
# ending now keeps the /restart prompt from ever reaching the model.
kill -TERM "$cpid" 2>/dev/null || { : > "$COF_CTRL_DIR/switch"; nope "couldn't signal claude (pid $cpid)."; }
exit 0
