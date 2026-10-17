# claude-overflow.sh: route Claude Code overflow usage across multiple Max accounts.
# Source this from your shell rc (bash or zsh). The guided installer (setup.sh) does
# this for you. https://github.com/AaronBergman/claude-max-overflow  (EXPERIMENTAL)
#
# One PRIMARY account (your normal ~/.claude login) owns all configuration.
# Any number of OVERFLOW accounts live in isolated CLAUDE_CONFIG_DIR profiles that
# symlink back to the primary's config, so settings/skills/history/memory are shared
# and --resume works across accounts. `claude` becomes a function that checks the
# primary's live rate limits and transparently launches whichever account has headroom.
#
# Credential lifecycle (why re-login is automatic):
#   Claude Code's OAuth access tokens live a few hours; the refresh token that renews
#   them lives ~28 days from its last use, and a rejected refresh (invalid_grant)
#   makes Claude Code blank the stored credentials. An overflow account you rarely
#   touch therefore drifts stale -> dead. This file classifies every account as
#   ok | stale | dead, refreshes stale tokens itself (a one-token `claude -p` ping,
#   so Claude Code does the refresh under its own lock), and re-logs-in dead accounts
#   through Claude Code's normal browser OAuth with the email pre-filled. The sign-in
#   is opened FOR you whenever it could plausibly unlock usage: synchronously when a
#   launch needs that account right now, and in the background (a browser window,
#   nothing else to do) when you launch a session while an account is signed out,
#   when a live conversation runs out and only signed-out accounts are left, or
#   from the keep-alive while you are at the keyboard. Scripts never see a window.
#
# Mirroring (why overflow sessions still show up in the primary's claude.ai):
#   Remote Control registers each session with claude.ai under the account that launched
#   it, and Claude Code refuses to upload a transcript into another account's session on
#   resume. After an overflow session exits, this file snapshots it into a primary-owned
#   claude.ai session: an idle `claude --bg` resume of a clean transcript copy (no inference).

# ---------- config (override via env or $CLAUDE_OVERFLOW_HOME/config.sh) ----------
CLAUDE_OVERFLOW_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
CLAUDE_OVERFLOW_PRIMARY_DIR="${CLAUDE_OVERFLOW_PRIMARY_DIR:-$HOME/.claude}"
CLAUDE_OVERFLOW_SESSION_AT="${CLAUDE_OVERFLOW_SESSION_AT:-85}"   # switch when 5h window >= %
CLAUDE_OVERFLOW_WEEKLY_AT="${CLAUDE_OVERFLOW_WEEKLY_AT:-92}"     # ...or weekly >= %
CLAUDE_OVERFLOW_SCOPED_AT="${CLAUDE_OVERFLOW_SCOPED_AT:-92}"     # ...or model-scoped weekly >= %
CLAUDE_OVERFLOW_FULL_AT="${CLAUDE_OVERFLOW_FULL_AT:-97}"         # an account counts as exhausted at %
CLAUDE_OVERFLOW_TTL="${CLAUDE_OVERFLOW_TTL:-60}"                 # usage-check cache seconds
CLAUDE_OVERFLOW_AUTOREFRESH="${CLAUDE_OVERFLOW_AUTOREFRESH:-1}"  # 1: refresh stale tokens inline (a 1-token ping)
CLAUDE_OVERFLOW_AUTOLOGIN="${CLAUDE_OVERFLOW_AUTOLOGIN:-1}"      # 1: open the browser sign-in for dead accounts by yourself | ask: prompt [Y/n] first | 0: never (just report)
CLAUDE_OVERFLOW_LOGIN_BROWSER="${CLAUDE_OVERFLOW_LOGIN_BROWSER:-private}"  # private | default | "<cmd with {url}>"
CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS="${CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS:-8}"  # a proactive (not strictly needed yet) sign-in window is re-opened at most this often per account
CLAUDE_OVERFLOW_LOGIN_TIMEOUT="${CLAUDE_OVERFLOW_LOGIN_TIMEOUT:-900}"     # seconds a background sign-in waits for you to finish in the browser
CLAUDE_OVERFLOW_PRESENT_IDLE_MAX="${CLAUDE_OVERFLOW_PRESENT_IDLE_MAX:-300}"  # keep-alive opens a sign-in only if you touched the keyboard/mouse within this many seconds
CLAUDE_OVERFLOW_PING_MODEL="${CLAUDE_OVERFLOW_PING_MODEL:-haiku}"  # model for the refresh ping (cheapest available)
CLAUDE_OVERFLOW_PING_TIMEOUT="${CLAUDE_OVERFLOW_PING_TIMEOUT:-60}" # seconds
CLAUDE_OVERFLOW_KEEPALIVE_HOURS="${CLAUDE_OVERFLOW_KEEPALIVE_HOURS:-12}"  # scheduled refresh cadence
CLAUDE_OVERFLOW_MIRROR="${CLAUDE_OVERFLOW_MIRROR:-1}"            # 1: after an overflow session exits, snapshot it into the primary's claude.ai
CLAUDE_OVERFLOW_MIRROR_CLEANUP="${CLAUDE_OVERFLOW_MIRROR_CLEANUP:-stop}"  # stop | rm : what to do with the helper background job afterwards
CLAUDE_OVERFLOW_MIRROR_TIMEOUT="${CLAUDE_OVERFLOW_MIRROR_TIMEOUT:-90}"    # seconds to wait for the upload to settle
CLAUDE_OVERFLOW_INSESSION="${CLAUDE_OVERFLOW_INSESSION:-1}"               # 1: move a live conversation to another account when the current one runs out
CLAUDE_OVERFLOW_INSESSION_PROACTIVE="${CLAUDE_OVERFLOW_INSESSION_PROACTIVE:-1}"  # 1: also hop at a clean turn boundary once the account is near its limit (uses the buffer to finish the turn, then transfers); 0: only when the wall is actually hit
CLAUDE_OVERFLOW_INSESSION_AT="${CLAUDE_OVERFLOW_INSESSION_AT:-95}"        # proactive hop threshold (% of any window) for a live session; higher than the launch thresholds so most of the buffer is used first
CLAUDE_OVERFLOW_INSESSION_KILL_DELAY="${CLAUDE_OVERFLOW_INSESSION_KILL_DELAY:-1}"  # seconds to let the transcript flush before ending the session to resume elsewhere
[ -f "$CLAUDE_OVERFLOW_HOME/config.sh" ] && . "$CLAUDE_OVERFLOW_HOME/config.sh"
[ -f "$CLAUDE_OVERFLOW_HOME/aliases.sh" ] && . "$CLAUDE_OVERFLOW_HOME/aliases.sh"
# Optional claude-shim (setup.sh offers it): first on PATH, so programs that run `claude` (scripts, subprocesses,
# Claude Code's Bash tool) go through the router too. Interactive shells keep using the `claude` function below.
case ":$PATH:" in
  *":$CLAUDE_OVERFLOW_HOME/shim:"*) ;;
  *) [ -x "$CLAUDE_OVERFLOW_HOME/shim/claude" ] && PATH="$CLAUDE_OVERFLOW_HOME/shim:$PATH" ;;
esac

_COF_ACCOUNTS="$CLAUDE_OVERFLOW_HOME/accounts.tsv"   # label<TAB>config_dir<TAB>cred_source[<TAB>email]
_COF_CACHE="$CLAUDE_OVERFLOW_HOME/cache"
_COF_MIRRORS="$CLAUDE_OVERFLOW_HOME/mirrors.tsv"     # source_session<TAB>claude.ai_session<TAB>label<TAB>when<TAB>title
_COF_TAB="$(printf '\t')"
_COF_LAUNCHD_LABEL="com.claude-max-overflow.keepalive"

