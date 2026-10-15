#!/usr/bin/env python3
"""
Forge's Ledger - desktop companion app for World of Warcraft players.

Pulls from BOTH sources into one local dashboard:
  1. The Forge's Ledger addon save file    -> per-character gold + history
  2. The Blizzard API (your own client)    -> levels, professions per character

Runs on your gaming PC. Your Client ID / Secret / tokens live only in
forge_dashboard_config.json next to this script - never sent anywhere
except Blizzard's own servers. On Windows the secret and tokens are
encrypted with DPAPI, so only your Windows account on this PC can read them.

Requires: Python 3.8+ (https://www.python.org/downloads/) - or use the
          packaged ForgesLedger.exe built by build_exe.bat
Run:      python forges_ledger.py
Open:     http://localhost:8765
"""

import base64
import concurrent.futures
import datetime
import html
import http.server
import json
import math
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser

PORT = 8765
REDIRECT_URI = "http://localhost:%d/callback" % PORT
OAUTH_AUTHORIZE = "https://oauth.battle.net/authorize"
OAUTH_TOKEN = "https://oauth.battle.net/token"
# Blizzard API regions (one host each). China is a separate Battle.net
# partition with different hosts, so it isn't supported.
REGIONS = {"us": "Americas & Oceania", "eu": "Europe",
           "kr": "Korea", "tw": "Taiwan"}
CAP = 90  # Midnight max level

APP_VERSION = "0.8.0"  # bump for each GitHub release (tag v<APP_VERSION>)
APP_NAME = "ForgesLedger"  # folder name for user data; no Blizzard trademarks
OLD_APP_NAME = "ForgeDashboard"  # data folder name before the rename

if getattr(sys, "frozen", False):
    # Running as the packaged .exe. PyInstaller unpacks the program into a
    # temporary folder each launch (sys._MEIPASS) - fine for read-only files
    # we ship (the addon, PRIVACY.md), but anything we save there vanishes
    # on exit. So user data goes in %LOCALAPPDATA%, which is per-user,
    # always writable, and not synced to OneDrive.
    RESOURCE_DIR = sys._MEIPASS
    _local = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    BASE_DIR = os.path.join(_local, APP_NAME)
    _old = os.path.join(_local, OLD_APP_NAME)
    if not os.path.exists(BASE_DIR) and os.path.isdir(_old):
        # one-time move of data saved under the app's previous name
        try:
            os.rename(_old, BASE_DIR)
        except OSError:
            # folder in use (e.g. an old copy still running) - copy instead
            import shutil as _shutil
            _shutil.copytree(_old, BASE_DIR)
    os.makedirs(BASE_DIR, exist_ok=True)
else:
    # running from source: keep everything next to the script, as before
    RESOURCE_DIR = BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "forge_dashboard_config.json")
CACHE_PATH = os.path.join(BASE_DIR, "forge_dashboard_cache.json")
ROLES_PATH = os.path.join(BASE_DIR, "forge_dashboard_roles.json")

# The companion addon's folder name, which WoW also uses for its save file
# (WTF/Account/<account>/SavedVariables/<folder>.lua).
ADDON_FOLDER = "ForgesLedger"
OLD_ADDON_FOLDER = "ForgeGoldTracker"  # name before the rename (addon v1.x)

# Optional companion addons ("satellites"). Each is its own addon folder,
# writes its own save file (named after the folder - WoW's rule) holding one
# DB table in the shared envelope (specs/SATELLITE_ARCHITECTURE_SPEC.md):
#   {schemaVersion, version, characters = {["Name-Realm"] = {exportedAt, data}}}
# schema = the newest envelope version this app understands; anything newer
# is skipped with a log line rather than misread.
SATELLITES = {
    "professions": {
        "folder": "ForgesLedger_Professions",
        "db": "ForgesLedgerProfessionsDB",
        "schema": 1,
        "title": "Forge's Ledger: Professions",
        # describe what it does TODAY; update as guides/shopping lists land
        "pitch": "your skill in every expansion at a glance, beside the profession window, and live skill numbers here",
        "games": ["retail"],  # Retail first; Forever later
    },
}

# Roles you can tag a character with on the dashboard (stored in ROLES_PATH).
ROLES = ["Main", "Farmer", "Crafter", "Bank", "Leveling", "Alt"]

# Expansions in release order. Blizzard names every profession tier
# "<Region> <Profession>" (e.g. "Outland Blacksmithing"), so we map a tier to
# its expansion by that prefix: (short label, full name, tier-name prefixes).
EXPANSIONS = [
    ("Classic", "Classic", ("Classic",)),
    ("TBC", "The Burning Crusade", ("Outland",)),
    ("Wrath", "Wrath of the Lich King", ("Northrend",)),
    ("Cata", "Cataclysm", ("Cataclysm",)),
    ("MoP", "Mists of Pandaria", ("Pandaria",)),
    ("WoD", "Warlords of Draenor", ("Draenor",)),
    ("Legion", "Legion", ("Legion",)),
    ("BfA", "Battle for Azeroth", ("Kul Tiran", "Zandalari")),
    ("SL", "Shadowlands", ("Shadowlands",)),
    ("DF", "Dragonflight", ("Dragon Isles",)),
    ("TWW", "The War Within", ("Khaz Algar",)),
    ("Midnight", "Midnight", ("Midnight",)),
]

# The addon stores class as Blizzard's token ("DEATHKNIGHT"); the API uses
# display names ("Death Knight"). Map tokens so both sources line up.
CLASS_TOKENS = {
    "DEATHKNIGHT": "Death Knight", "DEMONHUNTER": "Demon Hunter",
    "DRUID": "Druid", "EVOKER": "Evoker", "HUNTER": "Hunter", "MAGE": "Mage",
    "MONK": "Monk", "PALADIN": "Paladin", "PRIEST": "Priest", "ROGUE": "Rogue",
    "SHAMAN": "Shaman", "WARLOCK": "Warlock", "WARRIOR": "Warrior",
}

# Recipe catalogs only change with patches; refetch weekly at most.
CATALOG_MAX_AGE = 7 * 86400

# Blizzard Developer API Terms of Use 2(s): API Data may be kept 30 days max.
API_DATA_TTL = 30 * 86400

# WoW Forever: the original world with a level 60 cap and (at launch) the
# original nine classes. Blizzard offers no Forever API yet, so Forever data
# comes from the addon only.
FOREVER_CAP = 60
FOREVER_CLASSES = ["Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman",
                   "Mage", "Warlock", "Druid"]
ALL_CLASSES = ["Death Knight", "Demon Hunter", "Druid", "Evoker", "Hunter", "Mage",
               "Monk", "Paladin", "Priest", "Rogue", "Shaman", "Warlock", "Warrior"]

# How stale the Blizzard data may get before the dashboard re-syncs by itself.
AUTO_SYNC_EVERY = 3600

# Your own choices - tracked roster (★) and gold goal. Kept out of the code
# so every user has their own; set from the dashboard.
SETTINGS_PATH = os.path.join(BASE_DIR, "forge_dashboard_settings.json")

WOW_PATH_GUESSES = [
    r"C:\Program Files (x86)\World of Warcraft",
    r"C:\Program Files\World of Warcraft",
    "/Applications/World of Warcraft",
]

STATE = {"syncing": False, "sync_error": None, "oauth_state": None,
         "sv_mtime": None}
# the full sync and the addon-triggered single-character refresh run on
# different threads; this stops them writing the cache file at the same time
CACHE_LOCK = threading.Lock()
# Requests run in parallel threads, and every POST is a read-modify-write of
# a settings file (roles, tracked, goal, weekly) - one at a time, so two
# quick clicks can't overwrite each other's change.
WRITE_LOCK = threading.Lock()


# --------------------------------------------------------------- secrets ---
#
# Secrets in the config file are encrypted with Windows DPAPI. DPAPI derives
# the key from your Windows login, so there's no password for us to store:
# only your user account on this PC can decrypt them. A copy of the config
# file anywhere else - OneDrive, a zip you send someone - is unreadable.
# (Blizzard API Terms 2(l) keep keys confidential, 2(o) protect the Data.)

SECRET_FIELDS = ("client_secret", "access_token", "refresh_token")
SECRET_PREFIX = "dpapi:"
# Extra input DPAPI mixes into the key, so another program running as you
# can't decrypt these by casually calling DPAPI without knowing this value.
# Never change this value: it's part of the encryption key, so changing it
# makes every saved login unreadable (the old app name is intentional).
DPAPI_ENTROPY = b"ForgeDashboard/credentials/v1"

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    class _Blob(ctypes.Structure):
        # DATA_BLOB: how the Windows API passes a byte buffer (length + pointer)
        _fields_ = [("cbData", wintypes.DWORD),
                    ("pbData", ctypes.POINTER(ctypes.c_char))]

    _crypt32 = ctypes.windll.crypt32
    _kernel32 = ctypes.windll.kernel32
    for _fn in (_crypt32.CryptProtectData, _crypt32.CryptUnprotectData):
        _fn.argtypes = [ctypes.POINTER(_Blob), ctypes.c_void_p,
                        ctypes.POINTER(_Blob), ctypes.c_void_p,
                        ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_Blob)]
        _fn.restype = wintypes.BOOL
    # declared explicitly: ctypes would otherwise truncate 64-bit pointers
    _kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    _kernel32.LocalFree.restype = ctypes.c_void_p
    _CRYPTPROTECT_UI_FORBIDDEN = 0x1  # never pop a dialog; fail instead

    def _dpapi(data, protect):
        def blob(b):
            buf = ctypes.create_string_buffer(b, len(b))
            return _Blob(len(b), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf
        # keep the *_buf references alive until the call returns
        inp, _inp_buf = blob(data)
        ent, _ent_buf = blob(DPAPI_ENTROPY)
        out = _Blob()
        fn = _crypt32.CryptProtectData if protect else _crypt32.CryptUnprotectData
        if not fn(ctypes.byref(inp), None, ctypes.byref(ent), None, None,
                  _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(out)):
            raise ctypes.WinError()
        try:
            return ctypes.string_at(out.pbData, out.cbData)
        finally:
            _kernel32.LocalFree(ctypes.cast(out.pbData, ctypes.c_void_p))

    def encrypt_secret(text):
        raw = _dpapi(text.encode("utf-8"), True)
        return SECRET_PREFIX + base64.b64encode(raw).decode("ascii")

    def decrypt_secret(value):
        raw = base64.b64decode(value[len(SECRET_PREFIX):])
        return _dpapi(raw, False).decode("utf-8")
else:
    # Not built for Mac/Linux yet (PC first). Secrets stay plain text there;
    # main() prints a warning so it's never silent.
    def encrypt_secret(text):
        return text

    def decrypt_secret(value):
        raise RuntimeError("DPAPI-encrypted secrets can only be read on Windows")


# ---------------------------------------------------------------- config ---

def load_config():
    """Config with secrets decrypted. Callers never see ciphertext."""
    if not os.path.exists(CONFIG_PATH):
        return {}
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    for k in SECRET_FIELDS:
        v = cfg.get(k)
        if isinstance(v, str) and v.startswith(SECRET_PREFIX):
            try:
                cfg[k] = decrypt_secret(v)
            except Exception:
                # Encrypted by a different Windows user or PC (e.g. a copied
                # folder). Can't be recovered - drop the credentials so the
                # setup page asks for them again instead of crashing.
                print("Saved Blizzard credentials were encrypted on another "
                      "PC/user and can't be read here - please run setup "
                      "again.", flush=True)
                for s in SECRET_FIELDS + ("client_id", "expires_at"):
                    cfg.pop(s, None)
                break
    return cfg


def save_config(cfg):
    out = dict(cfg)
    for k in SECRET_FIELDS:
        if out.get(k):
            out[k] = encrypt_secret(out[k])
    # write to a temp file then swap it in, so a crash mid-write can't leave
    # a half-written config (which would lose your login)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    os.replace(tmp, CONFIG_PATH)


def secure_existing_config():
    """One-time upgrade: encrypt secrets saved by older versions in plain text."""
    if not os.path.exists(CONFIG_PATH):
        return
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        raw = json.load(f)
    plain = [k for k in SECRET_FIELDS
             if raw.get(k) and not str(raw[k]).startswith(SECRET_PREFIX)]
    if plain and sys.platform == "win32":
        save_config(load_config())
        print("Encrypted saved credentials (%s)." % ", ".join(plain), flush=True)


# ---------------------------------------------------------- lua parsing ---

class LuaParseError(Exception):
    pass


class LuaParser:
    """Minimal parser for WoW SavedVariables table syntax."""

    def __init__(self, text):
        self.text = text
        self.pos = 0

    def error(self, msg):
        raise LuaParseError("%s at position %d" % (msg, self.pos))

    def skip(self):
        while self.pos < len(self.text):
            c = self.text[self.pos]
            if c in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("--", self.pos):
                while self.pos < len(self.text) and self.text[self.pos] != "\n":
                    self.pos += 1
            else:
                break

    def peek(self):
        self.skip()
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def expect(self, ch):
        self.skip()
        if self.pos >= len(self.text) or self.text[self.pos] != ch:
            self.error("expected '%s'" % ch)
        self.pos += 1

    def parse_string(self):
        self.expect('"')
        out = []
        while True:
            if self.pos >= len(self.text):
                self.error("unterminated string")
            c = self.text[self.pos]
            if c == '"':
                self.pos += 1
                return "".join(out)
            if c == "\\":
                self.pos += 1
                if self.pos >= len(self.text):
                    self.error("unterminated escape")
                e = self.text[self.pos]
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(e, e))
                self.pos += 1
            else:
                out.append(c)
                self.pos += 1

    def parse_number(self):
        self.skip()
        m = re.match(r"-?\d+(\.\d+)?([eE][+-]?\d+)?", self.text[self.pos:])
        if not m:
            self.error("bad number")
        self.pos += len(m.group(0))
        s = m.group(0)
        return float(s) if ("." in s or "e" in s or "E" in s) else int(s)

    def parse_word(self):
        self.skip()
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.text[self.pos:])
        if not m:
            self.error("bad word")
        self.pos += len(m.group(0))
        return m.group(0)

    def parse_value(self):
        c = self.peek()
        if c == "{":
            return self.parse_table()
        if c == '"':
            return self.parse_string()
        if c == "-" or c.isdigit():
            return self.parse_number()
        w = self.parse_word()
        if w == "true":
            return True
        if w == "false":
            return False
        if w == "nil":
            return None
        self.error("unexpected word '%s'" % w)

    def parse_table(self):
        self.expect("{")
        arr = []
        obj = {}
        is_obj = False
        idx = 1
        while True:
            self.skip()
            if self.peek() == "}":
                self.pos += 1
                break
            # key = value  OR  [key] = value  OR  bare value
            save = self.pos
            key = None
            c = self.peek()
            if c == "[":
                self.pos += 1
                key = self.parse_value()
                self.expect("]")
                self.skip()
                if self.peek() == "=":
                    self.pos += 1
                    is_obj = True
                else:
                    self.pos = save  # not a key after all; reparse as value
                    key = None
            elif c.isalpha() or c == "_":
                # a bare word followed by "=" is a key; anything else
                # (true/false/nil) is a value. Quoted strings never get here:
                # in a table they're always bare array values, like the
                # "RIGHT" in buttonPos = { "RIGHT", -175, 257 }
                w = self.parse_word()
                self.skip()
                if self.peek() == "=":
                    self.pos += 1
                    key = w
                    is_obj = True
                else:
                    self.pos = save
            if key is None and not is_obj and self.peek() not in ("}",):
                # bare value -> array slot (only valid before any keyed entry)
                pass
            if is_obj and key is None:
                self.error("bad table key")
            value = self.parse_value()
            if is_obj:
                obj[key] = value
            else:
                arr.append(value)
                idx += 1
            self.skip()
            if self.peek() == "," or self.peek() == ";":
                self.pos += 1
        if is_obj:
            return obj
        return arr


def parse_lua_global(text, name):
    """Extract one global table (e.g. ForgesLedgerProfessionsDB) from a
    SavedVariables file."""
    m = re.search(r"\b%s\s*=" % re.escape(name), text)
    if not m:
        raise LuaParseError("%s not found in file" % name)
    return LuaParser(text[m.end():]).parse_value()


def parse_savedvariables(text):
    """Extract the core addon's ForgeGoldDB table from its save file."""
    return parse_lua_global(text, "ForgeGoldDB")


# ----------------------------------------------------------------- gold ---

def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def wow_root():
    """The World of Warcraft install folder (holds _retail_ and the others)."""
    cfg = load_config()
    for base in [cfg.get("wow_path")] + WOW_PATH_GUESSES:
        if base and os.path.isdir(os.path.join(base, "_retail_")):
            return base
    return None


def forever_clients(root=None):
    """Folders of installed WoW Forever clients (e.g. ..._classic_beta_).

    The launcher keeps every installed game version in .build.info, with a
    product name and version per line. Forever is the 1.60+ branch (its
    beta is 1.60.1); Classic Era stays on 1.15, so the version tells them
    apart without depending on folder names that may change at launch.
    Product "wow_classic_beta" lives in folder "_classic_beta_"."""
    root = root or wow_root()
    if not root:
        return []
    found = []
    try:
        with open(os.path.join(root, ".build.info"), encoding="utf-8", errors="replace") as f:
            lines = [l.rstrip("\r\n") for l in f if l.strip()]
        head = [h.split("!")[0] for h in lines[0].split("|")]
        col_p, col_v = head.index("Product"), head.index("Version")
        for line in lines[1:]:
            cells = line.split("|")
            product, version = cells[col_p], cells[col_v]
            m = re.match(r"(\d+)\.(\d+)", version)
            if not m or not product.startswith("wow_") or not (
                    int(m.group(1)) == 1 and int(m.group(2)) >= 60):
                continue
            folder = os.path.join(root, "_" + product[len("wow_"):] + "_")
            if os.path.isdir(folder) and folder not in found:
                found.append(folder)
    except (OSError, ValueError, IndexError):
        pass
    if os.path.isdir(os.path.join(root, "_forever_")):  # in case it ships under that name
        found.append(os.path.join(root, "_forever_"))
    return found


def wtf_account_dir(client=None):
    """A game client's per-account folder root (<client>/WTF/Account), or
    None. client = full path of a client folder; default retail."""
    if client is None:
        root = wow_root()
        client = os.path.join(root, "_retail_") if root else None
    d = os.path.join(client, "WTF", "Account") if client else None
    return d if d and os.path.isdir(d) else None


def find_sv_files(client=None):
    """[(account folder name, save file path)] for every WoW account on this
    PC that has addon data. One Battle.net login can hold several WoW
    accounts (WoW1, WoW2...), and each keeps its own save file."""
    base = wtf_account_dir(client)
    out = []
    for account in sorted(os.listdir(base)) if base else []:
        sv = os.path.join(base, account, "SavedVariables")
        p = os.path.join(sv, ADDON_FOLDER + ".lua")
        if not os.path.isfile(p):
            p = os.path.join(sv, OLD_ADDON_FOLDER + ".lua")  # not migrated yet
        if os.path.isfile(p):
            out.append((account, p))
    return out


def find_sv_file():
    """The most recently saved addon file - the one the game just wrote -
    in retail or Forever, so /fl sync in either game updates the page."""
    paths = [p for _f, p in find_sv_files()]
    for c in forever_clients():
        paths += [p for _f, p in find_sv_files(c)]
    return max(paths, key=os.path.getmtime, default=None)


def _find_retail_sv_file():
    """(Kept for reference: the original retail-only lookup.)"""
    cfg = load_config()
    guesses = []
    if cfg.get("wow_path"):
        guesses.append(cfg["wow_path"])
    guesses.extend(WOW_PATH_GUESSES)
    best = None
    best_mtime = 0
    for base in guesses:
        sv_dir = os.path.join(base, "_retail_", "WTF", "Account")
        if not os.path.isdir(sv_dir):
            continue
        for account in os.listdir(sv_dir):
            # current addon name first; the pre-rename file only if the new
            # one doesn't exist yet (not migrated)
            sv = os.path.join(sv_dir, account, "SavedVariables")
            p = os.path.join(sv, ADDON_FOLDER + ".lua")
            if not os.path.isfile(p):
                p = os.path.join(sv, OLD_ADDON_FOLDER + ".lua")
            if os.path.isfile(p):
                mt = os.path.getmtime(p)
                if mt > best_mtime:
                    best_mtime = mt
                    best = p
    return best


def _history(raw):
    out = [{"day": h["day"], "money": h.get("money", 0)}
           for h in (raw or []) if isinstance(h, dict) and "day" in h]
    return sorted(out, key=lambda h: h["day"])


def _cooldowns(raw):
    """Profession cooldowns the addon recorded: [{name, profession, ready_at}].
    Keys/values are checked because this comes from a user-editable file."""
    out = []
    for cd in (raw.values() if isinstance(raw, dict) else raw or []):
        if isinstance(cd, dict) and isinstance(cd.get("readyAt"), (int, float)):
            out.append({"name": str(cd.get("name") or "Cooldown"),
                        "profession": str(cd.get("profession") or ""),
                        "ready_at": int(cd["readyAt"])})
    return sorted(out, key=lambda c: (c["profession"], c["name"]))


def load_gold(client=None):
    """Read the addon's save file.

    Returns (chars, newest_path, warbands):
      chars    = {normkey: {name, realm, money, level, class, ..., folder}}
      warbands = {account folder: {money, updated, history}} - each WoW
                 account's warband bank, once the addon has recorded it
                 (v1.4+, after a bank was opened or its balance changed)."""
    files = find_sv_files(client)
    out, warbands = {}, {}
    for folder, path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            db = parse_savedvariables(f.read())
        _read_addon_db(db, folder, out, warbands)
    newest = max((p for _f, p in files), key=os.path.getmtime, default=None)
    return out, newest, warbands


def _read_addon_db(db, folder, out, warbands):
    """Add one account folder's addon data into out / warbands."""
    for key, c in (db.get("chars") or {}).items():
        if not isinstance(c, dict):
            continue
        name = c.get("name") or str(key).split("-")[0]
        # key looks like "Name-Realm"; realm part may itself contain dashes,
        # so split only on the FIRST dash... names can't contain dashes.
        realm = str(key).split("-", 1)[1] if "-" in str(key) else ""
        out[norm(name) + "@" + norm(realm)] = {
            "name": name,
            "realm": realm,
            "money": c.get("money", 0) or 0,
            "level": c.get("level", 0) or 0,
            "class": c.get("class", ""),
            "faction": c.get("faction", ""),
            "history": _history(c.get("history")),
            # addon v2.1+; older addon versions simply don't have these
            "rested": c.get("restedXP"),
            "xp_max": c.get("xpMax"),
            "last_seen": c.get("lastSeen", 0) or 0,
            "cooldowns": _cooldowns(c.get("cooldowns")),
            # addon v2.4+: this week's facts for the Todo tab (absent = manual)
            "todo": c.get("todo") if isinstance(c.get("todo"), dict) else None,
            "folder": folder,
        }
    # calendar events (e.g. Timewalking) are the same for every account;
    # keep the most recently read
    ev = db.get("events")
    if isinstance(ev, dict) and ev.get("checkedAt", 0) >= warbands.get("__events__", {}).get("checkedAt", 0):
        warbands["__events__"] = ev
    # each WoW account has its own warband bank
    w = db.get("warband")
    if isinstance(w, dict) and isinstance(w.get("money"), (int, float)):
        warbands[folder] = {"money": w["money"], "updated": w.get("updated", 0),
                            "history": _history(w.get("history"))}


def account_labels(characters):
    """Name Blizzard's numbered WoW accounts after their folders on this PC.

    The API only gives an account number. WoW keeps a folder per account
    (WTF/Account/MYACCOUNT, 12345678#1...) with a subfolder for every
    character played on it, so the folder whose characters best match an
    account's characters is that account. Returns ({id: label},
    {folder: id})."""
    base = wtf_account_dir()
    folders = {}
    for folder in os.listdir(base) if base else []:
        fdir = os.path.join(base, folder)
        if folder == "SavedVariables" or not os.path.isdir(fdir):
            continue
        keys = set()
        for realm in os.listdir(fdir):
            rdir = os.path.join(fdir, realm)
            if realm != "SavedVariables" and os.path.isdir(rdir):
                keys.update(norm(ch) + "@" + norm(realm) for ch in os.listdir(rdir)
                            if os.path.isdir(os.path.join(rdir, ch)))
        folders[folder] = keys
    by_id = {}
    for c in characters:
        if c.get("account_id") is not None:
            by_id.setdefault(c["account_id"], set()).add(
                norm(c["name"]) + "@" + norm(c.get("realm_slug", "")))
    labels, folder_ids = {}, {}
    for aid, keys in by_id.items():
        best = max(folders, key=lambda f: len(folders[f] & keys), default=None)
        if best and folders[best] & keys:
            # the launcher shows "12345678#2" as "WoW2"
            m = re.match(r"^\d+#(\d+)$", best)
            labels[aid] = "WoW" + m.group(1) if m else best
            folder_ids[best] = aid
    return labels, folder_ids


