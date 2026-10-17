---
description: Restart Claude Code and resume this same conversation (reloads settings, hooks, plugins, MCP servers, CLAUDE.md)
allowed-tools: Bash(bash ~/.claude-overflow/cof-restart.sh:*)
disable-model-invocation: true
---

!`bash ~/.claude-overflow/cof-restart.sh "${CLAUDE_SESSION_ID}"`

The line above is the result of the /restart command (installed by claude-max-overflow). The restart did not happen. Relay that message to the user in one or two short lines, and do not try to restart Claude Code any other way.
