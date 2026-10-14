# Privacy Policy — Forge's Ledger

**Last updated:** October 12, 2026
**Developer:** [YOUR NAME / STUDIO NAME]
**Contact:** [YOUR EMAIL]

## Overview

Forge's Ledger is a desktop dashboard for World of Warcraft players. It combines
character data from Blizzard's official API with gold data recorded by its free
companion in-game addon. **The app runs entirely on your own computer. There
are no Forge's Ledger servers, no analytics, and no tracking.**

This policy is intended to be consistent with Blizzard Entertainment's own
privacy policy, as required by the Blizzard Developer API Terms of Use.

## Data We Collect

### 1. Blizzard API Data
Obtained through Blizzard's official Battle.net API using OAuth — you log in
with your own Blizzard account and explicitly authorize access. It includes:
- **Per character:** name, realm, level, class, race, faction, active
  specialization, guild name, item level, achievement points, last login time,
  and profession skill levels and known recipes for every expansion.
- **Account-wide:** your mount collection, battle pet collection, and
  achievement progress.
- **Game reference data:** lists of all recipes, mounts, pets and achievements,
  used only to show what you have and haven't collected.

All of it is stored locally on your computer in `forge_dashboard_cache.json`,
replaced each time you sync, and **automatically deleted once it is more than
30 days old**, per Blizzard's Developer API Terms of Use.

### 2. Companion Addon Data
- Gold held per character (with a daily history), plus each character's
  level, class, faction, rested XP and profession cooldown timers, and your
  account's warband bank gold (with a daily history), recorded by the free
  Forge's Ledger in-game addon — in retail World of Warcraft and in
  World of Warcraft: Forever.
- Read from the addon's local SavedVariables file on your computer.
- Never leaves your computer.

### 3. Your Settings
- Roles you assign to characters (for example "Farmer" or "Main"), stored
  locally in `forge_dashboard_roles.json`.
- Which characters you track (★), your gold goal, your weekly checklist
  checkmarks, and which of your WoW accounts the dashboard shows, stored
  locally in `forge_dashboard_settings.json`.
- If you use **Export settings**, the file you save contains only these
  choices and your roles — never your Blizzard login or Blizzard data. Before
  an **Import**, your current choices are backed up to
  `settings-before-import.json` in the data folder.

### 4. Credentials
- Your Blizzard API client ID and secret (which you create yourself on
  Blizzard's developer portal) and the OAuth tokens issued at login.
- Stored locally on your computer in `forge_dashboard_config.json`.
- Sent only to Blizzard's servers during login and sync. Never shared with
  anyone else.
- On Windows, the client secret and tokens are **encrypted** with Windows'
  built-in Data Protection API (DPAPI), so only your Windows user account on
  your computer can read them. A copy of the file on another computer — for
  example in a cloud backup — cannot be decrypted. (The client ID is not
  encrypted; it is not secret and appears in Blizzard's login address.)

### 5. Patreon Account Data (premium tier only)
- If you connect Patreon to unlock premium features, we receive your Patreon
  user ID and active membership status via Patreon's official API.
- Used solely to verify your subscription. Stored locally; never sold or shared.

## Data We Do NOT Collect

- We never ask for, receive, or store your Blizzard account password. Login
  happens on Blizzard's own website.
- No analytics, telemetry, crash reporting, or usage tracking of any kind.
- No advertising data. The app contains no ads.

## How Your Data Is Used

Your data is used for one purpose only: displaying your personal dashboard
(character roster, professions, classes, collections and gold) on your own
computer.

## Third Parties

- **Blizzard Entertainment:** the app calls Blizzard's official API to fetch
  your character data. This is governed by Blizzard's own privacy policy in
  addition to this one.
- **GitHub:** once a day the app asks GitHub whether a newer version of
  Forge's Ledger has been released. The request contains no personal or game
  data — only the app's version number. GitHub, like any website, sees your
  IP address; see GitHub's privacy statement. The result is stored locally in
  `update_check.json`. The app never downloads or installs updates by itself.
- **Patreon (premium tier only):** used solely to verify an active membership.
- We do not sell, license, or transfer your data — or any data derived from
  it — to any third party, including advertisers or data brokers.

## Data Retention and Deletion

- Blizzard API data: deleted automatically once it is more than 30 days old,
  and replaced on every sync.
- Addon gold data: kept locally for as long as you keep the addon save file.
- To stop the app accessing your Blizzard data, revoke its access in your
  Battle.net account settings.
- All of the app's files live in one folder: `%LOCALAPPDATA%\ForgesLedger`
  (paste that into File Explorer's address bar to open it). To delete
  everything the app stores, delete that folder, and remove the addon's
  SavedVariables file
  (`WTF\Account\<account>\SavedVariables\ForgesLedger.lua`, and
  `ForgeGoldTracker.lua` if you used the addon before it was renamed). There is
  nothing stored anywhere else.

## Children's Privacy

Forge's Ledger is not designed for, or marketed to, users under 13 years of age,
consistent with Blizzard's Developer API Terms of Use.

## Blizzard Attribution

Character and game data is provided by Blizzard Entertainment. Forge's Ledger is
not endorsed by, affiliated with, or connected to Blizzard Entertainment.
World of Warcraft and Blizzard Entertainment are trademarks of Blizzard
Entertainment, Inc.

## Changes to This Policy

If this policy changes, the updated version will ship with the app and the
"Last updated" date above will be revised.

## Contact

Questions about this policy: [YOUR EMAIL]
