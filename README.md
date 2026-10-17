# claude-max-overflow

Use the model usage from **multiple Claude Max subscriptions** in Claude Code without ever thinking about which account you're on. One **primary** account owns all your configuration; any number of **overflow** accounts provide extra capacity. `claude` becomes a shell function that checks your primary account's live rate limits at launch and transparently starts the session under whichever account has headroom. Overflow credentials are kept alive automatically, and when one genuinely needs a fresh sign-in the tool opens the right login page for you instead of silently falling back. Sessions that ran on an overflow account are [mirrored](#seeing-overflow-sessions-in-claudeai) into your primary account's claude.ai afterwards, so your session history stays in one place there too.

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
- Subcommands (`claude mcp|auth|config|plugin|doctor|update|rc|…`) always run on primary so it stays in control. The one exception is `auth` with an explicit config dir: `CLAUDE_CONFIG_DIR=<profile dir> claude auth status|login|logout` acts on that profile, never on the primary. The list is parsed from `claude --help` and cached per installed binary (`~/.claude-overflow/cache/subcommands`), so new subcommands are picked up on upgrade; hidden ones like `remote-control`/`rc` are added from `_COF_SUBCMDS_HIDDEN`. Scripts and other programs don't see the shell function, so they run the plain binary on primary, unless you install the optional [claude-shim](#scripts-and-programs-claude-shim).
- Locally, everything is one history: `claude --resume`, `--continue` and `cswap` see every session no matter which account ran it. claude.ai is per-account, so after an overflow session exits the wrapper [mirrors](#seeing-overflow-sessions-in-claudeai) it into the primary's claude.ai in the background.
- A **live conversation moves itself** to another account when the current one runs out mid-session, without you doing anything: see [Switching accounts mid-conversation](#switching-accounts-mid-conversation).

## Credential lifecycle

Claude Code's OAuth **access token** lives a few hours. The **refresh token** that renews it lives about 28 days from its last use (each refresh rotates it and extends the clock). If a refresh is ever rejected (`invalid_grant`, e.g. after a revocation or a rare concurrent-refresh race), Claude Code blanks the stored credentials and the profile is signed out. So an overflow account you don't use drifts `ok` → `stale` → `dead`. The tool classifies every account on each look:

| state | meaning | what happens |
|---|---|---|
| `ok` | access token valid | used normally |
| `stale` | access token expired, refresh token live | renewed on the spot by a 1-token `claude -p` ping (no hooks, no MCP, no session file, cheapest model), so Claude Code performs the refresh under its own lock |
| `dead` | signed out / refresh token expired | the browser sign-in is opened **for you** (email pre-filled, private window, verified afterwards that the right account came back); see below for when |

Claude Code can also move a profile's login between its two stores (a plaintext `.credentials.json` written at sign-in, migrated into the macOS Keychain on the next launch). The router checks both before calling an account dead and re-points `accounts.tsv` when the login turns out to live in the other place.

**When a sign-in window opens by itself.** The rule is: whenever signing that account in could plausibly unlock usage. Concretely:

- **A launch needs it now** (`claude` finds primary and every other overflow account at their limits, and the next one in line is signed out): the sign-in runs in the foreground first, then the session starts on that account. Ctrl-C aborts the launch (then `cacct primary` forces primary).
- **A session starts while some account is signed out**: the window opens in the background; the launch does not wait for it. Finish the login whenever; a detached worker verifies the account and tells you when it landed. Re-opened at most every `CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS` (8) per account, so closing the window isn't nagged.
- **A live conversation runs out and only signed-out accounts are left** ([in-session switching](#switching-accounts-mid-conversation)): the window opens immediately. If the turn died on a hard rate limit, the worker moves the paused conversation to that account the moment the login lands; if it was the proactive "nearly out" hop, the next turn boundary does.
- **The keep-alive finds a dead account while you're at the keyboard** (screen unlocked, input within the last `CLAUDE_OVERFLOW_PRESENT_IDLE_MAX` = 300 s): it opens the window too; otherwise it posts a desktop notification once a day.
- Scripts and pipes never see a window; they fall back to primary with a notice. `CLAUDE_OVERFLOW_AUTOLOGIN=ask` restores a `[Y/n]` prompt for the foreground case and disables the background ones; `0` turns all of it off. Log: `~/.claude-overflow/login.log`.

The optional **keep-alive** (`claude-overflow install-keepalive`) runs the same refresh every 12 hours from launchd, so refresh tokens keep rotating and nothing expires while you're away (one retry after 20 s for the wake-from-sleep case).

## Switching accounts mid-conversation

The launch-time picker only chooses an account when a session *starts*. But a long session can run one account dry halfway through. Normally you'd hit the wall, then have to `cswap` by hand. With in-session switching (on by default) the conversation moves itself:

- **When the wall is hit.** If a turn ends because the account hit its rate limit (Claude Code fires a `StopFailure` with `rate_limit`/`overloaded`), the router resolves another account with headroom, ends the session cleanly, and re-launches `--resume <same-session-id>` under that account. Because every profile shares the project directory, the resumed session has the full conversation. You land back in the same chat on a fresh account and keep going.
- **Before the wall, using the buffer.** With `CLAUDE_OVERFLOW_INSESSION_PROACTIVE=1` (default), at any clean turn boundary where the current account is already at/over `CLAUDE_OVERFLOW_INSESSION_AT` (default 95%), it hops at that boundary instead. The turn you were on finishes on the remaining buffer; the switch happens before the next one, so you never actually hit the error.
- **Model-scoped limits are respected.** Some plans have a separate weekly window for one model (e.g. Fable-only). When that window is what ran out (the proactive hop fired on it, or a rate limit arrived while the account's 5h and weekly windows still had room), the next account must have room in that window too; otherwise a session on that model would bounce straight back. The launch picker applies the same rule when only the primary's model-scoped window is over.
- **If nothing has headroom, it pauses.** When no other account has room (all near their limits, or signed out), it does *not* end your session: it leaves the conversation exactly where it is and tells you (a line in the terminal, a desktop notification, and `~/.claude-overflow/insession.log`), so you can wait for a reset or `cswap` later. The conversation is never lost.
- **If what's left is a signed-out account, it opens that account's sign-in right away.** Finish it in the browser; if the pause was a hard rate limit, the conversation moves to that account by itself as soon as the login lands (resend your last prompt); if it was the proactive hop, it moves at the next turn boundary. While the pool is draining it also opens sign-ins (cooldown-limited) for any other signed-out account, so the next one is ready in time.

Mechanically: managed interactive sessions are launched with a tiny `Stop`/`StopFailure` hook injected via `--settings` (it *adds to* your existing hooks, it doesn't replace them), plus a few `COF_*` env vars. The hook (`cof-insession-hook.sh`) is inert for any session the router didn't launch. When it decides to switch it writes the target account and session id into a control file and ends the session with `SIGTERM` (after a ~1s flush); a loop in the wrapper picks that up and resumes on the new account. A switch is one uninterrupted conversation: it stays a single transcript, so `--resume`, tools that read transcripts, and the claude.ai [mirror](#seeing-overflow-sessions-in-claudeai) all still work.

Note that, like `cswap`, resuming under a different login mints a fresh claude.ai session for the new leg (claude.ai is per-account); local continuity is complete, and the post-exit mirror puts a readable snapshot in your primary's claude.ai. Turn it all off with `CLAUDE_OVERFLOW_INSESSION=0`.

A relaunch keeps the flags you launched with that shape the session (`--dangerously-skip-permissions`, `--permission-mode`, `--model`, `--effort`, `--add-dir`, `--mcp-config`/`--strict-mcp-config`, `--plugin-dir`, `--agent`, `--append-system-prompt`, `--chrome`, `--ide`) and drops the ones that pick a session or start a prompt.

### `/restart`

The same machinery gives you a `/restart` slash command (setup installs it to `~/.claude/commands/restart.md` unless you already have one): it ends the session and immediately resumes the same conversation, on the same account, in the same terminal. Use it to pick up anything Claude Code only reads at startup (edited `settings.json` or hooks, new plugins or MCP servers, a changed `CLAUDE.md`, a freshly updated CLI). It runs as a pre-command, so Claude Code exits before the prompt reaches the model: no turn, no usage, and nothing added to the transcript. It only works in sessions the router launched (an interactive `claude` from your shell); anywhere else, or in a conversation with no messages yet, it changes nothing and tells you the `claude --resume <id>` to run by hand.

## Seeing overflow sessions in claude.ai

Claude Code's Remote Control (`remoteControlAtStartup`, on by default in recent versions) registers every interactive session with claude.ai under **the account whose credentials launched it**, and that is the only account whose claude.ai lists it. So on its own, a session that ran on an overflow account shows up in the overflow account's claude.ai, not your primary's; and if you later resume that conversation under the primary, Claude Code mints a fresh claude.ai session but deliberately refuses to upload the earlier transcript into it (it records a `history-suppression` marker in the transcript instead). There is no token or setting that splits "who runs the model" from "who owns the claude.ai session"; the bridge and inference share one credential, and pointing `ANTHROPIC_BASE_URL` at a proxy disables Remote Control entirely.

What does work is a **mirror**: after an overflow session exits, the wrapper makes a clean copy of its transcript under a fresh session id (dropping the ownership pointer and any suppression markers), resumes that copy under the primary as an idle background session (`claude --bg`), waits for Claude Code to backfill the conversation into the new, primary-owned claude.ai session (about ten seconds, no model calls), stops the helper session, and deletes the copy. The result is a read-only snapshot in your primary's claude.ai, titled `<title> · via <label>`, holding the same post-compaction context a native session would show. Mirroring the same conversation again (after continuing it on an overflow account) replaces the previous snapshot. The original transcript is never modified, and the overflow account's own claude.ai entry is left alone.

- Automatic: every interactive overflow session is mirrored in the background when it exits (a dim one-liner tells you; a desktop notification carries the link; `~/.claude-overflow/mirror.log` has the details). Print-mode, `--bg` and non-persisted sessions are skipped.
- Manual: `claude-overflow mirror <session-id|last>` (`--force` to snapshot a primary-owned session too); `claude-overflow mirrors` lists what has been mirrored.
- Requirements: the primary must already trust the session's directory (open it once with `cacct primary`), and Remote Control must be enabled; otherwise the session is skipped with a note.
- Each mirror leaves a stopped helper session behind in `claude agents` / `~/.claude/jobs` (named like the snapshot); `claude rm <id>` removes it, or set `CLAUDE_OVERFLOW_MIRROR_CLEANUP=rm` to do that automatically.
- Snapshots are for reading (and for your other devices). To continue the conversation, use `claude --resume` / `cswap` on your machine as usual; the local history is shared anyway.

## Dashboard

`claude-overflow dashboard` (or `claude_router`, which setup links next to `claude-on`) starts a small localhost server in the background, or reuses the one already running, and opens a live page in your browser. It refreshes every minute and the server exits by itself 45 minutes after the last tab stops polling it (or use its *Stop server* button). Python 3 stdlib only; port 8787 (`COF_DASH_PORT` to change).

What it shows (at-a-glance pies on top, dense detail below the *Details* divider):
- **+ Add account**: sign in with another Claude account and add it to the router from the page. Enter its email (pre-fills and verifies the sign-in; optional) and a short name (suggested from the email); the dashboard runs `claude-overflow add` and opens the usual private-window browser sign-in, and the account shows up once you finish. A signed-out account can be unregistered with *Remove from router* (two clicks; its profile folder is kept).
- **Pie charts**: all accounts' combined weekly usage and combined Fable-only (model-scoped) usage, each sliced by account, plus one weekly pie and one 5-hour pie per account.
- **Where the next `claude` launch goes** and why: a read-only replay of the router's picker against live data, including which thresholds pushed it off the primary.
- **Pool headroom**: weekly and 5-hour headroom summed across accounts (primary counted up to its switch-off thresholds, overflow up to `CLAUDE_OVERFLOW_FULL_AT`), plus the pool's burn rate over the last 24 h and the runway at that pace.
- **Per account**: 5h / weekly / model-scoped windows with reset countdowns and the router's threshold ticks, extra-usage credits, any other windows the usage API reports, this week's usage split by surface, token and refresh-token expiry, credential store, and live-session count. Stale overflow tokens are renewed through the router's own ping (a 1-token `claude -p`, same as `claude-overflow refresh`) so their usage is readable; signed-out accounts get an *Open sign-in* button.
- **History charts** from `~/.claude-overflow/usage-history.jsonl`: the router appends one compact sample every time it actually fetches usage (launch picks, the in-session hook's turn-end checks, the dashboard), and the dashboard also reads the usage readings recorded in `insession.log` at each hop.
- **Router health**: install checks, keep-alive schedule, signed-out or soon-expiring logins, credential-store migrations, sessions that can't hop, and **ping-pong detection** (4+ hops back and forth between the same two accounts, each within 15 minutes of the last; bursts from before the 2026-09-26 model-scoped fix are shown as history).
- **In-session hops** per day and as a table, **live Claude Code sessions** (account, managed or not, Remote Control), keep-alive / sign-in / mirror logs, effective config, and local output tokens per day by model from your transcripts (all accounts combined; transcripts don't record which account served a turn).

Rate limits: the usage endpoint returns HTTP 429 when polled too often, and the router needs it for its own picks, so the dashboard reuses any account's usage (its own or the router's cache file) for 5 minutes, backs off an account for 10 minutes after a 429 (even on *Refresh now*), and doesn't fetch at all while its tab is in the background.

Safety: binds `127.0.0.1` only, rejects requests whose `Host` header isn't localhost (DNS rebinding), and requires a per-run token on every action (CSRF). OAuth tokens are read in the server process and never sent to the page.

## Claude knows about the router (claude-router plugin)

Without help, a Claude Code session has no idea it is one of several subscriptions, how much of its account is left, or that a big fan-out might not fit. The **claude-router** plugin (in this repo: `plugin/`, with the repo itself as the marketplace) fixes that for every session on every account. Plugins live in the shared `~/.claude/plugins`, so overflow profiles get it too; a user-scope MCP server would not reach them, because each profile has its own `.claude.json`.

- **Session start** (hook): a `<claude-router>` block tells Claude:
  - that the router exists, and which account this session runs on;
  - whether the router manages it, and what a hop means (the conversation resumes on another account at the next turn end, and background agents or workflows running at that moment are lost);
  - every account's 5h, weekly and model-scoped usage with reset times, pool headroom, and what a new launch would pick;
  - warnings, such as a nearly full account, signed-out accounts, or an `ANTHROPIC_API_KEY` in the environment.
- **Each prompt** (hook, normally silent): one line when this session's account crosses 80, 90 or 95%, recovers after a reset, or the router pauses the conversation. It reads the cache only; a stale cache is refreshed by a detached background process, so prompts never wait on the network (about 70 ms).
- **Before `Agent` / `Workflow` calls** (hook): if this account is at 60%+ (Workflow or background Agent) or 85%+ (foreground Agent), Claude gets a capacity note first. The note gives the other accounts' headroom and ways to fit the work: smaller batches with checkpointed results, or running shards on the account with the most room. The same note repeats at most every 20 minutes per session.
- **MCP server `claude-router`** (`cof-mcp.py`, stdlib, runs in the calling session's environment so it knows its account):
  - `router_status`: usage and resets, headroom, burn rate and runway, the pick, warnings;
  - `router_hops`: the hop log, with ping-pong detection;
  - `router_open_dashboard`.
- **Skill `claude-router`**: the playbook for splitting a big job across accounts.
- **Status line segment** (optional, not part of the plugin, since a status line is personal): `cof-statusline.py` reads Claude Code's status-line JSON and prints e.g. `acct:work fable:91% pool:42% next:alt`. The parts are:
  - `acct:` the account this session is on; `(fixed)` means the router can't move it;
  - the Fable window, shown when this session uses Fable or it is at 50%+;
  - `pool:` weekly usage across every account;
  - `next:` shown once this account is at 80%+, naming where a hop would go.
  5h and 7d for the current account already come from Claude Code's own `rate_limits`. Add it to your status-line script with `router_seg=$(printf '%s' "$input" | python3 ~/.claude-overflow/cof-statusline.py)`. It is cache-only and takes about 70 ms.
- **Stale logins get renewed on demand.** An unused account's access token expires after about 8 hours, which otherwise leaves its usage unreadable until the next keep-alive. Whenever the plugin or status line finds a stale login, a background job runs the router's own 1-token ping, so Claude Code refreshes the token itself under its lock, then reads the usage. This happens at most every 30 minutes per account. Other accounts' readings are refreshed in the background every 15 minutes, or 5 for the session's own account, while any session is active. Set `RENEW_LOGINS = False` in `cof-context.py` to leave renewal to the keep-alive.

Subagents always bill the calling session's account, so the way to actually put work elsewhere is **`claude-on <label|primary> [claude args]`**. It is a headless `claude -p` run on the chosen account, and it works from inside Claude Code's Bash tool. Inside that tool, the shell snapshot has `cacct` but not the router's helpers, so a bare `cacct work` would have silently run on primary; `cacct` now hands off to `claude-on` there. `claude-on` clears the calling session's router state, and the hooks confirm "managed" by checking that the router's recorded claude pid is the nearest claude process above them. A `-p` child of a managed session therefore never mistakes itself for the parent.

Everything reuses the dashboard's code, cache files, 5-minute usage TTL and a 429 backoff that is now persisted (`cache/ctx/backoff-<label>`) and honoured by the dashboard too. Per-session state lives in `cache/ctx/sess-<id>.json` and is pruned after 3 days.
- Silence it for one session with `CLAUDE_ROUTER_CONTEXT=0`, or turn it off with `claude plugin disable claude-router@claude-max-overflow`.
- `setup.sh` offers the install; `uninstall.sh` removes it.
- The hook and MCP commands run `~/.claude-overflow/cof-context.py` and `cof-mcp.py`, so code changes are live. Edits to the plugin's manifests or skill need a version bump plus `claude plugin marketplace update claude-max-overflow && claude plugin update claude-router@claude-max-overflow`.

## Scripts and programs (claude-shim)

The `claude` shell function only exists in your interactive shell. Anything that runs `claude` as a program gets the plain binary instead: scripts, `timeout`/`xargs`, Python's `subprocess`, and Claude Code's own Bash tool (its shell snapshot keeps the `claude` function but not the router's helpers, so the function falls back to whatever `claude` is on PATH). Those runs always use the primary account, and they bill `ANTHROPIC_API_KEY` instead of your subscription if that variable is set.

The optional **claude-shim** closes that gap. `setup.sh` offers it (default: no) and installs it as `~/.claude-overflow/shim/claude`; the loader then puts that directory first on PATH in every shell that sources it. The shim loads the router and hands off to its `claude` function, so a scripted `claude -p …` picks an account by live usage like an interactive launch does, subcommands still run on primary, and `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` are stripped.

- It's opt-in because it changes what `claude` means for every program you start from a shell. A script that relies on API-key billing should call `CLAUDE_OVERFLOW_SHIM=0 claude …`, which runs the real binary with the environment untouched.
- Programs that don't inherit your shell's PATH (launchd agents, cron, apps started from the Dock) don't see it.
- `claude-overflow doctor` shows the real binary the router uses and whether the shim is actually first on PATH (a line later in your shell rc that prepends `~/.local/bin` would put the binary back in front).

The router itself never runs Claude Code through a PATH lookup. Everything that targets one specific account (launches, refresh pings, sign-ins, mirrors, `--help` parsing) goes through `_cof_bin`, which skips the shim, follows a small wrapper script to the binary it names, and lands on the real executable. This matters: on 2026-10-16 a hand-made `~/bin/claude` wrapper of exactly this kind (load the router, call its `claude` function) sat in front of the binary, and a background sign-in for an overflow account resolved `claude` through PATH, re-entered the router, was treated as a primary-account subcommand, and wrote the overflow account's login into the primary's credential slot. `tests/test-bin-resolution.sh` reproduces that setup offline and checks every such path. As a second line of defence, the shim refuses to re-enter itself: if router code ever does resolve `claude` through PATH again, the shim runs the real binary with the account's `CLAUDE_CONFIG_DIR` intact instead of recursing.

If you already keep your own wrapper of this kind (e.g. `~/bin/claude`), it keeps working: the router follows it to the binary it names by absolute path.

## Requirements

- Claude Code with a claude.ai (subscription) login on the primary account
- `jq`, `curl`
- `python3` (standard library only) for the dashboard, the claude-router plugin and the status-line segment; the router itself is plain shell
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
| `/restart` (inside a session) | restart Claude Code and resume this same conversation on the same account (see [`/restart`](#restart)) |
| `climits` | every account's 5h/weekly/model-scoped % + reset times + extra-usage spend + credential state |
| `claude-overflow login <label\|all>` | browser sign-in for one profile (email pre-filled, private window, verified); `all` = every signed-out one in turn. Normally you don't need this: the router opens sign-ins by itself |
| `claude-overflow refresh [label]` | renew stale tokens now |
| `claude-overflow install-keepalive` | schedule the 12-hourly refresh (macOS launchd; prints a cron line on Linux) |
| `claude-overflow mirror <session-id\|last>` | snapshot a conversation into the primary's claude.ai (automatic after overflow sessions; see [above](#seeing-overflow-sessions-in-claudeai)) |
| `claude-overflow mirrors` | list the snapshots made so far |
| `claude-overflow dashboard` / `claude_router` | live HTML dashboard in your browser (see [Dashboard](#dashboard)) |
| `claude-on <label\|primary> …` | run Claude Code on one specific account from any shell, including Claude Code's own Bash tool (`claude-on work -p "…"`); see [claude-router plugin](#claude-knows-about-the-router-claude-router-plugin) |
| `claude-overflow add\|remove\|sync\|doctor\|status` | manage accounts, resync trust, diagnose |
| `CLAUDE_ACCOUNT=<label> claude …` | one-off override via env |
| `CLAUDE_CONFIG_DIR=<profile dir> claude auth …` | `auth status/login/logout` for that profile (every other subcommand runs on primary) |
| `CLAUDE_OVERFLOW_SHIM=0 claude …` | with the [claude-shim](#scripts-and-programs-claude-shim) installed: skip it for one call (real binary, environment untouched) |

Tuning (env vars, or `~/.claude-overflow/config.sh`):

| var | default | meaning |
|---|---|---|
| `CLAUDE_OVERFLOW_SESSION_AT` | 85 | switch when primary's 5h window ≥ this % |
| `CLAUDE_OVERFLOW_WEEKLY_AT` | 92 | …or weekly ≥ this % |
| `CLAUDE_OVERFLOW_SCOPED_AT` | 92 | …or a model-scoped weekly limit ≥ this % |
| `CLAUDE_OVERFLOW_FULL_AT` | 97 | an overflow account counts as exhausted at this % |
| `CLAUDE_OVERFLOW_TTL` | 60 | seconds to cache usage checks |
| `CLAUDE_OVERFLOW_AUTOREFRESH` | 1 | renew stale overflow tokens inline before deciding |
| `CLAUDE_OVERFLOW_AUTOLOGIN` | 1 | `1`: open the browser sign-in for dead accounts by yourself (foreground when a launch needs it, background otherwise); `ask`: prompt `[Y/n]` first, no background windows; `0`: only report |
| `CLAUDE_OVERFLOW_LOGIN_BROWSER` | private | `private` (Chrome/Brave incognito, Firefox private window), `default` (system browser), or a command template containing `{url}` |
| `CLAUDE_OVERFLOW_LOGIN_RETRY_HOURS` | 8 | a background sign-in window for the same account is re-opened at most this often (a launch that needs the account right now ignores this) |
| `CLAUDE_OVERFLOW_LOGIN_TIMEOUT` | 900 | seconds a background sign-in waits for you to finish in the browser |
| `CLAUDE_OVERFLOW_PRESENT_IDLE_MAX` | 300 | the keep-alive opens a sign-in only if there was keyboard/mouse input within this many seconds (and the screen is unlocked) |
| `CLAUDE_OVERFLOW_PING_MODEL` | haiku | model used by the refresh ping |
| `CLAUDE_OVERFLOW_KEEPALIVE_HOURS` | 12 | keep-alive cadence |
| `CLAUDE_OVERFLOW_MIRROR` | 1 | mirror overflow sessions into the primary's claude.ai when they exit |
| `CLAUDE_OVERFLOW_MIRROR_CLEANUP` | stop | `stop` keeps the helper background session listed in `claude agents`; `rm` deletes it |
| `CLAUDE_OVERFLOW_MIRROR_TIMEOUT` | 90 | seconds to wait for a mirror's upload to settle |
| `CLAUDE_OVERFLOW_INSESSION` | 1 | move a live conversation to another account when the current one runs out ([details](#switching-accounts-mid-conversation)) |
| `CLAUDE_OVERFLOW_INSESSION_PROACTIVE` | 1 | also hop at a clean turn boundary once near the limit (uses the buffer to finish the turn first); 0 = only when the wall is actually hit |
| `CLAUDE_OVERFLOW_INSESSION_AT` | 95 | proactive hop threshold (% of any window), higher than the launch thresholds so most of the buffer is used first |
| `CLAUDE_OVERFLOW_INSESSION_KILL_DELAY` | 1 | seconds to let the transcript flush before ending the session to resume elsewhere |

Switching *before* 100% is deliberate: if your primary has **extra usage** enabled, overflowing there costs real money; overflowing to a subscription you already pay for costs nothing.

## FAQ

**Is this allowed?** This tool is for people using **their own, separately paid** subscriptions, each within its own limits; it's an account *switcher*, not a limit bypass. It does not create accounts, share accounts, or evade any per-account enforcement. That said, this is not legal advice, the author is not affiliated with Anthropic, and you're responsible for your own accounts.

**Why not `claude setup-token` + `CLAUDE_CODE_OAUTH_TOKEN`?** Long-lived tokens are inference-only (Claude Code says so itself): connectors and some features degrade, and they can't read the usage endpoint. A real `claude auth login` per profile gets full-scope, auto-refreshing credentials.

**Why a `claude -p` ping instead of calling the token endpoint directly?** Claude Code refreshes under a cross-process lock with compare-and-swap on the stored refresh token. Rotating the token from outside that lock is exactly the kind of race that ends in `invalid_grant` and a signed-out profile. One Haiku call costs nothing measurable and lets Claude Code do it properly.

**Does it switch accounts mid-session?** Yes, automatically. A single Claude Code process is bound to one account, so "switching" means ending the session and resuming the *same conversation* (`--resume <session-id>`, shared history) under another account. The router does this for you the moment the current account runs out: see [Switching accounts mid-conversation](#switching-accounts-mid-conversation). `cswap` remains the manual version for when you just want to hop on purpose.

**Why isn't my overflow session in claude.ai / on my phone?** claude.ai lists a session only under the account that ran it. The wrapper mirrors overflow sessions into your primary's claude.ai when they exit (see [Seeing overflow sessions in claude.ai](#seeing-overflow-sessions-in-claudeai)); if one is missing, check `~/.claude-overflow/mirror.log` (usually the primary hasn't trusted that folder yet) or run `claude-overflow mirror last`.

**The login page shows my main account.** That's why sign-ins open in a private window by default and pre-fill the overflow account's email. If you'd rather use your normal browser, set `CLAUDE_OVERFLOW_LOGIN_BROWSER=default`. If the wrong account does get authorized, the tool notices (email mismatch), logs that profile out again, and tells you.

**macOS asks about Keychain access.** Click **Always Allow**; that grants `/usr/bin/security` (Apple's own tool) read access to the credential entry. It can reappear after a re-login recreates the entry.

**Windows?** Not supported. PRs welcome.

**What if two sessions run at once on different accounts?** Fine; that's no different from running two Claude Code sessions normally; they share the same project state files either way.

## Uninstall

```bash
bash uninstall.sh
```

Removes the keep-alive job, offers to log out the overflow profiles, removes the claude-router plugin, the `claude-on` / `claude_router` links, the claude-shim and the rc loader line, and offers to delete `~/.claude-overflow`. Profiles you adopted from elsewhere and your primary `~/.claude` are never touched.

## Development

- The loader is one POSIX-ish file that must pass both `bash -n claude-overflow.sh` and `zsh -n claude-overflow.sh`; the Python parts are stdlib only.
- `bash tests/test-bin-resolution.sh` runs offline in a few seconds (bash and zsh): a fake Claude Code binary records which config dir every launch, refresh ping, sign-in and `auth` call reaches, with a router-re-entering wrapper or the claude-shim first on PATH; Keychain, network and notifications are stubbed.
- To work on a live install, symlink the files in `~/.claude-overflow` to your clone instead of copying them, so edits take effect immediately. Shells opened before an edit keep the old functions in memory until you open a new one.

## License

MIT
