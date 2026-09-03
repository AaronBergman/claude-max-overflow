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
#   through Claude Code's normal browser OAuth with the email pre-filled, when you
#   are at an interactive shell and actually need that account.

# ---------- config (override via env or $CLAUDE_OVERFLOW_HOME/config.sh) ----------
CLAUDE_OVERFLOW_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
CLAUDE_OVERFLOW_PRIMARY_DIR="${CLAUDE_OVERFLOW_PRIMARY_DIR:-$HOME/.claude}"
CLAUDE_OVERFLOW_SESSION_AT="${CLAUDE_OVERFLOW_SESSION_AT:-85}"   # switch when 5h window >= %
CLAUDE_OVERFLOW_WEEKLY_AT="${CLAUDE_OVERFLOW_WEEKLY_AT:-92}"     # ...or weekly >= %
CLAUDE_OVERFLOW_SCOPED_AT="${CLAUDE_OVERFLOW_SCOPED_AT:-92}"     # ...or model-scoped weekly >= %
CLAUDE_OVERFLOW_FULL_AT="${CLAUDE_OVERFLOW_FULL_AT:-97}"         # an account counts as exhausted at %
CLAUDE_OVERFLOW_TTL="${CLAUDE_OVERFLOW_TTL:-60}"                 # usage-check cache seconds
CLAUDE_OVERFLOW_AUTOREFRESH="${CLAUDE_OVERFLOW_AUTOREFRESH:-1}"  # 1: refresh stale tokens inline (a 1-token ping)
CLAUDE_OVERFLOW_AUTOLOGIN="${CLAUDE_OVERFLOW_AUTOLOGIN:-1}"      # 1: offer browser re-login for dead accounts (interactive shells only)
CLAUDE_OVERFLOW_LOGIN_BROWSER="${CLAUDE_OVERFLOW_LOGIN_BROWSER:-private}"  # private | default | "<cmd with {url}>"
CLAUDE_OVERFLOW_PING_MODEL="${CLAUDE_OVERFLOW_PING_MODEL:-haiku}"  # model for the refresh ping (cheapest available)
CLAUDE_OVERFLOW_PING_TIMEOUT="${CLAUDE_OVERFLOW_PING_TIMEOUT:-60}" # seconds
CLAUDE_OVERFLOW_KEEPALIVE_HOURS="${CLAUDE_OVERFLOW_KEEPALIVE_HOURS:-12}"  # scheduled refresh cadence
[ -f "$CLAUDE_OVERFLOW_HOME/config.sh" ] && . "$CLAUDE_OVERFLOW_HOME/config.sh"
[ -f "$CLAUDE_OVERFLOW_HOME/aliases.sh" ] && . "$CLAUDE_OVERFLOW_HOME/aliases.sh"

_COF_ACCOUNTS="$CLAUDE_OVERFLOW_HOME/accounts.tsv"   # label<TAB>config_dir<TAB>cred_source[<TAB>email]
_COF_CACHE="$CLAUDE_OVERFLOW_HOME/cache"
_COF_TAB="$(printf '\t')"
_COF_LAUNCHD_LABEL="com.claude-max-overflow.keepalive"

# ---------- small utilities ----------
_cof_os() { uname; }
_cof_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
_cof_now_ms() { printf '%s000' "$(date +%s)"; }
_cof_interactive() { [ -t 0 ] && [ -t 1 ]; }
_cof_dim() { printf '\033[2m%s\033[0m\n' "$*" >&2; }
_cof_warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
_cof_sha8() { { command -v shasum >/dev/null 2>&1 && printf '%s' "$1" | shasum -a 256; } 2>/dev/null | cut -c1-8 \
              || printf '%s' "$1" | sha256sum | cut -c1-8; }
