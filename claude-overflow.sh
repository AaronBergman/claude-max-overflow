# claude-overflow.sh — route Claude Code overflow usage across multiple Max accounts.
# Source this from your shell rc (bash or zsh). The guided installer (setup.sh) does
# this for you. https://github.com/AaronBergman/claude-max-overflow  (EXPERIMENTAL)
#
# One PRIMARY account (your normal ~/.claude login) owns all configuration.
# Any number of OVERFLOW accounts live in isolated CLAUDE_CONFIG_DIR profiles that
# symlink back to the primary's config, so settings/skills/history/memory are shared
# and --resume works across accounts. `claude` becomes a function that checks the
# primary's live rate limits and transparently launches whichever account has headroom.

# ---------- config (override via env or $CLAUDE_OVERFLOW_HOME/config.sh) ----------
CLAUDE_OVERFLOW_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
CLAUDE_OVERFLOW_PRIMARY_DIR="${CLAUDE_OVERFLOW_PRIMARY_DIR:-$HOME/.claude}"
CLAUDE_OVERFLOW_SESSION_AT="${CLAUDE_OVERFLOW_SESSION_AT:-85}"   # switch when 5h window >= %
CLAUDE_OVERFLOW_WEEKLY_AT="${CLAUDE_OVERFLOW_WEEKLY_AT:-92}"     # ...or weekly >= %
CLAUDE_OVERFLOW_SCOPED_AT="${CLAUDE_OVERFLOW_SCOPED_AT:-92}"     # ...or model-scoped weekly >= %
CLAUDE_OVERFLOW_FULL_AT="${CLAUDE_OVERFLOW_FULL_AT:-97}"         # an account counts as exhausted at %
CLAUDE_OVERFLOW_TTL="${CLAUDE_OVERFLOW_TTL:-60}"                 # usage-check cache seconds
[ -f "$CLAUDE_OVERFLOW_HOME/config.sh" ] && . "$CLAUDE_OVERFLOW_HOME/config.sh"
[ -f "$CLAUDE_OVERFLOW_HOME/aliases.sh" ] && . "$CLAUDE_OVERFLOW_HOME/aliases.sh"

_COF_ACCOUNTS="$CLAUDE_OVERFLOW_HOME/accounts.tsv"   # label<TAB>config_dir<TAB>cred_source
_COF_CACHE="$CLAUDE_OVERFLOW_HOME/cache"
# Config-management subcommands always run on primary.
_COF_MGMT_RE='^(mcp|auth|config|doctor|plugin|plugins|setup-token|install|update|auto-mode|diagnose|migrate-installer|remote-control|agents)$'

_cof_primary_cred() {
  if [ "$(uname)" = "Darwin" ]; then printf '%s' "Claude Code-credentials"
  else printf '%s' "$CLAUDE_OVERFLOW_PRIMARY_DIR/.credentials.json"; fi
}

_cof_primary_state() {
  if [ "$CLAUDE_OVERFLOW_PRIMARY_DIR" = "$HOME/.claude" ]; then printf '%s' "$HOME/.claude.json"
  else printf '%s' "$CLAUDE_OVERFLOW_PRIMARY_DIR/.claude.json"; fi
}

_cof_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

_cof_token() {  # $1 = cred source (keychain service name, or path to .credentials.json)
  if [ -f "$1" ]; then
    jq -r '.claudeAiOauth.accessToken // empty' "$1" 2>/dev/null
  else
    security find-generic-password -w -s "$1" 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
  fi
}

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

_cof_pick() {  # $1 = optional label to exclude -> prints "label<TAB>reason"
  local exclude="${1:-}" json s w sc label dir cred first_overflow=""
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
  while IFS="$(printf '\t')" read -r label dir cred; do
    [ -z "$label" ] && continue
    [ "$label" = "$exclude" ] && continue
    [ -z "$first_overflow" ] && first_overflow="$label"
    if json=$(_cof_fetch "$cred" "$label"); then
      read -r s w sc <<EOF
$(printf '%s' "$json" | _cof_pcts)
EOF
      : "${s:=0}" "${w:=0}" "${sc:=0}"
      if [ "$s" -lt "$CLAUDE_OVERFLOW_FULL_AT" ] && [ "$w" -lt "$CLAUDE_OVERFLOW_FULL_AT" ]; then
        printf '%s\toverflow: session %s%% weekly %s%%\n' "$label" "$s" "$w"; return
      fi
    fi
  done < "$_COF_ACCOUNTS"
  if [ -n "$first_overflow" ]; then
    # Every overflow account was exhausted or unreadable; try the first one blind
    # rather than silently spending primary extra-usage credits.
    printf '%s\tblind (no overflow account had a readable, non-exhausted budget)\n' "$first_overflow"
  else
    printf 'primary\tall accounts near limits\n'
  fi
}

_cof_dir_for() {  # $1 = label -> config dir (empty output = primary/default)
  local label dir cred
  while IFS="$(printf '\t')" read -r label dir cred; do
    if [ "$label" = "$1" ]; then printf '%s' "$dir"; return 0; fi
  done < "$_COF_ACCOUNTS" 2>/dev/null
  return 1
}

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

