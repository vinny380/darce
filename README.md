# D'arce

An open-source, native macOS browser inspired by Arc. Built with SwiftUI, AppKit and WebKit. Not affiliated with The Browser Company.

> **Work in progress.** Expect missing features and rough edges. Don't use it as your only browser yet.

## Install

Requires an Apple Silicon Mac running macOS 14 or later.

1. Download the `.dmg` from [Releases](../../releases/latest).
2. Open it and drag **D'arce** into Applications.
3. The first time you launch it, macOS may say it can't verify the app. Open **System Settings → Privacy & Security** and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/D'arce.app"
   ```

## Build from source

Requires Xcode with Swift 6. No package dependencies.

```sh
bash scripts/run.sh          # debug build, data kept in .local/
bash scripts/package.sh      # release .dmg + .zip in dist/
```

## What works

- **Sidebar:** Favorites, pinned tabs with saved home URLs, Today tabs, nested folders, Spaces, archive and restore, auto-archive of inactive tabs.
- **Command bar:** URLs, search, open tabs, history, Spaces and actions.
- **Split view:** 2–4 panes, horizontal or vertical, saved across launches. Peek opens external links from pinned tabs without losing the pin.
- **Themes:** per-Space colors and icons, light/dark, Metal-rendered backgrounds.
- **Browsing:** profiles with separate website data, private windows, history, downloads, bookmark import/export, find, zoom, print, clear browsing data.
- **Extras:** Boosts (per-site CSS/JS and click-to-hide), local Notes and Easels.

## Shortcuts

| Keys | Action |
|---|---|
| Cmd+T | Search / new tab |
| Cmd+L | Edit current URL |
| Cmd+S | Toggle sidebar |
| Cmd+D | Pin / unpin tab |
| Cmd+W | Archive tab (closes in private windows) |
| Shift+Cmd+T | Reopen last archived tab |
| Cmd+N / Shift+Cmd+N | New window / private window |
| Ctrl+1…9 | Switch Space |
| Cmd+Y / Cmd+J / Cmd+F | History / Downloads / Find |

## Not done yet

- Chromium engine and Chrome extensions (it runs on WebKit, Safari's engine, today)
- Sync between Macs
- Password manager and passkey integration
- Restoring windows and their positions on relaunch
- Intel Macs

## Your data

Settings and tabs are stored in `~/Library/Application Support/Darce`. Website data uses macOS WebKit's per-profile stores. Private windows write nothing to disk except files you explicitly save. No account, no telemetry.

## Development

```text
Sources/BrowserCore/      Engine-independent models and stores
Sources/BrowserPrototype/ SwiftUI/AppKit WebKit app and smoke runners
Sources/BrowserTheme/     Palette and Metal theme renderer
Tests/BrowserCoreTests/   Regression tests
scripts/                  Build, package, launch and smoke tests
```

```sh
swift test
bash scripts/smoke.sh
bash scripts/network-smoke.sh
```

## License

MIT