# ---------- small utilities ----------
_cof_os() { uname; }
_cof_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
_cof_now_ms() { printf '%s000' "$(date +%s)"; }
_cof_interactive() { [ -t 0 ] && [ -t 1 ]; }
_cof_dim() { if [ -t 2 ]; then printf '\033[2m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }
_cof_warn() { if [ -t 2 ]; then printf '\033[33m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }
_cof_detach() {  # run "$@" fully detached (own session/process group) so it outlives hooks, launchd jobs and closed terminals; prints its pid
  ( if command -v setsid >/dev/null 2>&1; then setsid "$@" </dev/null >/dev/null 2>&1 &
    else perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@" </dev/null >/dev/null 2>&1 &
    fi
    printf '%s' "$!" )
}
_cof_sha8() { { command -v shasum >/dev/null 2>&1 && printf '%s' "$1" | shasum -a 256; } 2>/dev/null | cut -c1-8 \
              || printf '%s' "$1" | sha256sum | cut -c1-8; }
_cof_timeout() {  # $1 secs, rest = command
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}
_cof_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_cof_claude_paths() {  # every `claude` executable on PATH, in PATH order (shell functions and aliases skipped)
  if [ -n "${ZSH_VERSION:-}" ]; then whence -pa claude; else type -Pa claude; fi 2>/dev/null
}
_cof_bin() {  # absolute path to the real claude binary (skips this shell function, claude-shim and script wrappers)
  # Everything that runs Claude Code for one specific account goes through this, never through a PATH lookup.
  # A `claude` earlier on PATH may re-enter the router (claude-shim, or a ~/bin/claude wrapper that calls the
  # `claude` function), which re-picks the account and drops CLAUDE_CONFIG_DIR: on 2026-10-16 that wrote an
  # overflow account's background sign-in into the primary's credentials. The result must also exec() in
  # place (a native binary, the npm cli.js, or a symlink to one), so the managed launcher's `exec "$bin"`
  # keeps the recorded pid. A small wrapper script is followed to the binary it names by absolute path; one
  # that names none is skipped in favour of the next claude on PATH.
  [ -n "${_COF_BIN:-}" ] && { printf '%s' "$_COF_BIN"; return; }
  local p inner c="" wrapper=""
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] || continue
    if [ "$(head -c 2 "$p" 2>/dev/null)" = '#!' ] && [ "$(wc -c < "$p" 2>/dev/null)" -lt 65536 ]; then
      head -c 4096 "$p" 2>/dev/null | grep -q 'claude-max-overflow-shim' && continue
      inner=$(grep -oE '/[^ "'"'"']*/claude' "$p" 2>/dev/null | grep -vxF "$p" | tail -1)
      if [ -n "$inner" ] && [ -x "$inner" ]; then c="$inner"; break; fi
      [ -n "$wrapper" ] || wrapper="$p"
      continue
    fi
    c="$p"; break
  done <<EOF_BINS
$(_cof_claude_paths)
EOF_BINS
  _COF_BIN="${c:-${wrapper:-claude}}"
  printf '%s' "$_COF_BIN"
}

_cof_primary_cred() {
  if [ "$(_cof_os)" = "Darwin" ]; then printf '%s' "Claude Code-credentials"
  else printf '%s' "$CLAUDE_OVERFLOW_PRIMARY_DIR/.credentials.json"; fi
}

_cof_primary_state() {
  if [ "$CLAUDE_OVERFLOW_PRIMARY_DIR" = "$HOME/.claude" ]; then printf '%s' "$HOME/.claude.json"
  else printf '%s' "$CLAUDE_OVERFLOW_PRIMARY_DIR/.claude.json"; fi
}

_cof_cred_for_dir() {  # $1 = profile dir -> where Claude Code keeps that profile's credentials
  # Claude Code namespaces macOS Keychain entries by the first 8 hex chars of sha256(config dir path).
  if [ "$(_cof_os)" = "Darwin" ]; then printf 'Claude Code-credentials-%s' "$(_cof_sha8 "$1")"
  else printf '%s/.credentials.json' "$1"; fi
}

# ---------- accounts.tsv access ----------
_cof_rows() { [ -s "$_COF_ACCOUNTS" ] && cat "$_COF_ACCOUNTS"; }
_cof_row() {  # $1 = label -> the tsv row (or fail)
  local label dir cred email
  while IFS="$_COF_TAB" read -r label dir cred email; do
    [ "$label" = "$1" ] && { printf '%s\t%s\t%s\t%s\n' "$label" "$dir" "$cred" "$email"; return 0; }
  done < "$_COF_ACCOUNTS" 2>/dev/null
  return 1
}
_cof_field() {  # $1 = label, $2 = field number (2 dir, 3 cred, 4 email)
  _cof_row "$1" | cut -f "$2"
}
_cof_dir_for() { _cof_field "$1" 2; }
_cof_put_row() {  # $1 label $2 dir $3 cred $4 email : replace in place (row order = overflow priority) or append
  local tmp
  mkdir -p "$CLAUDE_OVERFLOW_HOME"; touch "$_COF_ACCOUNTS"
  tmp=$(mktemp) || return 1
  awk -F '\t' -v OFS='\t' -v l="$1" -v d="$2" -v c="$3" -v e="$4" \
      '$1 == l { print l, d, c, e; seen = 1; next } { print } END { if (!seen) print l, d, c, e }' "$_COF_ACCOUNTS" > "$tmp"
  mv "$tmp" "$_COF_ACCOUNTS"
}

# ---------- credentials: read, classify, refresh ----------
_cof_creds_json() {  # $1 = cred source -> the stored credential JSON (never log this)
  if [ -f "$1" ]; then cat "$1" 2>/dev/null
  else security find-generic-password -w -s "$1" 2>/dev/null; fi
}

_cof_token() {  # $1 = cred source -> access token on stdout
  _cof_creds_json "$1" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

_cof_cred_state() {  # $1 = cred source -> ok | stale | dead
  #  ok    access token present and not within 60s of expiry
  #  stale access token expired/missing but a live refresh token exists (Claude Code will renew it)
  #  dead  nothing usable: no entry, blanked tokens (invalid_grant), or refresh token expired
  local json
  json=$(_cof_creds_json "$1") || { printf 'dead'; return; }
  [ -z "$json" ] && { printf 'dead'; return; }
  printf '%s' "$json" | jq -r --argjson now "$(_cof_now_ms)" '
    .claudeAiOauth as $o
    | if ($o | not) then "dead"
      elif (($o.accessToken // "") != "" and (($o.expiresAt // 0) - 60000) > $now) then "ok"
      elif (($o.refreshToken // "") != "" and (($o.refreshTokenExpiresAt // 0) == 0 or ($o.refreshTokenExpiresAt // 0) > $now)) then "stale"
      else "dead" end' 2>/dev/null || printf 'dead'
}

_cof_cred_of() {  # $1 = label -> the credential source that actually holds this profile's login (self-healing)
  # Claude Code can move a profile's login between its two stores (e.g. a plaintext
  # .credentials.json written at sign-in, migrated into the macOS Keychain on the next
  # launch). If the recorded source looks dead, check the other place before believing
  # it, and update accounts.tsv when the login turns out to live there.
  local label="$1" dir cred alt
  dir=$(_cof_field "$label" 2) || return 1
  cred=$(_cof_field "$label" 3)
  if [ -n "$cred" ] && [ "$(_cof_cred_state "$cred")" != "dead" ]; then printf '%s' "$cred"; return 0; fi
  for alt in "$(_cof_cred_for_dir "$dir")" "$dir/.credentials.json"; do
    [ "$alt" = "$cred" ] && continue
    if [ "$(_cof_cred_state "$alt")" != "dead" ]; then
      _cof_put_row "$label" "$dir" "$alt" "$(_cof_field "$label" 4)"
      printf '%s' "$alt"; return 0
    fi
  done
  printf '%s' "$cred"
}

_cof_run_in() {  # $1 = profile dir ("" = primary), rest = claude args: the real binary on that account (no PATH lookup)
  local dir="$1"; shift
  [ -z "$dir" ] && dir="$CLAUDE_OVERFLOW_PRIMARY_DIR"
  [ -n "${_COF_BIN:-}" ] || _cof_bin >/dev/null   # resolve once per shell (a $(...) would lose the cache)
  if [ "$dir" = "$HOME/.claude" ]; then
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE -u CLAUDE_CONFIG_DIR "$_COF_BIN" "$@"
  else
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE CLAUDE_CONFIG_DIR="$dir" "$_COF_BIN" "$@"
  fi
}

_cof_ping() {  # $1 = label (or primary): make Claude Code renew the token itself via a 1-token print call.
  # No hooks, no MCP servers, no session file, cheapest model: side-effect free apart from the refresh.
  local dir="$CLAUDE_OVERFLOW_PRIMARY_DIR"
  [ "$1" != "primary" ] && { dir=$(_cof_dir_for "$1") || return 1; }
  mkdir -p "$_COF_CACHE"
  [ -n "${_COF_BIN:-}" ] || _cof_bin >/dev/null
  set -- "$1" -p "Reply with exactly: ok" --model "$CLAUDE_OVERFLOW_PING_MODEL" --max-turns 1 \
         --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}'
  ( cd "$CLAUDE_OVERFLOW_HOME" 2>/dev/null || cd "$HOME"
    # timeout(1) needs a real executable, so env + the real binary (_cof_bin) rather than _cof_run_in.
    # stdin closed explicitly: `claude -p` otherwise waits 3 s for piped input (and can hang on an
    # inherited pipe, e.g. inside a hook)
    if [ "$dir" = "$HOME/.claude" ]; then
      _cof_timeout "$CLAUDE_OVERFLOW_PING_TIMEOUT" env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE -u CLAUDE_CONFIG_DIR \
        "$_COF_BIN" "${@:2}" </dev/null >/dev/null 2>"$_COF_CACHE/ping-$1.err"
    else
      _cof_timeout "$CLAUDE_OVERFLOW_PING_TIMEOUT" env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE CLAUDE_CONFIG_DIR="$dir" \
        "$_COF_BIN" "${@:2}" </dev/null >/dev/null 2>"$_COF_CACHE/ping-$1.err"
    fi
  )
}

_cof_ensure_fresh() {  # $1 = label -> prints final state (ok|stale|dead); refreshes stale tokens if allowed
  local cred st
  cred=$(_cof_cred_of "$1") || { printf 'dead'; return; }
  st=$(_cof_cred_state "$cred")
  if [ "$st" = "stale" ] && [ "$CLAUDE_OVERFLOW_AUTOREFRESH" = "1" ]; then
    _cof_dim "  refreshing \"$1\" token…"
    _cof_ping "$1" >/dev/null 2>&1
    st=$(_cof_cred_state "$cred")
    [ "$st" = "stale" ] && st=stale  # ping failed (network?) but refresh token still live: launchable blind
  fi
  printf '%s' "$st"
}

# ---------- usage fetch ----------
_cof_fetch() {  # $1 = cred source, $2 = cache key, $3 = "fresh" to bypass cache
  local cache tok out now mt
  mkdir -p "$_COF_CACHE"
  cache="$_COF_CACHE/usage-$2.json"
  if [ "${3:-}" != "fresh" ] && [ -s "$cache" ]; then
    now=$(date +%s); mt=$(_cof_mtime "$cache")
    if [ $((now - mt)) -lt "$CLAUDE_OVERFLOW_TTL" ]; then cat "$cache"; return 0; fi
  fi
  tok=$(_cof_token "$1")
  [ -z "$tok" ] && return 1
  out=$(curl -sS -m 4 -H "Authorization: Bearer $tok" \
        -H "anthropic-beta: oauth-2025-04-20" -H "Content-Type: application/json" \
        https://api.anthropic.com/api/oauth/usage 2>/dev/null) || return 1
  [ -z "$out" ] && return 1
  printf '%s' "$out" | jq -e '.limits' >/dev/null 2>&1 || return 1
  printf '%s\n' "$out" > "$cache"
  _cof_history "$2" "$out"
  printf '%s\n' "$out"
}

_cof_history() {  # $1 = cache key, $2 = usage JSON: one compact sample per real fetch -> usage-history.jsonl (the dashboard charts it)
  printf '%s' "$2" | jq -c --arg k "$1" --argjson t "$(date +%s)" '
    def ep: if . then (sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdate) else null end;
    {t: $t, k: $k,
     s:  ([.limits[]? | select(.kind=="session")       | .percent] | max // 0 | round),
     w:  ([.limits[]? | select(.kind=="weekly_all")    | .percent] | max // 0 | round),
     sc: ([.limits[]? | select(.kind=="weekly_scoped") | .percent] | max // 0 | round),
     sr: (.five_hour.resets_at | ep), wr: (.seven_day.resets_at | ep),
     x: .extra_usage.used_credits, src: "router"}' >> "$CLAUDE_OVERFLOW_HOME/usage-history.jsonl" 2>/dev/null
  return 0
}

_cof_pcts() {  # stdin: usage JSON -> "session weekly scoped"
  jq -r '[
    ([.limits[]? | select(.kind=="session")       | .percent] | max // 0),
    ([.limits[]? | select(.kind=="weekly_all")    | .percent] | max // 0),
    ([.limits[]? | select(.kind=="weekly_scoped") | .percent] | max // 0)
  ] | map(round) | join(" ")' 2>/dev/null
}

# ---------- login (browser OAuth through Claude Code, email pre-filled, private window) ----------
_cof_browser_shim() {  # writes $CLAUDE_OVERFLOW_HOME/bin/open (macOS) and prints the bin dir
  local bin="$CLAUDE_OVERFLOW_HOME/bin"
  mkdir -p "$bin"
  cat > "$bin/open" <<'EOF'
#!/bin/bash
# claude-max-overflow shim: Claude Code opens its OAuth URL with `open`. Route it into a
# private browser window so an existing claude.ai session in your default browser can't
# silently authorize the wrong account. Everything else passes straight through.
url=""; for a in "$@"; do case "$a" in http://*|https://*) url="$a";; esac; done
if [ -n "$url" ]; then
  printf '%s login page opened (mode: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${CLAUDE_OVERFLOW_LOGIN_BROWSER:-private}" >> "$(dirname "$0")/../cache/login-browser.log" 2>/dev/null
  case "${CLAUDE_OVERFLOW_LOGIN_BROWSER:-private}" in
    private)
      if   [ -d "/Applications/Google Chrome.app" ]; then exec /usr/bin/open -na "Google Chrome" --args --incognito "$url"
      elif [ -d "/Applications/Brave Browser.app" ]; then exec /usr/bin/open -na "Brave Browser" --args --incognito "$url"
      elif [ -d "/Applications/Firefox.app" ];       then exec /usr/bin/open -na "Firefox" --args --private-window "$url"
      fi ;;
    default) ;;
    *) cmd="${CLAUDE_OVERFLOW_LOGIN_BROWSER//\{url\}/$url}"; exec /bin/bash -c "$cmd" ;;
  esac
fi
exec /usr/bin/open "$@"
EOF
  chmod +x "$bin/open"
  printf '%s' "$bin"
}

_cof_login() {  # $1 = label|primary : run Claude Code's browser login for that profile, verify the account
  local label="$1" dir cred email got pstate shimdir rc
  if [ "$label" = "primary" ]; then
    dir=""; pstate=$(_cof_primary_state); cred=$(_cof_primary_cred)
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$pstate" 2>/dev/null)
  else
    _cof_row "$label" >/dev/null || { _cof_warn "login: unknown account \"$label\""; return 1; }
    dir=$(_cof_field "$label" 2); cred=$(_cof_field "$label" 3); email=$(_cof_field "$label" 4)
    [ -d "$dir" ] || { _cof_warn "login: profile dir $dir missing (claude-overflow add $label ...)"; return 1; }
    pstate="$dir/.claude.json"
  fi
  if [ -t 2 ]; then printf '\n\033[1mSigning in the "%s" account%s\033[0m\n' "$label" "${email:+ ($email)}" >&2
  else printf 'Signing in the "%s" account%s\n' "$label" "${email:+ ($email)}" >&2; fi
  printf '  A browser window opens (private window when possible). Authorize as %s.\n' "${email:-the intended account}" >&2
  shimdir=""
  [ "$CLAUDE_OVERFLOW_LOGIN_BROWSER" = "default" ] || [ "$(_cof_os)" != "Darwin" ] || shimdir=$(_cof_browser_shim)
  if [ -n "$email" ]; then set -- auth login --email "$email"; else set -- auth login; fi
  if _cof_interactive; then
    # at a terminal: Claude Code owns the tty (it can also take a pasted code); Ctrl-C aborts
    if [ -n "$shimdir" ]; then
      PATH="$shimdir:$PATH" CLAUDE_OVERFLOW_LOGIN_BROWSER="$CLAUDE_OVERFLOW_LOGIN_BROWSER" _cof_run_in "$dir" "$@"; rc=$?
    else
      _cof_run_in "$dir" "$@"; rc=$?
    fi
  else
    # detached (background worker, keep-alive): no tty, so bound the wait for the browser callback.
    # The real binary, never `claude` from PATH: a wrapper there would sign in the primary instead (_cof_bin).
    [ -n "${_COF_BIN:-}" ] || _cof_bin >/dev/null
    ( [ -n "$shimdir" ] && PATH="$shimdir:$PATH"; export PATH CLAUDE_OVERFLOW_LOGIN_BROWSER
      if [ -z "$dir" ] || [ "$dir" = "$HOME/.claude" ]; then
        _cof_timeout "$CLAUDE_OVERFLOW_LOGIN_TIMEOUT" env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE -u CLAUDE_CONFIG_DIR "$_COF_BIN" "$@" </dev/null
      else
        _cof_timeout "$CLAUDE_OVERFLOW_LOGIN_TIMEOUT" env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE CLAUDE_CONFIG_DIR="$dir" "$_COF_BIN" "$@" </dev/null
      fi ); rc=$?
  fi
  [ "$rc" -eq 0 ] || { _cof_warn "login: claude auth login exited $rc$([ "$rc" = 124 ] && printf ' (no browser callback within %ss)' "$CLAUDE_OVERFLOW_LOGIN_TIMEOUT")"; return "$rc"; }
  got=$(jq -r '.oauthAccount.emailAddress // empty' "$pstate" 2>/dev/null)
  if [ -n "$email" ] && [ "$(_cof_lc "$got")" != "$(_cof_lc "$email")" ]; then
    _cof_warn "login: the browser authorized \"${got:-unknown}\" but \"$label\" is supposed to be $email."
    _cof_warn "       Logging that session out again so the profile doesn't impersonate the wrong account."
    _cof_run_in "$dir" auth logout >/dev/null 2>&1
    return 1
  fi
  if [ "$label" != "primary" ]; then
    # added without an email (e.g. from the dashboard): record which account actually signed in
    [ -z "$email" ] && [ -n "$got" ] && _cof_put_row "$label" "$dir" "$(_cof_field "$label" 3)" "$got"
    cred=$(_cof_cred_of "$label")   # the login may have landed in the other credential store; this re-points accounts.tsv
    [ "$(_cof_cred_state "$cred")" = "dead" ] && _cof_warn "login: credentials still unreadable at $cred (Keychain permission dialog? click Always Allow and retry)"
    rm -f "$_COF_CACHE/.notified-$label" "$_COF_CACHE/usage-$label.json"
  fi
  printf '  ✓ "%s" signed in as %s\n' "$label" "${got:-?}" >&2
  return 0
}

_cof_offer_login() {  # $1 = label, this launch needs it right now -> 0 if the account is usable afterwards
  local ans
  _cof_interactive || return 1
  case "$CLAUDE_OVERFLOW_AUTOLOGIN" in
    0) return 1 ;;
    ask) printf 'Overflow account "%s" needs a fresh sign-in (browser). Do it now? [Y/n] ' "$1" >&2
         read -r ans
         case "${ans:-Y}" in n|N) return 1 ;; esac ;;
    *) _cof_dim "→ \"$1\" is the account with headroom but it is signed out; opening its sign-in first (Ctrl-C aborts this launch; then c1 / CLAUDE_ACCOUNT=primary forces primary)" ;;
  esac
  _cof_login "$1"
}

# ---------- background sign-in: open the browser for a dead account without blocking anything ----------
# Used when a sign-in could plausibly unlock usage but nothing is waiting on it this instant:
# launching a session while some account is signed out, a live conversation that ran out with
# only signed-out accounts left, or the keep-alive noticing a dead account while you are at the
# keyboard. The browser window is the only thing you see; a detached worker waits for Claude
# Code's OAuth callback, verifies the account, and (if a paused conversation was waiting for
# exactly this account) moves it over.

_cof_llog() { mkdir -p "$CLAUDE_OVERFLOW_HOME"; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$CLAUDE_OVERFLOW_HOME/login.log"; }

_cof_user_present() {  # 0 when someone is at this Mac right now (console session, screen unlocked, recent input)
  [ "$(_cof_os)" = "Darwin" ] || return 0
  local idle locked
  [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$(id -un)" ] || return 1
  locked=$(ioreg -n Root -d1 -a 2>/dev/null | plutil -convert json -o - - 2>/dev/null | jq -r '.IOConsoleUsers[0].CGSSessionScreenIsLocked // false' 2>/dev/null)
  [ "$locked" = "true" ] && return 1
  idle=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  [ -n "$idle" ] && [ "$idle" -gt "$CLAUDE_OVERFLOW_PRESENT_IDLE_MAX" ] && return 1
  return 0
}

_cof_login_inflight() {  # $1 = label -> 0 if a background sign-in for it is still running
  local pid; pid=$(cat "$_COF_CACHE/login-$1.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_cof_login_bg() {  # $1 = label, $2 = why (launch|insession|keepalive), $3 = "force" to ignore the retry cooldown -> 0 if a window was opened (or is already open)
  local label="$1" why="${2:-}" force="${3:-}" marker now
  [ "$CLAUDE_OVERFLOW_AUTOLOGIN" != "0" ] || return 1
  _cof_row "$label" >/dev/null 2>&1 || return 1
  mkdir -p "$_COF_CACHE"
  _cof_login_inflight "$label" && return 0
  marker="$_COF_CACHE/.login-opened-$label"
  if [ -z "$force" ] && [ -f "$marker" ]; then
    now=$(date +%s)
    [ $(( now - $(_cof_mtime "$marker") )) -lt $(( CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS * 3600 )) ] && return 1
  fi
  touch "$marker"
  # COF_LOGIN_CTRL / COF_LOGIN_SID (set by the in-session hook) tell the worker which paused conversation to move
  COF_LOGIN_LABEL="$label" COF_LOGIN_WHY="$why" COF_LOGIN_CTRL="${COF_LOGIN_CTRL:-}" COF_LOGIN_SID="${COF_LOGIN_SID:-}" \
  CLAUDE_OVERFLOW_HOME="$CLAUDE_OVERFLOW_HOME" CLAUDE_OVERFLOW_LOGIN_BROWSER="$CLAUDE_OVERFLOW_LOGIN_BROWSER" \
  CLAUDE_OVERFLOW_LOGIN_TIMEOUT="$CLAUDE_OVERFLOW_LOGIN_TIMEOUT" CLAUDE_OVERFLOW_INSESSION_KILL_DELAY="$CLAUDE_OVERFLOW_INSESSION_KILL_DELAY" \
    _cof_detach bash -c '. "$0" && _cof_login_worker' "$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" > "$_COF_CACHE/login-$label.pid"
  return 0
}

_cof_login_worker() {  # detached: the browser sign-in for $COF_LOGIN_LABEL, then whatever was waiting on it
  local label="$COF_LOGIN_LABEL" why="${COF_LOGIN_WHY:-}" ctrl="${COF_LOGIN_CTRL:-}" sid="${COF_LOGIN_SID:-}" email rc pid
  [ -n "$label" ] || return 1
  email=$(_cof_field "$label" 4)
  _cof_llog "$label: sign-in window opened ($why)"
  _cof_notify "Claude overflow: sign in as ${email:-$label}" "A private browser window just opened for the \"$label\" account. Finish the login there; nothing else to do."
  _cof_login "$label" >>"$CLAUDE_OVERFLOW_HOME/login.log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    _cof_llog "$label: sign-in did not complete (exit $rc)"
    _cof_notify "Claude overflow: \"$label\" is still signed out" "The sign-in window was closed or timed out. It will be offered again later, or run: claude-overflow login $label"
    return "$rc"
  fi
  _cof_llog "$label: signed in as ${email:-?}"
  # A conversation paused on a hard limit with nobody else to go to? Move it here now.
  if [ -n "$ctrl" ] && [ -d "$ctrl" ] && [ "$(sed -n 1p "$ctrl/paused" 2>/dev/null)" = "wall" ] && [ ! -s "$ctrl/switch" ]; then
    pid=$(cat "$ctrl/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n%s\n%s\n' "$label" "$sid" "signed in" > "$ctrl/switch"
      sleep "${CLAUDE_OVERFLOW_INSESSION_KILL_DELAY:-1}"; kill -TERM "$pid" 2>/dev/null
      _cof_llog "$label: moving paused conversation ${sid:-?} here"
      _cof_notify "Claude overflow: \"$label\" signed in" "Moving your paused conversation to it now."
      return 0
    fi
  fi
  _cof_notify "Claude overflow: \"$label\" signed in" "The router can use it now."
}

_cof_dead_labels() {  # $@ = labels to skip -> space-separated labels whose login is dead
  local label dir cred email skip s out=""
  [ -s "$_COF_ACCOUNTS" ] || return 0
  while IFS="$_COF_TAB" read -r label dir cred email; do
    [ -n "$label" ] || continue
    skip=0; for s in "$@"; do [ "$s" = "$label" ] && skip=1; done; [ "$skip" = 1 ] && continue
    [ "$(_cof_cred_state "$(_cof_cred_of "$label")")" = "dead" ] && out="${out:+$out }$label"
  done < "$_COF_ACCOUNTS"
  printf '%s' "$out"
}

_cof_login_dead_bg() {  # $1 = why, rest = labels to skip: open background sign-ins for every dead account (cooldown-limited)
  local why="$1" l opened=""; shift
  for l in $(_cof_dead_labels "$@"); do _cof_login_bg "$l" "$why" && opened="${opened:+$opened, }$l"; done
  [ -n "$opened" ] && _cof_dim "→ sign-in window opened for signed-out account(s): $opened (finish it in the browser whenever; this launch is not waiting on it)"
  return 0
}

# ---------- picking ----------
_cof_pick() {  # $1 = optional label to exclude, $2 = "scoped": the model-scoped window must have headroom too -> prints "label<TAB>reason" | "login<TAB>label1[,label2]"
  # A model-scoped weekly window (e.g. Fable-only) is a separate wall: when it is what pushed us off an
  # account, the next account needs headroom there too, or a session on that model just bounces back
  # (seen 2026-09-17/18: sessions ping-ponged between two overflow accounts 16 and 18 times).
  local exclude="${1:-}" need_sc="${2:-}" json s w sc label dir cred email st blind="" dead=""
  if [ ! -s "$_COF_ACCOUNTS" ]; then printf 'primary\tno-overflow-accounts\n'; return; fi
  if [ "$exclude" != "primary" ]; then
    if json=$(_cof_fetch "$(_cof_primary_cred)" primary); then
      read -r s w sc <<EOF
$(printf '%s' "$json" | _cof_pcts)
EOF
      : "${s:=0}" "${w:=0}" "${sc:=0}"
      if [ "$s" -lt "$CLAUDE_OVERFLOW_SESSION_AT" ] && [ "$w" -lt "$CLAUDE_OVERFLOW_WEEKLY_AT" ] \
         && [ "$sc" -lt "$CLAUDE_OVERFLOW_SCOPED_AT" ]; then
        printf 'primary\tsession %s%% weekly %s%% scoped %s%%\n' "$s" "$w" "$sc"; return
      fi
      # only the model-scoped window is over: the overflow account must have room in it as well
      [ "$s" -lt "$CLAUDE_OVERFLOW_SESSION_AT" ] && [ "$w" -lt "$CLAUDE_OVERFLOW_WEEKLY_AT" ] && need_sc=scoped
    else
      printf 'primary\tusage-check-failed\n'; return
    fi
  fi
  # Primary tapped (or excluded): walk overflow accounts in priority order.
  while IFS="$_COF_TAB" read -r label dir cred email; do
    [ -z "$label" ] && continue
    [ "$label" = "$exclude" ] && continue
    st=$(_cof_ensure_fresh "$label")
    if [ "$st" = "dead" ]; then dead="${dead:+$dead,}$label"; continue; fi
    cred=$(_cof_cred_of "$label")
    if json=$(_cof_fetch "$cred" "$label"); then
      read -r s w sc <<EOF
$(printf '%s' "$json" | _cof_pcts)
EOF
      : "${s:=0}" "${w:=0}" "${sc:=0}"
      if [ "$s" -lt "$CLAUDE_OVERFLOW_FULL_AT" ] && [ "$w" -lt "$CLAUDE_OVERFLOW_FULL_AT" ] \
         && { [ "$need_sc" != "scoped" ] || [ "$sc" -lt "$CLAUDE_OVERFLOW_FULL_AT" ]; }; then
        if [ "$need_sc" = "scoped" ]; then printf '%s\toverflow: session %s%% weekly %s%% scoped %s%%\n' "$label" "$s" "$w" "$sc"
        else printf '%s\toverflow: session %s%% weekly %s%%\n' "$label" "$s" "$w"; fi
        return
      fi
    else
      [ -z "$blind" ] && blind="$label"   # live refresh token, usage unreadable right now
    fi
  done < "$_COF_ACCOUNTS"
  if [ -n "$blind" ]; then
    printf '%s\tblind (usage unreadable; Claude Code will renew the token on launch)\n' "$blind"
  elif [ -n "$dead" ]; then
    printf 'login\t%s\n' "$dead"
  else
    if [ "$need_sc" = "scoped" ]; then printf 'primary\tall accounts near limits (incl. the model-scoped window)\n'
    else printf 'primary\tall accounts near limits\n'; fi
  fi
}

_cof_resolve() {  # $1 = exclude -> prints the label to launch, after any interactive re-login
  local line pick reason first
  line=$(_cof_pick "$1")
  pick=${line%%"$_COF_TAB"*}
  reason=${line#*"$_COF_TAB"}
  if [ "$pick" = "login" ]; then
    first=${reason%%,*}
    if _cof_offer_login "$first"; then printf '%s\n' "$first"; return; fi
    if _cof_interactive; then _cof_dim "→ primary (overflow account(s) need sign-in: $reason; a sign-in window opens at the next launch, or run: claude-overflow login <label>)"
    else _cof_dim "→ primary (overflow account(s) need sign-in: $reason; run: claude-overflow login <label>)"; fi
    printf 'primary\n'; return
  fi
  [ "$pick" != "primary" ] && _cof_dim "→ overflow account \"$pick\" ($reason)"
  printf '%s\n' "$pick"
}

# ---------- profile plumbing ----------
_cof_sync() {  # $1 = profile dir: push primary's per-project trust/config into it (one-way)
  local state="$1/.claude.json" pstate marker tmp
  pstate=$(_cof_primary_state)
  marker="$_COF_CACHE/.sync-$(basename "$1")"
  [ -f "$state" ] && [ -f "$pstate" ] || return 0
  mkdir -p "$_COF_CACHE"
  if [ -f "$marker" ] && [ ! "$pstate" -nt "$marker" ]; then return 0; fi
  tmp=$(mktemp) || return 0
  if jq -s '.[1] + {projects: .[0].projects}' "$pstate" "$state" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$state" && touch "$marker"
  else
    rm -f "$tmp"
  fi
}

_cof_link_farm() {  # $1 = profile dir: symlink the shared config from the primary
  local item src dst
  for item in CLAUDE.md settings.json agents commands skills hooks plugins projects \
              history.jsonl keybindings.json output-styles plans workflows; do
    src="$CLAUDE_OVERFLOW_PRIMARY_DIR/$item"; dst="$1/$item"
    [ -e "$src" ] || continue
    if [ -L "$dst" ] || [ ! -e "$dst" ]; then ln -sfn "$src" "$dst"
    else _cof_warn "  skip $item (real file already in profile; resolve manually)"; fi
  done
}

_cof_seed_state() {  # $1 = profile dir: first-run state file (trust + prefs from primary, no identity)
  [ -f "$1/.claude.json" ] && return 0
  jq '{hasCompletedOnboarding: true}
      + ({theme, editorMode, autoUpdates, verbose, preferredNotifChannel,
          autocheckpointingEnabled, bypassPermissionsModeAccepted, projects}
         | with_entries(select(.value != null)))' "$(_cof_primary_state)" > "$1/.claude.json"
}

_cof_mark() { mkdir -p "$_COF_CACHE"; printf '%s\n' "$1" > "$_COF_CACHE/last"; }

_cof_notify() {  # $1 = title, $2 = body (desktop notification, best effort)
  local t b
  if [ "$(_cof_os)" = "Darwin" ]; then
    # escape for the AppleScript string literal (a quoted label like "work" used to break the whole notification)
    t=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'); b=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript -e "display notification \"$b\" with title \"$t\"" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then notify-send "$1" "$2" >/dev/null 2>&1; fi
}

# ---------- mirroring: snapshot overflow sessions into the primary account's claude.ai ----------
# Remote Control registers every interactive session with claude.ai under the account whose
# credentials launched it, so a session that ran on an overflow account is listed in THAT
# account's claude.ai, not the primary's; and when a session is resumed under a different
# login, Claude Code mints a fresh claude.ai session but refuses to upload the earlier
# transcript (it appends a history-suppression marker). What does work: a copy of the
# transcript under a fresh session id, resumed under the primary as an idle background
# session (`claude --bg`), gets a primary-owned claude.ai session into which Claude Code
# backfills the conversation (post-compaction context, like any native session; no
# inference; a few seconds). Each mirror is a snapshot; mirroring the same conversation
# again replaces (archives) the previous snapshot. The original transcript is never touched.

_cof_primary_uuid() { jq -r '.oauthAccount.accountUuid // empty' "$(_cof_primary_state)" 2>/dev/null; }

_cof_label_for_uuid() {  # $1 = accountUuid -> overflow label (or "overflow")
  local label dir cred email
  while IFS="$_COF_TAB" read -r label dir cred email; do
    [ -n "$dir" ] && [ "$(jq -r '.oauthAccount.accountUuid // empty' "$dir/.claude.json" 2>/dev/null)" = "$1" ] && { printf '%s' "$label"; return; }
  done < "$_COF_ACCOUNTS" 2>/dev/null
  printf 'overflow'
}

_cof_transcript_for() {  # $1 = session id -> transcript path (the projects dir is shared by all profiles)
  local f
  f=$(find "$CLAUDE_OVERFLOW_PRIMARY_DIR/projects" -maxdepth 2 -name "$1.jsonl" 2>/dev/null | head -1)
  [ -n "$f" ] && printf '%s' "$f"
}

_cof_session_owner() {  # $1 = transcript -> accountUuid on its last bridge-session record ("" = never bridged)
  grep '"type":"bridge-session"' -- "$1" 2>/dev/null | tail -1 | jq -r '.ownerAccountUuid // empty' 2>/dev/null
}

_cof_session_cwd() { grep -m1 -o '"cwd":"[^"]*"' -- "$1" 2>/dev/null | head -1 | cut -d'"' -f4; }

_cof_session_title() {  # $1 = transcript -> custom title, else AI title, else first prompt, else the id
  local t
  t=$(grep '"type":"custom-title"' -- "$1" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
  [ -n "$t" ] || t=$(grep '"type":"ai-title"' -- "$1" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)
  [ -n "$t" ] || t=$(grep '"type":"user"' -- "$1" 2>/dev/null | head -20 \
      | jq -r '.message.content | if type=="string" then . else (map(select(.type=="text") | .text) | join(" ")) end' 2>/dev/null \
      | grep -v '^<' | grep -m1 . | cut -c1-60)
  [ -n "$t" ] || t="session $(basename "$1" .jsonl | cut -c1-8)"
  printf '%s' "$t" | tr -d '\n\r\t' | cut -c1-80
}

_cof_api() {  # $1 = method, $2 = path on api.anthropic.com (claude.ai session API, primary's OAuth token) -> body
  local tok
  tok=$(_cof_token "$(_cof_primary_cred)"); [ -z "$tok" ] && return 1
  curl -sS -m 20 -X "$1" -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
       -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" "https://api.anthropic.com$2" 2>/dev/null
}

_cof_mirror_url() { printf 'https://claude.ai/code/session_%s' "${1#cse_}"; }
_cof_mlog() { mkdir -p "$CLAUDE_OVERFLOW_HOME"; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$CLAUDE_OVERFLOW_HOME/mirror.log"; }

_cof_mirror() {  # $1 = session id, [$2 = label for the title], [$3 = force] -> prints the claude.ai URL; 0 on success
  local id="$1" label="${2:-}" force="${3:-}" src cwd title owner puuid mid copy out short state cse n last tries prev
  src=$(_cof_transcript_for "$id") || { _cof_warn "mirror: no transcript found for $id"; _cof_mlog "$id: no transcript"; return 1; }
  puuid=$(_cof_primary_uuid)
  owner=$(_cof_session_owner "$src")
  if [ -z "$force" ]; then
    [ -z "$owner" ] && { _cof_dim "mirror: $id was never registered with claude.ai (Remote Control off?); nothing to mirror"; _cof_mlog "$id: skip, never bridged"; return 0; }
    [ "$owner" = "$puuid" ] && { _cof_dim "mirror: $id already belongs to the primary account"; _cof_mlog "$id: skip, primary-owned"; return 0; }
  fi
  grep -q '"type":"user"' -- "$src" || { _cof_mlog "$id: skip, no messages"; return 0; }
  [ -n "$label" ] || label=$(_cof_label_for_uuid "$owner")
  cwd=$(_cof_session_cwd "$src")
  [ -n "$cwd" ] && [ -d "$cwd" ] || { _cof_warn "mirror: the session's directory is gone ($cwd); skipping $id"; _cof_mlog "$id: skip, cwd missing ($cwd)"; return 1; }
  jq -e --arg p "$cwd" '.projects[$p].hasTrustDialogAccepted == true' "$(_cof_primary_state)" >/dev/null 2>&1 \
    || { _cof_warn "mirror: the primary account hasn't trusted $cwd (open it once with: cacct primary); skipping $id"; _cof_mlog "$id: skip, untrusted cwd $cwd"; return 1; }
  [ "$(_cof_cred_state "$(_cof_primary_cred)")" = "stale" ] && _cof_ping primary >/dev/null 2>&1
  title="$(_cof_session_title "$src") · via $label"
  mid=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]'); [ -n "$mid" ] || mid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  [ -n "$mid" ] || { _cof_warn "mirror: cannot generate a session id"; return 1; }
  copy="$(dirname "$src")/$mid.jsonl"
  # Clean copy under a fresh id: no bridge pointer (an owner mismatch would suppress the upload) and none of
  # the markers earlier cross-account resumes may have left behind.
  jq -c -R --arg m "$mid" 'fromjson? | select(type == "object")
      | select(.type != "bridge-session" and .type != "history-suppression" and .type != "atis-latch" and .type != "continued-in")
      | (if has("sessionId") then .sessionId = $m else . end) | (if has("session_id") then .session_id = $m else . end)' \
      "$src" > "$copy" 2>/dev/null
  [ -s "$copy" ] || { rm -f "$copy"; _cof_warn "mirror: could not build a copy of $src"; _cof_mlog "$id: copy failed"; return 1; }
  out=$( cd "$cwd" && _cof_run_in "" --bg --resume "$mid" --name "$title" --strict-mcp-config --settings '{"disableAllHooks":true}' 2>&1 )
  short=$(printf '%s' "$out" | grep -oE 'backgrounded · [0-9a-f]{8}' | grep -oE '[0-9a-f]{8}$')
  [ -n "$short" ] || { rm -f "$copy"; _cof_warn "mirror: background launch failed: $(printf '%s' "$out" | tail -1)"; _cof_mlog "$id: launch failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; return 1; }
  state="$CLAUDE_OVERFLOW_PRIMARY_DIR/jobs/$short/state.json"
  tries=0; cse=""   # wait for the claude.ai session to exist...
  while [ "$tries" -lt 30 ]; do cse=$(jq -r '.bridgeSessionId // empty' "$state" 2>/dev/null); [ -n "$cse" ] && break; sleep 1; tries=$((tries + 1)); done
  [ -n "$cse" ] || { _cof_run_in "" stop "$short" >/dev/null 2>&1; rm -f "$copy"; _cof_warn "mirror: claude.ai never registered the session (Remote Control disabled? offline?)"; _cof_mlog "$id: no claude.ai session after 30s (job $short)"; return 1; }
  last=-1; n=0; tries=0   # ...then for the backfill to settle (event count stops changing)
  while [ "$tries" -lt "$CLAUDE_OVERFLOW_MIRROR_TIMEOUT" ]; do
    sleep 3; tries=$((tries + 3))
    n=$(_cof_api GET "/v1/code/sessions/$cse/events?limit=200" | jq '.data | length' 2>/dev/null); n=${n:-0}
    [ "$n" -gt 0 ] && [ "$n" = "$last" ] && break
    last=$n
  done
  _cof_run_in "" stop "$short" >/dev/null 2>&1
  [ "$CLAUDE_OVERFLOW_MIRROR_CLEANUP" = "rm" ] && _cof_run_in "" rm "$short" >/dev/null 2>&1
  rm -f "$copy"
  if [ -s "$_COF_MIRRORS" ]; then   # this conversation's previous snapshot gets archived
    awk -F '\t' -v s="$id" '$1 == s {print $2}' "$_COF_MIRRORS" | while read -r prev; do
      [ -n "$prev" ] && [ "$prev" != "$cse" ] && _cof_api POST "/v1/code/sessions/$prev/archive" >/dev/null 2>&1
    done
    awk -F '\t' -v s="$id" '$1 != s' "$_COF_MIRRORS" > "$_COF_MIRRORS.tmp" && mv "$_COF_MIRRORS.tmp" "$_COF_MIRRORS"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$cse" "$label" "$(date '+%Y-%m-%dT%H:%M:%S')" "$title" >> "$_COF_MIRRORS"
  _cof_mlog "$id: mirrored -> $cse ($n events, job $short) $title"
  printf '%s\n' "$(_cof_mirror_url "$cse")"
}

_cof_mirror_wanted() {  # $@ = claude args -> 0 when this launch is an interactive, persisted session
  [ "$CLAUDE_OVERFLOW_MIRROR" = "1" ] && _cof_interactive || return 1
  local a
  for a in "$@"; do
    case "$a" in -p|--print|--bg|--background|--no-session-persistence|-v|--version|-h|--help|--cloud|--cloud=*) return 1 ;; esac
  done
  return 0
}

_cof_mirror_after() {  # $1 = launch time (ms), $2 = label: mirror every conversation that got prompts during the run (background)
  local t0="$1" label="$2" ids
  ids=$(tail -n 3000 "$CLAUDE_OVERFLOW_PRIMARY_DIR/history.jsonl" 2>/dev/null \
        | jq -r -R --argjson t0 "$t0" 'fromjson? | select((.timestamp // 0) >= $t0) | .sessionId // empty' 2>/dev/null | awk '!seen[$0]++')
  [ -n "$ids" ] || return 0
  _cof_dim "→ mirroring this conversation into the primary account's claude.ai in the background (log: $CLAUDE_OVERFLOW_HOME/mirror.log)"
  ( ( printf '%s\n' "$ids" | while read -r id; do
        [ -n "$id" ] || continue
        url=$(_cof_mirror "$id" "$label" 2>>"$CLAUDE_OVERFLOW_HOME/mirror.log") && [ -n "$url" ] \
          && _cof_notify "Claude overflow: mirrored to claude.ai" "$url"
      done ) >/dev/null 2>&1 & )
}

# ---------- in-session switching: move a live conversation to another account ----------
# A session is bound to one account, so "switching mid-conversation" means: end the
# current session cleanly and re-launch `--resume <same-session-id>` under another
# account. The transcript (project dir) is shared across profiles, so the resumed
# session has the full conversation. The observation of "the account just ran out"
# comes from a Stop / StopFailure hook injected into the managed session (see
# cof-insession-hook.sh); the hook writes a switch request and ends the session, and
# the loop below picks the next account and resumes. StopFailure(rate_limit) is the
# "hit the wall this turn" trigger; Stop over CLAUDE_OVERFLOW_INSESSION_AT is the
# "buffer finished the turn, hop before the next one" trigger. If nothing has
# headroom the hook pauses instead (leaves the session up), so the conversation is
# never lost.

_cof_insession_hook_path() { printf '%s/cof-insession-hook.sh' "$CLAUDE_OVERFLOW_HOME"; }

_cof_session_launch() {  # $@ = claude args -> 0 when this is an interactive, persisted, non-subcommand session launch
  _cof_interactive || return 1
  local a
  for a in "$@"; do
    case "$a" in -p|--print|--bg|--background|--no-session-persistence|-v|--version|-h|--help|--cloud|--cloud=*) return 1 ;; esac
  done
  for a in "$@"; do   # first non-flag arg: skip subcommands
    case "$a" in -*) continue ;; esac
    _cof_is_subcommand "$a" && return 1
    break
  done
  return 0
}

# Subcommands are read from `claude --help` (Commands:, incl. a|b aliases) and cached per binary, so new
# ones are picked up on upgrade. --help omits some (remote-control and its alias rc), so those are always added;
# the fallback list is used only when the help can't be read or parsed.
_COF_SUBCMDS_HIDDEN="config diagnose migrate-installer remote-control rc resume-tool"
_COF_SUBCMDS_FALLBACK="mcp auth doctor plugin plugins setup-token install update upgrade auto-mode agents attach logs rm stop kill respawn gateway import project ultrareview"
_COF_SUBCMDS_MAX_AGE=86400   # re-parse at least daily even if the binary key looks unchanged

_cof_claude_bin_key() {  # every claude executable on PATH, symlinks resolved, with mtimes: changes on upgrade even when
  # a wrapper script shadows the real binary (the native installer re-points ~/.local/bin/claude at versions/<ver>)
  local p r out=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    r=$(readlink -f "$p" 2>/dev/null) || r="$p"
    out="$out$r:$(_cof_mtime "$r") "
  done <<EOF_BINS
$(_cof_claude_paths | sort -u)
EOF_BINS
  [ -n "$out" ] && printf '%s' "$out"
}

_cof_load_subcommands() {  # sets $_COF_SUBCMDS (space-separated); memoized in the shell for 5 min, cached on disk per binary
  # call directly, not via $(...), or the memo is lost with the subshell
  [ -n "${_COF_SUBCMDS:-}" ] && [ $(( SECONDS - ${_COF_SUBCMDS_AT:-0} )) -lt 300 ] && return 0
  local f="$_COF_CACHE/subcommands" key k="" l="" parsed
  key=$(_cof_claude_bin_key)
  [ -f "$f" ] && { IFS= read -r k; IFS= read -r l; } < "$f"
  if [ -z "$key" ] || [ "$k" != "$key" ] || [ -z "$l" ] || [ $(( $(date +%s) - $(_cof_mtime "$f") )) -gt "$_COF_SUBCMDS_MAX_AGE" ]; then
    [ -n "${_COF_BIN:-}" ] || _cof_bin >/dev/null
    parsed=$("$_COF_BIN" --help </dev/null 2>/dev/null \
             | awk '/^Commands:/{on=1;next} on && /^  [a-z]/{n=split($1,a,"|"); for(i=1;i<=n;i++) printf "%s ", a[i]}')
    if [ -n "$parsed" ]; then
      l="$parsed"
      [ -n "$key" ] && mkdir -p "$_COF_CACHE" && printf '%s\n%s\n' "$key" "$l" > "$f"
    elif [ -z "$l" ]; then
      l="$_COF_SUBCMDS_FALLBACK"
    fi
  fi
  _COF_SUBCMDS="$l $_COF_SUBCMDS_HIDDEN"; _COF_SUBCMDS_AT=$SECONDS
}

_cof_is_subcommand() {  # $1 = first non-flag claude arg -> 0 when it is a subcommand (never a session launch; must not get --settings)
  case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac   # prompts/paths ("fix the bug", ./dir) are never subcommands
  _cof_load_subcommands
  case " $_COF_SUBCMDS " in *" $1 "*) return 0 ;; esac
  return 1
}

_cof_insession_wanted() {  # $@ = claude args -> 0 when this launch should be managed (in-session switching)
  [ "$CLAUDE_OVERFLOW_INSESSION" = "1" ] || return 1
  [ -s "$_COF_ACCOUNTS" ] || return 1
  [ -f "$(_cof_insession_hook_path)" ] || return 1
  _cof_session_launch "$@"
}

_cof_insession_settings() {  # JSON string for --settings that adds the switch hook (merges with the user's settings)
  # 60 s: the hook may refresh a stale token (a ~1-5 s ping) before it can pick; sign-ins it starts are detached.
  local h; h=$(_cof_insession_hook_path)
  printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash %s Stop","timeout":60}]}],"StopFailure":[{"matcher":"","hooks":[{"type":"command","command":"bash %s StopFailure","timeout":60}]}]}}' "$h" "$h"
}

_cof_launch_managed() {  # $1 label, $2 dir, $3 ctrl dir, rest = full claude args (incl injected --settings)
  # Runs claude in the foreground while recording its pid (the sh execs into claude, so
  # $$ is claude's pid) so the switch hook knows which process to end.
  local label="$1" dir="$2" ctrl="$3"; shift 3
  local bin; bin=$(_cof_bin)
  : > "$ctrl/pid"
  if [ "$dir" = "$HOME/.claude" ] || [ -z "$dir" ]; then
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE -u CLAUDE_CONFIG_DIR \
      COF_MANAGED=1 COF_CTRL_DIR="$ctrl" COF_ACCOUNT="$label" COF_PIDFILE="$ctrl/pid" \
      COF_LOADER="$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" CLAUDE_OVERFLOW_HOME="$CLAUDE_OVERFLOW_HOME" \
      sh -c 'echo $$ > "$COF_PIDFILE"; exec "$0" "$@"' "$bin" "$@"
  else
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u COF_SHIM_ACTIVE CLAUDE_CONFIG_DIR="$dir" \
      COF_MANAGED=1 COF_CTRL_DIR="$ctrl" COF_ACCOUNT="$label" COF_PIDFILE="$ctrl/pid" \
      COF_LOADER="$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" CLAUDE_OVERFLOW_HOME="$CLAUDE_OVERFLOW_HOME" \
      sh -c 'echo $$ > "$COF_PIDFILE"; exec "$0" "$@"' "$bin" "$@"
  fi
}

_cof_run_managed() {  # $1 label, $2 dir, rest = original claude args. Loops across accounts on limit.
  local label="$1" dir="$2"; shift 2
  local ctrl rc target sid reason ndir hooks t0 a prev="" first=1
  ctrl=$(mktemp -d "${TMPDIR:-/tmp}/cof.XXXXXX") || { _cof_run_in "$dir" "$@"; return $?; }
  hooks=$(_cof_insession_settings)
  set -- "$@"
  local -a orig keep
  orig=("$@")
  # Launch flags that must survive a relaunch (hop or /restart): permission mode (`cf` =
  # --dangerously-skip-permissions), model, effort, extra trusted dirs, MCP config, plugins.
  # Session-picking flags (--resume/--continue/--session-id/...) and the initial prompt are dropped.
  for a in "$@"; do
    case "$prev" in
      multi) case "$a" in -*) prev="" ;; *) keep+=("$a"); continue ;; esac ;;   # variadic values run to the next flag
      one) keep+=("$a"); prev=""; continue ;;
    esac
    case "$a" in
      --add-dir|--mcp-config) keep+=("$a"); prev=multi ;;
      --permission-mode|--model|--effort|--agent|--plugin-dir|--append-system-prompt) keep+=("$a"); prev=one ;;
      --add-dir=*|--mcp-config=*|--permission-mode=*|--model=*|--effort=*|--agent=*|--plugin-dir=*|--append-system-prompt=*) keep+=("$a") ;;
      --dangerously-skip-permissions|--allow-dangerously-skip-permissions|--strict-mcp-config|--chrome|--no-chrome|--ide) keep+=("$a") ;;
    esac
  done
  t0=$(_cof_now_ms)
  while :; do
    : > "$ctrl/switch"; : > "$ctrl/paused"
    if [ "$first" = "1" ]; then
      _cof_launch_managed "$label" "$dir" "$ctrl" "${orig[@]}" --settings "$hooks"; rc=$?
      first=0
    else
      _cof_launch_managed "$label" "$dir" "$ctrl" --resume "$sid" "${keep[@]}" --settings "$hooks"; rc=$?
    fi
    [ -s "$ctrl/switch" ] || break
    target=$(sed -n 1p "$ctrl/switch" 2>/dev/null)
    sid=$(sed -n 2p "$ctrl/switch" 2>/dev/null)
    reason=$(sed -n 3p "$ctrl/switch" 2>/dev/null)
    [ -n "$sid" ] || sid=$(tail -n 1 "$CLAUDE_OVERFLOW_PRIMARY_DIR/history.jsonl" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null)
    [ -n "$target" ] && [ -n "$sid" ] || break
    if [ "$target" = "primary" ]; then
      ndir="$CLAUDE_OVERFLOW_PRIMARY_DIR"
    else
      ndir=$(_cof_dir_for "$target") || break
      [ -d "$ndir" ] || break
      [ "$(_cof_ensure_fresh "$target")" = "dead" ] && { _cof_warn "in-session switch: \"$target\" needs sign-in; staying on \"$label\""; break; }
      _cof_sync "$ndir"
    fi
    _cof_mark "$target"
    if [ "$reason" = "restart" ]; then   # /restart (cof-restart.sh): same account, not a hop
      _cof_dim "↻ restarting Claude Code and resuming this conversation…"
    else
      _cof_dim "→ \"$label\" ran out; moving this conversation to \"$target\" ($reason) and resuming…"
      _cof_notify "Claude overflow: switched to $target" "$reason"
    fi
    label="$target"; dir="$ndir"
  done
  _cof_mirror_wanted "${orig[@]}" && _cof_mirror_after "$t0" "$label"
  rm -rf "$ctrl" 2>/dev/null
  return $rc
}

