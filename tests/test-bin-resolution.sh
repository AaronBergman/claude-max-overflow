#!/usr/bin/env bash
# Regression test: whatever the router runs for one specific account must reach the real Claude Code binary
# with that account's CLAUDE_CONFIG_DIR, even when a `claude` that re-enters the router comes first on PATH
# (the optional claude-shim, or a hand-made ~/bin/claude wrapper that calls the `claude` function).
# Before 2026-10-17 such a wrapper turned an overflow account's background sign-in into a sign-in of the
# primary account: `env CLAUDE_CONFIG_DIR=<overflow> claude auth login` found the wrapper, the wrapper
# re-entered the router, and the router runs subcommands on primary.
#
# Fully offline and isolated: a fake claude binary records the config dir and arguments it was given;
# `security` (Keychain), `curl` and `osascript` are stubbed out, so no real credential, network call or
# notification is touched.   Run: bash tests/test-bin-resolution.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/cof-test.XXXXXX")
trap 'pkill -f "$T" 2>/dev/null; rm -rf "$T"' EXIT   # pkill: a regression could leave a recursion running
pass=0 fail=0

# ---------- fixture ----------
mkdir -p "$T/real" "$T/wrap" "$T/tools" "$T/home/cache" "$T/home/shim" "$T/primary" "$T/profiles/t1"
LOG="$T/calls.log"

# The fake "real" binary: a script padded past 64 KB, so the router treats it like a real CLI (the npm
# cli.js is a large #! script too) rather than a small wrapper to follow.
{ printf '%s\n' '#!/bin/bash' \
    'printf "%s|%s|%s\n" "${CLAUDE_CONFIG_DIR-<unset>}" "${ANTHROPIC_API_KEY:+key}" "$*" >> "$FAKE_LOG"' \
    'if [ "${1:-}" = "--help" ]; then printf "Commands:\n  auth   Manage authentication\n  mcp    Configure MCP servers\n  plugin|plugins   Manage plugins\n"; fi' \
    'exit 0'
  printf '#%.0s' $(seq 1 70000); printf '\n'; } > "$T/real/claude"
chmod +x "$T/real/claude"

# A hand-made wrapper of the kind that caused the incident: puts the real binary first, loads the router and
# hands off to its `claude` function (falls back to the binary it names by absolute path).
cat > "$T/wrap/claude" <<EOF
#!/bin/bash
unset COF_MANAGED COF_CTRL_DIR COF_ACCOUNT COF_PIDFILE
PATH="$T/real:\$PATH"
. "\$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" >/dev/null 2>&1
type _cof_run_in >/dev/null 2>&1 && { claude "\$@"; exit \$?; }
exec env -u ANTHROPIC_API_KEY $T/real/claude "\$@"
EOF
chmod +x "$T/wrap/claude"
cp "$REPO/claude-shim" "$T/home/shim/claude" && chmod +x "$T/home/shim/claude"
ln -s "$REPO/claude-overflow.sh" "$T/home/claude-overflow.sh"

for t in jq perl shasum sha256sum; do p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$T/tools/$t"; done
for t in security curl osascript; do printf '#!/bin/sh\nexit 1\n' > "$T/tools/$t"; chmod +x "$T/tools/$t"; done

future=$(( ($(date +%s) + 86400) * 1000 ))
printf '{"oauthAccount":{"emailAddress":"primary@example.com"}}\n' > "$T/primary/.claude.json"
printf '{"oauthAccount":{"emailAddress":"t1@example.com"}}\n' > "$T/profiles/t1/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"x","refreshToken":"y","expiresAt":%s}}\n' "$future" > "$T/profiles/t1/.credentials.json"
printf 't1\t%s\t%s\tt1@example.com\n' "$T/profiles/t1" "$T/profiles/t1/.credentials.json" > "$T/home/accounts.tsv"

BASE_PATH="$T/tools:/usr/bin:/bin:/usr/sbin:/sbin"
export FAKE_LOG="$LOG" CLAUDE_OVERFLOW_HOME="$T/home" CLAUDE_OVERFLOW_PRIMARY_DIR="$T/primary" HOME="$T"
unset CLAUDE_CONFIG_DIR CLAUDE_ACCOUNT ANTHROPIC_API_KEY COF_MANAGED COF_CTRL_DIR COF_ACCOUNT COF_PIDFILE

