---
name: claude-router
description: Multi-account Claude Max router on this machine (claude-max-overflow). Use when the user asks about Claude usage, limits, "how much is left", accounts or the router/dashboard; when planning a large Workflow or many subagents that might not fit in the current account's remaining usage; when a rate-limit error, pause or account hop happens; or when work should be split across accounts.
---

# claude-router (claude-max-overflow)

This Mac spreads Claude Code over several Claude Max subscriptions: a **primary** account (`~/.claude`, owns all config) and **overflow** accounts (isolated `CLAUDE_CONFIG_DIR` profiles listed in `~/.claude-overflow/accounts.tsv`). Each account has its own **5-hour**, **weekly**, and **model-scoped weekly** (e.g. Fable-only) window. Settings, skills, memory and history are shared, so a conversation can resume on any account.

## What you get automatically
- **Session start**: a `<claude-router>` block with this session's account, whether it is router-managed, every account's usage and reset times, pool headroom, and warnings.
- **Prompts**: a one-line note only when this session's account crosses 80/90/95%, recovers, or the router pauses the conversation.
- **Before Agent/Workflow calls**: a capacity note when this account is at 60%+ (Workflow or background Agent) or 85%+ (foreground Agent).
- **On demand**: the `claude-router` MCP server. `router_status` (usage, headroom, burn rate, pick, warnings), `router_hops` (switch log), `router_open_dashboard`.

## How the router moves work
- `claude` in a terminal is a wrapper that picks the account with headroom at launch.
- **Managed sessions** (launched through that wrapper) move themselves when the account runs out:
  - at 95% on any window, the hook ends the session at the next turn boundary (SIGTERM) and relaunches `--resume <id>` on another account;
  - on a rate-limit error, it does the same right away.
  - The conversation survives. Work in flight in the process (background agents, running Workflows, background Bash) does not.
- **Unmanaged sessions** stay put and just stop at the limit. These are desktop-app sessions, Remote Control, `claude -p`, or anything launched outside the wrapper.
- Subagents and workflow agents **always** run on the calling session's account. Nothing inside a session can change which account a subagent bills.

## Planning a big fan-out
1. **Check first.** Run `router_status`, or read the session-start block. Compare the job with this account's tightest window (5h, weekly, and the Fable window if agents use a Fable model).
2. **If it fits comfortably, just run it.**
3. **If it's tight and this session is managed:** a hop mid-run kills in-flight background work. Instead:
   - run it in smaller batches;
   - have agents write results to files, so a restart only loses the current batch;
   - avoid leaving long background workflows running when the account is near 95%.
4. **Put self-contained chunks on another account** (the account with the most room is named in the notes):
   ```bash
   claude-on <label> -p "<self-contained prompt>" --permission-mode acceptEdits --output-format json
   ```
   - `claude-on <label|primary> [claude args]` is a normal headless Claude Code run billed to that account.
   - It does not see this conversation: give it everything it needs, and have it write outputs to files.
   - Pass `--allowedTools` / `--permission-mode` as the task needs; headless runs cannot ask for permission.
   - Use `claude-on`, not `cacct`, from the Bash tool: Claude Code's shell snapshot lacks the router's helpers (`cacct` there only works by handing off to `claude-on`).
5. **For interactive continuation elsewhere:** ask the user to run `c-<label>` for a new session there, or `cswap` to continue the latest conversation on another account.
6. **If every account is tight:** say so, give the next reset times from `router_status`, and scope the work down. Do not start a big job that will stall.

## User-facing commands (they run these, in a terminal)
| command | what |
|---|---|
| `claude_router` | live HTML dashboard: pies, per-account windows, hops, sessions, health, "+ Add account" |
| `climits` / `claude-overflow status` | every account's limits in the terminal |
| `c-<label>` / `cacct <label>` | start a session on a specific account |
| `cswap` | continue the latest conversation on another account |
| `claude-overflow login <label>` | browser sign-in for a signed-out account |

## Don'ts
- Never read, print, copy or refresh OAuth tokens (Keychain `Claude Code-credentials*`, `.credentials.json`). External refreshes sign accounts out.
- Never `bash -x` / `set -x` the loader or the hook: sourcing traces credential JSON.
- Be frugal with `/api/oauth/usage`. Use `router_status` (shared 5-minute cache), not curl loops: 429s blind the router's picks.
- Details: the router's logs in `~/.claude-overflow/` (`insession.log` hops and pauses, `login.log`, `keepalive.log`) and the project README (github.com/AaronBergman/claude-max-overflow).
