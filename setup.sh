#!/usr/bin/env bash
# claude-max-overflow guided setup. Run from the cloned repo:  bash setup.sh
# Idempotent: re-run any time to add more overflow accounts or refresh symlinks.
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COF_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
PRIMARY_DIR="${CLAUDE_OVERFLOW_PRIMARY_DIR:-$HOME/.claude}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*"; exit 1; }

primary_state() {
  if [ "$PRIMARY_DIR" = "$HOME/.claude" ]; then printf '%s' "$HOME/.claude.json"
  else printf '%s' "$PRIMARY_DIR/.claude.json"; fi
}

bold "== claude-max-overflow setup =="
echo "EXPERIMENTAL: relies on undocumented Claude Code internals; see README."
echo

# ---------- preflight ----------
command -v claude >/dev/null || die "claude not found on PATH; install Claude Code first."
command -v jq     >/dev/null || die "jq not found; install it (brew install jq / apt install jq)."
[ -d "$PRIMARY_DIR" ] || die "Primary config dir $PRIMARY_DIR not found; run claude once and log in first."
[ -f "$(primary_state)" ] || die "Primary state file $(primary_state) not found; run claude once and log in first."
if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  warn "Couldn't confirm you're logged in on the primary account (claude auth status)."
  warn "Continuing anyway; make sure your normal 'claude' works before adding overflow accounts."
fi
p_email=$(jq -r '.oauthAccount.emailAddress // "unknown"' "$(primary_state)" 2>/dev/null)
echo "Primary account: $p_email  (config: $PRIMARY_DIR)"
echo

# ---------- install runtime ----------
mkdir -p "$COF_HOME/profiles" "$COF_HOME/cache"
cp "$REPO_DIR/claude-overflow.sh" "$COF_HOME/claude-overflow.sh"
touch "$COF_HOME/accounts.tsv" "$COF_HOME/aliases.sh"
echo "Installed runtime -> $COF_HOME/claude-overflow.sh"
# shellcheck source=claude-overflow.sh
. "$COF_HOME/claude-overflow.sh"

# ---------- account loop ----------
if [ -s "$COF_HOME/accounts.tsv" ]; then
  echo "Existing overflow accounts:"
  claude-overflow doctor 2>/dev/null | sed -n '/^accounts/,/^keep-alive/p' | sed 's/^/  /'
fi
add_account() {
  local label email dir
  while :; do
    printf 'Short label for this overflow account (e.g. work, school, alt): '
    read -r label
    case "$label" in
      primary) warn "  'primary' is reserved."; continue ;;
      *[!a-zA-Z0-9_-]*|"") warn "  letters/digits/_/- only."; continue ;;
    esac
    break
  done
  printf 'Email of that account (pre-fills the login page and guards against signing in as the wrong one): '
  read -r email
  printf 'Profile dir [default %s/profiles/%s; or an existing CLAUDE_CONFIG_DIR to adopt]: ' "$COF_HOME" "$label"
  read -r dir
  echo
  bold "  A browser window will open for OAuth (private window when possible)."
  echo "  Authorize as ${email:-the overflow account}; if the page shows $p_email, switch accounts first."
  printf '  Press Enter to continue... '
  read -r _
  claude-overflow add "$label" "$email" "$dir"
}
while :; do
  if [ -s "$COF_HOME/accounts.tsv" ]; then printf 'Add another overflow account? [y/N] '
  else printf 'Add your first overflow account now? [Y/n] '; fi
  read -r ans
  case "${ans:-}" in
    y|Y) add_account ;;
    "")  [ -s "$COF_HOME/accounts.tsv" ] && break || add_account ;;
    *)   break ;;
  esac
done

# ---------- shell rc wiring ----------
case "${SHELL:-}" in
  */zsh)  RC="$HOME/.zshrc" ;;
  */bash) RC="$HOME/.bashrc" ;;
  *)      RC="" ;;
esac
SRC_LINE="[ -f \"$COF_HOME/claude-overflow.sh\" ] && . \"$COF_HOME/claude-overflow.sh\""
echo
if [ -n "$RC" ] && ! grep -qF "claude-overflow.sh" "$RC" 2>/dev/null; then
  if grep -nE '^[^#]*alias +claude=' "$RC" >/dev/null 2>&1; then
    warn "Heads-up: $RC defines 'alias claude=...' which would shadow the wrapper."
    warn "Comment it out (aliases win over functions):"
    grep -nE '^[^#]*alias +claude=' "$RC" | sed 's/^/    /'
  fi
  printf 'Append the loader to %s? [Y/n] ' "$RC"
  read -r ans
  case "${ans:-Y}" in
    n|N) echo "Add this line to your shell rc yourself:"; echo "  $SRC_LINE" ;;
    *)   printf '\n# claude-max-overflow (multi-account Claude Max routing)\n%s\n' "$SRC_LINE" >> "$RC"
         echo "Appended to $RC." ;;
  esac
elif [ -z "$RC" ]; then
  echo "Unrecognized shell; add this line to your shell rc:"
  echo "  $SRC_LINE"
else
  echo "Loader already wired into $RC."
fi

# ---------- keep-alive ----------
echo
printf 'Schedule the keep-alive (renews overflow tokens every %sh so they never expire; notifies you when a real sign-in is needed)? [Y/n] ' "$CLAUDE_OVERFLOW_KEEPALIVE_HOURS"
read -r ans
case "${ans:-Y}" in
  n|N) echo "Skipped. Later: claude-overflow install-keepalive" ;;
  *)   claude-overflow install-keepalive ;;
esac

echo
bold "Done. Open a new shell (or: . \"$COF_HOME/claude-overflow.sh\"), then try:"
echo "  climits          # every account's limit windows + credential state"
echo "  claude           # auto-picks; switches when primary nears its limits"
echo "  cacct <label>    # force a specific account (aliases: c-<label>)"
echo "  cswap            # continue your latest conversation on another account"
echo "  claude-overflow  # login / refresh / add / remove / doctor"