def accounts_info(cache, settings=None):
    """Per WoW account: label, character count, best characters, included?"""
    chars = cache.get("characters", [])
    labels, _ = account_labels(chars)
    picked = set((settings or {}).get("accounts") or [])
    out = {}
    for c in chars:
        aid = c.get("account_id")
        if aid is None:
            continue
        a = out.setdefault(aid, {"id": aid, "label": labels.get(aid) or "Account %s" % aid,
                                 "count": 0, "top": []})
        a["count"] += 1
        a["top"].append((c.get("level") or 0, c["name"]))
    for a in out.values():
        a["top"] = ["%s %d" % (n, lv) for lv, n in sorted(a["top"], reverse=True)[:3]]
        a["included"] = not picked or a["id"] in picked
    return sorted(out.values(), key=lambda a: -a["count"])


def load_satellites(client=None, game="retail"):
    """Every satellite's state for one game client:
    {id: {installed, bundled, chars: {normkey: {exported_at, data, folder}}}}.

    A satellite is "installed" when its addon folder exists in the client's
    AddOns. Save files that are unreadable, from a newer schema, or not
    shaped like the envelope are skipped with a log line - a satellite can
    never break the core dashboard."""
    if client is None:
        root = wow_root()
        client = os.path.join(root, "_retail_") if root else None
    accounts = wtf_account_dir(client)
    out = {}
    for sid, sat in SATELLITES.items():
        if game not in sat["games"]:
            continue
        addon_dir = os.path.join(client, "Interface", "AddOns", sat["folder"]) if client else ""
        entry = {"installed": os.path.isfile(os.path.join(addon_dir, sat["folder"] + ".toc")),
                 "bundled": os.path.isdir(os.path.join(RESOURCE_DIR, "addon", sat["folder"])),
                 "chars": {}}
        for account in sorted(os.listdir(accounts)) if accounts else []:
            path = os.path.join(accounts, account, "SavedVariables", sat["folder"] + ".lua")
            if not os.path.isfile(path):
                continue
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    db = parse_lua_global(f.read(), sat["db"])
                schema = db.get("schemaVersion")
                if not isinstance(schema, int) or schema > sat["schema"]:
                    print("Skipping %s (schema %r; this app reads up to %d) - update the app."
                          % (path, schema, sat["schema"]), flush=True)
                    continue
                for key, c in (db.get("characters") or {}).items():
                    if not isinstance(c, dict) or "-" not in str(key):
                        continue
                    name, realm = str(key).split("-", 1)
                    entry["chars"][norm(name) + "@" + norm(realm)] = {
                        "exported_at": c.get("exportedAt", 0),
                        "data": c.get("data") if isinstance(c.get("data"), dict) else {},
                        "folder": account}
            except Exception as e:
                print("Skipping unreadable %s: %s" % (path, e), flush=True)
        out[sid] = entry
    return out


def apply_live_professions(c, api_synced_at):
    """Where the Professions satellite read a skill in game MORE RECENTLY than
    Blizzard's last sync, show the game's number (marked live). Tiers learned
    since the sync are added. Older satellite readings never override."""
    data = (c.get("sat") or {}).get("professions") or {}
    tiers, scanned = data.get("tiers"), data.get("lastScan", 0)
    if not isinstance(tiers, dict) or not isinstance(scanned, (int, float)) or scanned <= api_synced_at:
        return
    profs = {p["name"]: p for p in c.get("professions", [])}
    for tier_name, t in tiers.items():
        if not isinstance(t, dict) or not isinstance(t.get("skill"), (int, float)):
            continue
        prof = profs.get(str(t.get("profession") or ""))
        if prof is None:
            prof = {"name": str(t.get("profession") or ""), "id": None, "tiers": []}
            if not prof["name"]:
                continue
            c.setdefault("professions", []).append(prof)
            profs[prof["name"]] = prof
        tier = next((x for x in prof["tiers"] if x.get("name") == tier_name), None)
        if tier is None:
            order, exp = expansion_of(tier_name)
            tier = {"id": None, "name": tier_name, "recipes": [], "order": order, "exp": exp}
            prof["tiers"].append(tier)
            prof["tiers"].sort(key=lambda x: x.get("order", 99))
        tier["skill"], tier["max"] = int(t["skill"]), int(t.get("maxSkill") or tier.get("max") or 0)
        tier["live"] = int(scanned)


def satellites_summary(sats):
    """What the page needs to decide: real view, "no data yet", or install card."""
    return {sid: {"title": SATELLITES[sid]["title"], "pitch": SATELLITES[sid]["pitch"],
                  "installed": e["installed"], "bundled": e["bundled"],
                  "characters": len(e["chars"])}
            for sid, e in sats.items()}


def gold_7d_change(hist):
    if not hist or len(hist) < 2:
        return 0
    now = hist[-1]["money"]
    week_ago = (datetime.date.today() - datetime.timedelta(days=7)).isoformat()
    old = hist[0]["money"]
    for h in hist:
        if h["day"] <= week_ago:
            old = h["money"]
        else:
            break
    return now - old