# ---------- user-facing commands ----------
# Some hosts (notably Claude Code's own Bash tool) replay a snapshot of the interactive shell
# that keeps public functions but drops the _cof_* helpers. In that case degrade to plain primary.

cacct() {  # launch a specific account: cacct <label|primary> [claude args...]
  if ! type _cof_run_in >/dev/null 2>&1; then
    # stripped shell (e.g. Claude Code's Bash-tool snapshot keeps cacct but not the _cof_* helpers): hand off to
    # claude-on, which loads the router. Without it primary is safe to run plainly (a `claude` found on PATH could
    # be claude-shim, which would re-pick the account), but a named overflow account must never silently run on primary.
    if command -v claude-on >/dev/null 2>&1; then [ $# -gt 0 ] || set -- primary; claude-on "$@"; return $?; fi
    if [ "${1:-primary}" = "primary" ]; then shift 2>/dev/null; env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR command claude "$@"; return $?; fi
    printf 'cacct: router helpers not loaded in this shell; run: bash -c %s\n' "'. ~/.claude-overflow/claude-overflow.sh; cacct $1 ...'" >&2; return 1
  fi
  local label="$1" dir cred st t0 rc
  shift 2>/dev/null || { printf 'usage: cacct <label|primary> [args...]\n' >&2; return 2; }
  if [ "$label" = "primary" ]; then
    _cof_mark primary
    # a session is starting: any signed-out overflow account gets its sign-in window now (background, cooldown-limited)
    _cof_session_launch "$@" && [ -s "$_COF_ACCOUNTS" ] && _cof_login_dead_bg launch primary
    if _cof_insession_wanted "$@"; then _cof_run_managed "primary" "$CLAUDE_OVERFLOW_PRIMARY_DIR" "$@"; return $?; fi
    _cof_run_in "" "$@"; return $?
  fi
  dir=$(_cof_dir_for "$label") || { printf 'cacct: unknown account "%s" (see %s)\n' "$label" "$_COF_ACCOUNTS" >&2; return 1; }
  [ -d "$dir" ] || { printf 'cacct: profile dir %s missing (claude-overflow add %s ...)\n' "$dir" "$label" >&2; return 1; }
  cred=$(_cof_cred_of "$label")
  st=$(_cof_cred_state "$cred")
  if [ "$st" = "dead" ]; then
    if _cof_interactive && [ "$CLAUDE_OVERFLOW_AUTOLOGIN" != "0" ]; then _cof_login "$label" || return 1
    else printf 'cacct: account "%s" needs sign-in: claude-overflow login %s\n' "$label" "$label" >&2; return 1; fi
  fi
  _cof_sync "$dir"
  _cof_mark "$label"
  _cof_session_launch "$@" && _cof_login_dead_bg launch "$label"
  if _cof_insession_wanted "$@"; then _cof_run_managed "$label" "$dir" "$@"; return $?; fi
  t0=$(_cof_now_ms)
  _cof_run_in "$dir" "$@"; rc=$?
  _cof_mirror_wanted "$@" && _cof_mirror_after "$t0" "$label"
  return $rc
}

claude() {  # auto-picking wrapper; inert (plain primary) until accounts.tsv exists
  type _cof_run_in >/dev/null 2>&1 || { env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR command claude "$@"; return $?; }
  local a pick
  if [ -n "${CLAUDE_ACCOUNT:-}" ]; then cacct "$CLAUDE_ACCOUNT" "$@"; return $?; fi
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    if _cof_is_subcommand "$a"; then
      # `auth` acts on the profile an explicit CLAUDE_CONFIG_DIR names (`CLAUDE_CONFIG_DIR=<dir> claude auth logout`
      # must never log out the primary); every other subcommand runs on primary
      if [ "$a" = "auth" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then _cof_run_in "$CLAUDE_CONFIG_DIR" "$@"; return $?; fi
      cacct primary "$@"; return $?
    fi
    break  # first non-flag arg is a prompt/path, not a subcommand
  done
  if [ ! -s "$_COF_ACCOUNTS" ]; then cacct primary "$@"; return $?; fi
  pick=$(_cof_resolve "")
  cacct "$pick" "$@"
}

cswap() {  # continue the latest conversation on a DIFFERENT account
  type _cof_run_in >/dev/null 2>&1 || { printf 'cswap: router helpers not loaded in this shell\n' >&2; return 1; }
  local last pick
  last=$(cat "$_COF_CACHE/last" 2>/dev/null || echo primary)
  pick=$(_cof_resolve "$last")
  if [ "$pick" = "$last" ]; then
    [ "$last" = "primary" ] && { printf 'cswap: no other account available\n' >&2; return 1; }
    pick=primary
  fi
  _cof_dim "→ continuing on \"$pick\""
  cacct "$pick" --continue "$@"
}

climits() {  # all accounts' limit windows + extra-usage spend + credential state
  type _cof_run_in >/dev/null 2>&1 || { printf 'climits: router helpers not loaded in this shell (source %s)\n' "$HOME/.claude-overflow/claude-overflow.sh" >&2; return 1; }
  local label dir cred email st
  _cof_show_one "primary" "$(_cof_primary_cred)" primary ""
  if [ -s "$_COF_ACCOUNTS" ]; then
    while IFS="$_COF_TAB" read -r label dir cred email; do
      [ -z "$label" ] && continue
      st=$(_cof_ensure_fresh "$label")
      if [ "$st" = "dead" ]; then
        if _cof_login_inflight "$label"; then
          printf '%-26s NEEDS SIGN-IN%s   a sign-in window is open for it right now\n' "$label" "${email:+ ($email)}"
        else
          printf '%-26s NEEDS SIGN-IN%s   opens by itself at your next launch; now: claude-overflow login %s\n' "$label" "${email:+ ($email)}" "$label"
        fi
        continue
      fi
      _cof_show_one "$label" "$(_cof_cred_of "$label")" "$label" "$email"
    done < "$_COF_ACCOUNTS"
  else
    printf '%-26s %s\n' "(overflow)" "none configured: claude-overflow add <label> <email>"
  fi
}

_cof_show_one() {  # $1 label, $2 cred source, $3 cache key, $4 email
  local json s w sc rs rw extra name="$1"
  [ -n "$4" ] && name="$1 ($4)"
  if ! json=$(_cof_fetch "$2" "$3" fresh); then
    printf '%-26s %s\n' "$name" "usage unreadable right now (token stale, network, or keychain); launching will renew it"
    return
  fi
  read -r s w sc <<EOF
$(printf '%s' "$json" | _cof_pcts)
EOF
  : "${s:=0}" "${w:=0}" "${sc:=0}"
  rs=$(printf '%s' "$json" | jq -r '.five_hour.resets_at // empty' \
       | jq -Rr 'select(length>0) | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdate | strflocaltime("%a %H:%M")' 2>/dev/null)
  rw=$(printf '%s' "$json" | jq -r '.seven_day.resets_at // empty' \
       | jq -Rr 'select(length>0) | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdate | strflocaltime("%a %H:%M")' 2>/dev/null)
  printf '%-26s 5h %3s%% (resets %s)   week %3s%% (resets %s)   model-wk %3s%%\n' \
    "$name" "$s" "${rs:-?}" "$w" "${rw:-?}" "$sc"
  extra=$(printf '%s' "$json" | jq -r '.extra_usage | select(.is_enabled==true) | "extra usage: \(.used_credits/100 | floor)/\(.monthly_limit/100) \(.currency) (\(.utilization|round)%)"' 2>/dev/null)
  [ -n "$extra" ] && printf '%-26s %s\n' "" "$extra"
}

# ---------- claude-overflow CLI ----------
_cof_add() {  # add <label> [email] [dir]: build/adopt a profile, register it, sign in if interactive
  local label="$1" email="${2:-}" dir="${3:-}" cred p_email
  case "$label" in
    primary|login|all) _cof_warn "'$label' is reserved."; return 1 ;;   # login/all: _cof_pick's sentinel and `login all`
    *[!a-zA-Z0-9_-]*|"") _cof_warn "label: letters/digits/_/- only."; return 1 ;;
  esac
  [ -n "$dir" ] || dir="$CLAUDE_OVERFLOW_HOME/profiles/$label"
  case "$dir" in "~"*) dir="$HOME${dir#"~"}" ;; esac
  dir=${dir%/}
  p_email=$(jq -r '.oauthAccount.emailAddress // empty' "$(_cof_primary_state)" 2>/dev/null)
  if [ -n "$email" ] && [ "$(_cof_lc "$email")" = "$(_cof_lc "$p_email")" ]; then
    _cof_warn "$email is the primary account; overflow accounts must be different subscriptions."; return 1
  fi
  mkdir -p "$dir" "$CLAUDE_OVERFLOW_HOME/profiles" "$_COF_CACHE"
  _cof_link_farm "$dir"
  _cof_seed_state "$dir"
  cred=$(_cof_cred_for_dir "$dir")
  _cof_put_row "$label" "$dir" "$cred" "$email"
  touch "$CLAUDE_OVERFLOW_HOME/aliases.sh"
  if ! awk -v a="alias c-$label=" 'index($0, a) == 1 {f=1} END {exit !f}' "$CLAUDE_OVERFLOW_HOME/aliases.sh"; then
    printf "alias c-%s='cacct %s'\n" "$label" "$label" >> "$CLAUDE_OVERFLOW_HOME/aliases.sh"
  fi
  alias "c-$label=cacct $label"
  printf 'Registered "%s"%s\n  profile: %s\n  creds:   %s\n  alias:   c-%s\n' "$label" "${email:+ ($email)}" "$dir" "$cred" "$label"
  if [ "$(_cof_cred_state "$cred")" = "dead" ]; then
    if _cof_interactive; then _cof_login "$label"
    else printf '  not signed in yet: run  claude-overflow login %s\n' "$label"; fi
  else
    printf '  already signed in.\n'
  fi
}