_cof_timeout() {  # $1 secs, rest = command
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}
_cof_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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
_cof_put_row() {  # $1 label $2 dir $3 cred $4 email : replace-or-append
  local tmp
  mkdir -p "$CLAUDE_OVERFLOW_HOME"; touch "$_COF_ACCOUNTS"
  tmp=$(mktemp) || return 1
  awk -F '\t' -v l="$1" '$1 != l' "$_COF_ACCOUNTS" > "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$tmp"
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

_cof_run_in() {  # $1 = profile dir ("" = primary), rest = claude args. Bypasses this wrapper.
  local dir="$1"; shift
  [ -z "$dir" ] && dir="$CLAUDE_OVERFLOW_PRIMARY_DIR"
  if [ "$dir" = "$HOME/.claude" ]; then
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR command claude "$@"
  else
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$dir" command claude "$@"
  fi
}

_cof_ping() {  # $1 = label (or primary): make Claude Code renew the token itself via a 1-token print call.
  # No hooks, no MCP servers, no session file, cheapest model: side-effect free apart from the refresh.
  local dir="$CLAUDE_OVERFLOW_PRIMARY_DIR"
  [ "$1" != "primary" ] && { dir=$(_cof_dir_for "$1") || return 1; }
  mkdir -p "$_COF_CACHE"
  set -- "$1" -p "Reply with exactly: ok" --model "$CLAUDE_OVERFLOW_PING_MODEL" --max-turns 1 \
         --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}'
  ( cd "$CLAUDE_OVERFLOW_HOME" 2>/dev/null || cd "$HOME"
    # timeout(1) needs a real executable, so call env+claude directly (env's PATH lookup skips this wrapper)
    if [ "$dir" = "$HOME/.claude" ]; then
      _cof_timeout "$CLAUDE_OVERFLOW_PING_TIMEOUT" env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR \
        claude "${@:2}" >/dev/null 2>"$_COF_CACHE/ping-$1.err"
    else
      _cof_timeout "$CLAUDE_OVERFLOW_PING_TIMEOUT" env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$dir" \
        claude "${@:2}" >/dev/null 2>"$_COF_CACHE/ping-$1.err"
    fi
  )
}

_cof_ensure_fresh() {  # $1 = label -> prints final state (ok|stale|dead); refreshes stale tokens if allowed
  local cred st
  cred=$(_cof_field "$1" 3) || { printf 'dead'; return; }
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
  printf '%s\n' "$out"
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
  printf '\n\033[1mSigning in the "%s" account%s\033[0m\n' "$label" "${email:+ ($email)}" >&2
  printf '  A browser window opens (private window when possible). Authorize as %s.\n' "${email:-the intended account}" >&2
  shimdir=""
  [ "$CLAUDE_OVERFLOW_LOGIN_BROWSER" = "default" ] || [ "$(_cof_os)" != "Darwin" ] || shimdir=$(_cof_browser_shim)
  if [ -n "$email" ]; then set -- auth login --email "$email"; else set -- auth login; fi
  if [ -n "$shimdir" ]; then
    PATH="$shimdir:$PATH" CLAUDE_OVERFLOW_LOGIN_BROWSER="$CLAUDE_OVERFLOW_LOGIN_BROWSER" _cof_run_in "$dir" "$@"; rc=$?
  else
    _cof_run_in "$dir" "$@"; rc=$?
  fi
  [ "$rc" -eq 0 ] || { _cof_warn "login: claude auth login exited $rc"; return "$rc"; }
  got=$(jq -r '.oauthAccount.emailAddress // empty' "$pstate" 2>/dev/null)
  if [ -n "$email" ] && [ "$(_cof_lc "$got")" != "$(_cof_lc "$email")" ]; then
    _cof_warn "login: the browser authorized \"${got:-unknown}\" but \"$label\" is supposed to be $email."
    _cof_warn "       Logging that session out again so the profile doesn't impersonate the wrong account."
    _cof_run_in "$dir" auth logout >/dev/null 2>&1
    return 1
  fi
  if [ "$label" != "primary" ]; then
    [ "$(_cof_cred_state "$cred")" = "dead" ] && _cof_warn "login: credentials still unreadable at $cred (Keychain permission dialog? click Always Allow and retry)"
    rm -f "$_COF_CACHE/.notified-$label" "$_COF_CACHE/usage-$label.json"
  fi
  printf '  ✓ "%s" signed in as %s\n' "$label" "${got:-?}" >&2
  return 0
}

