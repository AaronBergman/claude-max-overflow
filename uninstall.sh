#!/usr/bin/env bash
# Remove claude-max-overflow. Run:  bash uninstall.sh
set -u
COF_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
TAB="$(printf '\t')"
PLIST="$HOME/Library/LaunchAgents/com.claude-max-overflow.keepalive.plist"

echo "== claude-max-overflow uninstall =="

# 1. Keep-alive job.
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST" && echo "Removed keep-alive LaunchAgent."
fi

# 2. Offer to log the overflow profiles out (clears their OS credential entries).
if [ -s "$COF_HOME/accounts.tsv" ]; then
  while IFS="$TAB" read -r label dir cred email; do
    [ -z "$label" ] && continue
    printf 'Log out overflow account "%s"%s (clears its stored credentials)? [y/N] ' "$label" "${email:+ ($email)}"
    read -r ans
    case "${ans:-}" in
      y|Y) CLAUDE_CONFIG_DIR="$dir" claude auth logout || true ;;
    esac
  done < "$COF_HOME/accounts.tsv"
fi

# 3. Remove the rc loader line.
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$RC" ] || continue
  if grep -q "claude-overflow.sh" "$RC"; then
    cp "$RC" "$RC.cof-backup"
    grep -v "claude-overflow" "$RC.cof-backup" > "$RC"
    echo "Removed loader from $RC (backup: $RC.cof-backup)"
  fi
done

# 4. Remove the install dir (profiles are symlinks + a small state file; your real
#    config in ~/.claude is untouched). Profiles adopted from outside $COF_HOME stay.
printf 'Delete %s entirely? [y/N] ' "$COF_HOME"
read -r ans
case "${ans:-}" in
  y|Y) rm -rf "$COF_HOME"; echo "Deleted $COF_HOME." ;;
  *)   echo "Left $COF_HOME in place." ;;
esac

echo "Done. Open a new shell; 'claude' is the plain CLI again."
