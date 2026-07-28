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
│ Claude · max                 $436  │
│  ⌛ 5h    ▬▬▬▬▬▬▭▭▭▭   70%          │
│    resets today at 05:37 · in 2 h  │
│  🗓 week  ▬▬▭▭▭▭▭▭▭▭   20%          │
│    resets tomorrow at 15:37        │
│ Codex · plus                 $0.75 │
│  🗓 week  ▬▬▬▬▬▬▬▭▭▭   78%          │
│    resets Mon 21 Jul · in 74 h     │
│  last reading 2 min ago            │
│ Today $437 · ~$768 projected       │
│ Language ▸ · Refresh · Quit        │
└────────────────────────────────────┘
```

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
Codex has no usage API, so the quota is read from your local Codex logs. Since mid-2026 OpenAI
moved Codex to a **single weekly window** (it used to be a 5-hour + weekly pair) — the widget
classifies each window by its **duration**, so it always shows whatever windows currently exist.

The reading comes from `~/.codex/sessions/**/rollout-*.jsonl` (the `rate_limits` events), and,
on Codex versions that still log them, the `X-Codex-*` response headers in
`~/.codex/logs_2.sqlite`. The freshest reading wins. Because this data is **passive** (it only
updates when Codex makes a call), the widget shows the **age of the last reading** ("last
reading X ago") so you know the figures are from your last Codex call, not real time.

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
- **Codex** — cache read / output / input. OpenAI bills no cache *writes*, and cache-read is
  0.1× input across the whole GPT-5 family; the output multiplier is 8× up to gpt-5.3 and 6×
  from gpt-5.4 on, read from the model name and averaged when a day mixes models.

Note the **Claude cost reflects Claude Code (CLI)
usage only** — Claude Desktop chats aren't logged locally, so they aren't counted here (the
**quota %**, being server-side, still covers everything).

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