# ---------- runner ----------
# check <name> <shell|prog> <PATH prefix> <expected "dir|key|args" line, or a prefix of it> <snippet>
# A shell name sources the router into that shell first; "prog" runs the snippet in a plain bash with no
# router functions, the way a script or subprocess sees `claude`.
check() {
  local name="$1" sh="$2" pre="$3" want="$4" code="$5" got
  : > "$LOG"
  # perl alarm: a case that hangs (e.g. a wrapper recursing into itself) fails after 20 s instead of blocking
  if [ "$sh" = prog ]; then PATH="$pre:$BASE_PATH" perl -e 'alarm 20; exec @ARGV' bash -c "$code" </dev/null >"$T/out" 2>&1
  else PATH="$pre:$BASE_PATH" perl -e 'alarm 20; exec @ARGV' "$sh" -c '. "$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" >/dev/null 2>&1; '"$code" </dev/null >"$T/out" 2>&1; fi
  pkill -f "$T/home/shim/claude" 2>/dev/null
  got=$(grep -v -- '|--help$' "$LOG" | tail -1)
  case "$got" in
    "$want"*) pass=$((pass + 1)); printf 'ok    %-5s %s\n' "$sh" "$name" ;;
    *) fail=$((fail + 1)); printf 'FAIL  %-5s %s\n        want: %s\n        got:  %s\n' "$sh" "$name" "$want" "${got:-<binary not called>}"
       sed 's/^/        | /' "$T/out" | head -8 ;;
  esac
}
check_bin() {  # <shell> <PATH prefix> <tag> : _cof_bin must name the fake binary
  local sh="$1" pre="$2" tag="$3" got
  got=$(PATH="$pre:$BASE_PATH" "$sh" -c '. "$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" >/dev/null 2>&1; _cof_bin' 2>/dev/null)
  if [ "$got" = "$T/real/claude" ]; then pass=$((pass + 1)); printf 'ok    %-5s _cof_bin %s\n' "$sh" "$tag"
  else fail=$((fail + 1)); printf 'FAIL  %-5s _cof_bin %s: got %s\n' "$sh" "$tag" "${got:-<empty>}"; fi
}

export P1="$T/profiles/t1" PR="$T/primary"
shells="bash"; command -v zsh >/dev/null 2>&1 && shells="bash zsh"
for sh in $shells; do
  for front in "$T/wrap" "$T/home/shim"; do
    pre="$front:$T/real"
    tag="[${front##*/} first]"
    check_bin "$sh" "$pre" "$tag"
    check "_cof_run_in overflow $tag"      "$sh" "$pre" "$P1||--version"                     '_cof_run_in "$P1" --version'
    check "_cof_ping overflow $tag"        "$sh" "$pre" "$P1||-p Reply with exactly: ok"      '_cof_ping t1'
    check "_cof_login overflow, no tty $tag" "$sh" "$pre" "$P1||auth login --email t1@example.com" '_cof_login t1'
    check "claude auth with explicit CLAUDE_CONFIG_DIR $tag" "$sh" "$pre" "$P1||auth status" 'CLAUDE_CONFIG_DIR="$P1" claude auth status'
    check "claude mcp runs on primary $tag" "$sh" "$pre" "$PR||mcp list"                       'claude mcp list'
    check "cacct t1 -p $tag"               "$sh" "$pre" "$P1||-p hi"                          'cacct t1 -p hi'
  done
done

# The shim as a program (no shell function in sight), the way scripts and subprocesses run `claude`.
pre="$T/home/shim:$T/real"
check "shim: CLAUDE_CONFIG_DIR=<overflow> claude auth logout" prog "$pre" "$P1||auth logout" 'CLAUDE_CONFIG_DIR="$P1" claude auth logout'
check "shim: subcommand -> primary, API key stripped"          prog "$pre" "$PR||plugin list" 'ANTHROPIC_API_KEY=k claude plugin list'
check "shim: CLAUDE_ACCOUNT=t1 claude -p"                       prog "$pre" "$P1||-p hi"       'CLAUDE_ACCOUNT=t1 claude -p hi'
check "shim: CLAUDE_OVERFLOW_SHIM=0 passes through untouched"   prog "$pre" "<unset>|key|-p hi" 'CLAUDE_OVERFLOW_SHIM=0 ANTHROPIC_API_KEY=k claude -p hi'
check "shim: router missing -> real binary, key stripped"       prog "$pre" "<unset>||-p hi"   'CLAUDE_OVERFLOW_HOME=/nonexistent ANTHROPIC_API_KEY=k claude -p hi'
check "shim: re-entered from the router -> real binary, dir kept" prog "$pre" "$P1||auth status" 'COF_SHIM_ACTIVE=1 CLAUDE_CONFIG_DIR="$P1" claude auth status'

# Loading the router puts an installed shim first on PATH (once).
got=$(PATH="$T/real:$BASE_PATH" bash -c '. "$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" >/dev/null 2>&1; . "$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" >/dev/null 2>&1; printf %s "$PATH"')
case "$got" in
  "$T/home/shim:$T/real:"*) pass=$((pass + 1)); echo "ok    bash  loader puts the installed shim first on PATH" ;;
  *) fail=$((fail + 1)); echo "FAIL  bash  loader puts the installed shim first on PATH: $got" ;;
esac

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
