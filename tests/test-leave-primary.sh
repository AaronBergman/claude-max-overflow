#!/bin/bash
# Offline test for the in-session hook's soft "leave primary" hop (CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY).
# A stub loader replaces the router (no network, no credentials); a `sleep` stands in for claude.
# Run: bash tests/test-leave-primary.sh

HOOK="$(cd "$(dirname "$0")/.." && pwd)/cof-insession-hook.sh"
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0

cat > "$T/stub-loader.sh" <<'EOF'
CLAUDE_OVERFLOW_SESSION_AT="${CLAUDE_OVERFLOW_SESSION_AT:-85}"
CLAUDE_OVERFLOW_WEEKLY_AT="${CLAUDE_OVERFLOW_WEEKLY_AT:-50}"
CLAUDE_OVERFLOW_SCOPED_AT="${CLAUDE_OVERFLOW_SCOPED_AT:-50}"
CLAUDE_OVERFLOW_FULL_AT="${CLAUDE_OVERFLOW_FULL_AT:-97}"
_cof_primary_cred() { echo primary-cred; }
_cof_cred_of() { echo "cred-$1"; }
_cof_fetch() { echo '{}'; }
_cof_pcts() { echo "${FAKE_S:-0} ${FAKE_W:-0} ${FAKE_SC:-0}"; }
_cof_pick() { echo "pick $1 $2" >> "$CALLS"; printf '%s\t%s\n' "${FAKE_PICK:-work}" "${FAKE_REASON:-overflow: session 0% weekly 3%}"; }
_cof_cred_state() { echo live; }
_cof_login_bg() { echo "login_bg $*" >> "$CALLS"; }
_cof_login_dead_bg() { echo "login_dead_bg $*" >> "$CALLS"; }
_cof_notify() { echo "notify $*" >> "$CALLS"; }
EOF

# run_case <name> <expect: hop|stay> [env assignments...]; $FAKE_CLAUDE_CMD picks what stands in for claude
run_case() {
  local name="$1" expect="$2"; shift 2
  local c="$T/$name"; mkdir -p "$c/ctrl" "$c/home" "$c/tasks" "$c/sess/workflows" "$c/sess/subagents"
  : > "$c/ctrl/switch"; : > "$c/ctrl/paused"; : > "$c/calls"; : > "$c/sess.jsonl"
  [ -n "${SETUP:-}" ] && (cd "$c" && eval "$SETUP")
  bash -c "${FAKE_CLAUDE_CMD:-exec sleep 60}" & local cpid=$!; disown "$cpid" 2>/dev/null
  sleep 0.3
  echo "$cpid" > "$c/ctrl/pid"
  local input; input=$(jq -cn --arg tp "$c/sess.jsonl" --argjson sha "${SHA:-false}" \
    '{session_id:"test-sid", transcript_path:$tp, stop_hook_active:$sha, hook_event_name:"Stop"}')
  printf '%s' "$input" | env COF_MANAGED=1 COF_CTRL_DIR="$c/ctrl" COF_ACCOUNT="${ACCT:-primary}" COF_PIDFILE="$c/ctrl/pid" \
    COF_LOADER="$T/stub-loader.sh" CLAUDE_OVERFLOW_HOME="$c/home" COF_TASKS_DIR="$c/tasks" CALLS="$c/calls" \
    CLAUDE_OVERFLOW_INSESSION_KILL_DELAY=0 "$@" bash "$HOOK" Stop > "$c/out" 2>&1
  sleep 0.6
  local got=stay alive=1
  [ -s "$c/ctrl/switch" ] && got=hop
  kill -0 "$cpid" 2>/dev/null || alive=0
  kill "$cpid" 2>/dev/null; pkill -P "$cpid" 2>/dev/null
  local ok=1
  [ "$got" = "$expect" ] || ok=0
  [ "$got" = hop ] && [ "$alive" = 1 ] && ok=0                       # a hop must end the session
  [ "$got" = stay ] && [ "$alive" = 0 ] && ok=0                      # staying must not
  [ "$expect" = stay ] && [ -s "$c/ctrl/paused" ] && [ -z "${PAUSE_OK:-}" ] && ok=0   # soft never pauses
  if [ -n "${WANT_REASON:-}" ] && ! grep -q -- "$WANT_REASON" "$c/ctrl/switch"; then ok=0; fi
  if [ -n "${NO_CALL:-}" ] && grep -q -- "$NO_CALL" "$c/calls"; then ok=0; fi
  if [ "$ok" = 1 ]; then pass=$((pass+1)); echo "ok    $name ($got)"
  else fail=$((fail+1)); echo "FAIL  $name: expected $expect, got $got (alive=$alive)"; sed 's/^/      switch: /' "$c/ctrl/switch"; sed 's/^/      paused: /' "$c/ctrl/paused"; sed 's/^/      out: /' "$c/out"; fi
}