_cof_mark() { mkdir -p "$_COF_CACHE"; printf '%s\n' "$1" > "$_COF_CACHE/last"; }

cacct() {  # launch a specific account: cacct <label|primary> [claude args...]
  local label="$1" dir
  shift 2>/dev/null || { printf 'usage: cacct <label|primary> [args...]\n' >&2; return 2; }
  if [ "$label" = "primary" ]; then
    _cof_mark primary
    if [ "$CLAUDE_OVERFLOW_PRIMARY_DIR" = "$HOME/.claude" ]; then
      env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR command claude "$@"
    else
      env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
          CLAUDE_CONFIG_DIR="$CLAUDE_OVERFLOW_PRIMARY_DIR" command claude "$@"
    fi
    return $?
  fi
  dir=$(_cof_dir_for "$label") || { printf 'cacct: unknown account "%s" (see %s)\n' "$label" "$_COF_ACCOUNTS" >&2; return 1; }
  [ -d "$dir" ] || { printf 'cacct: profile dir %s missing — re-run setup\n' "$dir" >&2; return 1; }
  _cof_sync "$dir"
  _cof_mark "$label"
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$dir" command claude "$@"
}

claude() {  # auto-picking wrapper; inert (plain primary) until accounts.tsv exists
  local a pick reason line
  if [ -n "${CLAUDE_ACCOUNT:-}" ]; then cacct "$CLAUDE_ACCOUNT" "$@"; return $?; fi
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    if printf '%s' "$a" | grep -Eq "$_COF_MGMT_RE"; then cacct primary "$@"; return $?; fi
    break  # first non-flag arg is a prompt/path, not a subcommand
  done
  if [ ! -s "$_COF_ACCOUNTS" ]; then cacct primary "$@"; return $?; fi
  line=$(_cof_pick)
  pick=${line%%"$(printf '\t')"*}
  reason=${line#*"$(printf '\t')"}
  if [ "$pick" != "primary" ]; then
    printf '\033[2m→ overflow account "%s" (%s)\033[0m\n' "$pick" "$reason" >&2
  fi
  cacct "$pick" "$@"
}

cswap() {  # continue the latest conversation on a DIFFERENT account
  local last line pick
  last=$(cat "$_COF_CACHE/last" 2>/dev/null || echo primary)
  line=$(_cof_pick "$last")
  pick=${line%%"$(printf '\t')"*}
  if [ "$pick" = "$last" ]; then pick=primary; [ "$last" = "primary" ] && { printf 'cswap: no other account configured\n' >&2; return 1; }; fi
  printf '\033[2m→ continuing on "%s"\033[0m\n' "$pick" >&2
  cacct "$pick" --continue "$@"
}

climits() {  # all accounts' limit windows + extra-usage spend
  local label dir cred
  _cof_show_one "primary" "$(_cof_primary_cred)" primary
  if [ -s "$_COF_ACCOUNTS" ]; then
    while IFS="$(printf '\t')" read -r label dir cred; do
      [ -z "$label" ] && continue
      _cof_show_one "$label" "$cred" "$label"
    done < "$_COF_ACCOUNTS"
  else
    printf '%-22s %s\n' "(overflow)" "none configured — run setup.sh"
  fi
}

_cof_show_one() {  # $1 label, $2 cred source, $3 cache key
  local json s w sc rs rw extra email dir
  if ! json=$(_cof_fetch "$2" "$3" fresh); then
    printf '%-22s %s\n' "$1" "unavailable (not logged in / network / keychain)"
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
  printf '%-22s 5h %3s%% (resets %s)   week %3s%% (resets %s)   model-wk %3s%%\n' \
    "$1" "$s" "${rs:-?}" "$w" "${rw:-?}" "$sc"
  extra=$(printf '%s' "$json" | jq -r '.extra_usage | select(.is_enabled==true) | "extra usage: \(.used_credits/100 | floor)/\(.monthly_limit/100) \(.currency) (\(.utilization|round)%)"' 2>/dev/null)
  [ -n "$extra" ] && printf '%-22s %s\n' "" "$extra"
}

claude-overflow() {  # tiny CLI: status | sync | doctor | help
  case "${1:-help}" in
    status) climits ;;
    sync)
      local label dir cred
      while IFS="$(printf '\t')" read -r label dir cred; do
        [ -n "$dir" ] && rm -f "$_COF_CACHE/.sync-$(basename "$dir")" && _cof_sync "$dir" && printf 'synced %s\n' "$label"
      done < "$_COF_ACCOUNTS" 2>/dev/null ;;
    doctor)
      command -v claude >/dev/null || printf '!! claude not on PATH\n'
      command -v jq >/dev/null || printf '!! jq not installed\n'
      [ -s "$_COF_ACCOUNTS" ] && printf 'accounts:\n' && cat "$_COF_ACCOUNTS" || printf 'no overflow accounts configured\n'
      climits ;;
    *) printf 'claude-overflow: status | sync | doctor\ncommands: claude (auto), cacct <label>, cswap, climits\n' ;;
  esac
}
