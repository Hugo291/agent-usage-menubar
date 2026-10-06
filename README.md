# Agent Usage — Claude, Codex and Ollama in your menu bar (macOS)

A tiny native macOS menu-bar widget that shows **what you have left** across
**Claude**, **Codex** and **Ollama Cloud**, at a glance:

- ⌛ your **5-hour** rolling window and 🗓 your **weekly** quota — for each
  (Ollama reports a **session** window instead of a 5-hour one);
- 💲 today's **combined cost** (via [`ccusage`](https://github.com/ryoppippi/ccusage)) with an **end-of-day projection**;
- 🔔 an optional **notification** the moment a quota window resets.

The menu-bar icons stay monochrome and only turn **orange/red** when a quota gets low.
Click them for the full breakdown.

**▶︎ Live demo & screenshot:** <https://hugo291.github.io/agent-usage-menubar/>

```
  ⌛70%  🗓20%  $436            ← menu bar (here: Claude — see "Menu bar" below)
┌────────────────────────────────────┐
│ Usage — Claude · Codex · Ollama    │
│ Claude · max                 $436  │
│  ⌛ 5h    ▬▬▬▬▬▬▭▭▭▭   70%         │
│    resets today at 05:37 · in 2 h  │
│  🗓 week  ▬▬▭▭▭▭▭▭▭▭   20%          │
│    resets tomorrow at 15:37        │
│ Codex · plus                 $0.75 │
│  🗓 week  ▬▬▬▬▬▬▬▭▭▭   78%          │
│    resets Mon 21 Jul · in 74 h     │
│  last reading 2 min ago            │
│ Ollama · pro                       │
│  ⚡ session ▬▬▬▬▬▬▬▬▬▬  100%       │
│  🗓 week   ▬▬▬▬▬▬▬▭▭▭   73%         │
│ Today $437 · ~$768 projected       │
│ Menu bar ▸ · Language ▸ · Refresh  │
└────────────────────────────────────┘
```

## Notification Centre / desktop widget

Besides the menu bar, the app ships two real **WidgetKit widgets**. Add them the usual way —
right-click the desktop → **Edit Widgets**, or click the clock → scroll down → **Edit Widgets**:

| Widget | Shows | Sizes |
|---|---|---|
| **Agent Usage** | Claude + Codex quotas, today's cost, projection — **plus Ollama Cloud on the large size** | small, medium, large |
| **Agent Usage — Cost detail** | today's cost **split by token type** (cache read / cache write / output / input), with a proportion bar per row | small, medium, large |

Both **large** sizes also carry a **token-share bar**: today's tokens split by provider, as a
stacked bar with a legend (`Claude 97% · Codex 3%`). It is on the large sizes only — a widget
does not scroll, and the smaller ones are already full. **Ollama Cloud is deliberately absent
from it** because its API reports `request_count`, not tokens; folding requests into a token
comparison would make the percentages wrong.

The split is the same one the menu-bar app computes — no prices are hardcoded, a known total is
divided by price *ratios*, so the rows always add up to the cost shown.

It is installed automatically by `install.sh`; nothing extra to do.

**How it gets its numbers.** A widget extension is *always sandboxed*, so it cannot run `ccusage`,
read the keychain, or look inside `~/.codex`. The menu-bar app therefore stays the engine: after
each successful refresh it writes a small JSON snapshot into the **extension's own container** and
asks the system to redraw. A sandbox may always read its own container, which is what lets this
work with a plain ad-hoc signature — an App Group would have required a paid Apple Team ID.

Two consequences worth knowing:

- **The menu-bar app must be running** (it is, at login). If it never ran, the widget says so
  rather than showing zeros.
- **The widget is a mirror, not a live view.** macOS budgets widget reloads; the app pushes a
  refresh whenever it has fresh data, and the widget falls back to a 15-minute timer.

## What the menu bar shows

The dropdown always lists **every** provider it has data for. The bar itself is yours to choose,
from the **Menu bar** submenu — handy when one provider runs dry and you want another under your
eyes without clicking:

| Choice | Bar shows |
|---|---|
| **Claude** (default) | `⌛70% 🗓20% $436` — Claude's 5h + weekly, and Claude's cost |
| **Codex** | `🗓78% $0.75` — Codex's weekly, and Codex's cost |
| **Ollama** | `⚡100% 🗓73%` — Ollama's session + weekly, and **no cost**: its API only reports a 4-week figure, which would clash with the daily numbers everywhere else |
| **Total cost** | `$437` — the combined spend, nothing else |

