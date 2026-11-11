# Claude Usage Bar

A tiny macOS menu bar app that shows your claude.ai plan usage — the same numbers as **Settings → Usage** — one click away, next to your Wi‑Fi icon.

```
5h 11% · W 11%      ← always visible in the menu bar
```

Click it for the full breakdown:

- **Current session** (5‑hour window): progress bar, % used, when it resets
- **This week**: progress bar, % used, when it resets
- **Model‑scoped weekly limits** (e.g. Fable) with their allowance
- **Limit resets**: how many free resets you have and when each expires

The icon only appears while the **Claude desktop app** or **Claude Code** is running, and hides when both are closed.

> **Unofficial.** Not affiliated with or endorsed by Anthropic. It reads the same internal endpoint the claude.ai Usage page uses, which is undocumented and may change at any time.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- The Claude desktop app, signed in

## Install

```bash
git clone https://github.com/georgesldk/claude-usage-bar.git
cd claude-usage-bar
./build.sh
open ~/Applications/"Claude Usage.app"
```

`build.sh` compiles the app with `swiftc` (no Xcode project needed), signs it locally, and installs it to `~/Applications/Claude Usage.app`.

### First launch

1. macOS asks to let **Claude Usage** access **"Claude Safe Storage"** in your Keychain. Enter your Mac password and click **Always Allow**. This lets the app reuse the Claude desktop app's existing login, so you never sign in separately.
2. The app registers itself to start at login (you'll see a macOS notification). It stays idle and invisible until Claude or Claude Code runs.

> After rebuilding, macOS may ask for Keychain access again, because it treats the rebuilt app as a new one.

## Usage

- **Click the icon** to open the breakdown. Data refreshes when you open it (if older than 30 s) and every 5 minutes while visible.
- **↻** forces a refresh.
- **Open Usage page** opens claude.ai's real Usage page — the app itself is read‑only and never spends a reset.
- **Quit** stops it until next login.

To stop it starting at login: **System Settings → General → Login Items** → turn off *Claude Usage*.

## How it works

| Piece | What it does |
|---|---|
| `Sources/ClaudeCookies.swift` | Copies the claude.ai login cookies from the Claude desktop app's cookie store (`~/Library/Application Support/Claude/Cookies`), decrypting them with the app's Keychain key. Cloudflare cookies are skipped. |
| `Sources/main.swift` | Menu bar item and popover (AppKit + SwiftUI), app detection (desktop app via `NSWorkspace`, Claude Code via `pgrep`), and fetching `GET /api/organizations/{org}/usage` from a hidden WebKit view. |
| `build.sh` | Builds, ad‑hoc signs, and installs the `.app`. |

### Privacy

- Nothing leaves your Mac except requests to `claude.ai` — the same ones the Usage page makes.
- No analytics, no third‑party servers.
- Login cookies are copied into the app's own private WebKit storage; they are never written to the repo or to plain files.
- This repo contains no keys, tokens, or account IDs, and needs no `.env` file.

### If you can't use the Keychain import

Click the icon → **Paste session key from Chrome**: in Chrome on claude.ai open DevTools → **Application** → **Cookies** → `https://claude.ai`, copy the value of `sessionKey`, then click the button (it pre‑fills from your clipboard). Treat that key like a password.

## Troubleshooting

- **No icon** — make sure the Claude app or Claude Code is running; with a crowded menu bar the icon can hide behind the notch.
- **"Couldn't pick up your login"** — make sure you're signed in to the Claude desktop app, then press ↻.
- **Crashes or odd behaviour** — run the binary directly to see logs:
  `~/Applications/"Claude Usage.app"/Contents/MacOS/ClaudeUsageBar`
- **Numbers stopped loading after an update to claude.ai** — the internal endpoint probably changed; open an issue.

## Uninstall

```bash
pkill -x ClaudeUsageBar
rm -rf ~/Applications/"Claude Usage.app"
```
Then remove it from **Login Items** if it's still listed.

## License

MIT — see [LICENSE](LICENSE).
