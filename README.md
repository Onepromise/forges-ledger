# Forge's Ledger

A desktop dashboard for World of Warcraft players that tracks every character
on your account in one place: levels, professions across every expansion,
known and missing recipes, class coverage, mounts, pets, achievements, and
gold — with a gold goal to work toward.

Everything runs on your own PC. There are no servers, no analytics, and no
tracking. See [PRIVACY.md](PRIVACY.md).

## Features

- **Roster** — every character with level, item level, last played, role
  tags (Main, Farmer, Crafter, Bank, Leveling, Alt), professions, and gold.
  Star (☆) the characters you want to track.
- **Professions** — skill per expansion (Classic through Midnight) for every
  character, with the recipes each one knows and the ones they're missing.
- **Classes** — which classes you have, which are missing, and which have no
  max-level character yet.
- **Collections** — mounts, battle pets, and achievement progress by category.
- **Gold** — per-character gold, warband bank gold, totals, 7-day change, and a gold goal
  with an optional deadline, daily target, and projected finish date.
- **Live updates** — the companion addon's Sync button, a keybind, or
  `/fl sync` updates the dashboard within seconds. It also refreshes from
  Blizzard on startup and hourly.

## Getting started

1. Download `ForgesLedger.exe` and double-click it. (Windows may warn that
   the app is unrecognized — choose **More info → Run anyway**. The app
   isn't code-signed yet.)
2. Your browser opens the setup screen. It walks you through creating your
   own free Blizzard API key (Blizzard requires one per person), checks it,
   finds your World of Warcraft folder, and installs the companion addon.
3. Connect your Battle.net account. Your characters load in about a minute.
4. In game, log into each character once so the addon records its gold.

Your data is stored in `%LOCALAPPDATA%\ForgesLedger`. Your Blizzard secret
and login are encrypted with your Windows account.

## Companion addon

The **Forge's Ledger** addon (in `addon/ForgesLedger`) records each
character's gold and your warband bank gold, which Blizzard's API doesn't
provide. It's free and stays
free — Blizzard's add-on policy requires that.

- `/fl` — gold total (characters + warband bank)
- `/fl sync` or the on-screen **Sync** button — update the dashboard now
  (reloads your UI; WoW only saves addon data on reload, logout, or exit)
- `/fl button` — show/hide the Sync button (shift-drag to move it)
- Keybind: Options → Keybindings → AddOns → Forge's Ledger
- `/forgesledger` works too, if another addon also uses `/fl`

## Running from source

Requires Python 3.8+ on Windows. No other packages are needed.

```
python forges_ledger.py
```

Then open http://localhost:8765. When run from source, data is saved next to
the script.

## Building the .exe

Double-click `build_exe.bat`. It creates its own build environment (in
`%LOCALAPPDATA%\ForgesLedgerBuild`), installs PyInstaller there, and writes
`dist\ForgesLedger.exe`.

When the addon changes, update `addon/ForgesLedger` and bump its
`## Version` line so the app's Settings page offers the update.

## Blizzard

Character and game data provided by Blizzard Entertainment. Forge's Ledger
is not endorsed by, affiliated with, or connected to Blizzard Entertainment.
World of Warcraft and Blizzard Entertainment are trademarks of Blizzard
Entertainment, Inc.

## License

All rights reserved. No license has been granted yet.