_cof_keepalive() {  # scheduled: renew stale tokens; for dead accounts open the sign-in (if you're at the keyboard) or notify once/24h
  local label dir cred email st log="$CLAUDE_OVERFLOW_HOME/keepalive.log" marker
  mkdir -p "$_COF_CACHE"
  _log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log"; }
  [ -s "$_COF_ACCOUNTS" ] || { _log "no overflow accounts"; return 0; }
  while IFS="$_COF_TAB" read -r label dir cred email; do
    [ -z "$label" ] && continue
    cred=$(_cof_cred_of "$label")
    st=$(_cof_cred_state "$cred")
    case "$st" in
      ok)    _log "$label: ok" ;;
      stale) if _cof_ping "$label" || { sleep 20; _cof_ping "$label"; }; then _log "$label: refreshed"   # one retry: a wake-from-sleep run can beat the network
             else _log "$label: refresh ping failed ($(head -c 200 "$_COF_CACHE/ping-$label.err" 2>/dev/null | tr '\n' ' '))"; fi
             [ "$(_cof_cred_state "$cred")" = "dead" ] && st=dead ;;
    esac
    if [ "$st" = "dead" ]; then
      if _cof_login_inflight "$label"; then
        _log "$label: NEEDS SIGN-IN (a sign-in window is already open)"
      elif [ "$CLAUDE_OVERFLOW_AUTOLOGIN" != "0" ] && _cof_user_present && _cof_login_bg "$label" keepalive; then
        _log "$label: NEEDS SIGN-IN -> opened the sign-in window (you're at the keyboard)"
      else
        _log "$label: NEEDS SIGN-IN (claude-overflow login $label)"
        marker="$_COF_CACHE/.notified-$label"
        if [ ! -f "$marker" ] || [ $(( $(date +%s) - $(_cof_mtime "$marker") )) -gt 86400 ]; then
          _cof_notify "Claude overflow: $label needs sign-in" "A sign-in window opens by itself at your next claude launch (or run: claude-overflow login $label)."
          touch "$marker"
        fi
      fi
    fi
  done < "$_COF_ACCOUNTS"
}

