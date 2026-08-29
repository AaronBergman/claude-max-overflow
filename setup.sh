#!/usr/bin/env bash
# claude-max-overflow guided setup. Run from the cloned repo:  bash setup.sh
# Idempotent — re-run any time to add more overflow accounts or refresh symlinks.
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COF_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
PRIMARY_DIR="${CLAUDE_OVERFLOW_PRIMARY_DIR:-$HOME/.claude}"
ACCOUNTS="$COF_HOME/accounts.tsv"
ALIASES="$COF_HOME/aliases.sh"
TAB="$(printf '\t')"
OS="$(uname)"

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
command -v claude >/dev/null || die "claude not found on PATH — install Claude Code first."
command -v jq     >/dev/null || die "jq not found — install it (brew install jq / apt install jq)."
[ -d "$PRIMARY_DIR" ] || die "Primary config dir $PRIMARY_DIR not found — run claude once and log in first."
[ -f "$(primary_state)" ] || die "Primary state file $(primary_state) not found — run claude once and log in first."
if ! claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  warn "Couldn't confirm you're logged in on the primary account (claude auth status)."
  warn "Continuing anyway — make sure your normal 'claude' works before adding overflow accounts."
fi
p_email=$(jq -r '.oauthAccount.emailAddress // "unknown"' "$(primary_state)" 2>/dev/null)
echo "Primary account: $p_email  (config: $PRIMARY_DIR)"
echo

# ---------- install runtime ----------
mkdir -p "$COF_HOME/profiles" "$COF_HOME/cache"
cp "$REPO_DIR/claude-overflow.sh" "$COF_HOME/claude-overflow.sh"
touch "$ACCOUNTS" "$ALIASES"
echo "Installed runtime -> $COF_HOME/claude-overflow.sh"

# ---------- helpers ----------
snapshot_keychain() {
  security dump-keychain 2>/dev/null | grep -o '"Claude Code-credentials[^"]*"' | tr -d '"' | sort -u
}

link_farm() {  # $1 = profile dir
  local item src dst
  for item in CLAUDE.md settings.json agents commands skills hooks plugins projects \
              history.jsonl keybindings.json output-styles plans workflows; do
    src="$PRIMARY_DIR/$item"; dst="$1/$item"
    [ -e "$src" ] || continue
    if [ -L "$dst" ] || [ ! -e "$dst" ]; then ln -sfn "$src" "$dst"
    else warn "  skip $item (real file already in profile — resolve manually)"; fi
  done
}

seed_state() {  # $1 = profile dir
  [ -f "$1/.claude.json" ] && return 0
  jq '{hasCompletedOnboarding: true}
      + ({theme, editorMode, autoUpdates, verbose, preferredNotifChannel,
          autocheckpointingEnabled, bypassPermissionsModeAccepted, projects}
         | with_entries(select(.value != null)))' "$(primary_state)" > "$1/.claude.json"
}

add_account() {
  local label dir cred before after new email
  while :; do
    printf 'Short label for this overflow account (e.g. work, school, alt): '
    read -r label
    case "$label" in
      primary) warn "  'primary' is reserved."; continue ;;
      *[!a-zA-Z0-9_-]*|"") warn "  letters/digits/_/- only."; continue ;;
    esac
    break
  done
  dir="$COF_HOME/profiles/$label"
  mkdir -p "$dir"
  link_farm "$dir"
  seed_state "$dir"
  echo "  Profile ready: $dir (shares your primary's settings/skills/history via symlinks)"
  echo
  bold "  A browser window will open for OAuth."
  echo "  * Authorize as the OVERFLOW account for '$label' — if the page shows"
  echo "    $p_email, switch accounts first (a private window logged into"
  echo "    claude.ai as the overflow account is the easy way)."
  printf '  Press Enter to open the login flow... '
  read -r _
  if [ "$OS" = "Darwin" ]; then before=$(snapshot_keychain); fi
  CLAUDE_CONFIG_DIR="$dir" claude auth login || { warn "  login failed — this account was not added."; return 1; }

  if [ "$OS" = "Darwin" ]; then
    after=$(snapshot_keychain)
    new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
    if [ "$(printf '%s\n' "$new" | grep -c .)" -eq 1 ]; then
      cred="$new"
    else
      # Re-login into an existing entry, or ambiguous diff: keep any previous mapping.
      cred=$(grep "^$label$TAB" "$ACCOUNTS" | cut -f3)
      if [ -z "$cred" ]; then
        warn "  Couldn't auto-detect the Keychain entry for this profile."
        warn "  Find it:  security dump-keychain | grep 'Claude Code-credentials-'"
        printf '  Paste the service name (Claude Code-credentials-XXXXXXXX): '
        read -r cred
      fi
    fi
  else
    cred="$dir/.credentials.json"
  fi

  email=$(jq -r '.oauthAccount.emailAddress // "unknown"' "$dir/.claude.json" 2>/dev/null)
  if [ "$email" = "$p_email" ] && [ "$email" != "unknown" ]; then
    warn "  !! You logged into the SAME account as primary ($email)."
    warn "     Re-run setup and pick the overflow account in the browser."
  fi
  grep -v "^$label$TAB" "$ACCOUNTS" > "$ACCOUNTS.tmp" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$label" "$dir" "$cred" >> "$ACCOUNTS.tmp"
  mv "$ACCOUNTS.tmp" "$ACCOUNTS"
  if ! grep -q "alias c-$label=" "$ALIASES" 2>/dev/null; then
    printf "alias c-%s='cacct %s'\n" "$label" "$label" >> "$ALIASES"
  fi
  echo "  ✓ Added '$label' ($email). Shortcut: c-$label"
}

# ---------- account loop ----------
if [ -s "$ACCOUNTS" ]; then
  echo "Existing overflow accounts:"
  sed 's/^/  /' "$ACCOUNTS"
fi
while :; do
  if [ -s "$ACCOUNTS" ]; then printf 'Add another overflow account? [y/N] '
  else printf 'Add your first overflow account now? [Y/n] '; fi
  read -r ans
  case "${ans:-}" in
    y|Y) add_account ;;
    "")  [ -s "$ACCOUNTS" ] && break || add_account ;;
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
  echo "Unrecognized shell — add this line to your shell rc:"
  echo "  $SRC_LINE"
else
  echo "Loader already wired into $RC."
fi

echo
bold "Done. Open a new shell (or: . \"$COF_HOME/claude-overflow.sh\"), then try:"
echo "  climits          # every account's limit windows"
echo "  claude           # auto-picks; switches when primary nears its limits"
echo "  cacct <label>    # force a specific account (aliases: c-<label>)"
echo "  cswap            # continue your latest conversation on another account"