_cof_offer_login() {  # $1 = label -> 0 if the account is usable afterwards
  local ans
  [ "$CLAUDE_OVERFLOW_AUTOLOGIN" = "1" ] && _cof_interactive || return 1
  printf 'Overflow account "%s" needs a fresh sign-in (browser). Do it now? [Y/n] ' "$1" >&2
  read -r ans
  case "${ans:-Y}" in n|N) return 1 ;; esac
  _cof_login "$1"
}

# ---------- picking ----------
_cof_pick() {  # $1 = optional label to exclude -> prints "label<TAB>reason" | "login<TAB>label1[,label2]"
  local exclude="${1:-}" json s w sc label dir cred email st blind="" dead=""
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
    if json=$(_cof_fetch "$cred" "$label"); then
      read -r s w sc <<EOF
$(printf '%s' "$json" | _cof_pcts)
EOF
      : "${s:=0}" "${w:=0}" "${sc:=0}"
      if [ "$s" -lt "$CLAUDE_OVERFLOW_FULL_AT" ] && [ "$w" -lt "$CLAUDE_OVERFLOW_FULL_AT" ]; then
        printf '%s\toverflow: session %s%% weekly %s%%\n' "$label" "$s" "$w"; return
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
    printf 'primary\tall accounts near limits\n'
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
    _cof_dim "→ primary (overflow account(s) need sign-in: $reason; run: claude-overflow login <label>)"
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
  if [ "$(_cof_os)" = "Darwin" ]; then
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then notify-send "$1" "$2" >/dev/null 2>&1; fi
}

# ---------- user-facing commands ----------
# Some hosts (notably Claude Code's own Bash tool) replay a snapshot of the interactive shell
# that keeps public functions but drops the _cof_* helpers. In that case degrade to plain primary.

cacct() {  # launch a specific account: cacct <label|primary> [claude args...]
  type _cof_run_in >/dev/null 2>&1 || { shift; env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR command claude "$@"; return $?; }
  local label="$1" dir cred st
  shift 2>/dev/null || { printf 'usage: cacct <label|primary> [args...]\n' >&2; return 2; }
  if [ "$label" = "primary" ]; then _cof_mark primary; _cof_run_in "" "$@"; return $?; fi
  dir=$(_cof_dir_for "$label") || { printf 'cacct: unknown account "%s" (see %s)\n' "$label" "$_COF_ACCOUNTS" >&2; return 1; }
  [ -d "$dir" ] || { printf 'cacct: profile dir %s missing (claude-overflow add %s ...)\n' "$dir" "$label" >&2; return 1; }
  cred=$(_cof_field "$label" 3)
  st=$(_cof_cred_state "$cred")
  if [ "$st" = "dead" ]; then
    if _cof_interactive; then _cof_login "$label" || return 1
    else printf 'cacct: account "%s" needs sign-in: claude-overflow login %s\n' "$label" "$label" >&2; return 1; fi
  fi
  _cof_sync "$dir"
  _cof_mark "$label"
  _cof_run_in "$dir" "$@"
}

claude() {  # auto-picking wrapper; inert (plain primary) until accounts.tsv exists
  type _cof_run_in >/dev/null 2>&1 || { env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR command claude "$@"; return $?; }
  local a pick
  if [ -n "${CLAUDE_ACCOUNT:-}" ]; then cacct "$CLAUDE_ACCOUNT" "$@"; return $?; fi
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    case "$a" in  # config-management subcommands always run on primary
      mcp|auth|config|doctor|plugin|plugins|setup-token|install|update|auto-mode|diagnose|migrate-installer|remote-control|agents|resume-tool)
        cacct primary "$@"; return $? ;;
    esac
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
        printf '%-26s NEEDS SIGN-IN%s   run: claude-overflow login %s\n' "$label" "${email:+ ($email)}" "$label"
        continue
      fi
      _cof_show_one "$label" "$cred" "$label" "$email"
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
    primary) _cof_warn "'primary' is reserved."; return 1 ;;
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