The cost always follows the same choice, so the whole bar talks about one thing.

**Total cost** shows money only, on purpose: dollars add up across providers, percentages don't
(70% left of Claude's weekly and 78% of Codex's are two unrelated resources — a sum or an average
of them would be a made-up number). The percentages stay one click away in the dropdown.

## Install

One line downloads it, builds it, installs it to `~/Applications`, enables auto-start
at login, and launches it. Nothing to clone, nothing else to set up.

```bash
# macOS 12+, needs the Xcode Command Line Tools:  xcode-select --install
curl -fsSL https://raw.githubusercontent.com/Hugo291/agent-usage-menubar/main/install.sh | bash
```

Prefer to see the code first? Clone it and run the same script:

```bash
git clone https://github.com/Hugo291/agent-usage-menubar.git
cd agent-usage-menubar && ./install.sh
```

Uninstall any time (stops it, disables auto-start, removes the app):

```bash
curl -fsSL https://raw.githubusercontent.com/Hugo291/agent-usage-menubar/main/install.sh | bash -s uninstall
```

> **Optional:** install [`ccusage`](https://github.com/ryoppippi/ccusage)
> (`npm i -g ccusage`) to unlock the daily **$ cost** and **token** figures. The quota
> percentages work without it.

## Where the numbers come from

These are **real server-side numbers**, not a local guess.

### Claude — live, account-wide
The 5-hour / weekly percentages come from `GET https://api.anthropic.com/api/oauth/usage`,
read with the OAuth token Claude Code stores in your **macOS keychain**. On a Max plan these
limits are **shared across all Claude surfaces** (Desktop, Code, claude.ai), so the figures
already include your Desktop usage.

**Self-refreshing token (no terminal needed).** The OAuth access token expires every few
hours. The widget **renews it itself** using the refresh token in the keychain, then writes
the updated item back — so you never have to keep a terminal open. It only ever touches the
access/refresh token; it never reads your prompts.

**Gentle on the endpoint.** `/usage` rate-limits rapid polling, so the widget refreshes in
the background every ~10 min and, on menu open, only re-fetches when the data is older than
5 minutes — otherwise it shows the cached value. A transient `429` is treated as harmless.

### Codex — read from local logs (no API)
The widget reads quota snapshots from local Codex logs. It classifies windows by
`window_minutes`, rather than assuming that `primary` always means 5 hours: the
available windows depend on the account and the budget Codex reports.

The reading comes from `~/.codex/sessions/**/rollout-*.jsonl` (`rate_limits` events
for the account's `codex` budget), and, on versions that still log them, the
`X-Codex-*` response headers in `~/.codex/logs_2.sqlite`. The freshest reading wins.
The widget and menu show **remaining** quota (`100 − used_percent`), whereas Codex
may show consumption.

These logs only change when Codex makes a call. The menu-bar app reads them every
minute and when opening the menu, independently of Claude's API and retry backoff.
It shows the age of the reading in both the menu and the desktop widget. Costs
and the other providers also refresh when Claude's API is unavailable; cached
Claude quotas keep their original refresh timestamp. macOS still controls when
a WidgetKit redraw request is displayed.

### Ollama Cloud — opt-in, needs an API key
Ollama Cloud publishes its quota at `GET https://ollama.com/api/usage`, and nothing else works:
there is no local trace to read (the desktop app's database only holds conversations), and the
CLI's Ed25519 signature is only good for the model registry. So this section is **off unless you
opt in**:

```bash
# create a key at https://ollama.com/settings/keys, then:
printf '%s' 'YOUR_KEY' > ~/.ollama/widget-key && chmod 600 ~/.ollama/widget-key
```

The widget reads that file at each refresh and never writes the key anywhere. With no file, the
Ollama section simply does not appear — the menu, the widgets and the **Menu bar ▸ Ollama** choice
all skip it, and nothing else changes.

The account **plan** shown next to the name (`Ollama · pro`) comes from `POST /api/me`.

Two windows are shown, **session** and **weekly** — the API reports each as a consumed fraction
(`usage: 1` means the quota is spent, which is what a `429 … reached your session usage limit`
looks like from the CLI). The account **plan** comes from `POST /api/me`.

**Only server-reported quotas are displayed.** A consumed fraction of 0.706 means
70.6% used and 29.4% remaining; every gauge in this app shows **remaining** quota.
An empty session (`usage: 0`, `models: []`) is labelled inactive rather than shown
as a full gauge. HTTP/format failures clear the gauges and display an unavailable
status instead of silently keeping old values. The menu shows the reading's age.

**Reset dates are not inferred.** The four-week activity period is not a weekly
quota reset, and decreases in usage do not prove a fixed session period. Only an
explicit `resets_at` field from the quota window can produce a countdown; otherwise
the app says that Ollama did not provide the reset time. Old inferred cache dates
are discarded. New credit-based Ollama plans may not correspond to this legacy
session/weekly endpoint; a monthly balance must not be fabricated from it.

Ollama's `activity.cost` covers the **last 4 weeks**, not today, so it is labelled as such and is
never added to the daily total or the projection.

### Local models (Ollama + LM Studio) — automatic counting
Models running on your own Mac have **no quota and no bill**, so there is no percentage
and no dollar figure to show. What there *is* to count is **tokens and requests, per
model** — and that is what this section does.

**The section appears on its own** as soon as either runtime answers on its default port
(Ollama on `11434`, LM Studio on `1234`), listing what is loaded in memory. The token counter starts automatically with the menu-bar app.

**Why a response counter and not a log file.** Neither runtime keeps a usage total you
could read after the fact:

- Ollama's `~/.ollama/logs/server.log` is a Gin **access log** — method, path, status,
  latency, one line per call. No tokens, no model name. Persisting a token total is
  still an [open feature request](https://github.com/ollama/ollama/issues/11118).
- LM Studio prints token counts, but only into `~/.lmstudio/server-logs/` while its
  server is running, in an unversioned text format — and not at all for chats held in
  its own window.

The exact numbers exist in exactly one place: **the responses themselves**, where both
runtimes report their own counts (`prompt_eval_count` / `eval_count` for Ollama,
`usage.prompt_tokens` / `completion_tokens` on the OpenAI-compatible routes both
expose). So the widget reads them there, as they go past.

**Counting is enabled automatically**, with no menu switch. The app listens on the
loopback address only, at **the runtime's port + 1**, and forwards everything to the
real runtime. Point your client at it and its traffic is counted:

| Runtime | Counter address | What to change client-side |
|---|---|---|
| Ollama | `127.0.0.1:11435` | `OLLAMA_HOST=127.0.0.1:11435` |
| LM Studio | `127.0.0.1:1235` | base URL → `http://127.0.0.1:1235/v1` |

Nothing is rewritten in transit — bytes are relayed **verbatim** in both directions and
merely read on the way back, so chunked encoding, SSE streaming and keep-alive keep
working exactly as before. The worst a mistake there can do is miscount; it cannot
corrupt a request. Quitting the menu-bar app closes both counter ports.

Two honest limits: **only traffic that goes through the counter is counted** (anything
sent straight to `11434` / `1234` stays invisible, by construction), and the counters
**reset at local midnight** — this is a "today" figure, like the costs above, not an
archive. If the port is already taken the menu says so rather than counting nothing in
silence.

Local tokens are deliberately kept **out of** the daily cost, the projection and the
widget's token-share bar: that bar compares *billed* tokens, and folding in free ones
would make its percentages mean nothing.

### Cost & tokens
`ccusage claude daily` (Claude only — not the agent-wide `ccusage daily`, which would fold in
Codex and others) and `ccusage codex daily` (Codex) provide today's cost and token counts. Each
cost is the **equivalent API price** — `input × in-price + output × out-price + cache-write ×
write-price + cache-read × read-price`, summed per model. It's what the usage *would* cost
pay-as-you-go, **not** what a subscription actually bills.

**Where the money goes.** **Hover either cost** in the menu for a per-token-type split — usually
a reminder that *cache*, not output, drives the number. Prefer it always visible? Toggle **Show
cost by token type** in the menu to pin the breakdown as its own rows under each provider. The
split needs no hardcoded prices: it distributes the known total using price *ratios* only.
- **Claude** — cache read / cache write / output / input. Anthropic's ratios are identical on
  every model (output 5×, cache-write 1.25×, cache-read 0.1× input), so the split is exact.
- **Codex** — cache read / output / input. Cache-read is 0.1× input across the whole GPT-5
  family; the output multiplier is 8× up to gpt-5.3 and 6× from gpt-5.4 on, read from the model
  name and averaged when a day mixes models. There is no cache-*write* row: Codex does log a
  `cache_write_input_tokens` counter, but it reads 0 in practice and `ccusage`'s Codex parser
  never looks at it — so no write cost enters the total being split.

**`codex exec --ephemeral` runs.** `--ephemeral` stops Codex from writing its session file, so
`ccusage` never sees those tokens and they count as $0. The optional `codex-shim` fixes that:
installed ahead of the real `codex` in your `PATH`, it steps aside for every other command, and
for `--ephemeral` runs it records each turn's usage, in Codex's own session format, under
`~/.codex-ephemeral` (a folder Codex doesn't list in its history). The widget adds that folder
to what `ccusage` reads, so those runs are priced like any other.

```bash
install -m 755 codex-shim ~/.local/bin/codex   # ~/.local/bin must come before the real codex in PATH
```

Note the **Claude cost reflects Claude Code (CLI)
usage only** — Claude Desktop chats aren't logged locally, so they aren't counted here (the
**quota %**, being server-side, still covers everything).

## Language

The whole interface is available in **English (default)** and **French**. Switch it from the
**Language** submenu in the menu — the change is instant and remembered.

## Preferences and additional providers

Open **Preferences…** from the menu-bar app for a live indicator preview and an always-visible
detailed menu preview beside the settings (no click needed). Choose its indicator, show/hide
provider sections in the menu/widget, and toggle the token cost breakdown.
**Add a provider… → OpenRouter** only needs a name and a standard API key; its
usage URL is preconfigured. It reads `GET https://openrouter.ai/api/v1/key` and
shows daily API spending (`usage_daily`), the remaining **key budget** when
a spending cap exists (`limit_remaining / limit`), and a **daily request gauge**
from `free_model_daily_requests.remaining / limit`. Those numbers are calculated
by OpenRouter server-side, so they include requests made from other machines that
use the same API key. This is not the account's credit balance and does not require
a management key.
[OpenRouter endpoint documentation](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key).

For **Custom API**, supply a name, an HTTPS **usage endpoint**, and a key. The app
makes a GET request with `Authorization: Bearer <key>`. Configure at least one
dotted JSON field path: remaining quota **0–100 percent** and/or **daily cost in
USD**, for example `data.remaining_percent` and `data.usage_daily`. A chat endpoint
alone cannot report usage; other authentication schemes/JSON formats need an
adapter. Redirects are refused to avoid forwarding credentials.

Keys are stored in macOS Keychain, never in preferences or widget snapshots.
Use **Edit…** to replace a key (an empty field keeps the current key), or
**Remove…** to delete the provider and its key. Changing a custom destination
requires re-entering its key. Connection failures are shown explicitly, not as
zero usage. Added providers can also be selected as the menu-bar indicator.
Their costs remain separate from the existing Claude/Codex total to avoid double
counting. Widgets show up to five compact rows; further providers remain in the
menu. Settings and provider definitions persist across restarts.

## Diagnostic modes (CLI)

The built binary lives at `~/Applications/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget`:

```bash
ClaudeUsageWidget --once     # real /usage + ccusage call, print and exit
ClaudeUsageWidget --mock     # no network: fake quotas + real ccusage / Codex data
ClaudeUsageWidget --refresh  # force an OAuth token refresh + rewrite the keychain item
ClaudeUsageWidget --notify-test  # send a sample notification
```



## How it's built

A single Swift file compiled with `swiftc` into a self-contained, ad-hoc-signed `.app`
(no Xcode project). It runs as an `LSUIElement` agent (no Dock icon).

| File | Role |
|---|---|
| `ClaudeUsage.swift` | everything — model, fetch, menu-bar UI, notifications, i18n |
| `install.sh` | build + install + auto-start + launch (and `uninstall`) |
| `Info.plist` | bundle metadata (`LSUIElement`) |
| `AppIcon.icns` | app icon |
| `docs/` | the demo / landing page (GitHub Pages) |

## License

[MIT](LICENSE) © Hugo Ferreira. Free to use, modify and redistribute.

---

*Not affiliated with Anthropic, OpenAI or Ollama. "Claude", "Codex" and "Ollama" are
trademarks of their respective owners. This tool only reads your own usage data.*