_cof_install_keepalive() {  # macOS LaunchAgent (Linux: prints a crontab line)
  local loader="$CLAUDE_OVERFLOW_HOME/claude-overflow.sh" plist secs
  [ -f "$loader" ] || { _cof_warn "loader not found at $loader (run setup.sh first)"; return 1; }
  secs=$(( CLAUDE_OVERFLOW_KEEPALIVE_HOURS * 3600 ))
  if [ "$(_cof_os)" != "Darwin" ]; then
    printf 'Add to crontab -e:\n0 */%s * * * bash -lc '"'"'. "%s" && claude-overflow keepalive'"'"'\n' "$CLAUDE_OVERFLOW_KEEPALIVE_HOURS" "$loader"
    return 0
  fi
  plist="$HOME/Library/LaunchAgents/$_COF_LAUNCHD_LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$_COF_LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>. "$loader" &amp;&amp; claude-overflow keepalive</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key><string>$HOME</string>
        <key>CLAUDE_OVERFLOW_HOME</key><string>$CLAUDE_OVERFLOW_HOME</string>
    </dict>
    <key>StartInterval</key><integer>$secs</integer>
    <key>RunAtLoad</key><true/>
    <key>AbandonProcessGroup</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/claude-overflow-keepalive.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/claude-overflow-keepalive.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$plist" && printf 'Keep-alive installed: every %sh via launchd (%s)\nLog: %s\n' "$CLAUDE_OVERFLOW_KEEPALIVE_HOURS" "$plist" "$CLAUDE_OVERFLOW_HOME/keepalive.log"
}

