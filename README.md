# Agent Usage — Claude + Codex in your menu bar (macOS)

A tiny native macOS menu-bar widget that shows **what you have left** for both
**Claude** and **Codex**, at a glance:

- ⌛ your **5-hour** rolling window and 🗓 your **weekly** quota — for each;
- 💲 today's **combined cost** (via [`ccusage`](https://github.com/ryoppippi/ccusage)) with an **end-of-day projection**;
- 🔔 an optional **notification** the moment a quota window resets.

The menu-bar icons stay monochrome and only turn **orange/red** when a quota gets low.
Click them for the full breakdown.

**▶︎ Live demo & screenshot:** <https://hugo291.github.io/agent-usage-menubar/>

```
  ⌛70%  🗓20%  $437            ← menu bar (combined cost = Claude + Codex)
┌────────────────────────────────────┐
│ Usage — Claude + Codex             │
│ Today total ≈ $437.02              │
│ Projected day ≈ $2898 (at current… │
│ Claude (Anthropic · max)           │
│  5h window   ██████░░░░  70% left   │
│   resets today at 05:37            │
│  Weekly quota ██░░░░░░░░ 20% left    │
│  Today: $436 · 551 M tokens        │
│ Codex (OpenAI · plus)              │
│  5h window   ░░░░░░░░░░  0% left     │
│   resets today at 18:12            │
│  Weekly quota ██████░░░░ 57% left   │
│  last reading 2 min ago · …        │
│ Language ▸ · Refresh · Quit        │
└────────────────────────────────────┘
```

## Install

One command builds it, installs it to `~/Applications`, enables auto-start at login,
and launches it. Nothing else to set up.

```bash
# macOS 12+, needs the Xcode Command Line Tools:  xcode-select --install
git clone https://github.com/Hugo291/agent-usage-menubar.git
cd agent-usage-menubar
./install.sh
```

Uninstall any time (stops it, disables auto-start, removes the app):

```bash
./install.sh uninstall
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
Codex has no usage API, so the 5-hour / weekly windows are read from two local sources, keeping
the **freshest reading per window**:

1. **CLI sessions** — `~/.codex/sessions/**/rollout-*.jsonl` (the `rate_limits` events);
2. **The Codex app** — `~/.codex/logs_2.sqlite` (the `X-Codex-*-Used-Percent` response headers).

Whether you use the terminal or the Codex app, it picks the most recent. Because this data is
**passive** (it only updates when Codex makes a call), the widget shows the **age of the last
reading** ("last reading X ago") so you know the figures are from your last Codex call, not
real time.

### Cost & tokens
`ccusage daily` (Claude) and `ccusage codex daily` (Codex) provide today's cost and token
counts. Note the **Claude cost reflects Claude Code (CLI) usage only** — Claude Desktop chats
aren't logged locally, so they aren't counted there (the **quota %**, being server-side, still
covers everything).

## Language

The whole interface is available in **English (default)** and **French**. Switch it from the
**Language** submenu in the menu — the change is instant and remembered.

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

*Not affiliated with Anthropic or OpenAI. "Claude" and "Codex" are trademarks of their
respective owners. This tool only reads your own local usage data.*
