# claude-max-overflow

Use the model usage from **multiple Claude Max subscriptions** in Claude Code without ever thinking about which account you're on. One **primary** account owns all your configuration; any number of **overflow** accounts provide extra capacity. `claude` becomes a shell function that checks your primary account's live rate limits at launch and transparently starts the session under whichever account has headroom. Overflow credentials are kept alive automatically, and when one genuinely needs a fresh sign-in the tool opens the right login page for you instead of silently falling back.

> ⚠️ **Experimental.** This is a young project, lightly tested (macOS + zsh primarily; Linux/bash support is best-effort and less exercised). It reads Claude Code's OAuth credentials from your OS credential store and calls the same undocumented usage endpoint that powers `/usage`; any Claude Code update could break it. Nothing here touches your primary login, and there's a clean [uninstall](#uninstall), but treat it accordingly.

## Why

- Max plans have 5-hour and weekly rate-limit windows per account. If you own more than one subscription (e.g. a personal one and one through school/work), overflow capacity sits idle while you wait out a limit, or worse, while **extra usage** silently bills your card.
- Anthropic doesn't (yet) offer multi-account support in Claude Code. Manually running `/login` back and forth loses your flow and forks your settings.
- This tool keeps **one account authoritative for all config** (settings, skills, agents, hooks, plugins, history, memory) and treats the others as pure model capacity. Session history is shared, so you can hit a limit mid-conversation, type `cswap`, and continue the same conversation on another account.
- Overflow accounts you rarely touch would otherwise quietly log themselves out (see [credential lifecycle](#credential-lifecycle)); this tool notices and fixes that for you.

## How it works

- Each overflow account gets an isolated profile via `CLAUDE_CONFIG_DIR` (default `~/.claude-overflow/profiles/<label>`, or any existing config dir you want to adopt). Claude Code namespaces credentials per config dir (macOS Keychain: `Claude Code-credentials-<first 8 hex of sha256(dir)>`; Linux: per-dir `.credentials.json`), so all accounts stay logged in simultaneously.
- Each profile is a **symlink farm** back into your primary `~/.claude`: `settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `hooks/`, `plugins/`, `projects/` (session history + memory), `history.jsonl`, etc. are literally the same files. Only credentials and the per-profile `.claude.json` (account identity + per-project trust, one-way synced from primary before each overflow launch) differ.
- The `claude` wrapper function calls `GET https://api.anthropic.com/api/oauth/usage` with the primary's OAuth token (60s cache, 4s timeout, fail-open to primary):
  - primary under thresholds: primary, silently, exactly as before;
  - primary ≥ 85% of the 5h window, or ≥ 92% weekly: walks your overflow accounts in the order you added them and launches the first one with headroom, printing a dim one-liner so you always know;
  - an overflow account whose token is stale gets a one-token refresh ping first so the decision uses real numbers; one that is dead (signed out) triggers a sign-in offer if you're at a terminal;
  - everything exhausted: primary (visible notice).
- Config-management subcommands (`claude mcp|auth|config|plugin|doctor|update|…`) always run on primary so it stays in control. Scripts/cron never see the shell function and keep using primary.

## Credential lifecycle

Claude Code's OAuth **access token** lives a few hours. The **refresh token** that renews it lives about 28 days from its last use (each refresh rotates it and extends the clock). If a refresh is ever rejected (`invalid_grant`, e.g. after a revocation or a rare concurrent-refresh race), Claude Code blanks the stored credentials and the profile is signed out. So an overflow account you don't use drifts `ok` → `stale` → `dead`. The tool classifies every account on each look:

| state | meaning | what happens |
|---|---|---|
| `ok` | access token valid | used normally |
| `stale` | access token expired, refresh token live | renewed on the spot by a 1-token `claude -p` ping (no hooks, no MCP, no session file, cheapest model), so Claude Code performs the refresh under its own lock |
| `dead` | signed out / refresh token expired | `climits` says so; `cacct <label>` or the auto-picker offers a browser sign-in with the email pre-filled, in a private window, and verifies afterwards that the right account came back |

The optional **keep-alive** (`claude-overflow install-keepalive`) runs the same refresh every 12 hours from launchd, so refresh tokens keep rotating and nothing expires while you're away; if an account is dead it posts a desktop notification (once a day) telling you which one to sign in. The keep-alive never opens a browser on its own.

## Requirements

- Claude Code with a claude.ai (subscription) login on the primary account
- `jq`, `curl`
- macOS (Keychain) or Linux (credentials file); zsh or bash
- Two or more Claude subscriptions **you personally own and pay for**

## Install

```bash
git clone https://github.com/AaronBergman/claude-max-overflow.git
cd claude-max-overflow
bash setup.sh
```

The guided setup checks prerequisites, then for each overflow account asks for a label, the account's email, and optionally an existing config dir to adopt; builds the profile; opens Claude Code's normal browser OAuth (email pre-filled, private window when a Chromium/Firefox app is present so your default browser's claude.ai session can't pick the wrong account); verifies the signed-in email matches; and wires a `source` line into your shell rc. It then offers to install the keep-alive. Re-run it any time to add more accounts. It never modifies your primary `~/.claude`.

Non-interactive equivalent once the loader is sourced: `claude-overflow add <label> <email> [dir]`.

## Commands

| command | does |
|---|---|
| `claude …` | auto-picks an account (primary-preferred); inert until an overflow account exists |
| `cacct <label\|primary> …` | force a specific account (setup also creates `c-<label>` aliases); signs it in first if it's dead |
| `cswap` | `--continue` your latest conversation on a *different* account: the "hit a limit mid-session" escape hatch |
| `climits` | every account's 5h/weekly/model-scoped % + reset times + extra-usage spend + credential state |
| `claude-overflow login <label>` | browser sign-in for one profile (email pre-filled, private window, verified) |
| `claude-overflow refresh [label]` | renew stale tokens now |
| `claude-overflow install-keepalive` | schedule the 12-hourly refresh (macOS launchd; prints a cron line on Linux) |
| `claude-overflow add\|remove\|sync\|doctor\|status` | manage accounts, resync trust, diagnose |
| `CLAUDE_ACCOUNT=<label> claude …` | one-off override via env |

Tuning (env vars, or `~/.claude-overflow/config.sh`):

| var | default | meaning |
|---|---|---|
| `CLAUDE_OVERFLOW_SESSION_AT` | 85 | switch when primary's 5h window ≥ this % |
| `CLAUDE_OVERFLOW_WEEKLY_AT` | 92 | …or weekly ≥ this % |
| `CLAUDE_OVERFLOW_SCOPED_AT` | 92 | …or a model-scoped weekly limit ≥ this % |
| `CLAUDE_OVERFLOW_FULL_AT` | 97 | an overflow account counts as exhausted at this % |
| `CLAUDE_OVERFLOW_TTL` | 60 | seconds to cache usage checks |
| `CLAUDE_OVERFLOW_AUTOREFRESH` | 1 | renew stale overflow tokens inline before deciding |
| `CLAUDE_OVERFLOW_AUTOLOGIN` | 1 | offer a browser sign-in for dead accounts (interactive shells only) |
| `CLAUDE_OVERFLOW_LOGIN_BROWSER` | private | `private` (Chrome/Brave incognito, Firefox private window), `default` (system browser), or a command template containing `{url}` |
| `CLAUDE_OVERFLOW_PING_MODEL` | haiku | model used by the refresh ping |
| `CLAUDE_OVERFLOW_KEEPALIVE_HOURS` | 12 | keep-alive cadence |

Switching *before* 100% is deliberate: if your primary has **extra usage** enabled, overflowing there costs real money; overflowing to a subscription you already pay for costs nothing.

## FAQ

**Is this allowed?** This tool is for people using **their own, separately paid** subscriptions, each within its own limits; it's an account *switcher*, not a limit bypass. It does not create accounts, share accounts, or evade any per-account enforcement. That said, this is not legal advice, the author is not affiliated with Anthropic, and you're responsible for your own accounts.

**Why not `claude setup-token` + `CLAUDE_CODE_OAUTH_TOKEN`?** Long-lived tokens are inference-only (Claude Code says so itself): connectors and some features degrade, and they can't read the usage endpoint. A real `claude auth login` per profile gets full-scope, auto-refreshing credentials.

**Why a `claude -p` ping instead of calling the token endpoint directly?** Claude Code refreshes under a cross-process lock with compare-and-swap on the stored refresh token. Rotating the token from outside that lock is exactly the kind of race that ends in `invalid_grant` and a signed-out profile. One Haiku call costs nothing measurable and lets Claude Code do it properly.

**Does it switch accounts mid-session?** No; a session is bound to one account. `cswap` gets you the next best thing: because session history is shared across profiles, it re-opens your latest conversation on another account in one command.

**The login page shows my main account.** That's why sign-ins open in a private window by default and pre-fill the overflow account's email. If you'd rather use your normal browser, set `CLAUDE_OVERFLOW_LOGIN_BROWSER=default`. If the wrong account does get authorized, the tool notices (email mismatch), logs that profile out again, and tells you.

**macOS asks about Keychain access.** Click **Always Allow**; that grants `/usr/bin/security` (Apple's own tool) read access to the credential entry. It can reappear after a re-login recreates the entry.

**Windows?** Not supported. PRs welcome.

**What if two sessions run at once on different accounts?** Fine; that's no different from running two Claude Code sessions normally; they share the same project state files either way.

## Uninstall

```bash
bash uninstall.sh
```

Removes the keep-alive job, offers to log out the overflow profiles, removes the rc loader line, and deletes `~/.claude-overflow`. Profiles you adopted from elsewhere and your primary `~/.claude` are never touched.

## License

MIT
