#!/usr/bin/env bash
# Remove claude-max-overflow. Run:  bash uninstall.sh
set -u
COF_HOME="${CLAUDE_OVERFLOW_HOME:-$HOME/.claude-overflow}"
TAB="$(printf '\t')"
PLIST="$HOME/Library/LaunchAgents/com.claude-max-overflow.keepalive.plist"

echo "== claude-max-overflow uninstall =="

# The real claude binary: a `claude` found on PATH may be the claude-shim, and `CLAUDE_CONFIG_DIR=<dir> claude ...`
# must reach Claude Code itself (the loader's _cof_bin knows how to find it).
CLAUDE_BIN=claude
if [ -f "$COF_HOME/claude-overflow.sh" ]; then
  CLAUDE_BIN=$(bash -c '. "$1" >/dev/null 2>&1 && _cof_bin' _ "$COF_HOME/claude-overflow.sh" 2>/dev/null)
  [ -n "$CLAUDE_BIN" ] || CLAUDE_BIN=claude
fi

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
      y|Y) env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$dir" "$CLAUDE_BIN" auth logout || true ;;
    esac
  done < "$COF_HOME/accounts.tsv"
fi

# 3. The claude-router plugin (session awareness), the claude-on / claude_router links and the claude-shim.
if command -v "$CLAUDE_BIN" >/dev/null 2>&1 && env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" plugin uninstall claude-router@claude-max-overflow --scope user >/dev/null 2>&1; then
  env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" plugin marketplace remove claude-max-overflow >/dev/null 2>&1
  echo "Removed the claude-router plugin."
fi
for d in "$HOME/.local/bin" "$HOME/bin"; do
  [ -L "$d/claude-on" ] && rm -f "$d/claude-on" && echo "Removed $d/claude-on."
  case "$(readlink "$d/claude_router" 2>/dev/null)" in */cof-dashboard.py) rm -f "$d/claude_router" && echo "Removed $d/claude_router." ;; esac
done
if [ -f "$COF_HOME/shim/claude" ]; then
  rm -f "$COF_HOME/shim/claude"; rmdir "$COF_HOME/shim" 2>/dev/null
  echo "Removed the claude-shim (open a new shell so 'claude' in scripts is the plain binary again)."
fi
# The /restart command setup.sh put in ~/.claude/commands (only if it is ours; it only works with the router).
RESTART_CMD="${CLAUDE_OVERFLOW_PRIMARY_DIR:-$HOME/.claude}/commands/restart.md"
grep -q "cof-restart.sh" "$RESTART_CMD" 2>/dev/null && rm -f "$RESTART_CMD" && echo "Removed the /restart command ($RESTART_CMD)."

# 4. Remove the rc loader line.
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$RC" ] || continue
  if grep -q "claude-overflow.sh" "$RC"; then
    cp "$RC" "$RC.cof-backup"
    grep -v "claude-overflow" "$RC.cof-backup" > "$RC"
    echo "Removed loader from $RC (backup: $RC.cof-backup)"
  fi
done

# 5. Remove the install dir (profiles are symlinks + a small state file; your real
#    config in ~/.claude is untouched). Profiles adopted from outside $COF_HOME stay.
printf 'Delete %s entirely? [y/N] ' "$COF_HOME"
read -r ans
case "${ans:-}" in
  y|Y) rm -rf "$COF_HOME"; echo "Deleted $COF_HOME." ;;
  *)   echo "Left $COF_HOME in place." ;;
esac

echo "Done. Open a new shell; 'claude' is the plain CLI again."