_cof_uninstall_keepalive() {
  local plist="$HOME/Library/LaunchAgents/$_COF_LAUNCHD_LABEL.plist"
  [ "$(_cof_os)" = "Darwin" ] || { printf 'Remove the crontab line you added.\n'; return 0; }
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1
  rm -f "$plist" && printf 'Keep-alive removed.\n'
}

claude-overflow() {
  type _cof_run_in >/dev/null 2>&1 || { printf 'claude-overflow: router helpers not loaded in this shell (source %s)\n' "$HOME/.claude-overflow/claude-overflow.sh" >&2; return 1; }
  local label dir cred email st id url p
  case "${1:-help}" in
    status) climits ;;
    dashboard) command -v python3 >/dev/null 2>&1 || { printf 'claude-overflow dashboard: needs python3\n' >&2; return 1; }
               python3 "$CLAUDE_OVERFLOW_HOME/cof-dashboard.py" ;;
    login)   [ -n "${2:-}" ] || { printf 'usage: claude-overflow login <label|primary|all>\n' >&2; return 2; }
             if [ "$2" = "all" ]; then   # every signed-out account, one after the other
               st=$(_cof_dead_labels)
               [ -n "$st" ] || { printf 'all accounts are signed in\n'; return 0; }
               for label in $st; do _cof_login "$label" || printf '%s: not signed in\n' "$label" >&2; done
             else _cof_login "$2"; fi ;;
    refresh) if [ -n "${2:-}" ]; then _cof_ping "$2" && printf '%s: %s\n' "$2" "$(_cof_cred_state "$(_cof_cred_of "$2")")"
             else while IFS="$_COF_TAB" read -r label dir cred email; do
                    [ -z "$label" ] && continue; _cof_ping "$label" >/dev/null 2>&1; printf '%s: %s\n' "$label" "$(_cof_cred_state "$(_cof_cred_of "$label")")"
                  done < "$_COF_ACCOUNTS" 2>/dev/null; fi ;;
    keepalive) _cof_keepalive ;;
    install-keepalive)   _cof_install_keepalive ;;
    uninstall-keepalive) _cof_uninstall_keepalive ;;
    add)    shift; _cof_add "$@" ;;
    remove) [ -n "${2:-}" ] || { printf 'usage: claude-overflow remove <label>\n' >&2; return 2; }
            dir=$(_cof_dir_for "$2") || { printf 'unknown account "%s"\n' "$2" >&2; return 1; }
            awk -F '\t' -v l="$2" '$1 != l' "$_COF_ACCOUNTS" > "$_COF_ACCOUNTS.tmp" && mv "$_COF_ACCOUNTS.tmp" "$_COF_ACCOUNTS"
            awk -v a="alias c-$2=" 'index($0, a) != 1' "$CLAUDE_OVERFLOW_HOME/aliases.sh" > "$CLAUDE_OVERFLOW_HOME/aliases.sh.tmp" 2>/dev/null \
              && mv "$CLAUDE_OVERFLOW_HOME/aliases.sh.tmp" "$CLAUDE_OVERFLOW_HOME/aliases.sh"
            printf 'Removed "%s" from the router. Its profile dir is untouched: %s\n(log it out first if you want: CLAUDE_CONFIG_DIR=%s claude auth logout)\n' "$2" "$dir" "$dir" ;;
    sync)
      while IFS="$_COF_TAB" read -r label dir cred email; do
        [ -n "$dir" ] && rm -f "$_COF_CACHE/.sync-$(basename "$dir")" && _cof_sync "$dir" && printf 'synced %s\n' "$label"
      done < "$_COF_ACCOUNTS" 2>/dev/null ;;
    mirror)
      [ -n "${2:-}" ] || { printf 'usage: claude-overflow mirror <session-id|last> [--force]\n' >&2; return 2; }
      id="$2"
      [ "$id" = "last" ] && id=$(tail -n 1 "$CLAUDE_OVERFLOW_PRIMARY_DIR/history.jsonl" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null)
      [ -n "$id" ] || { printf 'mirror: no session id\n' >&2; return 1; }
      [ "${3:-}" = "--force" ] && st=1 || st=""
      url=$(_cof_mirror "$id" "" "$st") || return 1
      [ -n "$url" ] && printf 'mirrored → %s\n' "$url" ;;
    mirrors)
      if [ -s "$_COF_MIRRORS" ]; then
        awk -F '\t' '{printf "%s  %-8s  %s  https://claude.ai/code/session_%s  %s\n", $4, $3, $1, substr($2, 5), $5}' "$_COF_MIRRORS"
      else printf 'no mirrors yet (automatic after overflow sessions; manual: claude-overflow mirror <session-id|last>)\n'; fi ;;
    doctor)
      command -v claude >/dev/null || printf '!! claude not on PATH\n'
      command -v jq >/dev/null || printf '!! jq not installed\n'
      printf 'claude binary: %s\n' "$(_cof_bin)"
      if [ -x "$CLAUDE_OVERFLOW_HOME/shim/claude" ]; then
        p=$(_cof_claude_paths | head -1)
        if [ "$p" = "$CLAUDE_OVERFLOW_HOME/shim/claude" ]; then printf 'claude-shim: on (programs that run `claude` go through the router)\n'
        else printf '!! claude-shim: installed, but %s comes first on PATH (something after the loader in your shell rc reorders PATH)\n' "$p"; fi
      else printf 'claude-shim: off (scripts and subprocesses run the plain binary; setup.sh offers it)\n'; fi
      if [ -s "$_COF_ACCOUNTS" ]; then
        printf 'accounts (label, dir, credential store, email, state):\n'
        while IFS="$_COF_TAB" read -r label dir cred email; do
          [ -z "$label" ] && continue
          cred=$(_cof_cred_of "$label")
          printf '  %-10s %-40s %-36s %-28s %s%s\n' "$label" "$dir" "$cred" "${email:--}" "$(_cof_cred_state "$cred")" "$(_cof_login_inflight "$label" && printf ' (sign-in window open)')"
        done < "$_COF_ACCOUNTS"
      else printf 'no overflow accounts configured\n'; fi
      [ "$(_cof_os)" = "Darwin" ] && { launchctl print "gui/$(id -u)/$_COF_LAUNCHD_LABEL" >/dev/null 2>&1 && printf 'keep-alive: installed (launchd)\n' || printf 'keep-alive: not installed (claude-overflow install-keepalive)\n'; }
      case "$CLAUDE_OVERFLOW_AUTOLOGIN" in
        0)   printf 'auto sign-in: off (CLAUDE_OVERFLOW_AUTOLOGIN=0; dead accounts are only reported)\n' ;;
        ask) printf 'auto sign-in: ask (prompts [Y/n] when a launch needs a signed-out account)\n' ;;
        *)   printf 'auto sign-in: on (window opens by itself: at launch, mid-conversation, keep-alive when present; retry every %sh; log %s/login.log)\n' "$CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS" "$CLAUDE_OVERFLOW_HOME" ;;
      esac
      if [ "$CLAUDE_OVERFLOW_INSESSION" = "1" ]; then
        if [ -f "$(_cof_insession_hook_path)" ]; then
          printf 'in-session switch: on (hop at %s%%%s; hook %s)\n' "$CLAUDE_OVERFLOW_INSESSION_AT" "$([ "$CLAUDE_OVERFLOW_INSESSION_PROACTIVE" = 1 ] || printf ', wall only')" "$(_cof_insession_hook_path)"
        else
          printf '!! in-session switch: enabled but hook missing at %s (re-run setup.sh)\n' "$(_cof_insession_hook_path)"
        fi
      else printf 'in-session switch: off (CLAUDE_OVERFLOW_INSESSION=0)\n'; fi
      climits ;;
    *) cat <<'EOF'
