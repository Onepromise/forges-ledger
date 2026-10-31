# Tests

Everything runs without WoW, without a Blizzard key and without touching your
real data.

| Command (from the repo root) | What it checks |
|---|---|
| `python -m unittest discover -s tests -v` | The desktop app: sync hardening, weekly gold, custom tasks, the companion addon file, diagnostics |
| `python tests/lua/run.py addon` | Forge's Ledger (core bar and windows), Professions and Dungeons, driven in a mock WoW client |
| `python tests/lua/chron_run.py addon` | Forge's Chronicle, the same way |

The Lua suites need `pip install lupa`. `tests/lua/wowmock.lua` is the stand-in
for the game's UI; a widget method it doesn't know fails loudly, so a typo can't
pass silently. GitHub runs all three on every push (`.github/workflows/tests.yml`).

Fixtures use made-up character names. Never put real character names in a test.