def fmt_gold(copper):
    try:
        copper = int(copper)
    except (TypeError, ValueError):
        copper = 0
    # exact whole gold with thousands separators (silver/copper dropped)
    return "{:,}g".format(copper // 10000)


# -------------------------------------------------------------- blizzard ---

def token_request(data, client_id=None, client_secret=None):
    """POST to Blizzard's token endpoint. Credentials default to the saved
    ones; setup passes new ones explicitly to test them before saving."""
    if client_id is None:
        cfg = load_config()
        client_id, client_secret = cfg["client_id"], cfg["client_secret"]
    req = urllib.request.Request(
        OAUTH_TOKEN,
        data=urllib.parse.urlencode(data).encode("utf-8"),
        headers={
            "Authorization": "Basic " + base64.b64encode(
                ("%s:%s" % (client_id, client_secret)).encode("utf-8")
            ).decode("ascii"),
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def is_connected():
    """True while the Battle.net *login* token is valid. Blizzard's login
    tokens last 24 hours and come with no refresh token, so this goes False
    daily - which only limits the few endpoints that need the login."""
    cfg = load_config()
    if cfg.get("access_token") and cfg.get("expires_at", 0) > time.time() + 60:
        return True
    return bool(cfg.get("refresh_token"))


def has_credentials():
    cfg = load_config()
    return bool(cfg.get("client_id") and cfg.get("client_secret"))


def ensure_token():
    """The Battle.net login token (authorization code flow)."""
    cfg = load_config()
    # use a still-valid access token even if no refresh token was issued
    if cfg.get("access_token") and cfg.get("expires_at", 0) > time.time() + 60:
        return cfg["access_token"]
    if not cfg.get("refresh_token"):
        raise RuntimeError("not_connected")
    tok = token_request({"grant_type": "refresh_token",
                         "refresh_token": cfg["refresh_token"]})
    cfg["access_token"] = tok["access_token"]
    cfg["refresh_token"] = tok.get("refresh_token", cfg["refresh_token"])
    cfg["expires_at"] = time.time() + tok.get("expires_in", 86400)
    save_config(cfg)
    return cfg["access_token"]


_APP_TOKEN = {"token": None, "expires_at": 0}


def app_token():
    """An app-level token (client credentials flow) - no login needed.

    Blizzard only requires your *login* for your account's character list
    and mounts/pets. Everything else (each character's profile, professions,
    achievements, game data) works with this token, which we can renew any
    time on our own - so syncing keeps working after the 24h login expires.
    Kept in memory only; never written to disk."""
    if _APP_TOKEN["token"] and _APP_TOKEN["expires_at"] > time.time() + 60:
        return _APP_TOKEN["token"]
    tok = token_request({"grant_type": "client_credentials"})
    _APP_TOKEN["token"] = tok["access_token"]
    _APP_TOKEN["expires_at"] = time.time() + tok.get("expires_in", 86400)
    return _APP_TOKEN["token"]


def region():
    r = load_config().get("region", "us")
    return r if r in REGIONS else "us"


def api_get(path, params=None):
    # /profile/user/... is "your account" data and needs the login token;
    # everything else uses the self-renewing app token
    token = ensure_token() if path.startswith("/profile/user/") else app_token()
    reg = region()
    q = dict(params or {})
    q["locale"] = "en_US"
    url = "https://%s.api.blizzard.com%s" % (reg, path)
    # namespace goes in the query string: profile-* for your characters,
    # static-* for game data like the full recipe list of a profession tier
    if path.startswith("/profile/"):
        q["namespace"] = "profile-" + reg
    elif path.startswith("/data/"):
        q["namespace"] = "static-" + reg
    url += "?" + urllib.parse.urlencode(q)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        raise RuntimeError("Blizzard API error %s: %s" % (e.code, body))


def parse_professions(prof):
    """Keep EVERY expansion tier (skill + known recipes), not just one."""
    out = []
    for p in (prof.get("primaries") or []) + (prof.get("secondaries") or []):
        pinfo = p.get("profession") or {}
        tiers = []
        for t in p.get("tiers") or []:
            tinfo = t.get("tier") or {}
            tiers.append({
                "id": tinfo.get("id"),
                "name": tinfo.get("name", ""),
                "skill": t.get("skill_points", 0),
                "max": t.get("max_skill_points", 0),
                "recipes": [{"id": r.get("id"), "name": r.get("name", "")}
                            for r in (t.get("known_recipes") or [])],
            })
        # a few professions (e.g. Archaeology) have one flat skill, no tiers
        if not tiers and "skill_points" in p:
            tiers.append({"id": None, "name": "", "recipes": [],
                          "skill": p.get("skill_points", 0),
                          "max": p.get("max_skill_points", 0)})
        out.append({"name": pinfo.get("name", ""), "id": pinfo.get("id"),
                    "tiers": tiers})
    return out


def fetch_tier_catalog(prof_id, tier_id):
    """Every recipe that exists in one profession tier (game data API)."""
    d = api_get("/data/wow/profession/%s/skill-tier/%s" % (prof_id, tier_id))
    recipes = {}
    for cat in d.get("categories") or []:
        for r in cat.get("recipes") or []:
            if r.get("id"):
                recipes[str(r["id"])] = r.get("name", "")
    return {"name": d.get("name", ""), "recipes": recipes,
            "fetched_at": int(time.time())}


def sync_catalog(dataset, catalog):
    """Fetch recipe lists for any tier we haven't seen (or that went stale)."""
    needed = set()
    for c in dataset:
        for p in c["professions"]:
            for t in p["tiers"]:
                if p.get("id") and t.get("id"):
                    needed.add((p["id"], t["id"]))
    now = time.time()
    todo = sorted(x for x in needed
                  if now - catalog.get(str(x[1]), {}).get("fetched_at", 0)
                  > CATALOG_MAX_AGE)
    for j, (pid, tid) in enumerate(todo):
        try:
            catalog[str(tid)] = fetch_tier_catalog(pid, tid)
        except Exception as e:
            print("  recipe list for tier %s failed: %s" % (tid, e), flush=True)
        if (j + 1) % 10 == 0 or (j + 1) == len(todo):
            print("  recipe lists %d/%d..." % (j + 1, len(todo)), flush=True)
        time.sleep(0.05)
    return catalog


def refresh_character(entry):
    """Fill one character's profile details + professions from Blizzard.

    Each call is allowed to fail on its own: Blizzard 404s characters that
    haven't logged in recently, and that shouldn't sink the whole sync."""
    path = "/profile/wow/character/%s/%s" % (
        entry["realm_slug"], urllib.parse.quote(entry["name"].lower()))
    try:
        s = api_get(path)
        entry["level"] = s.get("level", entry.get("level", 0))
        entry["ilvl"] = s.get("equipped_item_level") or s.get("average_item_level") or 0
        entry["achievement_points"] = s.get("achievement_points", 0)
        entry["last_login"] = int((s.get("last_login_timestamp") or 0) / 1000)
        entry["race"] = (s.get("race") or {}).get("name", "")
        entry["spec"] = (s.get("active_spec") or {}).get("name", "")
        entry["guild"] = (s.get("guild") or {}).get("name", "")
    except Exception:
        pass
    try:
        entry["professions"] = parse_professions(api_get(path + "/professions"))
    except Exception:
        pass


def sync_all():
    """Pull characters + professions from Blizzard. Returns dataset dict."""
    old = load_cache()
    try:
        account = api_get("/profile/user/wow")
        logged_in = True
    except RuntimeError as e:
        if str(e) != "not_connected" or not old.get("characters"):
            raise
        # Login expired (they last 24h). The character LIST needs the login,
        # but each character's details don't - so refresh the characters we
        # already know about, using the app token.
        logged_in = False
        print("  Battle.net login expired - refreshing known characters only "
              "(Connect again to pick up new characters and mounts/pets).",
              flush=True)
    if logged_in:
        bases = []
        for acct in account.get("wow_accounts", []):
            for ch in acct.get("characters", []):
                bases.append({
                    "account_id": acct.get("id"),
                    "name": ch.get("name", ""),
                    "realm_slug": (ch.get("realm") or {}).get("slug", ""),
                    "realm": (ch.get("realm") or {}).get("name", ""),
                    "level": ch.get("level", 0),
                    "class": ((ch.get("playable_class") or {}).get("name")) or "",
                    "faction": ((ch.get("faction") or {}).get("name")) or "",
                    "professions": [],
                })
    else:
        # keep last known professions in case this character's refresh fails
        keep = ("account_id", "name", "realm_slug", "realm", "level", "class",
                "faction", "professions")
        bases = [{k: c.get(k) for k in keep} for c in old["characters"]]
    dataset = []
    for i, entry in enumerate(bases):
        refresh_character(entry)
        dataset.append(entry)
        if (i + 1) % 5 == 0 or (i + 1) == len(bases):
            print("  synced %d/%d characters..." % (i + 1, len(bases)), flush=True)
        time.sleep(0.05)  # be polite to the API
    catalog = sync_catalog(dataset, old.get("catalog", {}))
    collections = sync_collections(dataset)
    if not logged_in:
        # mounts/pets need the login; keep the last copy (30-day TTL applies
        # via login_synced_at below)
        for k in ("mounts", "pets"):
            if k not in collections and k in old.get("collections", {}):
                collections[k] = old["collections"][k]
    game = sync_game_data(old.get("game", {}))
    sync_reputations(dataset, old)
    rep_meta = sync_rep_meta(old.get("rep_meta", {}))
    now = int(time.time())
    return {"characters": dataset, "catalog": catalog,
            "collections": collections, "game": game, "rep_meta": rep_meta,
            "synced_at": now,
            # when login-only data (character list, mounts, pets) was last
            # fetched; the 30-day limit is enforced from this too
            "login_synced_at": now if logged_in else
            old.get("login_synced_at", old.get("synced_at", now))}


def sync_collections(dataset):
    """Account-wide mounts + pets, and achievements.

    Mounts and pets are Warband-wide, so one call each covers the account.
    Achievements are also mostly account-wide, but Blizzard only serves them
    per character - so we read the character with the most points, which is
    the fullest view of the account."""
    out = {}
    print("  collections...", flush=True)
    try:
        m = api_get("/profile/user/wow/collections/mounts")
        out["mounts"] = sorted(
            [{"id": x["mount"].get("id"), "name": x["mount"].get("name", ""),
              "fav": bool(x.get("is_favorite"))}
             for x in m.get("mounts", []) if x.get("mount")],
            key=lambda x: x["name"])
    except Exception as e:
        print("  mounts failed: %s" % e, flush=True)
    try:
        p = api_get("/profile/user/wow/collections/pets")
        out["pets"] = [{
            "species_id": (x.get("species") or {}).get("id"),
            "name": (x.get("species") or {}).get("name", ""),
            "nick": x.get("name", ""),
            "level": x.get("level", 0),
            "quality": (x.get("quality") or {}).get("name", ""),
            "fav": bool(x.get("is_favorite")),
        } for x in p.get("pets", [])]
    except Exception as e:
        print("  pets failed: %s" % e, flush=True)
    best = max(dataset, key=lambda c: (c.get("achievement_points", 0),
                                       c.get("last_login", 0)), default=None)
    if best and best.get("achievement_points"):
        try:
            a = api_get("/profile/wow/character/%s/%s/achievements"
                        % (best["realm_slug"],
                           urllib.parse.quote(best["name"].lower())))
            done = [x for x in a.get("achievements", [])
                    if x.get("completed_timestamp")]
            done.sort(key=lambda x: -x["completed_timestamp"])
            out["achievements"] = {
                "character": best["name"], "realm": best["realm"],
                "faction": best.get("faction", ""),
                "points": a.get("total_points", 0),
                "completed": len(done),
                "categories": {
                    str((cp.get("category") or {}).get("id")):
                        {"quantity": cp.get("quantity", 0),
                         "points": cp.get("points", 0)}
                    for cp in a.get("category_progress", [])},
                "recent": [{"id": x.get("id"),
                            "name": (x.get("achievement") or {}).get("name", ""),
                            "at": int(x["completed_timestamp"] / 1000)}
                           for x in done[:40]],
            }
        except Exception as e:
            print("  achievements failed: %s" % e, flush=True)
    return out


# Reputation standings change slowly and cost one request per character,
# so they're refreshed once a day rather than on every hourly sync.
REP_SYNC_EVERY = 86400
UNGROUPED = "Not grouped by Blizzard"


def _compact_rep(x):
    """One reputation from Blizzard, trimmed to what the tab needs."""
    st, pa = x.get("standing") or {}, x.get("paragon") or {}
    return {"nm": (x.get("faction") or {}).get("name", ""), "n": st.get("name", ""),
            "t": st.get("tier"), "v": st.get("value", 0), "m": st.get("max", 0),
            "raw": st.get("raw", 0), "r": st.get("renown_level"),
            "pv": pa.get("value"), "pm": pa.get("max")}


def sync_reputations(dataset, old):
    """Attach each character's reputations (refetched when a day old)."""
    prev = {norm(c["name"]) + "@" + norm(c.get("realm_slug", "")): c
            for c in old.get("characters", [])}
    now, fetched = time.time(), 0
    for c in dataset:
        p = prev.get(norm(c["name"]) + "@" + norm(c.get("realm_slug", "")), {})
        if p.get("reps") is not None and now - p.get("reps_at", 0) < REP_SYNC_EVERY:
            c["reps"], c["reps_at"] = p["reps"], p["reps_at"]
            continue
        try:
            r = api_get("/profile/wow/character/%s/%s/reputations"
                        % (c["realm_slug"], urllib.parse.quote(c["name"].lower())))
            c["reps"] = {str((x.get("faction") or {}).get("id")): _compact_rep(x)
                         for x in r.get("reputations", []) if (x.get("faction") or {}).get("id")}
            c["reps_at"] = int(now)
            fetched += 1
        except Exception:
            if p.get("reps") is not None:  # keep yesterday's rather than nothing
                c["reps"], c["reps_at"] = p["reps"], p.get("reps_at", 0)
        time.sleep(0.05)
    if fetched:
        print("  reputations refreshed for %d characters" % fetched, flush=True)


def sync_rep_meta(meta):
    """Faction reference data (weekly): which expansion each faction belongs
    to, how many Renown levels it has, and its standing tiers. Blizzard's
    faction tree has the expansions at the top, so the grouping comes from
    Blizzard rather than a hand-made list."""
    if meta and time.time() - meta.get("fetched_at", 0) < CATALOG_MAX_AGE:
        return meta
    print("  reputation reference data...", flush=True)
    try:
        idx = api_get("/data/wow/reputation-faction/index")
        roots = idx.get("root_factions", [])
        factions, tier_ids, seen = {}, set(), set()

        def fetch(fid):
            try:
                return api_get("/data/wow/reputation-faction/%s" % fid)
            except Exception:
                return None

        # walk the tree one level at a time, ~6 requests in flight - well
        # under Blizzard's 100/second limit, and ~4x faster than one by one
        level = [(r["id"], r["name"]) for r in roots]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            while level:
                level = [(fid, root) for fid, root in level if fid not in seen]
                seen.update(fid for fid, _ in level)
                nxt = []
                for (fid, root), f in zip(level, pool.map(fetch, [fid for fid, _ in level])):
                    if not f:
                        continue
                    tid = (f.get("reputation_tiers") or {}).get("id")
                    levels = [t.get("level", 0) for t in f.get("renown_tiers") or []]
                    factions[str(fid)] = {
                        "name": f.get("name", ""), "root": root, "header": bool(f.get("is_header")),
                        "renown_max": (max(levels) if levels else None) if f.get("is_renown") else None,
                        "tiers": tid}
                    if tid is not None:
                        tier_ids.add(tid)
                    nxt.extend((ch["id"], root) for ch in f.get("factions") or [] if ch.get("id"))
                level = nxt
        tiers = {}
        for tid in tier_ids:
            try:
                ts = api_get("/data/wow/reputation-tiers/%s" % tid).get("tiers") or []
                tiers[str(tid)] = {"last": max(t.get("id", 0) for t in ts) if ts else None}
            except Exception:
                pass
        # newest expansion first, as Blizzard lists them; guild-style groups
        # last. A few old factions (the Aldor, Booty Bay...) sit under groups
        # Blizzard's data doesn't include, so they have no expansion - shown
        # as such rather than guessed.
        order = [r["name"] for r in roots if r["name"] != "Guild"] + ["Guild", UNGROUPED]
        return {"fetched_at": int(time.time()), "order": order,
                "factions": factions, "tiers": tiers}
    except Exception as e:
        print("  reputation reference data failed: %s" % e, flush=True)
        return meta


def rep_rows(entries, meta):
    """Display rows for {faction id: (compact rep, best character name)}."""
    facs, tiers = (meta or {}).get("factions", {}), (meta or {}).get("tiers", {})
    rows = []
    for fid, (r, who) in entries.items():
        m = facs.get(fid, {})
        if r.get("r") is not None:  # Renown faction
            top = m.get("renown_max")
            maxed = bool(top) and r["r"] >= top
            standing = "Renown %d" % r["r"] + (" of %d" % top if top else "")
        else:
            last = (tiers.get(str(m.get("tiers"))) or {}).get("last")
            # top tier reached: Exalted for classic factions, or the last
            # rank of a "friendship" faction (Best Friend, etc.)
            maxed = (last is not None and r.get("t") == last) or (
                last is None and not r.get("m") and r.get("raw", 0) > 0)
            standing = r.get("n", "")
        # round DOWN while unfinished: 5,999 of 6,000 is 99.9%, never "100%"
        pct = 100.0 if maxed else (math.floor(r.get("v", 0) * 1000.0 / r["m"]) / 10 if r.get("m") else 0.0)
        rows.append({
            "id": fid, "name": m.get("name") or r.get("nm") or "Faction %s" % fid,
            "expansion": m.get("root") or UNGROUPED, "standing": standing,
            "value": r.get("v", 0), "max": r.get("m", 0), "pct": round(pct, 1),
            "maxed": maxed, "who": who,
            "paragon": {"value": r["pv"], "max": r["pm"]} if r.get("pm") else None})
    return rows


def reps_payload(chars, cache, char_key=None):
    """Account best per faction across the shown characters, or one
    character's standings. Since The War Within many reputations are shared
    by the whole warband, so the account view takes the best of anyone."""
    meta = cache.get("rep_meta", {})
    with_reps = [c for c in chars if c.get("reps")]
    if char_key:
        c = next((c for c in with_reps if c["key"] == char_key), None)
        entries = {fid: (r, None) for fid, r in (c["reps"] if c else {}).items()}
    else:
        entries = {}
        for c in with_reps:
            for fid, r in c["reps"].items():
                if fid not in entries or r.get("raw", 0) > entries[fid][0].get("raw", 0):
                    entries[fid] = (r, c["name"])
    return {"order": meta.get("order", []), "rows": rep_rows(entries, meta),
            "characters": [{"key": c["key"], "name": c["name"], "realm": c.get("realm", ""),
                            "level": c.get("level", 0), "tracked": c.get("tracked", False)}
                           for c in with_reps],
            "has_meta": bool(meta)}


def sync_game_data(game):
    """Totals to measure collections against (weekly, they rarely change)."""
    if time.time() - game.get("fetched_at", 0) < CATALOG_MAX_AGE:
        return game
    print("  game data (mount/pet/achievement lists)...", flush=True)
    try:
        g = {"fetched_at": int(time.time())}
        g["mounts"] = {str(m["id"]): m.get("name", "")
                       for m in api_get("/data/wow/mount/index").get("mounts", [])}
        g["pets"] = {str(p["id"]): p.get("name", "")
                     for p in api_get("/data/wow/pet/index").get("pets", [])}
        g["achievement_total"] = len(
            api_get("/data/wow/achievement/index").get("achievements", []))
        cats = []
        idx = api_get("/data/wow/achievement-category/index")
        for rc in idx.get("root_categories", []):
            try:
                c = api_get("/data/wow/achievement-category/%s" % rc["id"])
            except Exception:
                continue
            if c.get("is_guild_category"):
                continue  # guild achievements aren't yours to earn solo
            agg = c.get("aggregates_by_faction") or {}
            cats.append({"id": c.get("id"), "name": c.get("name", ""),
                         "order": c.get("display_order", 0),
                         "alliance": (agg.get("alliance") or {}).get("quantity", 0),
                         "horde": (agg.get("horde") or {}).get("quantity", 0)})
        g["achievement_categories"] = sorted(cats, key=lambda c: c["order"])
        return g
    except Exception as e:
        print("  game data failed: %s" % e, flush=True)
        return game


def load_cache():
    if os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            return enforce_ttl(json.load(f))
    return {"characters": [], "synced_at": 0}


def enforce_ttl(data):
    """Blizzard API Terms 2(s): at most 30 days' retention for API Data.

    Anything older is deleted from disk here, on every read - so the limit
    holds even if you stop syncing. Addon gold data isn't API Data and lives
    in its own file, so it's untouched."""
    now = time.time()
    purged = False
    # login-only data (character list, mounts, pets) can be older than the
    # last sync if you haven't reconnected, so check both timestamps
    stamps = [t for t in (data.get("synced_at"), data.get("login_synced_at")) if t]
    if stamps and now - min(stamps) > API_DATA_TTL:
        data["characters"], data["collections"], data["synced_at"] = [], {}, 0
        data.pop("login_synced_at", None)
        purged = True
    for tid in [t for t, c in data.get("catalog", {}).items()
                if now - c.get("fetched_at", 0) > API_DATA_TTL]:
        del data["catalog"][tid]
        purged = True
    if data.get("game") and now - data["game"].get("fetched_at", 0) > API_DATA_TTL:
        data["game"] = {}
        purged = True
    if purged:
        print("Deleted Blizzard data older than 30 days (API Terms 2(s)).",
              flush=True)
        save_cache(data)
    return data


def save_cache(data):
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f)


def load_settings():
    s = {}
    if os.path.exists(SETTINGS_PATH):
        with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
            s = json.load(f)
    s.setdefault("tracked", [])
    s.setdefault("gold_goal", None)
    return s


def save_settings(s):
    with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
        json.dump(s, f, indent=2)


def load_roles():
    if os.path.exists(ROLES_PATH):
        with open(ROLES_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_roles(roles):
    with open(ROLES_PATH, "w", encoding="utf-8") as f:
        json.dump(roles, f, indent=2, sort_keys=True)


def expansion_of(tier_name):
    """(sort index, short label) for a tier name like 'Northrend Mining'."""
    for i, (short, _full, prefixes) in enumerate(EXPANSIONS):
        if tier_name.startswith(prefixes):
            return i, short
    if not tier_name:
        return len(EXPANSIONS), "Skill"  # flat skill, e.g. Archaeology
    return len(EXPANSIONS) + 1, "Other"


def normalize_professions(profs):
    """Tag tiers with their expansion; also upgrades caches from v1."""
    out = []
    for p in profs or []:
        tiers = p.get("tiers")
        if tiers is None:
            # v1 cache: one tier per profession, no recipes - shows until
            # the next sync replaces it
            tiers = [{"id": None, "name": p.get("tier", ""), "recipes": [],
                      "skill": p.get("skill", 0), "max": p.get("max", 0)}]
        for t in tiers:
            t["order"], t["exp"] = expansion_of(t.get("name", ""))
        tiers.sort(key=lambda t: t["order"])
        out.append({"name": p.get("name", ""), "id": p.get("id"),
                    "tiers": tiers})
    return out


def do_sync():
    if STATE["syncing"]:
        print("Sync already running - ignoring duplicate request.", flush=True)
        return
    STATE["syncing"] = True
    STATE["sync_error"] = None
    print("Sync started...", flush=True)
    try:
        data = sync_all()
        with CACHE_LOCK:
            save_cache(data)
        print("Sync complete: %d characters saved." % len(data["characters"]),
              flush=True)
    except Exception as e:
        import traceback
        traceback.print_exc()
        msg = str(e)
        if msg == "not_connected":
            msg = ("Not connected to Battle.net. Either click 'Connect Battle.net', "
                   "or - if you moved forge_dashboard.py to a new folder - move it "
                   "back: your login is saved in forge_dashboard_config.json next "
                   "to the script, so each copy starts fresh.")
        STATE["sync_error"] = msg
        print("Sync FAILED: %s" % msg, flush=True)
    finally:
        STATE["syncing"] = False


def quick_sync(char_key):
    """Refresh one character from Blizzard after the addon saved in game.

    char_key is the addon's "Name-Realm" (realm with spaces/apostrophes
    stripped). norm() strips those from the API's realm slug too, so
    "Earthen Ring" / "earthen-ring" / "EarthenRing" all compare equal."""
    if STATE["syncing"] or not has_credentials() or "-" not in char_key:
        return
    name, realm = char_key.split("-", 1)
    want = norm(name) + "@" + norm(realm)
    with CACHE_LOCK:
        cache = load_cache()
        entry = next((c for c in cache.get("characters", [])
                      if norm(c["name"]) + "@" + norm(c.get("realm_slug", "")) == want),
                     None)
    if entry is None:
        return  # not synced yet (brand-new character) - the next full sync adds it
    refresh_character(entry)
    with CACHE_LOCK:
        # re-read in case a full sync finished meanwhile; swap in our entry
        cache = load_cache()
        for i, c in enumerate(cache.get("characters", [])):
            if norm(c["name"]) + "@" + norm(c.get("realm_slug", "")) == want:
                cache["characters"][i] = entry
                save_cache(cache)
                break
    print("Refreshed %s from Blizzard." % name, flush=True)


def auto_sync_loop():
    """Full Blizzard sync on startup if data is stale, then hourly.

    An hourly full sync is ~300 requests - under 1% of Blizzard's
    36,000/hour limit - and also keeps cached Data well inside the 30-day
    retention rule. Checks every 5 minutes so a stale cache after the PC
    wakes from sleep gets picked up quickly."""
    time.sleep(5)  # let the server finish starting first
    while True:
        try:
            check_for_update()  # no-op unless a day has passed
        except Exception:
            pass
        try:
            age = time.time() - load_cache().get("synced_at", 0)
            if age >= AUTO_SYNC_EVERY and has_credentials() and not STATE["syncing"]:
                print("Auto-sync: Blizzard data is %d min old." % (age // 60),
                      flush=True)
                do_sync()
        except Exception as e:
            print("Auto-sync check failed: %s" % e, flush=True)
        time.sleep(300)


def watch_addon_file():
    """Notice the moment WoW writes the addon's save file (/fl sync,
    /reload, logout) and refresh that character. Polling every 2s is
    simpler than OS file-watch APIs and costs nothing measurable."""
    last = None
    while True:
        try:
            path = find_sv_file()
            mtime = os.path.getmtime(path) if path else None
            if mtime and last and mtime != last:
                STATE["sv_mtime"] = mtime
                print("Addon data saved in game - updating.", flush=True)
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    db = parse_savedvariables(f.read())
                if db.get("lastChar"):
                    threading.Thread(target=quick_sync, args=(str(db["lastChar"]),),
                                     daemon=True).start()
            STATE["sv_mtime"] = mtime
            last = mtime or last
        except Exception as e:
            # WoW may be mid-write; the next tick will see the finished file
            print("Addon watcher: %s" % e, flush=True)
        time.sleep(2)


# ----------------------------------------------------------- app update ---
#
# Once a day, ask GitHub for the newest release and tell the user if it's
# newer than this build. Notify + link only - never download or install
# anything (the .exe isn't code-signed, so silent installs would be a red
# flag). Offline, rate-limited, or the repo still private (GitHub answers
# 404 without a login) all just mean "no update info": no banner, no error.

UPDATE_REPO = "Onepromise/forges-ledger"
UPDATE_PATH = os.path.join(BASE_DIR, "update_check.json")
UPDATE_EVERY = 86400


def parse_version(tag):
    """'v0.10.0' -> (0, 10, 0) so versions compare numerically, not as text
    (as text, '0.10.0' would sort before '0.2.1')."""
    m = re.match(r"v?(\d+)(?:\.(\d+))?(?:\.(\d+))?", str(tag or "").strip())
    return tuple(int(x or 0) for x in m.groups()) if m else None


def _read_update_state():
    try:
        with open(UPDATE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def check_for_update(force=False):
    state = _read_update_state()
    if not force and time.time() - state.get("checked_at", 0) < UPDATE_EVERY:
        return state
    # The releases LIST, not /releases/latest: "latest" skips pre-releases,
    # and every release so far is a pre-release.
    url = "https://api.github.com/repos/%s/releases?per_page=20" % UPDATE_REPO
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "ForgesLedger/" + APP_VERSION})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            releases = json.load(r)
        best = None
        for rel in releases if isinstance(releases, list) else []:
            v = parse_version(rel.get("tag_name"))
            if rel.get("draft") or not v:
                continue
            if best is None or v > best[0]:
                best = (v, rel.get("tag_name"), rel.get("html_url", ""))
        state = {"checked_at": int(time.time()),
                 "latest": best[1] if best else None,
                 "url": best[2] if best else None}
    except urllib.error.HTTPError:
        # 404 = repo private (or gone), 403 = rate limited: no update info
        state = {"checked_at": int(time.time()), "latest": None, "url": None}
    except (OSError, ValueError):
        return state  # offline or a garbled reply: try again next time
    try:
        with open(UPDATE_PATH, "w", encoding="utf-8") as f:
            json.dump(state, f)
    except OSError:
        pass
    return state


def update_available():
    st = _read_update_state()
    latest, current = parse_version(st.get("latest")), parse_version(APP_VERSION)
    url = st.get("url") or ""
    # only ever link to this project's own release pages
    if (latest and current and latest > current
            and url.startswith("https://github.com/%s/releases/" % UPDATE_REPO)):
        return {"version": str(st["latest"]).lstrip("v"), "url": url}
    return None


# --------------------------------------------------------------- todo ---
#
# Daily and weekly tasks per character. "auto" items are answered from what
# the addon read in game (addon v2.4+), but only if it was read SINCE the
# last reset - last week's Great Vault is not this week's. Anything the
# addon can't see, or hasn't seen yet, falls back to a manual checkbox.
# Manual ticks are stored with the day/week id and clear on rollover.
# Catalogs are per game: Forever has no Great Vault, Mythic+ or Sparks.

TODO_CATALOG = {
    "retail": {
        "daily": [
            ("cooldowns", "Profession cooldowns", "auto"),
            ("timewalking", "Timewalking dungeon", "event"),  # only while the event runs
        ],
        "weekly": [
            ("vault", "Great Vault slots", "auto"),
            ("vaultclaim", "Claim last week's Vault", "auto"),
            ("mplus", "Mythic+ runs", "auto"),
            ("raids", "Raid lockouts", "auto"),
            ("worldboss", "World boss", "auto"),
            ("quests", "Weekly quests & Sparks", "manual"),
            ("knowledge", "Profession knowledge treasures", "manual"),
        ],
    },
    "forever": {
        "daily": [],
        "weekly": [
            ("raids", "Raid lockouts", "auto"),
            ("quests", "Weekly quests", "manual"),
        ],
    },
}
# US resets: daily at 15:00 UTC, weekly on Tuesday at 15:00 UTC
# (7am Pacific standard / 8am daylight). Any past reset works as the anchor.
RESET_ANCHOR = datetime.datetime(2026, 1, 6, 15, 0, tzinfo=datetime.timezone.utc)


def week_id(now=None):
    now = now if now is not None else time.time()
    return int((now - RESET_ANCHOR.timestamp()) // (7 * 86400))


def day_id(now=None):
    now = now if now is not None else time.time()
    return int((now - RESET_ANCHOR.timestamp()) // 86400)


def next_reset(now=None):
    """Next weekly reset (unix time)."""
    now = now if now is not None else time.time()
    return int(RESET_ANCHOR.timestamp() + (week_id(now) + 1) * 7 * 86400)


def next_daily_reset(now=None):
    now = now if now is not None else time.time()
    return int(RESET_ANCHOR.timestamp() + (day_id(now) + 1) * 86400)


def todo_checks(settings):
    """Manual ticks still valid now: {"daily": {key: {item: True}}, "weekly": ...}.
    Reads the pre-Todo "weekly" checklist too, so this week's ticks survive."""
    t = settings.get("todo") or {}
    daily = t.get("daily", {}) if t.get("day") == day_id() else {}
    weekly = t.get("weekly", {}) if t.get("week") == week_id() else {}
    old = settings.get("weekly") or {}
    if not t and old.get("week") == week_id():
        weekly = old.get("checks", {})
    return {"daily": daily, "weekly": weekly}


def todo_payload(settings, game, events):
    cat = TODO_CATALOG[game]
    tw = None
    if events and events.get("checkedAt", 0) >= next_daily_reset() - 86400:
        tw = events.get("timewalking")  # read today, so it's current
    return {"catalog": {period: [{"id": i, "label": l, "kind": k} for i, l, k in items]
                        for period, items in cat.items()},
            "checks": todo_checks(settings),
            "next_daily": next_daily_reset(), "next_weekly": next_reset(),
            "timewalking": tw}


def todo_auto(c, facts):
    """Auto answers for one character from the addon's facts (+ cooldowns).
    {item: {"state": "done"|"todo"|"info", "detail": "..."}}; items with no
    fresh facts are left out, so the page shows a manual checkbox."""
    out = {}
    week_start = next_reset() - 7 * 86400
    now = time.time()
    cds = c.get("cooldowns") or []
    if cds:
        ready = [cd for cd in cds if cd["ready_at"] <= now]
        out["cooldowns"] = {"state": "todo" if ready else "done",
                            "detail": ("%d ready" % len(ready)) if ready else "all used"}
    if not facts or facts.get("at", 0) < week_start:
        return out  # nothing read since the weekly reset
    vault = facts.get("vault")
    if isinstance(vault, dict):
        # "Concession" is the vault's "Or collect" reward, taken INSTEAD of a
        # slot - not a slot to earn, so it isn't counted
        vault = {n: r for n, r in vault.items() if n != "Concession"}
    if isinstance(vault, dict) and vault:
        unlocked = sum(r.get("unlocked", 0) for r in vault.values() if isinstance(r, dict))
        total = sum(r.get("total", 0) for r in vault.values() if isinstance(r, dict))
        rows = " · ".join("%s %d/%d" % ({"Activities": "Dungeons"}.get(n, n), r.get("unlocked", 0), r.get("total", 0))
                          for n, r in sorted(vault.items()) if isinstance(r, dict))
        out["vault"] = {"state": "done" if total and unlocked >= total else "todo",
                        "detail": "%d/%d · %s" % (unlocked, total, rows)}
    if "vaultClaim" in facts:
        out["vaultclaim"] = ({"state": "todo", "detail": "rewards waiting"} if facts["vaultClaim"]
                             else {"state": "done", "detail": "nothing waiting"})
    mp = facts.get("mplus")
    if isinstance(mp, dict):
        runs = mp.get("runs", 0)
        out["mplus"] = {"state": "done" if runs >= 8 else "todo",
                        "detail": "%d/8 runs%s" % (runs, (", best +%d" % mp["best"]) if mp.get("best") else "")}
    raids = facts.get("raids")
    if isinstance(raids, list):
        live = [r for r in raids if isinstance(r, dict) and r.get("resetAt", 0) > now]
        out["raids"] = ({"state": "done", "detail": " · ".join(
                            "%s (%s) %d/%d" % (r.get("name"), r.get("difficulty"), r.get("killed", 0), r.get("total", 0))
                            for r in live)} if live else {"state": "todo", "detail": "none yet"})
    bosses = facts.get("worldBosses")
    if isinstance(bosses, list):
        live = [b for b in bosses if isinstance(b, dict) and b.get("resetAt", 0) > now]
        out["worldboss"] = ({"state": "done", "detail": ", ".join(str(b.get("name")) for b in live)}
                            if live else {"state": "todo", "detail": "not killed yet"})
    return out


# ------------------------------------------------------------------ web ---

# raw string so JS/CSS in the page can never be mangled by Python escapes
PAGE = r"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Forge's Ledger</title>
<link rel="icon" href="/favicon.ico">
<style>
:root{--bg:#0e1015;--panel:#161920;--panel2:#1b1f27;--hover:#1e232c;--line:#252a35;--txt:#e6e8ee;--dim:#8b93a5;--faint:#596173;
--gold:#f5c542;--green:#4ade80;--red:#f87171;--amber:#fbbf24;--accent:#7c93ff}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--txt);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;margin:0}
.wrap{max-width:1320px;margin:0 auto;padding:28px 20px 60px}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;flex-wrap:wrap}
h1{margin:0;font-size:22px;font-weight:650;letter-spacing:-.01em}
.sub{color:var(--dim);font-size:13px;margin-top:3px}
.btn{background:var(--panel2);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:8px 14px;cursor:pointer;font:inherit;text-decoration:none;display:inline-block}
.btn:hover{background:var(--hover)}.btn.primary{background:#3b5bfd;border-color:#3b5bfd;color:#fff}.btn.primary:hover{background:#4d6bff}
.btn:disabled{opacity:.5;cursor:default}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:22px 0 8px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.stat .v{font-size:24px;font-weight:650;font-variant-numeric:tabular-nums}
.stat .l{color:var(--dim);font-size:12px;margin-top:2px}
.goldv{color:var(--gold)}
.alert{padding:10px 14px;border-radius:10px;margin:12px 0;font-size:13px}
.alert.err{background:#2a1517;border:1px solid #5c2328;color:#fecaca}
.alert.ok{background:#11261b;border:1px solid #1f5136;color:#bbf7d0}
.alert.info{background:var(--panel);border:1px solid var(--line);color:var(--dim)}
.tabs{display:flex;gap:2px;border-bottom:1px solid var(--line);margin:18px 0 16px}
.tab{background:none;border:none;color:var(--dim);padding:10px 16px;font:inherit;font-weight:550;cursor:pointer;border-bottom:2px solid transparent;margin-bottom:-1px}
.tab:hover{color:var(--txt)}.tab.on{color:var(--txt);border-bottom-color:var(--accent)}
.controls{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
.controls .count{color:var(--dim);font-size:13px;margin-left:auto}
input[type=search],select{background:var(--panel);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:7px 10px;font:inherit;outline:none}
input[type=search]:focus,select:focus{border-color:var(--accent)}
input[type=search]{min-width:200px}
label.chk{display:flex;align-items:center;gap:6px;color:var(--dim);font-size:13px;cursor:pointer;user-select:none}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.scroll{overflow-x:auto}
table{width:100%;border-collapse:collapse}
th,td{padding:9px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}
th{color:var(--dim);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;background:var(--panel2);white-space:nowrap}
th[data-sort]{cursor:pointer;user-select:none}th[data-sort]:hover{color:var(--txt)}
th .arr{color:var(--accent)}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover>td{background:var(--hover)}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.cn{font-weight:600}.star{color:var(--gold);font-size:12px}
td:first-child{white-space:nowrap}
.realm{color:var(--faint);font-size:12px}
.faint{color:var(--faint)}.dim{color:var(--dim)}
.lvl{display:flex;align-items:center;gap:8px;min-width:120px}
.lvl b{font-variant-numeric:tabular-nums;width:22px;text-align:right}
.bar{flex:1;height:6px;background:#262b36;border-radius:3px;overflow:hidden}
.bar>i{display:block;height:100%;background:var(--accent);border-radius:3px}
.bar.cap>i{background:var(--green)}
.pill{display:inline-flex;align-items:baseline;gap:4px;background:var(--panel2);border:1px solid var(--line);border-radius:20px;padding:2px 9px;margin:2px 4px 2px 0;font-size:12px;white-space:nowrap}
.pill b{font-weight:600}.pill .exp{color:var(--faint);font-size:11px}
.pill.maxed{border-color:#1f5136;background:#11261b}.pill.maxed b{color:var(--green)}
.rolesel{padding:4px 8px;font-size:12px;border-radius:20px}
.role{display:inline-block;font-size:11px;font-weight:600;padding:1px 8px;border-radius:20px;border:1px solid}
.r-Main{color:#f5c542;border-color:#5a4a1a}.r-Farmer{color:#4ade80;border-color:#1f5136}.r-Crafter{color:#7cb8ff;border-color:#1f3d63}
.r-Bank{color:#c4a7ff;border-color:#3d2e66}.r-Leveling{color:#fb923c;border-color:#5c3216}.r-Alt{color:#9aa3b5;border-color:#363c4a}
select.rolesel.r-Main,select.rolesel.r-Farmer,select.rolesel.r-Crafter,select.rolesel.r-Bank,select.rolesel.r-Leveling,select.rolesel.r-Alt{border:1px solid}
/* profession matrix */
.matrix td.tc{text-align:center;min-width:84px;padding:7px 8px;cursor:default}
.matrix td.tc.has{cursor:pointer}
.matrix td.tc.sel{background:#232a3a !important;box-shadow:inset 0 0 0 1px var(--accent)}
.matrix th.tc{text-align:center}
.sk{font-variant-numeric:tabular-nums;font-weight:600;font-size:13px}
.sk span{color:var(--faint);font-weight:400}
.mini{height:3px;background:#262b36;border-radius:2px;margin:4px auto 0;width:56px;overflow:hidden}
.mini>i{display:block;height:100%;background:var(--accent)}
.tc.maxed .sk{color:var(--green)}.tc.maxed .mini>i{background:var(--green)}
.rc{font-size:11px;color:var(--faint);margin-top:2px}
.who{font-size:11px;color:var(--dim);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:110px;margin-inline:auto}
.matrix tr.prow{cursor:pointer}
tr.detail>td{background:#12151b !important;padding:14px 18px}
.dwrap{position:sticky;left:18px;width:min(1240px,calc(100vw - 80px))}
.dhead{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:10px}
.dhead h3{margin:0;font-size:14px;font-weight:600}
.recipes{display:flex;flex-wrap:wrap;gap:4px;max-height:280px;overflow:auto}
.rec{font-size:12px;background:var(--panel2);border:1px solid var(--line);border-radius:6px;padding:2px 8px}
.rec.miss{color:var(--faint);border-style:dashed}
.sect{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:12px 0 6px}
.hint{color:var(--faint);font-size:12px;margin-top:8px}
/* classes */
.seg{display:inline-flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
.seg button{background:var(--panel);color:var(--dim);border:none;padding:7px 14px;font:inherit;cursor:pointer}
.seg button.on{background:var(--panel2);color:var(--txt)}
.summary{display:flex;flex-wrap:wrap;gap:8px 18px;margin:0 0 14px;font-size:13px;color:var(--dim)}
.summary b{color:var(--txt);font-weight:600}
.cgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:12px}
.ccard{background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--cc);border-radius:12px;padding:14px 16px}
.ccard h3{margin:0;font-size:15px;color:var(--cc);display:flex;justify-content:space-between;align-items:center}
.ccard .meta{color:var(--dim);font-size:12px;margin:2px 0 10px}
.badge{font-size:11px;font-weight:600;padding:2px 8px;border-radius:20px}
.b-miss{background:#2a1517;color:var(--red)}.b-need{background:#2a2312;color:var(--amber)}.b-done{background:#11261b;color:var(--green)}
.clist{list-style:none;margin:0;padding:0}
.clist li{display:flex;align-items:center;gap:8px;padding:5px 0;border-top:1px solid var(--line);font-size:13px}
.clist li:first-child{border-top:none}
.clist .nm{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.clist .lv{font-variant-numeric:tabular-nums;color:var(--dim);width:24px;text-align:right}
.clist .lv.cap{color:var(--green);font-weight:600}
.more{background:none;border:none;color:var(--accent);font:inherit;font-size:12px;cursor:pointer;padding:6px 0 0}
.empty{color:var(--faint);font-size:13px;padding:6px 0}
.note{color:var(--faint);font-size:12px;margin-top:20px;line-height:1.6}
.trk{background:none;border:none;padding:0 2px;font-size:13px;cursor:pointer;color:var(--faint);line-height:1}
.trk.on{color:var(--gold)}.trk:hover{color:var(--gold)}
input[type=number],input[type=date]{background:var(--panel);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:7px 10px;font:inherit;outline:none;color-scheme:dark}
input[type=number]:focus,input[type=date]:focus{border-color:var(--accent)}
.goal{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:12px 0 4px}
.goal .gh{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}
.goal .gt{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--dim)}
.goal .gv{font-size:22px;font-weight:650;font-variant-numeric:tabular-nums;margin-top:4px}
.goal .gv span{color:var(--dim);font-size:15px;font-weight:500}
.goal .bar{height:10px;margin:12px 0 10px;border-radius:5px}
.goal .bar>i{background:var(--gold);border-radius:5px}
.goal .gd{display:flex;flex-wrap:wrap;gap:6px 22px;font-size:13px;color:var(--dim)}
.goal .gd b{color:var(--txt);font-weight:600}
.goal form{display:flex;flex-wrap:wrap;gap:10px;align-items:flex-end;margin-top:12px}
.goal label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--dim)}
.good{color:var(--green) !important}.warn{color:var(--amber) !important}
.mg{color:var(--gold)}.ms{color:#c9ccd6}.mc{color:#d4894b}
#gamesw{vertical-align:middle;margin-right:6px}
#gamesw button{padding:8px 14px}
.picks{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-bottom:14px}
.pick{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.pick:first-child{border-color:#3b4a8a;background:#171c2b}
.pick .pk{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--dim)}
.pick .pn{font-size:17px;margin-top:4px}.pick .pv{margin-top:8px;font-size:14px}.pick .pv b{font-size:20px}
.pick .pr{margin-top:6px;font-size:12px;min-height:18px}
.psum{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px;margin-bottom:14px}
.pcard{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 14px;font-size:13px}
.pcard .pt{font-weight:600}.pcard .pv2{margin-top:2px}
input.wk{width:18px;height:18px;accent-color:var(--green);cursor:pointer}
.names{columns:4 220px;column-gap:24px;font-size:13px;padding:14px 18px}
.names div{padding:3px 0;break-inside:avoid;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.names div.miss{color:var(--dim)}
.q-Poor{color:#9d9d9d}.q-Common{color:#e6e8ee}.q-Uncommon{color:#1eff00}.q-Rare{color:#3d8bfd}
.catrow{display:grid;grid-template-columns:minmax(120px,200px) 1fr 90px;gap:12px;align-items:center;padding:8px 16px;border-top:1px solid var(--line);font-size:13px}
.catrow:first-child{border-top:none}
.catrow .bar{height:8px}
.panel-h{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:20px 0 8px}
.two{display:grid;grid-template-columns:3fr 2fr;gap:16px}
@media(max-width:900px){.two{grid-template-columns:1fr}}
[hidden]{display:none !important}
@media(max-width:700px){.wrap{padding:18px 16px 40px}th,td{padding:7px 8px}input[type=search]{min-width:0;flex:1}.controls .count{margin-left:0}}
</style></head><body><div class="wrap">

<header>
  <div><h1>Forge&#39;s Ledger</h1><div class="sub" id="syncinfo">Loading…</div></div>
  <div><div class="seg" id="gamesw" hidden><button data-game="retail">Retail</button><button data-game="forever">Forever</button></div>
  <a class="btn" href="/setup">Settings</a> <a class="btn" href="/connect">Connect Battle.net</a> <button class="btn primary" id="syncbtn">Sync now</button></div>
</header>
<div id="alert"></div>
<div class="stats" id="stats"></div>
<div id="goal"></div>

<nav class="tabs">
  <button class="tab" data-tab="roster">Roster</button>
  <button class="tab" data-tab="level">Leveling</button>
  <button class="tab" data-tab="profs">Professions</button>
  <button class="tab" data-tab="reps">Reputations</button>
  <button class="tab" data-tab="weekly">Todo</button>
  <button class="tab" data-tab="classes">Classes</button>
  <button class="tab" data-tab="coll">Collections</button>
</nav>

<section id="tab-roster" hidden>
  <div class="controls">
    <input type="search" id="q" placeholder="Search name or realm">
    <select id="fcls"><option value="">All classes</option></select>
    <select id="frole"><option value="">All roles</option></select>
    <label class="chk"><input type="checkbox" id="fstar"> ★ Tracked only</label>
    <label class="chk"><input type="checkbox" id="flvl"> Level 10+</label>
    <span class="count" id="rcount"></span>
  </div>
  <div class="card scroll"><table>
    <thead><tr>
      <th data-sort="name">Character</th><th data-sort="class">Class</th><th data-sort="level">Level</th><th data-sort="ilvl" class="num">iLvl</th>
      <th>Role</th><th>Professions <span class="faint" style="text-transform:none;letter-spacing:0">(latest tier · hover for all)</span></th>
      <th data-sort="gold" class="num">Gold</th><th data-sort="gold_7d" class="num">7d</th>
    </tr></thead>
    <tbody id="roster"></tbody></table></div>
</section>

<section id="tab-level" hidden>
  <div class="controls">
    <label class="chk"><input type="checkbox" id="lvstar"> ★ Tracked only</label>
    <label class="chk"><input type="checkbox" id="lv10"> Level 10+</label>
    <span class="count" id="lvcount"></span>
  </div>
  <div class="picks" id="lvnext"></div>
  <div class="card scroll"><table id="lvtable"></table></div>
  <div class="hint">Characters tagged <b>Leveling</b> come first, then whoever is closest to max level, then the most rested. Rested XP is the amount when the addon last saw the character; it keeps growing while they rest.</div>
</section>

<section id="tab-reps" hidden>
  <div class="controls">
    <select id="repchar"></select>
    <div class="seg" id="repview"><button data-repview="exp">By expansion</button><button data-repview="close">Closest to next</button></div>
    <label class="chk"><input type="checkbox" id="rephide"> Hide maxed</label>
    <input type="search" id="repq" placeholder="Search factions">
    <span class="count" id="repcount"></span>
  </div>
  <div id="repsum"></div>
  <div id="repbody"></div>
  <div class="hint">Account best shows each faction's highest standing across the characters shown — many reputations are shared by your whole warband. Exalted, a friendship's top rank, or the last Renown level counts as maxed. Blizzard doesn't report whether a paragon reward cache is waiting to be opened, so only paragon progress is shown. Standings refresh once a day.</div>
</section>

<section id="tab-weekly" hidden>
  <div class="controls">
    <div class="seg" id="wscope"><button data-wscope="cap">Tracked at max level</button><button data-wscope="all">All tracked</button></div>
    <span class="count" id="wcount"></span>
  </div>
  <div class="card scroll"><table id="wtable"></table></div>
  <div class="hint">Green items are checked by the addon from what it saw in game since the reset; boxes are for you to tick. Daily ticks clear at the daily reset, weekly ticks on Tuesday (US).</div>
</section>

<section id="tab-profs" hidden>
  <div class="controls">
    <select id="profsel"></select>
    <label class="chk"><input type="checkbox" id="pstar"> ★ Tracked only</label>
    <label class="chk" id="psecwrap"><input type="checkbox" id="psec"> Include Cooking &amp; Fishing</label>
    <span class="count" id="pcount"></span>
  </div>
  <div id="plansum" hidden></div>
  <div id="satcard"></div>
  <div class="card scroll"><table class="matrix" id="matrix"></table></div>
  <div class="hint" id="phint"></div>
</section>

<section id="tab-classes" hidden>
  <div class="controls">
    <div class="seg" id="scope"><button data-scope="all">All characters</button><button data-scope="star">★ Tracked</button></div>
    <select id="crole"><option value="">Any role</option></select>
  </div>
  <div class="summary" id="csummary"></div>
  <div class="cgrid" id="cgrid"></div>
</section>

<section id="tab-coll" hidden>
  <div class="controls">
    <div class="seg" id="cview"><button data-cview="mounts">Mounts</button><button data-cview="pets">Pets</button><button data-cview="ach">Achievements</button></div>
    <input type="search" id="cq" placeholder="Search">
    <div class="seg" id="cown"><button data-cown="have">Collected</button><button data-cown="miss">Missing</button></div>
    <span class="count" id="ccount"></span>
  </div>
  <div class="stats" id="cstats" style="margin-top:4px"></div>
  <div id="cbody"></div>
</section>

<div class="note">Gold comes from the Forge's Ledger addon save file on this PC (re-read on every page load).
Levels, professions and recipes come from the Blizzard API when you sync. Roles, tracked characters, your goal and weekly checkmarks are saved in your Forge&#39;s Ledger data folder.
<span id="appver"></span>Blizzard data older than 30 days is deleted automatically. <a href="/privacy" target="_blank" style="color:inherit">Privacy policy</a>.<br>
Character and game data provided by Blizzard Entertainment. This app is not endorsed by, affiliated with, or connected to Blizzard Entertainment.
World of Warcraft and Blizzard Entertainment are trademarks of Blizzard Entertainment, Inc.</div>
</div>
<script>
const CLASS_COLORS={"Death Knight":"#C41E3A","Demon Hunter":"#A330C9","Druid":"#FF7C0A","Evoker":"#33937F","Hunter":"#AAD372","Mage":"#3FC7EB","Monk":"#00FF98","Paladin":"#F48CBA","Priest":"#FFFFFF","Rogue":"#FFF468","Shaman":"#0070DD","Warlock":"#8788EE","Warrior":"#C69B6D"};
const CLASSES=Object.keys(CLASS_COLORS);
const GATHER=new Set(["Herbalism","Mining","Skinning"]);
let CAP=90;  // max level of the game being shown (Forever: 60) - set from the data
let D=null;
const CAT={};                 // tier id -> recipe catalog, fetched on demand
const openCell=new Map();     // "charKey|profession" -> tier index shown below that row
const moreClasses=new Set();  // class cards expanded past the first 8
const ui=Object.assign({tab:"roster",q:"",cls:"",role:"",star:false,lvl:false,sort:"",dir:1,prof:"",pstar:false,scope:"all",crole:"",cview:"mounts",cown:"have",cq:"",lvstar:true,lv10:false,psec:false,wscope:"cap",game:"retail",repchar:"",repview:"exp",rephide:false,repq:""},readUI());
let COL=null,colLoading=false;  // collections payload, fetched when the tab is first opened

// Open straight to a tab from the address, e.g. localhost:8765/#weekly -
// handy for bookmarks (and how the README screenshots are taken).
(function(){
  const h=location.hash.slice(1),tabs=["roster","level","profs","reps","weekly","classes","coll"];
  const extra={planner:["profs",u=>u.prof="__planner"],achievements:["coll",u=>u.cview="ach"],todo:["weekly",u=>0]};
  if(tabs.includes(h))ui.tab=h;
  else if(extra[h]){ui.tab=extra[h][0];extra[h][1](ui)}
})();
function readDismissed(){try{return localStorage.getItem("dismissedUpdate")}catch(e){return null}}
function readUI(){try{return JSON.parse(localStorage.getItem("forgeUI")||"{}")}catch(e){return {}}}
function saveUI(){try{localStorage.setItem("forgeUI",JSON.stringify(ui))}catch(e){}}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function $(id){return document.getElementById(id)}
// exact whole gold, dropping silver/copper - matches the server's fmt_gold
function fmtG(c){return Math.trunc((c||0)/10000).toLocaleString()+"g"}
// Money as HTML (safe: built from numbers only). Retail shows whole gold;
// WoW Forever - where amounts are far smaller - shows gold, silver and
// copper, colored like the game's money display: 1,234g 56s 78c.
function money(copper){
  const c=Math.trunc(Math.abs(copper||0));
  if(!D||D.game!=="forever")return Math.trunc(c/10000).toLocaleString()+"g";
  const g=Math.floor(c/10000),s=Math.floor(c%10000/100),cp=c%100,parts=[];
  if(g)parts.push('<span class="mg">'+g.toLocaleString()+"g</span>");
  if(s)parts.push('<span class="ms">'+s+"s</span>");
  if(cp||!parts.length)parts.push('<span class="mc">'+cp+"c</span>");
  return parts.join(" ");
}
function signedMoney(copper){return copper>0?"+"+money(copper):copper<0?"−"+money(-copper):"—"}
function cc(cls){return CLASS_COLORS[cls]||"var(--txt)"}
function roleChip(r){return r?'<span class="role r-'+esc(r)+'">'+esc(r)+"</span>":""}
function nameHtml(c){return '<span class="cn" style="color:'+cc(c.class)+'">'+esc(c.name)+'</span> <button class="trk'+(c.tracked?" on":"")+'" data-track="'+esc(c.key)+'" title="'+(c.tracked?"Tracked — click to stop tracking":"Click to track this character")+'">'+(c.tracked?"★":"☆")+"</button>"}
// latest expansion tier the character has actually put points into
function curTier(p){let best=null;for(const t of p.tiers)if(t.skill>0)best=t;return best||p.tiers[p.tiers.length-1]||null}
function ago(ts){const d=(Date.now()/1000-ts)/86400;return d<1?"today":d<2?"yesterday":d<60?Math.floor(d)+"d ago":d<730?Math.floor(d/30)+"mo ago":Math.floor(d/365)+"y ago"}
function isMaxed(t){return t&&t.max>0&&t.skill>=t.max}

async function load(){
  let d;
  try{d=await (await fetch("/api/data?game="+encodeURIComponent(ui.game))).json()}catch(e){$("syncinfo").textContent="Can't reach the dashboard server — is forge_dashboard.py running?";return}
  if(d.error){$("alert").innerHTML='<div class="alert err">'+esc(d.error)+"</div>";return}
  const first=!D;if(D&&D.synced_at!==d.synced_at)COL=null;D=d;CAP=D.cap||90;
  if(!D.forever_available&&ui.game==="forever"){ui.game="retail";return load()}
  $("appver").textContent="Forge's Ledger v"+D.version+" · ";
  if(first)fillStaticOptions();
  header();render();
  if(D.syncing)setTimeout(load,3000);
}

function fillStaticOptions(){
  $("fcls").innerHTML+=CLASSES.map(c=>'<option>'+esc(c)+"</option>").join("");
  const roleOpts=D.roles.map(r=>'<option>'+esc(r)+"</option>").join("");
  $("frole").innerHTML+=roleOpts+'<option value="__none">No role set</option><option value="__gather">Has a gathering profession</option>';
  $("crole").innerHTML+=roleOpts;
  $("q").value=ui.q;$("fcls").value=ui.cls;$("frole").value=ui.role;$("fstar").checked=ui.star;$("flvl").checked=ui.lvl;
  $("pstar").checked=ui.pstar;$("crole").value=ui.crole;$("cq").value=ui.cq;
  $("lvstar").checked=ui.lvstar;$("lv10").checked=ui.lv10;$("psec").checked=ui.psec;$("rephide").checked=ui.rephide;$("repq").value=ui.repq;
}

function header(){
  const si=$("syncinfo");
  $("gamesw").hidden=!D.forever_available;
  document.querySelectorAll("#gamesw button").forEach(b=>b.classList.toggle("on",b.dataset.game===D.game));
  $("syncbtn").hidden=D.game==="forever";
  if(D.game==="forever"){
    si.innerHTML="Forever · "+D.characters.length+" character"+(D.characters.length===1?"":"s")+" · from the Forge&#39;s Ledger addon"+(D.sv_mtime?" · game saved "+agoShort(D.sv_mtime):"");
    let fa="";
    if(D.addon_error)fa+='<div class="alert err">'+esc(D.addon_error)+"</div>";
    if(!D.characters.length)fa+='<div class="alert info">No Forever characters yet. Install the addon in your Forever client (<a href="/setup" style="color:inherit">Settings</a> → Update addon), log into a character, then type <b>/fl sync</b>. Blizzard doesn&#39;t offer Forever character data yet, so everything here comes from the addon.</div>';
    $("alert").innerHTML=fa;
    const t=D.totals;renderGoal();
    $("stats").innerHTML=(t.tracked?stat(t.at_cap+" / "+t.tracked,"tracked characters at "+CAP)+stat(t.levels_remaining.toLocaleString(),"levels to go")
        :stat("—","tracked characters — click ☆ next to a name to track it")+stat("—","levels to go"))+
      stat('<span class="goldv">'+money(t.gold_total)+"</span>","total gold")+stat('<span class="goldv">'+signedMoney(t.gold_7d)+"</span>","gold change, last 7 days");
    return;
  }
  if(D.synced_at){const m=Math.round((Date.now()/1000-D.synced_at)/60);
    const shown=(D.accounts||[]).filter(a=>a.included),acctNote=shown.length&&shown.length<D.accounts.length
      ?' · showing '+shown.map(a=>esc(a.label)).join(", ")+' (<a href="/setup" style="color:inherit">change</a>)':"";
    si.innerHTML=esc("Synced with Blizzard "+(m<1?"just now":m<120?m+" min ago":Math.round(m/60)+" h ago")+" · "+D.characters.length+" character"+(D.characters.length===1?"":"s")+(D.sv_mtime?" · game saved "+agoShort(D.sv_mtime):""))+acctNote;}
  else si.textContent="Never synced — Connect Battle.net, then Sync now.";
  let a="";
  if(new URLSearchParams(location.search).get("ok")){history.replaceState(null,"",location.pathname);if(D.connected)a+='<div class="alert ok">Battle.net connected.</div>';}
  if(!D.connected&&!D.characters.length)a+='<div class="alert err">Not connected to Battle.net — click <b>Connect Battle.net</b> and approve at Blizzard to load your characters.</div>';
  else if(!D.connected)a+='<div class="alert info">Your Battle.net login has expired (Blizzard logins last 24 hours). Character details still update every hour — click <b>Connect Battle.net</b> to also pick up new characters, mounts and pets.</div>';
  if(D.addon_error)a+='<div class="alert err">'+esc(D.addon_error)+" Gold is hidden until it's fixed; everything else still works.</div>";
  if(D.update&&readDismissed()!==D.update.version)a+='<div class="alert ok">Forge&#39;s Ledger <b>v'+esc(D.update.version)+'</b> is available. '+
    '<a href="'+esc(D.update.url)+'" target="_blank" rel="noopener" style="color:inherit"><b>See what&#39;s new and download</b></a> · '+
    '<a href="#" data-dismiss-update="'+esc(D.update.version)+'" style="color:inherit">Not now</a></div>';
  if(D.sync_error)a+='<div class="alert err">Last sync failed: '+esc(D.sync_error)+"</div>";
  if(D.syncing)a+='<div class="alert info">Syncing with Blizzard… the first sync with recipe lists takes a few minutes. This page refreshes on its own.</div>';
  const legacy=D.characters.some(c=>c.professions.some(p=>p.tiers.length===1&&p.tiers[0].id==null&&p.tiers[0].recipes.length===0&&p.tiers[0].name));
  if(legacy&&!D.syncing)a+='<div class="alert info">Profession data is from the old version (one tier per profession, no recipes). Hit <b>Sync now</b> to pull every expansion tier and recipe.</div>';
  $("alert").innerHTML=a;
  $("syncbtn").disabled=!!D.syncing;$("syncbtn").textContent=D.syncing?"Syncing…":"Sync now";
  const t=D.totals;
  renderGoal();
  $("stats").innerHTML=(t.tracked?stat(t.at_cap+" / "+t.tracked,"tracked characters at "+CAP)+stat(t.levels_remaining.toLocaleString(),"levels to go")
      :stat("—","tracked characters — click ☆ next to a name to track it")+stat("—","levels to go"))+
    stat('<span class="goldv">'+money(t.gold_total)+"</span>",bankLine(t))+stat('<span class="goldv">'+signedMoney(t.gold_7d)+"</span>","gold change, last 7 days");
}
function bankLine(t){
  const b=D.warband_bank;
  if(!b)return 'total gold<br><span class="faint">warband bank: open a bank in game to record it</span>';
  return 'total gold<br><span class="faint">'+esc(t.characters_gold_fmt)+" on characters · "+esc(b.fmt)+" in warband bank</span>";
}
function stat(v,l){return '<div class="stat"><div class="v">'+v+'</div><div class="l">'+l+"</div></div>"}

function render(){
  document.querySelectorAll(".tab").forEach(b=>b.classList.toggle("on",b.dataset.tab===ui.tab));
  const avail=D&&D.game==="forever"?["roster","level","weekly","classes"]:["roster","level","profs","reps","weekly","classes","coll"];
  if(!avail.includes(ui.tab))ui.tab="roster";
  document.querySelectorAll(".tab").forEach(b=>b.hidden=!avail.includes(b.dataset.tab));
  ["roster","level","profs","reps","weekly","classes","coll"].forEach(t=>$("tab-"+t).hidden=t!==ui.tab);
  if(!D)return;
  if(ui.tab==="roster")renderRoster();else if(ui.tab==="level")renderLevel();else if(ui.tab==="weekly")renderWeekly();else if(ui.tab==="reps")renderReps();else if(ui.tab==="profs")renderProfs();else if(ui.tab==="classes")renderClasses();else renderCollections();
  saveUI();
}

/* ---------------- roster ---------------- */
function rosterRows(){
  const q=ui.q.trim().toLowerCase();
  const rows=D.characters.filter(c=>
    (!q||c.name.toLowerCase().includes(q)||(c.realm||"").toLowerCase().includes(q))&&
    (!ui.cls||c.class===ui.cls)&&
    (!ui.role||(ui.role==="__gather"?c.professions.some(p=>GATHER.has(p.name)):ui.role==="__none"?!c.role:c.role===ui.role))&&
    (!ui.star||c.tracked)&&(!ui.lvl||c.level>=10));
  if(ui.sort){const k=ui.sort,dir=ui.dir;
    rows.sort((a,b)=>{const x=a[k],y=b[k];return (typeof x==="string"?x.localeCompare(y):(x||0)-(y||0))*dir});}
  return rows;
}
function profPills(c){
  if(!c.professions.length)return '<span class="faint">—</span>';
  return c.professions.map(p=>{
    const t=curTier(p);
    const tip=[esc(p.name)].concat(p.tiers.filter(x=>x.skill>0).map(x=>esc(x.exp)+": "+x.skill+"/"+x.max)).join("&#10;");
    return '<span class="pill'+(isMaxed(t)?" maxed":"")+'" title="'+tip+'">'+esc(p.name)+
      (t?" <b>"+t.skill+'</b><span class="faint">/'+t.max+'</span> <span class="exp">'+esc(t.exp)+"</span>":"")+"</span>";
  }).join("");
}
function renderRoster(){
  const rows=rosterRows();
  document.querySelectorAll("#tab-roster th[data-sort]").forEach(th=>{
    th.querySelector(".arr")?.remove();
    if(th.dataset.sort===ui.sort)th.insertAdjacentHTML("beforeend",' <span class="arr">'+(ui.dir>0?"▲":"▼")+"</span>");
  });
  const roleOpts=r=>'<option value="">—</option>'+D.roles.map(x=>"<option"+(x===r?" selected":"")+">"+esc(x)+"</option>").join("");
  $("roster").innerHTML=rows.map(c=>{
    const pct=Math.min(100,Math.round((c.level||0)/CAP*100)),chg=c.gold_7d||0;
    return "<tr><td>"+nameHtml(c)+'<div class="realm">'+esc(c.realm)+(c.last_login?" · "+ago(c.last_login):"")+"</div></td>"+
      '<td style="color:'+cc(c.class)+'">'+esc(c.class)+"</td>"+
      '<td><div class="lvl"><div class="bar'+(c.level>=CAP?" cap":"")+'"><i style="width:'+pct+'%"></i></div><b>'+(c.level||0)+"</b></div></td>"+
      '<td class="num">'+(c.ilvl?c.ilvl:'<span class="faint">—</span>')+"</td>"+
      '<td><select class="rolesel'+(c.role?" r-"+esc(c.role):"")+'" data-key="'+esc(c.key)+'">'+roleOpts(c.role)+"</select></td>"+
      "<td>"+profPills(c)+"</td>"+
      '<td class="num goldv">'+(c.gold?money(c.gold):'<span class="faint">—</span>')+"</td>"+
      '<td class="num">'+(chg>0?'<span style="color:var(--green)">+'+money(chg)+"</span>":chg<0?'<span style="color:var(--red)">−'+money(-chg)+"</span>":'<span class="faint">—</span>')+"</td></tr>";
  }).join("")||'<tr><td colspan="8" class="empty">No characters match these filters.</td></tr>';
  $("rcount").textContent=rows.length+" of "+D.characters.length+" characters";
}

/* ---------------- professions ---------------- */
function profIndex(){
  const m={};
  D.characters.forEach(c=>{if(ui.pstar&&!c.tracked)return;c.professions.forEach(p=>{(m[p.name]=m[p.name]||[]).push({c,p})})});
  return m;
}
function expCols(tiers){const cols=D.expansions.map(e=>e.short);["Skill","Other"].forEach(x=>{if(tiers.some(t=>t.exp===x))cols.push(x)});return cols}
function expTitle(s){const e=D.expansions.find(x=>x.short===s);return e?e.full:s}
function tierCell(t,extra,attrs){
  if(!t||(!t.skill&&!t.max))return '<td class="tc"><span class="faint">·</span></td>';
  const pct=t.max?Math.min(100,t.skill/t.max*100):0;
  const live=t.live?' title="Read in game '+ago(t.live)+' by Forge&#39;s Ledger: Professions - newer than Blizzard&#39;s last sync"':"";
  return '<td class="tc has'+(isMaxed(t)?" maxed":"")+(extra||"")+'"'+(attrs||"")+live+'><div class="sk">'+t.skill+"<span>/"+t.max+'</span>'+(t.live?' <span class="good" style="font-size:10px">●</span>':"")+'</div><div class="mini"><i style="width:'+pct+'%"></i></div>'+recCount(t)+"</td>";
}
function recCount(t){
  const tot=t.id!=null?D.catalog_totals[String(t.id)]:null;
  if(!t.recipes.length&&!tot)return "";
  return '<div class="rc">'+t.recipes.length+(tot?"/"+tot:"")+" recipes</div>";
}
// A satellite's place on the page: nothing while it doesn't ship with the
// app; a small dismissible card while it isn't installed; a "no data yet"
// note until a character logs in with it.
function satelliteCard(id){
  const s=(D.satellites||{})[id];
  if(!s||!s.bundled)return "";
  let dismissed=false;try{dismissed=localStorage.getItem("satDismiss_"+id)==="1"}catch(e){}
  if(!s.installed)return dismissed?"":'<div class="alert info">Install <b>'+esc(s.title)+'</b> for '+esc(s.pitch)+
    ' — <a href="/setup" style="color:inherit">Settings → Companion addon</a> · <a href="#" data-sat-dismiss="'+esc(id)+'" style="color:inherit">Hide</a></div>';
  if(!s.characters)return '<div class="alert info">'+esc(s.title)+' is installed. Log into a character with it enabled to see its data here.</div>';
  return "";
}
function renderProfs(){
  $("satcard").innerHTML=satelliteCard("professions");
  const idx=profIndex(),names=Object.keys(idx).sort();
  if(ui.prof&&ui.prof!=="__planner"&&!idx[ui.prof])ui.prof="";
  $("plansum").hidden=true;$("psecwrap").hidden=ui.prof!=="__planner";
  $("profsel").innerHTML='<option value="__planner"'+(ui.prof==="__planner"?" selected":"")+'>Gap planner — Midnight</option>'+
    '<option value="">Overview — all professions</option>'+
    names.map(n=>'<option value="'+esc(n)+'"'+(n===ui.prof?" selected":"")+">"+esc(n)+" · "+idx[n].length+" character"+(idx[n].length===1?"":"s")+"</option>").join("");
  if(!names.length){$("matrix").innerHTML='<tbody><tr><td class="empty">No profession data yet — hit Sync now.</td></tr></tbody>';$("pcount").textContent="";$("phint").textContent="";return}
  if(ui.prof==="__planner")return renderPlanner();
  ui.prof?renderProfDetail(ui.prof,idx[ui.prof]):renderProfOverview(idx,names);
}
function renderProfOverview(idx,names){
  const cols=expCols(names.flatMap(n=>idx[n].flatMap(h=>h.p.tiers)));
  let h="<thead><tr><th>Profession</th><th class=num>Chars</th>"+cols.map(s=>'<th class="tc" title="'+esc(expTitle(s))+'">'+esc(s)+"</th>").join("")+"</tr></thead><tbody>";
  names.forEach(n=>{
    h+='<tr class="prow" data-prof="'+esc(n)+'"><td><b>'+esc(n)+'</b></td><td class="num dim">'+idx[n].length+"</td>";
    cols.forEach(s=>{
      // best skill on the account for this expansion, and who has it
      let best=null,who=null;
      idx[n].forEach(({c,p})=>p.tiers.forEach(t=>{if(t.exp===s&&(!best||t.skill>best.skill)){best=t;who=c}}));
      if(!best||!best.skill){h+='<td class="tc"><span class="faint">·</span></td>';return}
      const pct=best.max?Math.min(100,best.skill/best.max*100):0;
      h+='<td class="tc'+(isMaxed(best)?" maxed":"")+'"><div class="sk">'+best.skill+"<span>/"+best.max+'</span></div><div class="mini"><i style="width:'+pct+'%"></i></div><div class="who" style="color:'+cc(who.class)+'">'+esc(who.name)+"</div></td>";
    });
    h+="</tr>";
  });
  $("matrix").innerHTML=h+"</tbody>";
  $("pcount").textContent=names.length+" professions";
  $("phint").textContent="Each cell is the best skill on your account for that expansion, and who has it. Click a profession to see every character.";
}
function renderProfDetail(name,holders){
  const cols=expCols(holders.flatMap(h=>h.p.tiers));
  const score=h=>h.p.tiers.reduce((s,t)=>s+t.skill,0);
  holders=holders.slice().sort((a,b)=>score(b)-score(a)||b.c.level-a.c.level);
  let h="<thead><tr><th>Character</th><th class=num>Lvl</th><th>Role</th>"+cols.map(s=>'<th class="tc" title="'+esc(expTitle(s))+'">'+esc(s)+"</th>").join("")+'<th class="num">Recipes</th></tr></thead><tbody>';
  holders.forEach(({c,p})=>{
    const okey=c.key+"|"+name,sel=openCell.get(okey);
    h+="<tr><td>"+nameHtml(c)+'<div class="realm">'+esc(c.realm)+'</div></td><td class="num">'+c.level+"</td><td>"+roleChip(c.role)+"</td>";
    cols.forEach(s=>{
      const ti=p.tiers.findIndex(t=>t.exp===s);
      const t=ti<0?null:p.tiers[ti];
      h+=tierCell(t,ti===sel?" sel":"",t?' data-k="'+esc(okey)+'" data-ti="'+ti+'"':"");
    });
    h+='<td class="num dim">'+p.tiers.reduce((s,t)=>s+t.recipes.length,0)+"</td></tr>";
    if(sel!=null&&p.tiers[sel])h+='<tr class="detail"><td colspan="'+(cols.length+4)+'"><div class="dwrap">'+recipePanel(c,p.tiers[sel])+"</div></td></tr>";
  });
  $("matrix").innerHTML=h+"</tbody>";
  const maxedNow=holders.filter(({p})=>isMaxed(p.tiers.find(t=>t.exp==="Midnight"))).length;
  $("pcount").textContent=holders.length+" characters · "+maxedNow+" maxed in Midnight";
  $("phint").textContent="Click any skill cell to see the recipes that character knows for that expansion.";
}
function recipePanel(c,t){
  const tot=t.id!=null?D.catalog_totals[String(t.id)]:0;
  const known=t.recipes.slice().sort((a,b)=>a.name.localeCompare(b.name));
  let h='<div class="dhead"><h3><span style="color:'+cc(c.class)+'">'+esc(c.name)+"</span> · "+esc(t.name||t.exp)+
    ' <span class="dim" style="font-weight:400">— '+t.skill+"/"+t.max+" skill · "+known.length+(tot?" of "+tot:"")+" recipes known</span></h3>";
  if(tot&&!CAT[t.id])h+='<button class="btn" data-missing="'+t.id+'">Show missing recipes</button>';
  h+="</div>";
  if(t.id==null)return h+'<div class="empty">No recipe data for this tier yet — hit Sync now.</div>';
  h+=known.length?'<div class="recipes">'+known.map(r=>'<span class="rec">'+esc(r.name)+"</span>").join("")+"</div>":'<div class="empty">No recipes learned in this tier.</div>';
  const cat=CAT[t.id];
  if(cat){
    const have=new Set(known.map(r=>String(r.id)));
    const miss=Object.entries(cat.recipes).filter(([id])=>!have.has(id)).map(([,n])=>n).sort();
    h+='<div class="sect">Missing · '+miss.length+"</div>"+(miss.length?'<div class="recipes">'+miss.map(n=>'<span class="rec miss">'+esc(n)+"</span>").join("")+"</div>":'<div class="empty">Nothing missing — every recipe learned.</div>')+
      '<div class="hint">The full list includes recipes for both factions and some that are no longer obtainable, so 100% is rarely possible.</div>';
  }
  return h;
}

/* ---------------- classes ---------------- */
function renderClasses(){
  document.querySelectorAll("#scope button").forEach(b=>b.classList.toggle("on",b.dataset.scope===ui.scope));
  const pool=D.characters.filter(c=>(ui.scope!=="star"||c.tracked)&&(!ui.crole||c.role===ui.crole));
  const missing=[],needCap=[];
  const cards=(D.classes||CLASSES).map(cls=>{
    const list=pool.filter(c=>c.class===cls).sort((a,b)=>b.level-a.level||a.name.localeCompare(b.name));
    const atCap=list.filter(c=>c.level>=CAP).length;
    let badge;
    if(!list.length){missing.push(cls);badge='<span class="badge b-miss">Missing</span>'}
    else if(!atCap){needCap.push(cls);badge='<span class="badge b-need">No '+CAP+" yet</span>"}
    else badge='<span class="badge b-done">'+atCap+" at "+CAP+"</span>";
    const shown=moreClasses.has(cls)?list:list.slice(0,8);
    return '<div class="ccard" style="--cc:'+cc(cls)+'"><h3>'+esc(cls)+badge+'</h3><div class="meta">'+
      (list.length?list.length+" character"+(list.length===1?"":"s")+" · highest "+list[0].level:"None yet")+"</div>"+
      (list.length?'<ul class="clist">'+shown.map(c=>'<li><span class="nm">'+esc(c.name)+(c.tracked?' <span class="star">★</span>':"")+' <span class="realm">'+esc(c.realm)+"</span></span>"+roleChip(c.role)+'<span class="lv'+(c.level>=CAP?" cap":"")+'">'+c.level+"</span></li>").join("")+"</ul>":"")+
      (list.length>8?'<button class="more" data-more="'+esc(cls)+'">'+(moreClasses.has(cls)?"Show less":"Show all "+list.length)+"</button>":"")+"</div>";
  });
  const scopeTxt=ui.scope==="star"?"among tracked characters":"on your account";
  $("csummary").innerHTML=
    "<span>Missing "+scopeTxt+": <b>"+(missing.length?missing.map(esc).join(", "):"none")+"</b></span>"+
    "<span>No level "+CAP+" yet: <b>"+(needCap.length?needCap.map(esc).join(", "):"none")+"</b></span>";
  $("cgrid").innerHTML=cards.join("");
}

/* ---------------- collections ---------------- */
async function renderCollections(){
  document.querySelectorAll("#cview button").forEach(b=>b.classList.toggle("on",b.dataset.cview===ui.cview));
  document.querySelectorAll("#cown button").forEach(b=>b.classList.toggle("on",b.dataset.cown===ui.cown));
  $("cown").hidden=ui.cview==="ach";
  if(!COL){
    $("cstats").innerHTML="";$("cbody").innerHTML='<div class="empty">Loading…</div>';
    if(!colLoading){colLoading=true;try{COL=await (await fetch("/api/collections")).json()}catch(e){COL={collections:{},game:{}}}colLoading=false;if(ui.tab==="coll")renderCollections()}
    return;
  }
  const col=COL.collections||{},game=COL.game||{},q=ui.cq.trim().toLowerCase();
  const match=n=>!q||String(n||"").toLowerCase().includes(q);
  const pct=(a,b)=>b?Math.round(a/b*100)+"%":"";
  const nothing='<div class="faint">Nothing matches.</div>';
  if(!col.mounts&&!col.pets&&!col.achievements){$("cstats").innerHTML="";$("cbody").innerHTML='<div class="card"><div class="empty" style="padding:16px">No collection data yet — hit <b>Sync now</b>.</div></div>';$("ccount").textContent="";return}
  if(ui.cview==="mounts"){
    const have=col.mounts||[],all=game.mounts||{},own=new Set(have.map(m=>String(m.id)));
    const total=Object.keys(all).length;
    $("cstats").innerHTML=stat(have.length.toLocaleString(),"mounts collected")+stat(total?total.toLocaleString():"—","mounts in game data")+
      stat(pct(have.length,total)||"—","of game data")+stat(have.filter(m=>m.fav).length,"favorites");
    const list=ui.cown==="have"
      ?have.filter(m=>match(m.name)).map(m=>"<div>"+(m.fav?'<span class="star">★</span> ':"")+esc(m.name)+"</div>")
      :Object.entries(all).filter(([id,n])=>!own.has(id)&&match(n)).sort((a,b)=>a[1].localeCompare(b[1])).map(([,n])=>'<div class="miss">'+esc(n)+"</div>");
    $("ccount").textContent=list.length+" shown";
    $("cbody").innerHTML='<div class="card"><div class="names">'+(list.join("")||nothing)+"</div></div>"+
      (ui.cown==="miss"?'<div class="hint">Blizzard’s list includes removed, faction-locked and unobtainable mounts, so you can’t collect all of them.</div>':"");
  }else if(ui.cview==="pets"){
    const pets=col.pets||[],all=game.pets||{},by={};
    pets.forEach(p=>{const k=String(p.species_id);(by[k]=by[k]||{name:p.name,list:[]}).list.push(p)});
    const total=Object.keys(all).length,uniq=Object.keys(by).length;
    const QO={Poor:0,Common:1,Uncommon:2,Rare:3};
    $("cstats").innerHTML=stat(pets.length.toLocaleString(),"pets collected")+
      stat(uniq+(total?' <span class="dim" style="font-size:14px">/ '+total.toLocaleString()+"</span>":""),"unique species")+
      stat(pets.filter(p=>p.level>=25).length,"at level 25")+stat(pets.filter(p=>p.quality==="Rare").length,"rare quality");
    if(ui.cown==="have"){
      const rows=Object.values(by).filter(s=>match(s.name)||s.list.some(p=>match(p.nick))).sort((a,b)=>a.name.localeCompare(b.name));
      $("ccount").textContent=rows.length+" species shown";
      $("cbody").innerHTML='<div class="card scroll"><table><thead><tr><th>Species</th><th class="num">Owned</th><th class="num">Best level</th><th>Best quality</th><th>Nicknames</th></tr></thead><tbody>'+
        (rows.map(s=>{
          const bl=Math.max(...s.list.map(p=>p.level));
          const bq=s.list.reduce((a,p)=>((QO[p.quality]??-1)>(QO[a]??-1)?p.quality:a),"");
          const nicks=s.list.map(p=>p.nick).filter(Boolean);
          return "<tr><td>"+(s.list.some(p=>p.fav)?'<span class="star">★</span> ':"")+esc(s.name)+'</td><td class="num">'+s.list.length+
            '</td><td class="num"'+(bl>=25?' style="color:var(--green)"':"")+">"+bl+'</td><td class="q-'+esc(bq)+'">'+esc(bq)+'</td><td class="dim">'+esc(nicks.join(", "))+"</td></tr>";
        }).join("")||'<tr><td colspan="5" class="empty">Nothing matches.</td></tr>')+
        "</tbody></table></div>";
    }else{
      const list=Object.entries(all).filter(([id,n])=>!by[id]&&match(n)).sort((a,b)=>a[1].localeCompare(b[1])).map(([,n])=>'<div class="miss">'+esc(n)+"</div>");
      $("ccount").textContent=list.length+" shown";
      $("cbody").innerHTML='<div class="card"><div class="names">'+(list.join("")||nothing)+
        '</div></div><div class="hint">Blizzard’s species list includes NPC-only battle pets that can’t be collected, so the real gap is smaller.</div>';
    }
  }else{
    const a=col.achievements;
    if(!a){$("cstats").innerHTML="";$("cbody").innerHTML='<div class="card"><div class="empty" style="padding:16px">No achievement data yet — hit <b>Sync now</b>.</div></div>';$("ccount").textContent="";return}
    const tot=game.achievement_total||0,fac=(a.faction||"").toLowerCase()==="horde"?"horde":"alliance";
    $("cstats").innerHTML=stat(a.points.toLocaleString(),"achievement points")+
      stat(a.completed.toLocaleString()+(tot?' <span class="dim" style="font-size:14px">/ '+tot.toLocaleString()+"</span>":""),"achievements completed")+
      stat('<span style="font-size:18px">'+esc(a.character)+"</span>","read from (most points)");
    // totals are per faction, since some achievements only exist for one side
    const cats=(game.achievement_categories||[]).map(c=>{const pr=a.categories[String(c.id)]||{quantity:0};return {name:c.name,have:pr.quantity,total:c[fac]||0}}).filter(c=>match(c.name));
    const recent=a.recent.filter(r=>match(r.name));
    $("ccount").textContent="";
    $("cbody").innerHTML='<div class="two"><div><div class="panel-h">Progress by category</div><div class="card">'+
      (cats.map(c=>{const p=c.total?Math.min(100,c.have/c.total*100):0;
        return '<div class="catrow"><div>'+esc(c.name)+'</div><div class="bar'+(p>=100?" cap":"")+'"><i style="width:'+p+'%"></i></div><div class="num dim">'+c.have+(c.total?" / "+c.total:"")+"</div></div>"}).join("")
        ||'<div class="empty" style="padding:12px 16px">No categories match.</div>')+
      '</div></div><div><div class="panel-h">Recently completed</div><div class="card">'+
      (recent.map(r=>'<div class="catrow" style="grid-template-columns:1fr auto"><div>'+esc(r.name)+'</div><div class="dim" style="font-size:12px">'+new Date(r.at*1000).toLocaleDateString()+"</div></div>").join("")
        ||'<div class="empty" style="padding:12px 16px">Nothing matches.</div>')+
      "</div></div></div>";
  }
}

/* ---------------- tracking + gold goal ---------------- */
async function postJSON(url,obj){
  const r=await fetch(url,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(obj)});
  const j=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(j.error||"Request failed");
  return j;
}
async function setTracked(key,on){
  try{await postJSON("/api/track",{key,on})}catch(e){alert("Couldn't save: "+e.message);return}
  load();
}
let editingGoal=false;
function fmtDate(iso){return new Date(iso+"T00:00:00").toLocaleDateString(undefined,{month:"short",day:"numeric",year:"numeric"})}
// whole gold only, dropping silver/copper - matches the warband total card
function gold(n){return Math.trunc(n).toLocaleString()+"g"}
function renderGoal(){
  const g=D.gold_goal,el=$("goal");
  if(editingGoal){
    // the page auto-refreshes when the game saves; don't wipe a half-typed goal
    if($("goalform"))return;
    el.innerHTML='<div class="goal"><div class="gt">'+(g?"Edit gold goal":"Set a gold goal")+'</div>'+
      '<form id="goalform"><label>Target (gold)<input type="number" id="gamount" min="1" step="1" required value="'+(g?g.amount:"")+'" placeholder="e.g. 1000000"></label>'+
      '<label>Deadline (optional)<input type="date" id="gdate" value="'+(g&&g.deadline?esc(g.deadline):"")+'"></label>'+
      '<button class="btn primary" type="submit">Save</button><button class="btn" type="button" data-goal="cancel">Cancel</button>'+
      (g?'<button class="btn" type="button" data-goal="clear">Remove goal</button>':"")+"</form></div>";
    $("goalform").addEventListener("submit",async e=>{
      e.preventDefault();
      try{await postJSON("/api/goal",{amount:parseInt($("gamount").value,10),deadline:$("gdate").value||null,game:D.game})}
      catch(err){alert(err.message);return}
      editingGoal=false;load();
    });
    $("gamount").focus();
    return;
  }
  if(!g){
    el.innerHTML='<div class="goal"><div class="gh"><div><div class="gt">Gold goal</div><div class="dim" style="margin-top:4px">Set a target to track your progress toward it.</div></div>'+
      '<button class="btn" data-goal="edit">Set goal</button></div></div>';
    return;
  }
  const done=g.remaining<=0;
  let bits=[];
  if(done)bits.push('<b class="good">Goal reached!</b>');
  else bits.push("<b>"+money(g.remaining)+"</b> to go");
  if(g.deadline){
    if(g.days_left>0&&!done)bits.push("by <b>"+fmtDate(g.deadline)+"</b> · "+g.days_left+" day"+(g.days_left===1?"":"s")+" left · need <b>"+money(g.needed_per_day)+"</b>/day");
    else if(!done)bits.push('<span class="warn">Deadline ('+fmtDate(g.deadline)+") has passed</span>");
  }
  if(!done){
    if(g.pace_per_day==null)bits.push("Pace: not enough history yet — check back tomorrow");
    else{
      const pace=g.pace_per_day;
      let p="Your pace: <b"+(pace>0?' class="good"':pace<0?' class="warn"':"")+">"+signedMoney(pace)+"</b>/day";
      if(g.eta){
        const late=g.deadline&&g.eta>g.deadline;
        p+=" → reach it <b"+(late?' class="warn"':' class="good"')+">"+fmtDate(g.eta)+"</b>"+(g.deadline?(late?" (behind)":" (on track)"):"");
      }else if(pace<=0)p+=' <span class="warn">— not growing right now</span>';
      bits.push(p);
    }
  }
  el.innerHTML='<div class="goal"><div class="gh"><div><div class="gt">Gold goal</div>'+
    '<div class="gv"><span class="goldv">'+money(g.current)+"</span> <span>of "+money(g.amount*10000)+" · "+g.pct.toFixed(g.pct<10?1:0)+"%</span></div></div>"+
    '<button class="btn" data-goal="edit">Edit</button></div>'+
    '<div class="bar"><i style="width:'+Math.min(100,g.pct)+'%"></i></div><div class="gd">'+bits.map(b=>"<span>"+b+"</span>").join("")+"</div>"+
    '<div class="hint">Counts gold on characters the addon has recorded'+(D.game==="forever"?"":", plus your warband bank")+'. Log into an alt once to include it.</div></div>';
}
async function goalAction(a){
  if(a==="edit"){editingGoal=true;renderGoal()}
  else if(a==="cancel"){editingGoal=false;renderGoal()}
  else if(a==="clear"){
    if(!confirm("Remove your gold goal?"))return;
    try{await postJSON("/api/goal",{amount:null,game:D.game})}catch(e){alert(e.message);return}
    editingGoal=false;load();
  }
}

/* ---------------- leveling: who do I play tonight ---------------- */
// Ranking: characters tagged "Leveling" first, then fewest levels to go,
// then most rested. Real numbers only - no time estimates.
function levelRows(){
  return D.characters.filter(c=>(c.level||0)>0&&c.level<CAP&&(!ui.lvstar||c.tracked)&&(!ui.lv10||c.level>=10))
    .sort((a,b)=>((b.role==="Leveling")-(a.role==="Leveling"))||((CAP-a.level)-(CAP-b.level))||
      ((b.rested?b.rested.pct:0)-(a.rested?a.rested.pct:0))||a.name.localeCompare(b.name));
}
function restedCell(c){
  if(!c.rested)return '<span class="faint" title="Update the addon to v2.1 and log into this character to record rested XP">—</span>';
  if(!c.rested.pct)return '<span class="faint">not rested</span>';
  return '<b class="good">'+c.rested.pct+'%</b> <span class="faint">of a level · '+ago(c.rested.at)+"</span>";
}
function renderLevel(){
  const rows=levelRows(),toGo=rows.reduce((s,c)=>s+(CAP-c.level),0);
  $("lvcount").textContent=rows.length+" character"+(rows.length===1?"":"s")+" below "+CAP+" · "+toGo.toLocaleString()+" levels to go";
  if(!rows.length){
    const none=ui.lvstar&&!D.characters.some(c=>c.tracked);
    $("lvnext").innerHTML="";
    $("lvtable").innerHTML='<tbody><tr><td class="empty">'+(none
      ?'You aren&#39;t tracking any characters yet. Star (☆) the ones you&#39;re leveling on the Roster tab, or turn off "Tracked only".'
      :'Nobody to level here — everyone is '+CAP+'.'+(ui.lvstar?' Turn off "Tracked only" to see all characters.':''))+"</td></tr></tbody>";
    return}
  $("lvnext").innerHTML=rows.slice(0,3).map((c,i)=>'<div class="pick"><div class="pk">'+(i?"Then":"Up next")+'</div><div class="pn">'+nameHtml(c)+'</div>'+
    '<div class="realm">'+esc(c.realm)+" · "+esc(c.class)+'</div><div class="pv"><b>'+(CAP-c.level)+'</b> level'+(CAP-c.level===1?"":"s")+" to go <span class=\"dim\">(level "+c.level+")</span></div>"+
    '<div class="pr">'+(c.rested&&c.rested.pct?'<span class="good">'+c.rested.pct+"% rested</span>":"")+(c.role?" "+roleChip(c.role):"")+"</div></div>").join("");
  $("lvtable").innerHTML="<thead><tr><th class=num>#</th><th>Character</th><th>Level</th><th class=num>To go</th><th>Rested</th><th>Role</th><th>Last played</th></tr></thead><tbody>"+
    rows.map((c,i)=>{const pct=Math.round(c.level/CAP*100);
      return '<tr><td class="num dim">'+(i+1)+"</td><td>"+nameHtml(c)+'<div class="realm">'+esc(c.realm)+'</div></td><td><div class="lvl"><div class="bar"><i style="width:'+pct+'%"></i></div><b>'+c.level+'</b></div></td>'+
        '<td class="num"><b>'+(CAP-c.level)+"</b></td><td>"+restedCell(c)+"</td><td>"+roleChip(c.role)+'</td><td class="dim">'+(c.last_login?ago(c.last_login):"—")+"</td></tr>"}).join("")+"</tbody>";
}

/* ---------------- profession gap planner (Midnight) ---------------- */
const SECONDARY=new Set(["Cooking","Fishing"]);
function plannerPairs(){
  // Midnight max per profession, learned from any character that has the tier,
  // so characters who haven't started Midnight yet still get a real gap
  const mid={};
  D.characters.forEach(c=>c.professions.forEach(p=>p.tiers.forEach(t=>{if(t.exp==="Midnight"&&t.max)mid[p.name]=Math.max(mid[p.name]||0,t.max)})));
  const pairs=[];
  D.characters.forEach(c=>{
    if(ui.pstar&&!c.tracked)return;
    c.professions.forEach(p=>{
      if(p.name==="Archaeology"||(!ui.psec&&SECONDARY.has(p.name)))return;
      const t=p.tiers.find(t=>t.exp==="Midnight"),max=(t&&t.max)||mid[p.name]||0,skill=t?t.skill:0;
      pairs.push({c,p:p.name,skill,max,gap:max?Math.max(0,max-skill):null,started:skill>0});
    });
  });
  return pairs;
}
function renderPlanner(){
  const all=plannerPairs(),open=all.filter(x=>x.gap!==0);
  const maxed=all.length-open.length,points=open.reduce((s,x)=>s+(x.gap||0),0);
  // Crafter-tagged characters first, then pairs already started (closest to
  // done first), then not-started ones
  open.sort((a,b)=>((b.c.role==="Crafter")-(a.c.role==="Crafter"))||(b.started-a.started)||((a.gap??1e9)-(b.gap??1e9))||a.c.name.localeCompare(b.c.name));
  const by={};all.forEach(x=>{const e=by[x.p]=by[x.p]||{n:0,maxed:0,gap:0};e.n++;if(x.gap===0)e.maxed++;else e.gap+=x.gap||0});
  $("plansum").hidden=false;
  $("plansum").innerHTML='<div class="psum">'+Object.keys(by).sort((a,b)=>by[b].gap-by[a].gap).map(n=>{const e=by[n];
    return '<div class="pcard"><div class="pt">'+esc(n)+'</div><div class="pv2">'+(e.gap?"<b>"+e.gap.toLocaleString()+"</b> points to go":'<b class="good">All maxed</b>')+
      '</div><div class="faint">'+e.maxed+" of "+e.n+" maxed</div></div>"}).join("")+"</div>";
  $("pcount").textContent=maxed+" of "+all.length+" maxed in Midnight · "+points.toLocaleString()+" skill points to go";
  $("matrix").innerHTML=open.length?"<thead><tr><th>Character</th><th>Role</th><th>Profession</th><th>Midnight skill</th><th class=num>Gap</th></tr></thead><tbody>"+
    open.map(x=>{const pct=x.max?Math.min(100,x.skill/x.max*100):0;
      return "<tr><td>"+nameHtml(x.c)+'<div class="realm">'+esc(x.c.realm)+"</div></td><td>"+roleChip(x.c.role)+"</td><td><b>"+esc(x.p)+"</b></td>"+
        '<td><div class="lvl"><div class="bar"><i style="width:'+pct+'%"></i></div><span class="sk">'+x.skill+"<span>/"+(x.max||"?")+"</span></span></div></td>"+
        '<td class="num">'+(x.gap==null?'<span class="faint">not started</span>':x.started?"<b>"+x.gap+"</b>":'<span class="dim">'+x.gap+" · not started</span>")+"</td></tr>"}).join("")+"</tbody>"
    :'<tbody><tr><td class="empty good">Every profession on these characters is maxed for Midnight.</td></tr></tbody>';
  $("phint").textContent="Crafter-tagged characters are listed first, then the closest to max. Uses your last sync — no extra Blizzard calls.";
}

/* ---------------- weekly checklist ---------------- */
function resetText(ts){
  const s=ts-Date.now()/1000,d=Math.floor(s/86400),h=Math.floor(s%86400/3600);
  return (d?d+"d ":"")+h+"h · "+new Date(ts*1000).toLocaleString(undefined,{weekday:"short",hour:"numeric",minute:"2-digit"});
}
// Recipes that share one cooldown (e.g. all Mote transmutes) are used and
// ready together, so they're shown as one chip: same profession and ready
// within a minute of each other = same cooldown.
function cooldownGroups(list){
  const groups=[];
  [...list].sort((a,b)=>a.ready_at-b.ready_at).forEach(cd=>{
    const g=groups.find(g=>g.profession===cd.profession&&Math.abs(g.ready_at-cd.ready_at)<=60);
    g?g.names.push(cd.name):groups.push({profession:cd.profession,ready_at:cd.ready_at,names:[cd.name]});
  });
  return groups;
}
// "Transmute: Mote of Light" + "Transmute: Mote of Wild Magic" -> "Transmute: Mote of …"
function sharedLabel(names){
  if(names.length===1)return names[0];
  let pre=names.reduce((p,n)=>{let i=0;while(i<p.length&&p[i]===n[i])i++;return p.slice(0,i)});
  pre=pre.slice(0,pre.lastIndexOf(" ")+1).replace(/[\s:,-]+$/,"");
  return pre.length>=6?pre+" … ("+names.length+")":names[0]+" +"+(names.length-1)+" more";
}
function cooldownCell(c){
  if(!c.cooldowns||!c.cooldowns.length)return '<span class="faint" title="Update the addon to v2.2, then open your profession window in game after using a cooldown">—</span>';
  const now=Date.now()/1000;
  return cooldownGroups(c.cooldowns).map(g=>{const used=g.ready_at>now;
    const tip=g.profession+(g.names.length>1?" — these share one cooldown:&#10;"+g.names.map(esc).join("&#10;"):"");
    return '<span class="pill'+(used?" maxed":"")+'" title="'+tip+'">'+(used?"✓ ":"")+esc(sharedLabel(g.names))+
      ' <span class="exp">'+(used?"ready in "+resetText(g.ready_at).split(" · ")[0]:"ready")+"</span></span>"}).join("");
}
function renderWeekly(){
  // the Todo tab (its internal id stays "weekly" so old bookmarks still work)
  document.querySelectorAll("#wscope button").forEach(b=>b.classList.toggle("on",b.dataset.wscope===ui.wscope));
  const T=D.todo,cat=T.catalog,periods=["daily","weekly"].filter(p=>(cat[p]||[]).length);
  const rows=D.characters.filter(c=>c.tracked&&(ui.wscope==="all"||c.level>=CAP))
    .sort((a,b)=>b.level-a.level||a.name.localeCompare(b.name));
  let done=0,total=0;
  const ticked=(p,c,id)=>!!((T.checks[p]||{})[c.key]||{})[id];
  const box=(p,c,id,label,hint)=>'<input type="checkbox" class="wk" data-key="'+esc(c.key)+'" data-item="'+id+'"'+(ticked(p,c,id)?" checked":"")+
    ' aria-label="'+esc(label)+" — "+esc(c.name)+'"'+(hint?' title="'+esc(hint)+'"':"")+">";
  function cell(p,c,it){
    const auto=(c.todo||{})[it.id];
    if(it.id==="cooldowns"){
      if(!c.cooldowns||!c.cooldowns.length)return '<td><span class="faint" title="No profession cooldowns recorded for this character">—</span></td>';
      total++;if(auto&&auto.state==="done")done++;
      return "<td>"+cooldownCell(c)+"</td>";
    }
    if(it.kind==="event"){
      if(!T.timewalking)return '<td class="tc"><span class="faint" title="No Timewalking event today (from the in-game calendar)">—</span></td>';
      total++;if(ticked(p,c,it.id))done++;
      return '<td class="tc">'+box(p,c,it.id,it.label)+"</td>";
    }
    if(auto&&it.kind==="auto"){
      // answered by the addon; a manual tick still counts as done
      const ok=auto.state==="done"||ticked(p,c,it.id);
      total++;if(ok)done++;
      return '<td><span class="pill'+(ok?" maxed":"")+'">'+(ok?"✓ ":"")+'<span class="exp" style="color:inherit">'+esc(auto.detail)+"</span></span></td>";
    }
    // manual item, or nothing seen by the addon since the reset
    total++;if(ticked(p,c,it.id))done++;
    return '<td class="tc">'+box(p,c,it.id,it.label,it.kind==="auto"
      ?(c.has_addon?"The addon hasn't seen this since the reset - log in with addon v2.4, or tick it yourself":"No addon data for this character - tick it yourself")
      :"")+"</td>";
  }
  const head1="<tr><th></th>"+periods.map(p=>'<th class="tc" colspan="'+cat[p].length+'" style="border-left:1px solid var(--line)">'+(p==="daily"?"Daily":"Weekly")+"</th>").join("")+"</tr>";
  const head2="<tr><th>Character</th>"+periods.map(p=>cat[p].map((it,i)=>'<th class="tc"'+(i?"":' style="border-left:1px solid var(--line)"')+">"+esc(it.label)+"</th>").join("")).join("")+"</tr>";
  $("wtable").innerHTML=rows.length?"<thead>"+head1+head2+"</thead><tbody>"+
    rows.map(c=>"<tr><td>"+nameHtml(c)+'<div class="realm">'+esc(c.realm)+" · "+c.level+(c.has_addon?"":" · manual only")+"</div></td>"+
      periods.map(p=>cat[p].map(it=>cell(p,c,it)).join("")).join("")+"</tr>").join("")+"</tbody>"
    :'<tbody><tr><td class="empty">No tracked characters'+(ui.wscope==="all"?"":" at "+CAP)+' yet — star (☆) characters on the Roster tab.</td></tr></tbody>';
  const daily=periods.includes("daily")?"daily reset in "+resetText(T.next_daily).split(" · ")[0]+" · ":"";
  $("wcount").textContent=done+" of "+total+" done · "+daily+"weekly reset in "+resetText(T.next_weekly);
}
async function setWeekly(key,item,done){
  try{await postJSON("/api/todo",{key,item,done})}catch(e){alert("Couldn't save: "+e.message);load();return}
  const p=(D.todo.catalog.daily||[]).some(i=>i.id===item)?"daily":"weekly";
  const ck=(D.todo.checks[p]=D.todo.checks[p]||{})[key]=(D.todo.checks[p]||{})[key]||{};
  if(done)ck[item]=true;else delete ck[item];
  renderWeekly();
}

/* ---------------- reputations ---------------- */
const REPCHAR={};  // one character's standings, fetched when picked
async function renderReps(){
  document.querySelectorAll("#repview button").forEach(b=>b.classList.toggle("on",b.dataset.repview===ui.repview));
  const R=D.reps||{rows:[],characters:[],order:[]};
  const chars=[...R.characters].sort((a,b)=>(b.tracked-a.tracked)||(b.level-a.level)||a.name.localeCompare(b.name));
  if(ui.repchar&&!chars.some(c=>c.key===ui.repchar))ui.repchar="";
  $("repchar").innerHTML='<option value="">Account best (all characters shown)</option>'+
    chars.map(c=>'<option value="'+esc(c.key)+'"'+(c.key===ui.repchar?" selected":"")+">"+(c.tracked?"★ ":"")+esc(c.name)+" — "+esc(c.realm)+" · "+c.level+"</option>").join("");
  let rows=R.rows;
  if(ui.repchar){
    if(!REPCHAR[ui.repchar]){
      $("repbody").innerHTML='<div class="empty">Loading…</div>';
      try{REPCHAR[ui.repchar]=(await (await fetch("/api/reps?char="+encodeURIComponent(ui.repchar))).json()).rows}catch(e){REPCHAR[ui.repchar]=[]}
      if(ui.tab==="reps")renderReps();
      return;
    }
    rows=REPCHAR[ui.repchar];
  }
  if(!rows.length){
    $("repsum").innerHTML="";$("repcount").textContent="";
    $("repbody").innerHTML='<div class="card"><div class="empty" style="padding:16px">No reputation data yet. Reputations are fetched once a day — hit <b>Sync now</b>, and they appear within a few minutes.</div></div>';
    return;
  }
  const order=R.order.length?R.order:[...new Set(rows.map(r=>r.expansion))];
  // the summary always counts everything, so filters don't change the score
  const tally={};rows.forEach(r=>{const t=tally[r.expansion]=tally[r.expansion]||{n:0,maxed:0};t.n++;if(r.maxed)t.maxed++});
  $("repsum").innerHTML='<div class="psum">'+order.filter(e=>tally[e]).map(e=>'<div class="pcard"><div class="pt">'+esc(e)+'</div><div class="pv2">'+
    (tally[e].maxed===tally[e].n?'<b class="good">All maxed</b>':"<b>"+tally[e].maxed+"</b> of "+tally[e].n+" maxed")+"</div></div>").join("")+"</div>";
  const q=ui.repq.trim().toLowerCase();
  const shown=rows.filter(r=>(!ui.rephide||!r.maxed)&&(!q||r.name.toLowerCase().includes(q)));
  const maxedAll=rows.filter(r=>r.maxed).length;
  $("repcount").textContent=maxedAll+" of "+rows.length+" maxed"+(shown.length<rows.length?" · showing "+shown.length:"");
  const who=!ui.repchar;
  const line=(r,withExp)=>{
    const prog=r.maxed?'<span class="good">Maxed</span>':
      '<div class="lvl" style="min-width:160px"><div class="bar"><i style="width:'+r.pct+'%"></i></div><span class="dim" style="font-size:12px;white-space:nowrap">'+
      (r.max?r.value.toLocaleString()+" / "+r.max.toLocaleString():"")+"</span></div>";
    const para=r.paragon?'<div class="lvl" style="min-width:150px" title="Paragon progress toward the next reward cache"><div class="bar"><i style="width:'+
      Math.min(100,Math.floor(r.paragon.value*1000/r.paragon.max)/10)+'%;background:var(--gold)"></i></div><span class="dim" style="font-size:12px;white-space:nowrap">'+
      r.paragon.value.toLocaleString()+" / "+r.paragon.max.toLocaleString()+"</span></div>":'<span class="faint">—</span>';
    return "<tr><td><b>"+esc(r.name)+"</b></td>"+(withExp?'<td class="dim">'+esc(r.expansion)+"</td>":"")+
      "<td"+(r.maxed?' class="good"':"")+">"+esc(r.standing)+"</td><td>"+prog+"</td><td>"+para+"</td>"+
      (who?'<td class="dim">'+esc(r.who||"")+"</td>":"")+"</tr>";
  };
  const head=withExp=>"<thead><tr><th>Faction</th>"+(withExp?"<th>Expansion</th>":"")+"<th>Standing</th><th>Progress to next</th><th>Paragon</th>"+(who?"<th>Best on</th>":"")+"</tr></thead>";
  if(ui.repview==="close"){
    const list=shown.filter(r=>!r.maxed&&r.max).sort((a,b)=>b.pct-a.pct||a.name.localeCompare(b.name));
    $("repbody").innerHTML='<div class="card scroll"><table>'+head(true)+"<tbody>"+(list.map(r=>line(r,true)).join("")||'<tr><td colspan="6" class="empty">Nothing left to raise here.</td></tr>')+"</tbody></table></div>";
    return;
  }
  $("repbody").innerHTML=order.filter(e=>shown.some(r=>r.expansion===e)).map(e=>{
    const list=shown.filter(r=>r.expansion===e).sort((a,b)=>(a.maxed-b.maxed)||(b.pct-a.pct)||a.name.localeCompare(b.name));
    return '<div class="panel-h">'+esc(e)+" · "+tally[e].maxed+" of "+tally[e].n+' maxed</div><div class="card scroll"><table>'+head(false)+"<tbody>"+list.map(r=>line(r,false)).join("")+"</tbody></table></div>";
  }).join("")||'<div class="card"><div class="empty" style="padding:16px">Nothing matches.</div></div>';
}

/* ---------------- events ---------------- */
async function setRole(key,role){
  const r=await fetch("/api/role",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({key,role})});
  if(!r.ok){alert("Couldn't save that role.");return}
  D.characters.forEach(c=>{if(c.key===key)c.role=role});
  render();
}
document.addEventListener("click",async e=>{
  const el=e.target.closest("[data-tab],[data-sort],[data-prof],td.tc[data-k],[data-missing],[data-more],[data-scope],[data-cview],[data-cown],[data-track],[data-goal],[data-wscope],[data-dismiss-update],[data-game],[data-sat-dismiss],[data-repview]");
  if(!el)return;
  if(el.dataset.repview){ui.repview=el.dataset.repview;render()}
  else if(el.dataset.satDismiss){e.preventDefault();try{localStorage.setItem("satDismiss_"+el.dataset.satDismiss,"1")}catch(err){}render()}
  else if(el.dataset.game){if(ui.game!==el.dataset.game){ui.game=el.dataset.game;COL=null;saveUI();load()}}
  else if(el.dataset.dismissUpdate){e.preventDefault();try{localStorage.setItem("dismissedUpdate",el.dataset.dismissUpdate)}catch(err){}header()}
  else if(el.dataset.wscope){ui.wscope=el.dataset.wscope;render()}
  else if(el.dataset.track){setTracked(el.dataset.track,!el.classList.contains("on"))}
  else if(el.dataset.goal){goalAction(el.dataset.goal)}
  else if(el.dataset.tab){ui.tab=el.dataset.tab;render()}
  else if(el.dataset.sort){const k=el.dataset.sort;if(ui.sort===k){if(ui.dir===1)ui.dir=-1;else ui.sort=""}else{ui.sort=k;ui.dir=(k==="name"||k==="class")?1:-1}render()}
  else if(el.dataset.prof){ui.prof=el.dataset.prof;render()}
  else if(el.dataset.k){const ti=+el.dataset.ti;openCell.get(el.dataset.k)===ti?openCell.delete(el.dataset.k):openCell.set(el.dataset.k,ti);render()}
  else if(el.dataset.missing){el.disabled=true;el.textContent="Loading…";
    try{const r=await fetch("/api/catalog/"+el.dataset.missing);CAT[el.dataset.missing]=await r.json()}catch(err){}
    render()}
  else if(el.dataset.more){const c=el.dataset.more;moreClasses.has(c)?moreClasses.delete(c):moreClasses.add(c);render()}
  else if(el.dataset.scope){ui.scope=el.dataset.scope;render()}
  else if(el.dataset.cview){ui.cview=el.dataset.cview;render()}
  else if(el.dataset.cown){ui.cown=el.dataset.cown;render()}
});
document.addEventListener("change",e=>{
  const t=e.target;
  if(t.classList.contains("rolesel"))return setRole(t.dataset.key,t.value);
  if(t.classList.contains("wk"))return setWeekly(t.dataset.key,t.dataset.item,t.checked);
  const map={fcls:"cls",frole:"role",fstar:"star",flvl:"lvl",profsel:"prof",pstar:"pstar",crole:"crole",lvstar:"lvstar",lv10:"lv10",psec:"psec",repchar:"repchar",rephide:"rephide"};
  if(map[t.id]){ui[map[t.id]]=t.type==="checkbox"?t.checked:t.value;render()}
});
$("q").addEventListener("input",e=>{ui.q=e.target.value;render()});
$("cq").addEventListener("input",e=>{ui.cq=e.target.value;render()});
$("repq").addEventListener("input",e=>{ui.repq=e.target.value;render()});
$("syncbtn").addEventListener("click",async()=>{
  const j=await (await fetch("/sync",{method:"POST"})).json();
  if(j.needs_connect){location="/connect";return}
  setTimeout(load,500);
});
// Poll a tiny endpoint; reload full data only when the game saved or a sync
// wrote new data. This is what makes /fl sync show up without a refresh.
let lastStamp=null;
async function poll(){
  try{const s=await (await fetch("/api/stamp")).json();const k=s.sv+"|"+s.cache+"|"+s.upd+"|"+s.syncing;
    if(lastStamp!==null&&k!==lastStamp)load();lastStamp=k}catch(e){}
  setTimeout(poll,3000);
}
function agoShort(ts){const m=Math.round((Date.now()/1000-ts)/60);return m<1?"just now":m<120?m+" min ago":Math.round(m/60)+" h ago"}
render();load();poll();
</script></body></html>
"""

# raw string so the page's backslashes (Windows paths) survive as written
SETUP_TEMPLATE = r"""<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Setup - Forge's Ledger</title><link rel="icon" href="/favicon.ico"><style>
:root{--bg:#0e1015;--panel:#161920;--panel2:#1b1f27;--line:#252a35;--txt:#e6e8ee;--dim:#8b93a5;--faint:#596173;--green:#4ade80;--red:#f87171;--amber:#fbbf24;--accent:#7c93ff}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--txt);font:14px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;margin:0}
.wrap{max-width:720px;margin:0 auto;padding:32px 20px 60px}
h1{margin:0;font-size:24px;font-weight:650}
.sub{color:var(--dim);margin:4px 0 22px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px 20px;margin-bottom:14px}
.card h2{margin:0 0 4px;font-size:15px;font-weight:600;display:flex;align-items:center;gap:10px}
.card h2 .n{display:inline-grid;place-items:center;width:22px;height:22px;border-radius:50%;background:var(--panel2);border:1px solid var(--line);font-size:12px;color:var(--dim)}
.card .why{color:var(--dim);font-size:13px;margin:0 0 12px}
label{display:block;margin:12px 0 5px;color:var(--dim);font-size:13px}
input,select{width:100%;padding:9px 11px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--txt);font:inherit;outline:none}
input:focus,select:focus{border-color:var(--accent)}
ol{margin:8px 0 0;padding-left:22px}ol li{margin:8px 0}
code{background:var(--bg);border:1px solid var(--line);padding:2px 7px;border-radius:6px;font-size:13px;color:var(--txt)}
.copy{background:var(--panel2);color:var(--dim);border:1px solid var(--line);border-radius:6px;font:inherit;font-size:12px;padding:2px 8px;margin-left:6px;cursor:pointer}
.copy:hover{color:var(--txt)}
a{color:var(--accent)}
.btn{background:var(--panel2);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:10px 16px;font:inherit;cursor:pointer}
.btn.primary{background:#3b5bfd;border-color:#3b5bfd;color:#fff;font-weight:600;padding:12px 20px}
.btn.primary:hover{background:#4d6bff}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:18px}
.status{display:flex;gap:8px;align-items:flex-start;font-size:13px;margin-top:10px}
.ok{color:var(--green)}.bad{color:var(--red)}.warn{color:var(--amber)}
.alert{padding:11px 14px;border-radius:10px;margin:0 0 16px;font-size:13px}
.alert.err{background:#2a1517;border:1px solid #5c2328;color:#fecaca}
.alert.good{background:#11261b;border:1px solid #1f5136;color:#bbf7d0}
.hint{color:var(--faint);font-size:12px;margin-top:6px}
details summary{cursor:pointer;color:var(--accent);font-size:13px;margin-top:4px}
.note{color:var(--faint);font-size:12px;margin-top:22px;line-height:1.6}
label.acct{display:flex;align-items:baseline;gap:8px;margin:8px 0;color:var(--txt);font-size:14px;cursor:pointer}
label.acct input{width:auto;accent-color:var(--accent)}
.datapath{font-size:12px;word-break:break-all}
a.btn{text-decoration:none;color:var(--txt)}
</style></head><body><div class="wrap">
<h1>%%TITLE%%</h1>
<div class="sub">%%SUBTITLE%%</div>
%%ALERTS%%
<form method="post" action="/setup" autocomplete="off">

<div class="card">
  <h2><span class="n">1</span>Your region</h2>
  <p class="why">Pick the region your World of Warcraft account plays in.</p>
  <select name="region">%%REGION_OPTIONS%%</select>
</div>

<div class="card">
  <h2><span class="n">2</span>Create your Blizzard API client</h2>
  <p class="why">Blizzard requires each person to use their own free API key. It takes about two minutes, and you only do it once.</p>
  <details %%DETAILS_OPEN%%><summary>Show the steps</summary>
  <ol>
    <li>Open <a href="https://community.developer.battle.net/access/clients" target="_blank" rel="noopener">Blizzard's developer portal</a> and log in with your Battle.net account. Blizzard may ask you to add an authenticator first — API access requires one.</li>
    <li>Click <b>Create New Client</b>.</li>
    <li><b>Client Name:</b> anything unique to you, like <i>"Alex's Gold Tracker"</i>. Names are unique across all of Blizzard's developers, and can't include Blizzard trademarks such as "WoW" or "Warcraft".</li>
    <li><b>Redirect URIs:</b> <code>%%REDIRECT%%</code><button type="button" class="copy" data-copy="%%REDIRECT%%">Copy</button></li>
    <li><b>Service URL:</b> <code>http://localhost:%%PORT%%</code><button type="button" class="copy" data-copy="http://localhost:%%PORT%%">Copy</button></li>
    <li><b>Intended use:</b> <code>Personal dashboard for my own characters</code><button type="button" class="copy" data-copy="Personal dashboard to view my own World of Warcraft characters, professions and collections.">Copy</button></li>
    <li>Click <b>Create</b>. Copy the <b>Client ID</b> and <b>Client Secret</b> it shows you into step 3.</li>
  </ol>
  </details>
</div>

<div class="card">
  <h2><span class="n">3</span>Paste your Client ID and Secret</h2>
  <p class="why">We check them with Blizzard before saving. They're stored only on this PC, encrypted with your Windows login.</p>
  <label for="cid">Client ID</label>
  <input id="cid" name="client_id" value="%%CLIENT_ID%%" required spellcheck="false">
  <label for="csec">Client Secret</label>
  <input id="csec" name="client_secret" type="password" placeholder="%%SECRET_PLACEHOLDER%%" %%SECRET_REQUIRED%% spellcheck="false">
</div>

<div class="card">
  <h2><span class="n">4</span>World of Warcraft folder</h2>
  <p class="why">Where the game is installed — the folder that contains <code>_retail_</code>. Used to read the companion addon's gold data.</p>
  <input name="wow_path" value="%%WOW_PATH%%" placeholder="C:\Program Files (x86)\World of Warcraft" spellcheck="false">
  %%WOW_STATUS%%
</div>

<div class="card">
  <h2><span class="n">5</span>Companion addon</h2>
  <p class="why">A small free in-game addon that records each character's gold (Blizzard's API doesn't include gold). Optional, but needed for gold tracking and goals.</p>
  %%ADDON_STATUS%%
</div>

<div class="row"><button class="btn primary" type="submit">%%SUBMIT_LABEL%%</button>%%BACK_LINK%%</div>
</form>

%%ACCOUNTS%%

%%DATA%%

<div class="note">Everything stays on this computer: there are no servers, no analytics and no tracking. Read the <a href="/privacy" target="_blank">privacy policy</a>.<br>
Character and game data provided by Blizzard Entertainment. This app is not endorsed by, affiliated with, or connected to Blizzard Entertainment.
World of Warcraft and Blizzard Entertainment are trademarks of Blizzard Entertainment, Inc.</div>
</div>
<script>
document.addEventListener("click",async e=>{
  if(e.target.id==="install-addon")return installAddon(e.target);
  const b=e.target.closest(".copy");if(!b)return;
  try{await navigator.clipboard.writeText(b.dataset.copy);b.textContent="Copied";setTimeout(()=>b.textContent="Copy",1500)}catch(err){}
});
document.addEventListener("change",async e=>{
  if(e.target.id==="import-file")return importSettings(e.target);
  if(!e.target.classList.contains("acct-cb"))return;
  const boxes=[...document.querySelectorAll(".acct-cb")],ids=boxes.filter(b=>b.checked).map(b=>+b.value);
  const st=document.getElementById("acct-status");
  if(!ids.length){e.target.checked=true;st.textContent="Keep at least one account selected.";return}
  try{
    const r=await fetch("/api/accounts",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({include:ids})});
    if(!r.ok)throw new Error("save failed");
    st.textContent="Saved - showing "+ids.length+" of "+boxes.length+" accounts.";
  }catch(err){e.target.checked=!e.target.checked;st.textContent="Couldn't save - try again."}
});
async function importSettings(input){
  const st=document.getElementById("data-status"),file=input.files[0];input.value="";
  if(!file)return;
  if(file.size>1048576){st.textContent="That file is too large to be a settings file.";return}
  try{
    const r=await fetch("/api/import",{method:"POST",headers:{"Content-Type":"application/json"},body:await file.text()});
    const j=await r.json();
    if(!r.ok)throw new Error(j.error||"Import failed");
    st.textContent="Imported - your tracked characters, roles, goals and account picks are restored.";
    setTimeout(()=>location.reload(),1500);
  }catch(err){st.textContent=err.message}
}
document.addEventListener("click",async e=>{
  const sb=e.target.closest("[data-install-sat]");
  if(sb){
    sb.disabled=true;sb.textContent="Installing…";
    try{
      const r=await fetch("/setup/addon",{method:"POST",headers:{"Content-Type":"application/json"},
        body:JSON.stringify({wow_path:document.querySelector("[name=wow_path]").value,satellite:sb.dataset.installSat})});
      const j=await r.json();if(!r.ok)throw new Error(j.error||"Install failed");
      sb.outerHTML='<span class="ok">&#10003; installed (version '+j.version+'). Type /reload in game.</span>';
    }catch(err){sb.disabled=false;sb.textContent="Try again";alert(err.message)}
    return;
  }
  if(e.target.id!=="open-folder")return;
  try{await fetch("/api/open-folder",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"})}catch(err){}
});
async function installAddon(btn){
  btn.disabled=true;btn.textContent="Installing…";
  const box=btn.closest(".card");
  try{
    const r=await fetch("/setup/addon",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({wow_path:document.querySelector("[name=wow_path]").value})});
    const j=await r.json();
    if(!r.ok)throw new Error(j.error||"Install failed");
    box.querySelectorAll(".status,.row,.hint").forEach(el=>el.remove());
    box.insertAdjacentHTML("beforeend",'<div class="status ok">&#10003; Installed (version '+j.version+
      '). Restart WoW, or type /reload in game, then log into each character once.</div>');
  }catch(err){btn.disabled=false;btn.textContent="Try again";alert(err.message)}
}
</script></body></html>
"""


def render_setup(error=None, notice=None, form=None):
    """The first-run setup page, which doubles as Settings later.

    form = the values the user just submitted, so a validation error
    doesn't make them retype everything."""
    cfg = load_config()
    form = form or {}
    configured = bool(cfg.get("client_id") and cfg.get("client_secret"))
    esc = html.escape
    reg = form.get("region") or cfg.get("region", "us")
    wow = form.get("wow_path", cfg.get("wow_path") or detect_wow_path() or "")

    wow_ok = bool(wow) and os.path.isdir(os.path.join(wow, "_retail_"))
    if wow_ok:
        wow_status = '<div class="status ok">&#10003; Found World of Warcraft here.</div>'
    elif wow:
        wow_status = ('<div class="status bad">&#10007; No <code>_retail_</code> folder '
                      'here - check the path.</div>')
    else:
        wow_status = ('<div class="status warn">Couldn\'t find World of Warcraft '
                      'automatically - paste the folder it\'s installed in.</div>')

    st = addon_status(wow if wow_ok else None)
    # installs via fetch() so the rest of the form (region, Client ID...)
    # isn't lost to a page reload
    install_btn = '<button class="btn" type="button" id="install-addon">%s</button>'
    if not wow_ok:
        # still offer the button: the install uses whatever folder is typed
        # in step 4 right now, and the server checks it's a real WoW folder
        addon_html = ('<div class="status warn">Enter your WoW folder in step 4, '
                      'then install.</div><div class="row">'
                      + install_btn % "Install addon" + '</div>')
    elif not st["installed"] and st["old_installed"]:
        addon_html = ('<div class="status warn">The older "Forge Gold Tracker" addon is '
                      'installed - update to the renamed Forge\'s Ledger addon. Your gold '
                      'history comes with it. <b>Close World of Warcraft first.</b></div>'
                      '<div class="row">' + install_btn % "Update addon" + '</div>'
                      '<div class="hint">In game, the command is now /fl instead of /fgt.</div>')
    elif not st["installed"]:
        addon_html = ('<div class="status warn">Not installed.</div><div class="row">'
                      + install_btn % "Install addon" + '</div>'
                      '<div class="hint">Then restart WoW (or type /reload in game) '
                      'and log into each character once.</div>')
    elif st["installed"] != st["bundled"]:
        addon_html = ('<div class="status warn">Version %s installed - %s is available.'
                      '</div><div class="row">' % (esc(st["installed"]), esc(st["bundled"]))
                      + install_btn % "Update addon" + '</div>')
    else:
        addon_html = ('<div class="status ok">&#10003; Installed (version %s).</div>'
                      % esc(st["installed"]))
    # optional companion addons (satellites) - each with its own button
    for sat in satellite_status(wow) if wow_ok else []:
        btn = ('<button class="btn" type="button" data-install-sat="%s">%%s</button>' % esc(sat["id"]))
        if not sat["installed"]:
            state = '<span class="dim">optional - not installed</span> ' + btn % "Install"
        elif sat["installed"] != sat["bundled"]:
            state = ('<span class="warn">version %s installed - %s available</span> '
                     % (esc(sat["installed"]), esc(sat["bundled"]))) + btn % "Update"
        else:
            state = '<span class="ok">&#10003; installed (version %s)</span>' % esc(sat["installed"])
        addon_html += ('<div class="status" style="margin-top:12px;flex-wrap:wrap;gap:8px">'
                       '<b>%s</b> - %s. %s</div>' % (esc(sat["title"]), esc(sat["pitch"]), state))
    # WoW Forever: the same addon runs there too; installing covers both
    forever_old = [f for f in st.get("forever", []) if f["installed"] != st["bundled"]]
    if wow_ok and st.get("forever"):
        if forever_old:
            addon_html += ('<div class="status warn">Forever: %s.</div>'
                           % ("not installed" if not forever_old[0]["installed"]
                              else "version %s installed - %s is available"
                              % (esc(forever_old[0]["installed"]), esc(st["bundled"]))))
            if st["installed"] == st["bundled"]:  # retail is current: offer the button here
                addon_html += '<div class="row">' + install_btn % "Install for Forever" + '</div>'
        else:
            addon_html += ('<div class="status ok">&#10003; Forever: installed (version %s).</div>'
                           % esc(st["bundled"]))

    alerts = ""
    if error:
        alerts += '<div class="alert err">%s</div>' % esc(error)
    if notice:
        alerts += '<div class="alert good">%s</div>' % esc(notice)

    page = SETUP_TEMPLATE
    for k, v in {
        "%%TITLE%%": "Settings" if configured else "Set up your dashboard",
        "%%SUBTITLE%%": ("Change your region, Blizzard API key, or game folder."
                         if configured else
                         "Five quick steps, and then you're tracking your whole account."),
        "%%ALERTS%%": alerts,
        "%%REGION_OPTIONS%%": "".join(
            '<option value="%s"%s>%s</option>' % (k2, " selected" if k2 == reg else "", esc(v2))
            for k2, v2 in REGIONS.items()),
        "%%DETAILS_OPEN%%": "" if configured else "open",
        "%%REDIRECT%%": REDIRECT_URI,
        "%%PORT%%": str(PORT),
        "%%CLIENT_ID%%": esc(form.get("client_id", cfg.get("client_id", ""))),
        "%%SECRET_PLACEHOLDER%%": ("Saved - leave blank to keep it"
                                   if configured else ""),
        "%%SECRET_REQUIRED%%": "" if configured else "required",
        "%%WOW_PATH%%": esc(wow),
        "%%WOW_STATUS%%": wow_status,
        "%%ADDON_STATUS%%": addon_html,
        "%%SUBMIT_LABEL%%": ("Save" if configured and is_connected()
                             else "Save and connect to Battle.net"),
        "%%BACK_LINK%%": ('<a href="/">Back to dashboard</a>' if configured else ""),
        "%%ACCOUNTS%%": accounts_card() if configured else "",
        "%%DATA%%": data_card() if configured else "",
    }.items():
        page = page.replace(k, v)
    return page


def data_card():
    """Settings card: back up / restore your choices, and see where data lives."""
    return ('<div class="card"><h2><span class="n">7</span>Your data</h2>'
            '<p class="why">Back up your choices, or bring them to another PC: tracked '
            'characters, roles, gold goals, WoW account picks and this week\'s Todo ticks. '
            'Your Blizzard login and cached character data are never included - on a new '
            'PC you set up your Blizzard key once and the rest syncs in about a minute.</p>'
            '<div class="row" style="margin-top:4px">'
            '<a class="btn" href="/api/export" download>Export settings</a>'
            '<label class="btn" style="margin:0;display:inline-block;color:var(--txt);font-size:14px">'
            'Import settings<input type="file" id="import-file" accept=".json,application/json" hidden></label>'
            '<button class="btn" type="button" id="open-folder">Open data folder</button></div>'
            '<div class="hint" id="data-status">Importing replaces those choices; your current ones '
            'are saved first as settings-before-import.json in the data folder.</div>'
            '<div class="hint datapath">Data folder: <code>%s</code></div></div>'
            % html.escape(BASE_DIR))


def export_settings():
    """The portable part of your data: choices only, no login, no Blizzard data."""
    st = load_settings()
    keep = ("tracked", "gold_goal", "forever_gold_goal", "accounts", "todo")
    return {"app": "ForgesLedger", "format": 1, "appVersion": APP_VERSION,
            "exportedAt": int(time.time()),
            "settings": {k: st[k] for k in keep if k in st},
            "roles": load_roles()}


def _valid_goal(g):
    if g is None:
        return True
    if not isinstance(g, dict) or not isinstance(g.get("amount"), int) or not 0 < g["amount"] <= 10 ** 10:
        return False
    if g.get("deadline"):
        try:
            datetime.date.fromisoformat(str(g["deadline"]))
        except ValueError:
            return False
    return True


def import_settings(doc):
    """Check an exported file, back up the current choices, then apply it.
    Returns an error message, or None on success. Every field is checked -
    an import file is user-supplied and could be edited by hand."""
    if not isinstance(doc, dict) or doc.get("app") != "ForgesLedger":
        return "That isn't a Forge's Ledger settings file."
    if doc.get("format") != 1:
        return "This settings file is from a newer version of the app - update the app first."
    st, roles = doc.get("settings"), doc.get("roles")
    if not isinstance(st, dict) or not isinstance(roles, dict):
        return "The settings file is damaged."
    if not all(isinstance(k, str) for k in st.get("tracked", [])):
        return "The settings file has an invalid tracked list."
    if not all(isinstance(k, str) and v in ROLES for k, v in roles.items()):
        return "The settings file has an invalid role."
    if not (_valid_goal(st.get("gold_goal")) and _valid_goal(st.get("forever_gold_goal"))):
        return "The settings file has an invalid gold goal."
    if not all(isinstance(a, int) for a in st.get("accounts", [])):
        return "The settings file has an invalid account list."
    if "todo" in st and not isinstance(st["todo"], dict):
        return "The settings file has invalid Todo data."
    with open(os.path.join(BASE_DIR, "settings-before-import.json"), "w", encoding="utf-8") as f:
        json.dump(export_settings(), f, indent=2)
    current = load_settings()
    for k in ("tracked", "gold_goal", "forever_gold_goal", "accounts", "todo"):
        if k in st:
            current[k] = st[k]
    save_settings(current)
    save_roles(roles)
    return None


def accounts_card():
    """Settings card: pick which WoW accounts the dashboard shows."""
    esc = html.escape
    accts = accounts_info(load_cache(), load_settings())
    head = ('<div class="card"><h2><span class="n">6</span>WoW accounts</h2>'
            '<p class="why">One Battle.net login can hold several WoW accounts (the '
            'launcher\'s account picker). Choose which ones the dashboard shows - '
            'every tab, the totals and your gold goal follow this.</p>')
    if not accts:
        return head + ('<div class="status warn">Sync once from the dashboard to list '
                       'your WoW accounts here.</div></div>')
    rows = "".join(
        '<label class="acct"><input type="checkbox" class="acct-cb" value="%s"%s> '
        '<b>%s</b> <span class="faint">- %d character%s · %s</span></label>'
        % (a["id"], " checked" if a["included"] else "", esc(a["label"]), a["count"],
           "" if a["count"] == 1 else "s", esc(", ".join(a["top"])))
        for a in accts)
    return head + rows + '<div class="hint" id="acct-status">Changes save as you click.</div></div>'


def detect_wow_path():
    """Common install spots - the Battle.net launcher's default, plus other
    drives people often install games on."""
    guesses = list(WOW_PATH_GUESSES)
    for drive in "CDEFG":
        for sub in ("World of Warcraft", r"Games\World of Warcraft",
                    r"Program Files (x86)\World of Warcraft",
                    r"Program Files\World of Warcraft"):
            guesses.append("%s:\\%s" % (drive, sub))
    for g in guesses:
        if os.path.isdir(os.path.join(g, "_retail_")):
            return g
    return None


ADDON_BUNDLE = os.path.join(RESOURCE_DIR, "addon", ADDON_FOLDER)


def _toc_version(folder, name=None):
    try:
        with open(os.path.join(folder, (name or ADDON_FOLDER) + ".toc"),
                  encoding="utf-8") as f:
            for line in f:
                if line.startswith("## Version:"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return None


def addon_status(wow_path):
    addons = (os.path.join(wow_path, "_retail_", "Interface", "AddOns")
              if wow_path else None)
    dest = os.path.join(addons, ADDON_FOLDER) if addons else None
    old = os.path.join(addons, OLD_ADDON_FOLDER) if addons else None
    forever = []
    for client in forever_clients(wow_path) if wow_path else []:
        fdest = os.path.join(client, "Interface", "AddOns", ADDON_FOLDER)
        forever.append({"dest": fdest, "installed": _toc_version(fdest)})
    return {"installed": _toc_version(dest) if dest else None,
            "forever": forever,  # one entry per installed Forever client
            # the pre-rename "Forge Gold Tracker" addon, if still installed
            "old_installed": _toc_version(old, OLD_ADDON_FOLDER) if old else None,
            "bundled": _toc_version(ADDON_BUNDLE), "dest": dest, "old": old}


def wow_running():
    """True if retail WoW is open (tasklist ships with every Windows)."""
    if sys.platform != "win32":
        return False
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Wow.exe", "/NH"],
                             capture_output=True, text=True, timeout=15,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "wow.exe" in out.lower()


def install_addon(wow_path):
    """Copy the bundled addon into WoW's AddOns folder (overwrites old files).

    Also upgrades from the pre-rename "Forge Gold Tracker" addon: WoW names
    an addon's save file after its folder, so the old gold history lives in
    ForgeGoldTracker.lua and the renamed addon would start empty. We copy it
    to the new name (keeping the original as a backup) and remove the old
    addon folder so the two don't run side by side. This must happen with
    WoW closed - otherwise WoW writes its latest data to the OLD file on
    exit, after our copy."""
    st = addon_status(wow_path)
    if not os.path.isdir(ADDON_BUNDLE):
        raise RuntimeError("The addon files are missing from the app folder "
                           "(expected addon\\%s)." % ADDON_FOLDER)
    accounts = os.path.join(wow_path, "_retail_", "WTF", "Account")
    to_migrate = []
    if os.path.isdir(accounts):
        for a in os.listdir(accounts):
            sv = os.path.join(accounts, a, "SavedVariables")
            old_f = os.path.join(sv, OLD_ADDON_FOLDER + ".lua")
            new_f = os.path.join(sv, ADDON_FOLDER + ".lua")
            if os.path.isfile(old_f) and not os.path.exists(new_f):
                to_migrate.append((old_f, new_f))
    if (to_migrate or st["old_installed"]) and wow_running():
        raise RuntimeError("Close World of Warcraft completely first - this "
                           "update moves your saved gold history to the "
                           "addon's new name, which can't be done while the "
                           "game is open.")
    shutil.copytree(ADDON_BUNDLE, st["dest"], dirs_exist_ok=True)
    # the same addon also runs in WoW Forever (it declares both games)
    for f in st["forever"]:
        shutil.copytree(ADDON_BUNDLE, f["dest"], dirs_exist_ok=True)
    for old_f, new_f in to_migrate:
        shutil.copy2(old_f, new_f)
        print("Migrated addon data: %s -> %s" % (old_f, new_f), flush=True)
    if st["old_installed"] and os.path.isdir(st["old"]):
        shutil.rmtree(st["old"])
        print("Removed the old Forge Gold Tracker addon folder.", flush=True)


def satellite_status(wow_path):
    """Optional companion addons for the Settings page: installed vs bundled."""
    out = []
    for sid, sat in SATELLITES.items():
        bundle = os.path.join(RESOURCE_DIR, "addon", sat["folder"])
        if not os.path.isdir(bundle):
            continue  # doesn't ship with this build
        dest = os.path.join(wow_path, "_retail_", "Interface", "AddOns", sat["folder"]) if wow_path else ""
        out.append({"id": sid, "title": sat["title"], "pitch": sat["pitch"],
                    "installed": _toc_version(dest, sat["folder"]) if dest else None,
                    "bundled": _toc_version(bundle, sat["folder"])})
    return out


def install_satellite(wow_path, sid):
    """Copy one bundled satellite into retail's AddOns. Returns its version."""
    sat = SATELLITES.get(sid)
    bundle = os.path.join(RESOURCE_DIR, "addon", sat["folder"]) if sat else ""
    if not sat or not os.path.isdir(bundle):
        raise RuntimeError("unknown companion addon")
    dest = os.path.join(wow_path, "_retail_", "Interface", "AddOns", sat["folder"])
    shutil.copytree(bundle, dest, dirs_exist_ok=True)
    return _toc_version(dest, sat["folder"])


def check_credentials(client_id, client_secret):
    """Ask Blizzard for an app token with these credentials. Returns an error
    message, or None if Blizzard accepted them."""
    try:
        token_request({"grant_type": "client_credentials"}, client_id, client_secret)
        return None
    except urllib.error.HTTPError as e:
        if e.code in (400, 401):
            return ("Blizzard didn't accept that Client ID and Secret. Copy them "
                    "again from the developer portal - the secret is easy to "
                    "mis-copy.")
        return "Blizzard returned an error (%s). Try again in a minute." % e.code
    except OSError:
        return "Couldn't reach Blizzard - check your internet connection."


def build_api_data():
    cache = load_cache()
    addon_error = None
    try:
        gold, sv_path, warbands = load_gold()
        warbands_all = dict(warbands)
        warbands.pop("__events__", None)  # calendar events, not a bank
    except Exception as e:
        # a save file we can't read shouldn't take the whole dashboard down -
        # show the Blizzard data and say what went wrong instead
        gold, sv_path, warbands = {}, find_sv_file(), {}
        warbands_all = {}
        addon_error = "Couldn't read the addon save file (%s)." % e
    roles = load_roles()
    settings = load_settings()
    tracked_keys = set(settings["tracked"])
    chars = []
    by_key = {}
    for c in cache.get("characters", []):
        key = norm(c["name"]) + "@" + norm(c.get("realm_slug", ""))
        g = gold.get(key, {})
        hist = g.get("history", [])
        entry = dict(c)
        entry["key"] = key
        entry["gold"] = g.get("money", 0)
        entry["gold_7d"] = gold_7d_change(hist)
        entry["professions"] = normalize_professions(c.get("professions"))
        # fill level/class from addon if API lacks them
        if not entry.get("level") and g.get("level"):
            entry["level"] = g["level"]
        if not entry.get("class") and g.get("class"):
            entry["class"] = CLASS_TOKENS.get(g["class"], g["class"].title())
        chars.append(entry)
        by_key[key] = True
    # addon-only characters (logged in game but not in API cache yet)
    for key, g in gold.items():
        if key not in by_key:
            chars.append({
                "key": key,
                "name": g["name"], "realm": g["realm"], "realm_slug": "",
                "level": g.get("level", 0),
                "class": CLASS_TOKENS.get(g.get("class", ""),
                                          g.get("class", "").title()),
                "faction": g.get("faction", ""),
                "professions": [], "gold": g["money"],
                "gold_7d": gold_7d_change(g.get("history", [])),
            })
    # Only the WoW accounts picked in Settings (none picked = all). A
    # character whose account isn't known yet (not synced since this
    # feature) stays visible rather than silently disappearing.
    picked = set(settings.get("accounts") or [])
    _labels, folder_ids = account_labels(cache.get("characters", []))
    if picked:
        def included(c):
            aid = c.get("account_id")
            if aid is None:
                aid = folder_ids.get(gold.get(c["key"], {}).get("folder"))
            return aid is None or aid in picked
        chars = [c for c in chars if included(c)]
        warbands = {f: w for f, w in warbands.items()
                    if folder_ids.get(f) in picked}
    # optional companion addons' data, per character ({} when none)
    try:
        sats = load_satellites()
    except Exception as e:
        print("Satellite scan failed: %s" % e, flush=True)
        sats = {}
    for c in chars:
        c["sat"] = {sid: e["chars"][c["key"]]["data"]
                    for sid, e in sats.items() if c["key"] in e["chars"]}
        apply_live_professions(c, cache.get("synced_at", 0))
    for c in chars:
        g = gold.get(c["key"], {})
        c["cooldowns"] = g.get("cooldowns", [])
        c["todo"] = todo_auto(c, g.get("todo"))
        c["has_addon"] = bool(g)
        # rested XP as a % of the current level's XP bar (Blizzard caps the
        # pool at 150%). It's the value when the addon last saw this
        # character - it keeps growing while they rest, so show its date.
        if g.get("rested") is not None and g.get("xp_max") and (c.get("level") or 0) < CAP:
            c["rested"] = {"pct": min(150, round(g["rested"] * 100.0 / g["xp_max"])),
                           "at": g.get("last_seen", 0)}
        c["role"] = roles.get(c["key"], "")
        c["tracked"] = c["key"] in tracked_keys
    # sort: tracked first, then level desc, then name
    chars.sort(key=lambda c: (not c["tracked"], -(c.get("level") or 0), c["name"].lower()))

    tracked = [c for c in chars if c["tracked"]]
    at_cap = sum(1 for c in tracked if (c.get("level") or 0) >= CAP)
    levels_remaining = sum(max(0, CAP - (c.get("level") or 0)) for c in tracked)
    chars_total = sum(c.get("gold", 0) for c in chars)
    bank = sum(w["money"] for w in warbands.values())
    bank_7d = sum(gold_7d_change(w["history"]) for w in warbands.values())
    gold_total = chars_total + bank
    gold_7d = sum(c.get("gold_7d", 0) for c in chars) + bank_7d
    # The goal's pace counts each warband bank like one more "character", so
    # moving gold between characters and a bank isn't mistaken for earning
    # it. Only the characters still shown count toward the goal.
    shown = {c["key"] for c in chars}
    goal_series = {k: g for k, g in gold.items() if k in shown}
    for folder, w in warbands.items():
        goal_series["__warband_bank__" + folder] = w

    # only send recipe COUNTS per tier; full names come from /api/catalog/<id>
    # on demand, which keeps this payload small
    # account-best reputations are summarized here; the raw per-character
    # lists (~149 each) stay on the server - one character at a time comes
    # from /api/reps when the page asks for it
    reps_view = reps_payload(chars, cache)
    for c in chars:
        c.pop("reps", None)
        c.pop("reps_at", None)

    catalog_totals = {tid: len(t.get("recipes", {}))
                      for tid, t in cache.get("catalog", {}).items()}

    return {
        "synced_at": cache.get("synced_at", 0),
        "connected": is_connected(),
        "syncing": STATE["syncing"],
        "sync_error": STATE["sync_error"],
        "sv_path": sv_path,
        "sv_mtime": STATE["sv_mtime"],
        "addon_error": addon_error,
        "characters": chars,
        "catalog_totals": catalog_totals,
        "expansions": [{"short": s, "full": f} for s, f, _p in EXPANSIONS],
        "roles": ROLES,
        "version": APP_VERSION,
        "update": update_available(),
        "todo": todo_payload(settings, "retail", warbands_all.get("__events__")),
        "totals": {
            "tracked": len(tracked),
            "at_cap": at_cap,
            "levels_remaining": levels_remaining,
            "gold_fmt": fmt_gold(gold_total),
            "gold_total": gold_total, "gold_7d": gold_7d,  # exact, in copper
            "characters_gold_fmt": fmt_gold(chars_total),
            "gold_7d_fmt": ("+" if gold_7d > 0 else "-") + fmt_gold(abs(gold_7d))
            if gold_7d != 0 else "—",
        },
        "gold_goal": gold_goal_status(settings["gold_goal"], goal_series, gold_total),
        "game": "retail", "cap": CAP, "classes": ALL_CLASSES,
        "forever_available": bool(forever_clients()),
        "satellites": satellites_summary(sats),
        "reps": reps_view,
        "warband_bank": ({"money": bank, "fmt": fmt_gold(bank),
                          "updated": max(w["updated"] for w in warbands.values()),
                          "gold_7d": bank_7d}
                         if warbands else None),
        "accounts": accounts_info(cache, settings),
    }


def build_forever_data():
    """Dashboard data for WoW Forever, from the addon's save files only.

    Forever characters are kept apart from retail: their keys are prefixed
    "forever:" (so tracking/roles never collide with a retail character of
    the same name), and they have their own gold goal. The Settings account
    picker applies here too, matched by account folder name."""
    settings, roles = load_settings(), load_roles()
    tracked_keys = set(settings["tracked"])
    picked = set(settings.get("accounts") or [])
    _labels, folder_ids = account_labels(load_cache().get("characters", []))
    gold, addon_error = {}, None
    try:
        for client in forever_clients():
            g, _path, _warbands = load_gold(client)  # no warband bank in Forever
            gold.update(g)
    except Exception as e:
        addon_error = "Couldn't read the Forever addon save file (%s)." % e
    chars = []
    for key, g in gold.items():
        aid = folder_ids.get(g.get("folder"))
        if picked and aid is not None and aid not in picked:
            continue
        k = "forever:" + key
        c = {"key": k, "name": g["name"], "realm": g["realm"], "realm_slug": "",
             "level": g.get("level", 0),
             "class": CLASS_TOKENS.get(g.get("class", ""), g.get("class", "").title()),
             "faction": g.get("faction", ""), "professions": [], "cooldowns": [],
             "gold": g.get("money", 0), "gold_7d": gold_7d_change(g.get("history", [])),
             "last_login": g.get("last_seen", 0),
             "tracked": k in tracked_keys, "role": roles.get(k, ""), "has_addon": True}
        c["todo"] = todo_auto(c, g.get("todo"))
        if g.get("rested") is not None and g.get("xp_max") and c["level"] < FOREVER_CAP:
            c["rested"] = {"pct": min(150, round(g["rested"] * 100.0 / g["xp_max"])),
                           "at": g.get("last_seen", 0)}
        chars.append(c)
    chars.sort(key=lambda c: (not c["tracked"], -(c.get("level") or 0), c["name"].lower()))
    tracked = [c for c in chars if c["tracked"]]
    total = sum(c["gold"] for c in chars)
    gold_7d = sum(c["gold_7d"] for c in chars)
    shown = {c["key"][len("forever:"):] for c in chars}
    classes = FOREVER_CLASSES + sorted({c["class"] for c in chars} - set(FOREVER_CLASSES) - {""})
    return {
        "game": "forever", "cap": FOREVER_CAP, "classes": classes,
        "forever_available": True,
        "satellites": {},  # none support Forever yet
        "synced_at": 0, "connected": is_connected(), "syncing": STATE["syncing"],
        "sync_error": None, "sv_path": find_sv_file(), "sv_mtime": STATE["sv_mtime"],
        "addon_error": addon_error, "characters": chars, "catalog_totals": {},
        "expansions": [{"short": s2, "full": f} for s2, f, _p in EXPANSIONS],
        "roles": ROLES, "version": APP_VERSION, "update": update_available(),
        "todo": todo_payload(settings, "forever", None), "warband_bank": None,
        "accounts": accounts_info(load_cache(), settings),
        "totals": {
            "tracked": len(tracked),
            "at_cap": sum(1 for c in tracked if (c.get("level") or 0) >= FOREVER_CAP),
            "levels_remaining": sum(max(0, FOREVER_CAP - (c.get("level") or 0)) for c in tracked),
            "gold_fmt": fmt_gold(total), "characters_gold_fmt": fmt_gold(total),
            "gold_total": total, "gold_7d": gold_7d,  # exact, in copper
            "gold_7d_fmt": ("+" if gold_7d > 0 else "-") + fmt_gold(abs(gold_7d))
            if gold_7d != 0 else "—",
        },
        "gold_goal": gold_goal_status(settings.get("forever_gold_goal"),
                                      {k: g for k, g in gold.items() if k in shown}, total),
    }


def gold_goal_status(goal, gold, gold_total):
    """Progress toward the gold goal, plus a pace estimate from history.

    Pace = how much the warband total grew per day over the last (up to)
    7 days. A character first recorded partway through counts from its
    first recorded balance, so logging into an alt for the first time
    doesn't look like you earned all of its gold that day."""
    if not goal:
        return None
    today = datetime.date.today()
    target = int(goal["amount"]) * 10000  # goal is stored in gold, data in copper
    remaining = max(0, target - gold_total)
    out = {"amount": goal["amount"], "deadline": goal.get("deadline"),
           "current": gold_total, "remaining": remaining,
           "pct": min(100.0, gold_total * 100.0 / target) if target else 0,
           "pace_per_day": None, "eta": None, "needed_per_day": None,
           "days_left": None}
    days = [h["day"] for g in gold.values() for h in g.get("history", [])]
    if days:
        start_day = max((today - datetime.timedelta(days=7)).isoformat(), min(days))
        span = (today - datetime.date.fromisoformat(start_day)).days
        if span >= 1:
            change = 0
            for g in gold.values():
                hist = g.get("history", [])
                if not hist:
                    continue
                base = hist[0]["money"]
                for h in hist:
                    if h["day"] <= start_day:
                        base = h["money"]
                    else:
                        break
                change += g["money"] - base
            pace = change / span
            out["pace_per_day"] = pace
            if pace > 0 and remaining > 0:
                days_needed = math.ceil(remaining / pace)
                # past ~100 years a date is meaningless (and can overflow)
                if days_needed <= 36500:
                    out["eta"] = (today + datetime.timedelta(days=days_needed)).isoformat()
    if goal.get("deadline"):
        left = (datetime.date.fromisoformat(goal["deadline"]) - today).days
        out["days_left"] = left
        if left > 0 and remaining > 0:
            out["needed_per_day"] = remaining / left
    return out


def read_json_body(handler, body):
    """Parse a JSON POST body, or None if it isn't one.

    Requiring a JSON content type means some random web page you visit can't
    silently post here: browsers won't send that header cross-site without a
    CORS preflight, which we never answer."""
    if "application/json" not in (handler.headers.get("Content-Type") or ""):
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ForgesLedger/" + APP_VERSION
    # drop a connection that sends nothing for a minute, so idle browser
    # connections don't hold a thread forever
    timeout = 60

    def log_message(self, *a):
        pass

    def send_html(self, html, code=200):
        body = html.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path, qs = parsed.path, urllib.parse.parse_qs(parsed.query)

        if path == "/":
            if not has_credentials():
                self.send_html(render_setup())
            else:
                self.send_html(PAGE)
            return

        if path == "/setup":
            self.send_html(render_setup())
            return

        if path == "/favicon.ico":
            # the same anvil icon that's baked into the .exe; shipped inside
            # the .exe too, so it's read from the resource folder
            try:
                with open(os.path.join(RESOURCE_DIR, "forges-ledger.ico"), "rb") as f:
                    icon = f.read()
            except OSError:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/x-icon")
            self.send_header("Content-Length", str(len(icon)))
            self.send_header("Cache-Control", "max-age=86400")
            self.end_headers()
            self.wfile.write(icon)
            return

        if path == "/privacy":
            # shipped inside the .exe, so read it from the resource folder
            try:
                with open(os.path.join(RESOURCE_DIR, "PRIVACY.md"), encoding="utf-8") as f:
                    text = f.read()
            except OSError:
                text = "PRIVACY.md is missing from this copy of the app."
            body = text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/api/data":
            try:
                game = (qs.get("game") or ["retail"])[0]
                self.send_json(build_forever_data() if game == "forever"
                               else build_api_data())
            except Exception as e:
                self.send_json({"error": str(e)}, 500)
            return

        if path == "/api/stamp":
            # tiny "has anything changed?" check the page polls every few
            # seconds, so it only reloads the full data when needed
            # the cache file's modified time changes on every full or
            # single-character sync, so it's a free "data changed" signal
            cache_mtime = (os.path.getmtime(CACHE_PATH)
                           if os.path.exists(CACHE_PATH) else 0)
            # update_check.json changing means a new version may be out
            upd_mtime = (os.path.getmtime(UPDATE_PATH)
                         if os.path.exists(UPDATE_PATH) else 0)
            self.send_json({"sv": STATE["sv_mtime"], "cache": cache_mtime,
                            "upd": upd_mtime, "syncing": STATE["syncing"]})
            return

        if path == "/api/reps":
            # one character's standings (the account-best view comes with /api/data)
            key = (qs.get("char") or [""])[0]
            cache = load_cache()
            chars = [dict(c, key=norm(c["name"]) + "@" + norm(c.get("realm_slug", "")))
                     for c in cache.get("characters", [])]
            self.send_json(reps_payload([c for c in chars if c["key"] == key], cache, key))
            return

        if path == "/api/export":
            body = json.dumps(export_settings(), indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Disposition", 'attachment; filename="forges-ledger-settings-%s.json"'
                             % datetime.date.today().isoformat())
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/api/collections":
            cache = load_cache()
            self.send_json({"collections": cache.get("collections", {}),
                            "game": cache.get("game", {})})
            return

        if path.startswith("/api/catalog/"):
            tid = path.rsplit("/", 1)[1]
            entry = load_cache().get("catalog", {}).get(tid)
            self.send_json(entry or {"recipes": {}}, 200 if entry else 404)
            return

        if path == "/connect":
            cfg = load_config()
            if not has_credentials():
                self.redirect("/setup")
                return
            STATE["oauth_state"] = secrets.token_urlsafe(16)
            print("OAuth: opening Blizzard login...", flush=True)
            url = (OAUTH_AUTHORIZE + "?" + urllib.parse.urlencode({
                "client_id": cfg["client_id"],
                "redirect_uri": REDIRECT_URI,
                "response_type": "code",
                "scope": "wow.profile",
                "state": STATE["oauth_state"],
            }))
            self.redirect(url)
            return

        if path == "/callback":
            code = (qs.get("code") or [None])[0]
            state = (qs.get("state") or [None])[0]
            err = (qs.get("error") or [None])[0]
            print("OAuth: callback received from Blizzard.", flush=True)
            if err:
                print("OAuth: Blizzard refused: %s" % err, flush=True)
                self.send_html("<h1>Blizzard said no</h1><p>%s</p><a href='/'>back</a>"
                               % err.replace("<", "&lt;"))
                return
            if not code or state != STATE.get("oauth_state"):
                print("OAuth: state mismatch - try Connect again.", flush=True)
                self.send_html("<h1>Bad callback</h1><p>State mismatch. "
                               "Try Connect again.</p><a href='/'>back</a>", 400)
                return
            try:
                tok = token_request({"grant_type": "authorization_code",
                                     "code": code, "redirect_uri": REDIRECT_URI})
            except Exception as e:
                print("OAuth: token exchange failed: %s" % e, flush=True)
                self.send_html("<h1>Token exchange failed</h1><p>%s</p>"
                               "<a href='/'>back</a>" % str(e).replace("<", "&lt;"), 500)
                return
            cfg = load_config()
            cfg["access_token"] = tok["access_token"]
            cfg["refresh_token"] = tok.get("refresh_token", "")
            cfg["expires_at"] = time.time() + tok.get("expires_in", 86400)
            save_config(cfg)
            verify = load_config()
            print("OAuth: tokens saved (refresh token present: %s)."
                  % bool(verify.get("refresh_token")), flush=True)
            STATE["oauth_state"] = None
            threading.Thread(target=do_sync, daemon=True).start()
            self.redirect("/?ok=1")
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        with WRITE_LOCK:
            self._do_post()

    def _do_post(self):
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        form = urllib.parse.parse_qs(body)

        if parsed.path == "/setup/addon":
            req = read_json_body(self, body)
            wow = str((req or {}).get("wow_path") or "").strip() or detect_wow_path()
            if not wow or not os.path.isdir(os.path.join(wow, "_retail_")):
                self.send_json({"error": "Set a valid World of Warcraft folder first."}, 400)
                return
            sid = (req or {}).get("satellite")
            if sid:
                try:
                    version = install_satellite(wow, str(sid))
                except Exception as e:
                    self.send_json({"error": "Couldn't install it: %s" % e}, 500)
                    return
                print("Installed satellite %s %s" % (sid, version), flush=True)
                self.send_json({"ok": True, "version": version})
                return
            try:
                install_addon(wow)
            except Exception as e:
                self.send_json({"error": "Couldn't install the addon: %s" % e}, 500)
                return
            print("Addon installed to %s" % wow, flush=True)
            self.send_json({"ok": True, "version": addon_status(wow)["installed"]})
            return

        if parsed.path == "/setup":
            vals = {k: v[0].strip() for k, v in form.items()}
            cfg = load_config()
            reg = vals.get("region", "us")
            cid = vals.get("client_id", "")
            secret = vals.get("client_secret", "")
            wow = vals.get("wow_path", "")

            def fail(msg):
                vals.pop("client_secret", None)  # never echo the secret back
                self.send_html(render_setup(error=msg, form=vals))

            if reg not in REGIONS:
                return fail("Pick a region.")
            if not cid:
                return fail("Paste your Client ID.")
            if not secret:
                # blank = keep the saved one, but only for the same client
                if cid != cfg.get("client_id") or not cfg.get("client_secret"):
                    return fail("Paste your Client Secret.")
                secret = cfg["client_secret"]
            if wow and not os.path.isdir(os.path.join(wow, "_retail_")):
                return fail("That WoW folder doesn't contain a _retail_ folder. "
                            "Leave it blank if you don't use the addon.")
            err = check_credentials(cid, secret)
            if err:
                return fail(err)

            creds_changed = (cid != cfg.get("client_id")
                             or secret != cfg.get("client_secret"))
            region_changed = reg != cfg.get("region", "us")
            if creds_changed or region_changed:
                # an old login belongs to the old client/region - start fresh
                for k in ("access_token", "refresh_token", "expires_at"):
                    cfg.pop(k, None)
                _APP_TOKEN["token"] = None
            if region_changed and os.path.exists(CACHE_PATH):
                # characters from another region would be wrong here
                with CACHE_LOCK:
                    os.remove(CACHE_PATH)
            cfg.update({"client_id": cid, "client_secret": secret, "region": reg})
            if wow:
                cfg["wow_path"] = wow
            else:
                cfg.pop("wow_path", None)
            save_config(cfg)
            print("Setup saved (region %s)." % reg, flush=True)
            self.redirect("/" if is_connected() else "/connect")
            return

        if parsed.path == "/api/track":
            req = read_json_body(self, body)
            if not req or not req.get("key"):
                self.send_json({"error": "bad request"}, 400)
                return
            s = load_settings()
            keys = set(s["tracked"])
            if req.get("on"):
                keys.add(str(req["key"]))
            else:
                keys.discard(str(req["key"]))
            s["tracked"] = sorted(keys)
            save_settings(s)
            self.send_json({"ok": True})
            return

        if parsed.path == "/api/goal":
            req = read_json_body(self, body)
            if req is None:
                self.send_json({"error": "bad request"}, 400)
                return
            s = load_settings()
            # retail and Forever economies don't mix: one goal per game
            gkey = "forever_gold_goal" if req.get("game") == "forever" else "gold_goal"
            if not req.get("amount"):
                s[gkey] = None  # clearing the goal
            else:
                try:
                    amount = int(req["amount"])
                    deadline = req.get("deadline") or None
                    if deadline:
                        datetime.date.fromisoformat(deadline)  # validates
                    if not 0 < amount <= 10 ** 10:
                        raise ValueError
                except (ValueError, TypeError):
                    self.send_json({"error": "Goal must be a positive number "
                                    "of gold and a valid date."}, 400)
                    return
                s[gkey] = {"amount": amount, "deadline": deadline}
            save_settings(s)
            self.send_json({"ok": True})
            return

        if parsed.path == "/api/import":
            if length > 1048576:
                self.send_json({"error": "That file is too large to be a settings file."}, 413)
                return
            if "application/json" not in (self.headers.get("Content-Type") or ""):
                self.send_json({"error": "json required"}, 415)
                return
            try:
                doc = json.loads(body)
            except ValueError:
                self.send_json({"error": "That file isn't valid JSON."}, 400)
                return
            err = import_settings(doc)
            self.send_json({"error": err} if err else {"ok": True}, 400 if err else 200)
            return

        if parsed.path == "/api/open-folder":
            # JSON-only like the other POSTs, so a web page can't trigger it
            if read_json_body(self, body) is None:
                self.send_json({"error": "bad request"}, 400)
                return
            try:
                os.startfile(BASE_DIR)  # opens File Explorer (Windows only)
                self.send_json({"ok": True})
            except (AttributeError, OSError) as e:
                self.send_json({"error": str(e)}, 500)
            return

        if parsed.path == "/api/accounts":
            req = read_json_body(self, body)
            known = {a["id"] for a in accounts_info(load_cache())}
            try:
                ids = [int(i) for i in (req or {}).get("include", [])]
            except (TypeError, ValueError):
                ids = None
            if req is None or ids is None or not set(ids) <= known:
                self.send_json({"error": "bad request"}, 400)
                return
            s = load_settings()
            # all of them picked = no filter (new accounts then show up too)
            s["accounts"] = [] if set(ids) == known else sorted(ids)
            save_settings(s)
            self.send_json({"ok": True})
            return

        if parsed.path in ("/api/todo", "/api/weekly"):
            req = read_json_body(self, body)
            item = (req or {}).get("item")
            period = next((per for cat in TODO_CATALOG.values() for per, items in cat.items()
                           if item in [i for i, _l, _k in items]), None)
            if not req or not req.get("key") or not period:
                self.send_json({"error": "bad request"}, 400)
                return
            s = load_settings()
            checks = todo_checks(s)  # drops ticks from past days/weeks
            char = checks[period].setdefault(str(req["key"]), {})
            if req.get("done"):
                char[item] = True
            else:
                char.pop(item, None)
            s["todo"] = {"day": day_id(), "week": week_id(),
                         "daily": checks["daily"], "weekly": checks["weekly"]}
            s.pop("weekly", None)  # migrated into "todo"
            save_settings(s)
            self.send_json({"ok": True})
            return

        if parsed.path == "/api/role":
            req = read_json_body(self, body)
            if not req or "key" not in req:
                self.send_json({"error": "bad request"}, 400)
                return
            key, role = str(req["key"]), str(req.get("role") or "")
            if role and role not in ROLES:
                self.send_json({"error": "unknown role"}, 400)
                return
            roles = load_roles()
            if role:
                roles[key] = role
            else:
                roles.pop(key, None)
            save_roles(roles)
            self.send_json({"ok": True})
            return

        if parsed.path == "/sync":
            # The Battle.net login expires daily, but everything except new
            # characters and mounts/pets syncs without it (app token). So only
            # send people to log in when there's nothing synced yet at all.
            if not is_connected() and not load_cache().get("characters"):
                self.send_json({"needs_connect": True})
                return
            threading.Thread(target=do_sync, daemon=True).start()
            self.send_json({"started": True})
            return

        self.send_response(404)
        self.end_headers()


class LocalServer(http.server.ThreadingHTTPServer):
    # One thread per connection. The plain HTTPServer handles a single
    # connection at a time, and browsers open "speculative" connections they
    # may never send anything on - the server would wait on one forever and
    # every other request would queue behind it (the dashboard froze).
    daemon_threads = True  # don't keep the app alive for open connections
    # Python turns on SO_REUSEADDR by default. On Windows that option lets a
    # SECOND process bind a port that's already in use, so two copies of the
    # app would silently share port 8765. Off = the second copy gets an
    # error, which main() turns into "just open the browser".
    allow_reuse_address = False


def main():
    url = "http://localhost:%d" % PORT
    try:
        server = LocalServer(("127.0.0.1", PORT), Handler)
    except OSError:
        # already running (double-clicked twice) - show the existing one
        print("The dashboard is already running - opening it in your browser.")
        webbrowser.open(url)
        return
    if sys.platform == "win32":
        os.system("title Forge's Ledger - close this window to stop")
    print("=" * 60)
    print("Forge's Ledger v%s" % APP_VERSION)
    print("=" * 60)
    secure_existing_config()
    if sys.platform != "win32":
        print("WARNING: credential encryption is Windows-only for now - your "
              "Blizzard secret and tokens are stored as plain text.")
    if not has_credentials():
        print("First run: complete setup in your browser.")
    else:
        sv = find_sv_file()
        print("Addon save file: %s" % (sv or "not found yet - install the addon "
                                           "from Settings and log in"))
        if not is_connected():
            print("Battle.net login expired - character details still update; "
                  "Connect for new characters, mounts and pets.")
    threading.Thread(target=watch_addon_file, daemon=True).start()
    threading.Thread(target=auto_sync_loop, daemon=True).start()
    # right away, not after auto_sync_loop's start-up pause, so a new
    # version shows on the first launch
    threading.Thread(target=check_for_update, daemon=True).start()
    print("Dashboard: %s" % url)
    print("Your data is saved in: %s" % BASE_DIR)
    print("Close this window (or press Ctrl+C) to stop the dashboard.")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