claude-overflow: multi-account Claude Max routing
  status                       every account's limits + credential state (same as climits)
  dashboard                    live HTML dashboard (usage, burn rate, hops, sessions, health) in your browser
  login <label|primary|all>    browser sign-in for one profile (email pre-filled, private window); all = every signed-out one
  refresh [label]              renew stale tokens now via a 1-token ping
  keepalive                    what the scheduled job runs: refresh stale; dead -> open the sign-in if you're
                               at the keyboard, else notify once a day
  install-keepalive            schedule keepalive (macOS launchd; Linux prints a cron line)
  uninstall-keepalive
  add <label> [email] [dir]    create/adopt a profile, register it, sign in
  remove <label>               unregister (profile dir kept)
  mirror <session-id|last>     snapshot a conversation into the primary account's claude.ai
                               (automatic after every overflow session; --force to redo a primary-owned one)
  mirrors                      list the snapshots made so far
  sync | doctor
commands: claude (auto-picks), cacct <label|primary>, cswap, climits
in-session: a managed conversation moves itself to another account when the current
  one hits its limit (StopFailure/rate_limit) or, with a little buffer left, at the
  next clean turn boundary (>= CLAUDE_OVERFLOW_INSESSION_AT, default 95%); if nothing
  has headroom it pauses instead. Toggle: CLAUDE_OVERFLOW_INSESSION=0 (off),
  CLAUDE_OVERFLOW_INSESSION_PROACTIVE=0 (only switch when the wall is actually hit).
sign-in: a signed-out account gets its browser sign-in opened for you whenever that could
  unlock usage: synchronously when a launch needs it now; in the background when a session
  starts, when a paused conversation is waiting on it (it moves there once you finish), or
  from the keep-alive while you're at the keyboard. CLAUDE_OVERFLOW_AUTOLOGIN=1|ask|0,
  CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS=8 (proactive re-open cadence), log: login.log
EOF
    ;;
  esac
}