_cof_keepalive() {  # scheduled: renew stale tokens, notify (once/24h) about dead accounts
  local label dir cred email st log="$CLAUDE_OVERFLOW_HOME/keepalive.log" marker
  mkdir -p "$_COF_CACHE"
  _log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log"; }
  [ -s "$_COF_ACCOUNTS" ] || { _log "no overflow accounts"; return 0; }
  while IFS="$_COF_TAB" read -r label dir cred email; do
    [ -z "$label" ] && continue
    st=$(_cof_cred_state "$cred")
    case "$st" in
      ok)    _log "$label: ok" ;;
      stale) if _cof_ping "$label"; then _log "$label: refreshed"; else _log "$label: refresh ping failed ($(head -c 200 "$_COF_CACHE/ping-$label.err" 2>/dev/null | tr '\n' ' '))"; fi
             [ "$(_cof_cred_state "$cred")" = "dead" ] && st=dead ;;
    esac
    if [ "$st" = "dead" ]; then
      _log "$label: NEEDS SIGN-IN (claude-overflow login $label)"
      marker="$_COF_CACHE/.notified-$label"
      if [ ! -f "$marker" ] || [ $(( $(date +%s) - $(_cof_mtime "$marker") )) -gt 86400 ]; then
        _cof_notify "Claude overflow: \"$label\" needs sign-in" "Run in a terminal: claude-overflow login $label"
        touch "$marker"
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
  local label dir cred email st
  case "${1:-help}" in
    status) climits ;;
    login)   [ -n "${2:-}" ] || { printf 'usage: claude-overflow login <label|primary>\n' >&2; return 2; }; _cof_login "$2" ;;
    refresh) if [ -n "${2:-}" ]; then _cof_ping "$2" && printf '%s: %s\n' "$2" "$(_cof_cred_state "$(_cof_field "$2" 3)")"
             else while IFS="$_COF_TAB" read -r label dir cred email; do
                    [ -z "$label" ] && continue; _cof_ping "$label" >/dev/null 2>&1; printf '%s: %s\n' "$label" "$(_cof_cred_state "$cred")"
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
    doctor)
      command -v claude >/dev/null || printf '!! claude not on PATH\n'
      command -v jq >/dev/null || printf '!! jq not installed\n'
      if [ -s "$_COF_ACCOUNTS" ]; then
        printf 'accounts (label, dir, credential store, email, state):\n'
        while IFS="$_COF_TAB" read -r label dir cred email; do
          [ -z "$label" ] && continue
          printf '  %-10s %-40s %-36s %-28s %s\n' "$label" "$dir" "$cred" "${email:--}" "$(_cof_cred_state "$cred")"
        done < "$_COF_ACCOUNTS"
      else printf 'no overflow accounts configured\n'; fi
      [ "$(_cof_os)" = "Darwin" ] && { launchctl print "gui/$(id -u)/$_COF_LAUNCHD_LABEL" >/dev/null 2>&1 && printf 'keep-alive: installed (launchd)\n' || printf 'keep-alive: not installed (claude-overflow install-keepalive)\n'; }
      climits ;;
    *) cat <<'EOF'
claude-overflow: multi-account Claude Max routing
  status                       every account's limits + credential state (same as climits)
  login <label|primary>        browser sign-in for one profile (email pre-filled, private window)
  refresh [label]              renew stale tokens now via a 1-token ping
  keepalive                    what the scheduled job runs: refresh stale, notify about dead
  install-keepalive            schedule keepalive (macOS launchd; Linux prints a cron line)
  uninstall-keepalive
  add <label> [email] [dir]    create/adopt a profile, register it, sign in
  remove <label>               unregister (profile dir kept)
  sync | doctor
commands: claude (auto-picks), cacct <label|primary>, cswap, climits
EOF
    ;;
  esac
}
