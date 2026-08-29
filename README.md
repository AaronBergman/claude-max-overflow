# claude-max-overflow

Use the model usage from **multiple Claude Max subscriptions** in Claude Code without ever thinking about which account you're on. One **primary** account owns all your configuration; any number of **overflow** accounts provide extra capacity. `claude` becomes a shell function that checks your primary account's live rate limits at launch and transparently starts the session under whichever account has headroom.

> ⚠️ **Experimental.** This is a young project, lightly tested (macOS + zsh primarily; Linux/bash support is best-effort and less exercised). It reads Claude Code's OAuth credentials from your OS credential store and calls the same undocumented usage endpoint that powers `/usage` — any Claude Code update could break it. Nothing here touches your primary login, and there's a clean [uninstall](#uninstall), but treat it accordingly.

## Why

- Max plans have 5-hour and weekly rate-limit windows per account. If you own more than one subscription (e.g. a personal one and one through school/work), overflow capacity sits idle while you wait out a limit — or worse, while **extra usage** silently bills your card.
- Anthropic doesn't (yet) offer multi-account support in Claude Code. Manually running `/login` back and forth loses your flow and forks your settings.
- This tool keeps **one account authoritative for all config** — settings, skills, agents, hooks, plugins, history, memory — and treats the others as pure model capacity. Session history is shared, so you can hit a limit mid-conversation, type `cswap`, and continue the same conversation on another account.

## How it works

- Each overflow account gets an isolated profile via `CLAUDE_CONFIG_DIR` (`~/.claude-overflow/profiles/<label>`). Claude Code namespaces credentials per config dir (macOS Keychain: `Claude Code-credentials-<hash>`; Linux: per-dir `.credentials.json`), so all accounts stay logged in simultaneously — this is the supported-ish part.
- Each profile is a **symlink farm** back into your primary `~/.claude`: `settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `hooks/`, `plugins/`, `projects/` (session history + memory), `history.jsonl`, etc. are literally the same files. Only credentials and the per-profile `.claude.json` (account identity + per-project trust, one-way synced from primary before each overflow launch) differ.
- The `claude` wrapper function calls `GET https://api.anthropic.com/api/oauth/usage` with the primary's OAuth token (60s cache, 4s timeout, fail-open to primary):
  - primary under thresholds → primary, silently, exactly as before;
  - primary ≥ 85% of the 5h window, or ≥ 92% weekly → walks your overflow accounts in the order you added them and launches the first one with headroom, printing a dim one-liner so you always know;
  - everything exhausted → primary (visible notice).
- Config-management subcommands (`claude mcp|auth|config|plugin|doctor|update|…`) always run on primary so it stays in control. Scripts/cron never see the shell function and keep using primary.

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

The guided setup checks prerequisites, then for each overflow account: builds the profile, opens Claude Code's normal browser OAuth (**you pick which account to authorize** — a private window logged into claude.ai as the overflow account is the easy way), records where its credentials live, and wires a `source` line into your shell rc. Re-run it any time to add more accounts. It never modifies your primary `~/.claude`.

## Commands

| command | does |
|---|---|
| `claude …` | auto-picks an account (primary-preferred); inert until setup is done |
| `cacct <label\|primary> …` | force a specific account (setup also creates `c-<label>` aliases) |
| `cswap` | `--continue` your latest conversation on a *different* account — the "hit a limit mid-session" escape hatch |
| `climits` | every account's 5h/weekly/model-scoped % + reset times + extra-usage spend |
| `claude-overflow status\|sync\|doctor` | small utility CLI |
| `CLAUDE_ACCOUNT=<label> claude …` | one-off override via env |

Tuning (env vars, or `~/.claude-overflow/config.sh`):

| var | default | meaning |
|---|---|---|
| `CLAUDE_OVERFLOW_SESSION_AT` | 85 | switch when primary's 5h window ≥ this % |
| `CLAUDE_OVERFLOW_WEEKLY_AT` | 92 | …or weekly ≥ this % |
| `CLAUDE_OVERFLOW_SCOPED_AT` | 92 | …or a model-scoped weekly limit ≥ this % |
| `CLAUDE_OVERFLOW_FULL_AT` | 97 | an overflow account counts as exhausted at this % |
| `CLAUDE_OVERFLOW_TTL` | 60 | seconds to cache usage checks |

Switching *before* 100% is deliberate: if your primary has **extra usage** enabled, overflowing there costs real money; overflowing to a subscription you already pay for costs nothing.

## FAQ

**Is this allowed?** This tool is for people using **their own, separately paid** subscriptions, each within its own limits — it's an account *switcher*, not a limit bypass. It does not create accounts, share accounts, or evade any per-account enforcement. That said, this is not legal advice, the author is not affiliated with Anthropic, and you're responsible for your own accounts.

**Why not `claude setup-token` + `CLAUDE_CODE_OAUTH_TOKEN`?** Long-lived tokens are inference-only (Claude Code says so itself): connectors and some features degrade, and they can't read the usage endpoint. A real `claude auth login` per profile gets full-scope, auto-refreshing credentials.

**Does it switch accounts mid-session?** No — a session is bound to one account. `cswap` gets you the next best thing: because session history is shared across profiles, it re-opens your latest conversation on another account in one command.

**macOS asks about Keychain access.** Click **Always Allow** — that grants `/usr/bin/security` (Apple's own tool) read access to the credential entry. It can reappear after a re-login recreates the entry.

**Windows?** Not supported. PRs welcome.

**What if two sessions run at once on different accounts?** Fine — that's no different from running two Claude Code sessions normally; they share the same project state files either way.

## Uninstall

```bash
bash uninstall.sh
```

Offers to log out the overflow profiles, removes the rc loader line, and deletes `~/.claude-overflow`. Your primary `~/.claude` is never touched.

## License

MIT