W85="FAKE_W=85"
# 1. primary past the weekly reserve, nothing in flight: soft hop with a "leaving primary" reason, no sign-in windows
WANT_REASON="leaving primary (weekly 85% >= 50%)" NO_CALL="login_dead_bg" run_case soft-hop hop $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 2. same usage, feature off: stays (95% rule only)
run_case knob-off stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=0
# 3. below every threshold: stays
run_case under-reserve stay FAKE_W=40 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 4. a /goal loop is active (last goal_status unmet): stays
SETUP='printf "%s\n" "{\"type\":\"attachment\",\"attachment\":{\"type\":\"goal_status\",\"met\":true}}" "{\"type\":\"attachment\",\"attachment\":{\"type\":\"goal_status\",\"met\":false,\"sentinel\":true}}" > sess.jsonl' \
  run_case goal-active stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 5. the goal was met or cleared (last goal_status met): hops; a tool result quoting goal_status text doesn't count
SETUP='printf "%s\n" "{\"type\":\"attachment\",\"attachment\":{\"type\":\"goal_status\",\"met\":false}}" "{\"type\":\"attachment\",\"attachment\":{\"type\":\"goal_status\",\"met\":true}}" "{\"type\":\"user\",\"message\":{\"content\":\"{\\\"type\\\":\\\"goal_status\\\",\\\"met\\\":false}\"}}" > sess.jsonl' \
  run_case goal-done hop $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 6. a background Bash command is running (Bash-tool shell child of claude): stays
FAKE_CLAUDE_CMD='/bin/zsh -c ": shell-snapshots/snapshot-zsh-1.sh; sleep 60; true" & wait' \
  run_case bg-bash stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 7. some other child process (an MCP server, a hook): still hops
FAKE_CLAUDE_CMD='sleep 60 & wait' run_case other-child hop $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 8. a workflow is running (task output, no end record): stays
SETUP=': > tasks/w123abc.output' run_case workflow-running stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 9. that workflow has ended (end record names its task id): hops
SETUP=': > tasks/w123abc.output; printf "{\n  \"taskId\": \"w123abc\",\n  \"status\": \"completed\"\n}\n" > sess/workflows/wf_1.json' \
  run_case workflow-done hop $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 10. a workflow output with no end record and nothing written for 2 hours (died with an earlier process): hops
SETUP=': > tasks/w999.output; touch -t "$(date -v-2H +%Y%m%d%H%M)" tasks/w999.output' \
  run_case workflow-stale hop $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 11. a background agent wrote to its transcript just now: stays
SETUP=': > sess/subagents/agent-a1.jsonl; ln -s "$PWD/sess/subagents/agent-a1.jsonl" tasks/a1.output' \
  run_case agent-active stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 12. that agent has been quiet for 20 minutes: hops
SETUP=': > sess/subagents/agent-a1.jsonl; touch -t "$(date -v-20M +%Y%m%d%H%M)" sess/subagents/agent-a1.jsonl; ln -s "$PWD/sess/subagents/agent-a1.jsonl" tasks/a1.output' \
  run_case agent-idle hop $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 13. another Stop hook is continuing this turn: stays
SHA=true run_case stop-hook-active stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 14. no overflow account has room: stays quietly (no pause file, no notification)
NO_CALL="notify" run_case no-room stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1 FAKE_PICK=primary "FAKE_REASON=all accounts near limits"
# 15. only signed-out overflow accounts: stays quietly, no sign-in windows
NO_CALL="login_bg" run_case only-dead stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1 FAKE_PICK=login FAKE_REASON=work
# 16. only the model-scoped window is past the reserve: hops and asks the picker for scoped room
WANT_REASON="scoped 60% >= 50%" run_case scoped-only hop FAKE_SC=60 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
grep -q "pick primary scoped" "$T/scoped-only/calls" && { pass=$((pass+1)); echo "ok    scoped-only asks for scoped room"; } || { fail=$((fail+1)); echo "FAIL  scoped-only did not pass 'scoped' to _cof_pick"; }
# 16b. a session launched on primary by name (cacct primary) is pinned: stays
run_case pinned stay $W85 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1 COF_PIN_PRIMARY=1
# 17. a session on an overflow account at 60%: the reserve is primary-only, stays
ACCT=work run_case overflow-session stay FAKE_W=60 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
# 18. the hard 95% hop is unchanged: hops even with a goal active, normal reason
SETUP='printf "%s\n" "{\"type\":\"attachment\",\"attachment\":{\"type\":\"goal_status\",\"met\":false}}" > sess.jsonl' WANT_REASON="overflow: session" \
  run_case hard-hop hop FAKE_W=96 CLAUDE_OVERFLOW_INSESSION_LEAVE_PRIMARY=1
grep -q "leaving primary" "$T/hard-hop/ctrl/switch" && { fail=$((fail+1)); echo "FAIL  hard-hop reason should not say leaving primary"; } || { pass=$((pass+1)); echo "ok    hard-hop keeps its normal reason"; }

echo "---- $pass passed, $fail failed"
[ "$fail" = 0 ]
