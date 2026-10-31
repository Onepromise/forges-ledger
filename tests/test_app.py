"""Tests for the desktop app's logic (forges_ledger.py): sync hardening,
weekly gold, custom tasks, the companion data file, diagnostics and more.

Run from the repo root:   python -m unittest discover -s tests -v

Nothing here touches your real data: every path the app writes to is
pointed at a temporary folder, and the network is replaced by fakes.
"""
import email.message
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest import mock

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import forges_ledger as F  # noqa: E402


def http_error(code, retry_after=None):
    hdrs = email.message.Message()
    if retry_after is not None:
        hdrs["Retry-After"] = str(retry_after)
    return urllib.error.HTTPError("https://x", code, "err", hdrs, io.BytesIO(b"{}"))


class Resp:
    def __init__(self, data):
        self.data = json.dumps(data).encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, *a):
        return self.data


class TempData(unittest.TestCase):
    """Every file the app writes goes to a temp folder."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.patches = [
            mock.patch.object(F, "CACHE_PATH", os.path.join(self.tmp, "cache.json")),
            mock.patch.object(F, "SETTINGS_PATH", os.path.join(self.tmp, "settings.json")),
            mock.patch.object(F, "SYNC_STATUS_PATH", os.path.join(self.tmp, "sync_status.json")),
            mock.patch.object(F, "UPDATE_PATH", os.path.join(self.tmp, "update.json")),
            mock.patch.object(F.time, "sleep", lambda s: None),
        ]
        for p in self.patches:
            p.start()
        F.STATE.update({"syncing": False, "sync_error": None, "sync_tally": None})

    def tearDown(self):
        for p in self.patches:
            p.stop()


# ------------------------------------------------------------------ api_get
class ApiGet(TempData):
    def run_api(self, outcomes, path="/profile/wow/character/x/y"):
        """outcomes: a list of exceptions to raise or dicts to return."""
        calls = []

        def fake_urlopen(req, timeout=0):
            calls.append(req.full_url)
            o = outcomes[min(len(calls) - 1, len(outcomes) - 1)]
            if isinstance(o, Exception):
                raise o
            return Resp(o)

        with mock.patch.object(F, "region", lambda: "us"), mock.patch.object(F, "app_token", lambda: "tok"), \
                mock.patch.object(F.urllib.request, "urlopen", fake_urlopen):
            try:
                return F.api_get(path), calls
            except Exception as e:
                return e, calls

    def test_retries_a_503_then_succeeds(self):
        r, calls = self.run_api([http_error(503), {"ok": 1}])
        self.assertEqual(r, {"ok": 1})
        self.assertEqual(len(calls), 2)

    def test_does_not_retry_a_404(self):
        r, calls = self.run_api([http_error(404)])
        self.assertIsInstance(r, F.ApiError)
        self.assertEqual(r.code, 404)
        self.assertEqual(len(calls), 1)

    def test_retries_a_network_error_then_succeeds(self):
        r, calls = self.run_api([urllib.error.URLError("no route"), TimeoutError("slow"), {"ok": 2}])
        self.assertEqual(r, {"ok": 2})
        self.assertEqual(len(calls), 3)

    def test_gives_up_after_four_tries(self):
        r, calls = self.run_api([http_error(502)])
        self.assertIsInstance(r, F.ApiError)
        self.assertEqual(r.code, 502)
        self.assertEqual(len(calls), 4)

    def test_rate_limit_waits_as_long_as_blizzard_says(self):
        waits = []
        with mock.patch.object(F.time, "sleep", waits.append):
            r, _ = self.run_api([http_error(429, retry_after=7), {"ok": 3}])
        self.assertEqual(r, {"ok": 3})
        self.assertEqual(waits, [7])

    def test_expired_app_token_is_replaced_once(self):
        F._APP_TOKEN.update({"token": "stale", "expires_at": time.time() + 9999})
        with mock.patch.object(F, "token_request", lambda d, *a: {"access_token": "fresh", "expires_in": 3600}):
            r, calls = self.run_api([http_error(401), {"ok": 4}], path="/data/wow/x")
        # (run_api replaced app_token; the reset itself is what we check)
        self.assertEqual(F._APP_TOKEN["token"], None)
        self.assertEqual(r, {"ok": 4})
        self.assertEqual(len(calls), 2)

    def test_transient_classification(self):
        self.assertTrue(F.is_transient(F.ApiError(503)))
        self.assertTrue(F.is_transient(F.ApiError(429)))
        self.assertTrue(F.is_transient(RuntimeError("Couldn't reach Blizzard")))
        self.assertFalse(F.is_transient(F.ApiError(404)))
        self.assertFalse(F.is_transient(F.ApiError(403)))


# ------------------------------------------------------------ refresh + sync
def old_character(name="Alpha"):
    return {"account_id": 1, "name": name, "realm_slug": "area-52", "realm": "Area 52", "level": 80,
            "class": "Mage", "faction": "Horde", "ilvl": 280, "guild": "Old Guild", "race": "Orc",
            "achievement_points": 5000, "last_login": 1700000000,
            "professions": [{"name": "Alchemy", "id": 171, "tiers": []}], "reps": {"1": {}}, "reps_at": 5}


def account_reply(*names):
    return {"wow_accounts": [{"id": 1, "characters": [
        {"name": n, "realm": {"slug": "area-52", "name": "Area 52"}, "level": 90,
         "playable_class": {"name": "Mage"}, "faction": {"name": "Horde"}} for n in names]}]}


class SyncHardening(TempData):
    def sync(self, api, old_chars):
        old = {"characters": old_chars, "catalog": {}, "collections": {}, "game": {}, "rep_meta": {},
               "synced_at": 1, "login_synced_at": 1}
        stack = [mock.patch.object(F, "api_get", api), mock.patch.object(F, "load_cache", lambda: old),
                 mock.patch.object(F, "sync_catalog", lambda d, o: {}),
                 mock.patch.object(F, "sync_collections", lambda d: {}),
                 mock.patch.object(F, "sync_game_data", lambda g: {}),
                 mock.patch.object(F, "sync_reputations", lambda d, o: None),
                 mock.patch.object(F, "sync_rep_meta", lambda m: {})]
        for p in stack:
            p.start()
        try:
            return F.sync_all()
        finally:
            for p in stack:
                p.stop()

    def test_refresh_ok_updates_details(self):
        e = old_character()

        def api(path, params=None):
            if path.endswith("/professions"):
                return {"primaries": [{"profession": {"name": "Tailoring", "id": 197}, "tiers": []}]}
            return {"level": 90, "equipped_item_level": 301, "guild": {"name": "New Guild"}}
        with mock.patch.object(F, "api_get", api):
            self.assertEqual(F.refresh_character(e), "ok")
        self.assertEqual(e["ilvl"], 301)
        self.assertEqual(e["guild"], "New Guild")
        self.assertEqual(e["professions"][0]["name"], "Tailoring")

    def test_refresh_missing_when_blizzard_has_nothing(self):
        e = {"name": "Idle", "realm_slug": "area-52", "professions": []}
        with mock.patch.object(F, "api_get", mock.Mock(side_effect=F.ApiError(404))):
            self.assertEqual(F.refresh_character(e), "missing")

    def test_refresh_failed_keeps_what_the_entry_had(self):
        e = old_character()
        with mock.patch.object(F, "api_get", mock.Mock(side_effect=F.ApiError(503))):
            self.assertEqual(F.refresh_character(e), "failed")
        self.assertEqual(e["ilvl"], 280)
        self.assertEqual(e["professions"][0]["name"], "Alchemy")

    def test_a_failed_refresh_during_sync_keeps_last_known_details(self):
        # the bug: bases were rebuilt with professions=[] and no ilvl/guild,
        # so one Blizzard hiccup blanked the character until the next sync
        def api(path, params=None):
            if path == "/profile/user/wow":
                return account_reply("Alpha", "Bravo")
            if "/alpha" in path:
                raise F.ApiError(503)
            if path.endswith("/professions"):
                return {"primaries": []}
            return {"level": 90, "equipped_item_level": 310}
        data = self.sync(api, [old_character("Alpha")])
        alpha = next(c for c in data["characters"] if c["name"] == "Alpha")
        self.assertEqual(alpha["ilvl"], 280)
        self.assertEqual(alpha["guild"], "Old Guild")
        self.assertEqual(alpha["professions"][0]["name"], "Alchemy")
        self.assertEqual(alpha["level"], 90)  # the fresh character list still applies
        self.assertEqual(F.STATE["sync_tally"]["failed"], 1)
        self.assertEqual(F.STATE["sync_tally"]["failed_names"], ["Alpha"])
        self.assertEqual(F.STATE["sync_tally"]["ok"], 1)

    def test_login_expired_sync_keeps_everything_too(self):
        def api(path, params=None):
            if path == "/profile/user/wow":
                raise RuntimeError("not_connected")
            raise F.ApiError(503)
        data = self.sync(api, [old_character("Alpha")])
        alpha = data["characters"][0]
        self.assertEqual((alpha["ilvl"], alpha["guild"]), (280, "Old Guild"))
        self.assertEqual(alpha["reps"], {"1": {}})

    def test_inactive_characters_are_counted_as_missing_not_failed(self):
        def api(path, params=None):
            if path == "/profile/user/wow":
                return account_reply("Idle")
            raise F.ApiError(404)
        self.sync(api, [])
        self.assertEqual(F.STATE["sync_tally"], {"ok": 0, "missing": 1, "failed": 0, "failed_names": []})

    def test_blizzard_going_quiet_stops_the_sync_and_saves_nothing(self):
        names = ["C%d" % i for i in range(8)]

        def api(path, params=None):
            if path == "/profile/user/wow":
                return account_reply(*names)
            raise RuntimeError("Couldn't reach Blizzard: timed out")
        with self.assertRaises(RuntimeError) as cm:
            self.sync(api, [])
        self.assertIn("stopped answering", str(cm.exception))

    def test_a_good_character_resets_the_failure_streak(self):
        names = ["C%d" % i for i in range(12)]

        def api(path, params=None):
            if path == "/profile/user/wow":
                return account_reply(*names)
            # every other character fails: never 6 in a row
            n = int(path.split("/")[-2][1:]) if path.endswith("/professions") else int(path.split("/")[-1][1:])
            if n % 2:
                raise F.ApiError(503)
            return {"primaries": []} if path.endswith("/professions") else {"level": 90}
        data = self.sync(api, [])
        self.assertEqual(len(data["characters"]), 12)
        self.assertEqual(F.STATE["sync_tally"]["failed"], 6)

    def test_do_sync_remembers_failure_and_success_on_disk(self):
        with mock.patch.object(F, "sync_all", mock.Mock(side_effect=RuntimeError("Blizzard is down"))):
            F.do_sync()
        st = F.sync_status()
        self.assertFalse(st["ok"])
        self.assertEqual(st["error"], "Blizzard is down")
        self.assertEqual(F.STATE["sync_error"], "Blizzard is down")

        def ok():
            F.STATE["sync_tally"] = {"ok": 5, "missing": 2, "failed": 1, "failed_names": ["Alpha"]}
            return {"characters": [1], "synced_at": 1}
        with mock.patch.object(F, "sync_all", ok):
            F.do_sync()
        st = F.sync_status()  # survives a restart: it's read from disk
        self.assertTrue(st["ok"])
        self.assertEqual(st["notes"]["failed"], 1)
        self.assertIsNone(F.STATE["sync_error"])
        self.assertIn("ok_at", st)

    def test_diagnostics_report_the_last_sync(self):
        F.record_sync(False, "Blizzard is down")
        text = F.diagnostics_text()
        self.assertIn("Last sync error: Blizzard is down", text)
        self.assertIn("Last sync attempt:", text)

    def test_diagnostics_hold_nothing_personal(self):
        text = F.diagnostics_text()
        home = os.path.expanduser("~")
        for bad in (home, os.path.basename(home), "WTF", "SavedVariables"):
            self.assertNotIn(bad, text)


# ---------------------------------------------------------------- the watcher
class Watcher(TempData):
    def write_sv(self, name, last_char):
        path = os.path.join(self.tmp, name + ".lua")
        with open(path, "w", encoding="utf-8") as f:
            f.write('ForgeGoldDB = {\n\t["lastChar"] = "%s",\n}\n' % last_char)
        return path

    def test_every_save_file_is_watched_on_its_own(self):
        a, b = self.write_sv("a", "Alpha-Area52"), self.write_sv("b", "Bravo-Area52")
        seen = {}
        refreshed = []
        done = threading.Event()

        def fake_quick(key):
            refreshed.append(key)
            if len(refreshed) == 2:
                done.set()
        with mock.patch.object(F, "find_sv_files", lambda client=None: [("A", a), ("B", b)] if client is None else []), \
                mock.patch.object(F, "forever_clients", lambda root=None: []), mock.patch.object(F, "quick_sync", fake_quick):
            first = F.watch_tick(seen)
            self.assertEqual(refreshed, [])  # the first look only takes a baseline
            self.assertEqual(set(seen), {a, b})
            os.utime(a, (first + 10, first + 10))
            os.utime(b, (first + 20, first + 20))  # both change between two ticks
            newest = F.watch_tick(seen)
            self.assertTrue(done.wait(3))
        self.assertEqual(sorted(refreshed), ["Alpha-Area52", "Bravo-Area52"])
        self.assertEqual(newest, first + 20)

    def test_a_half_written_file_is_looked_at_again(self):
        a = self.write_sv("a", "Alpha-Area52")
        seen = {}
        with mock.patch.object(F, "find_sv_files", lambda client=None: [("A", a)] if client is None else []), \
                mock.patch.object(F, "forever_clients", lambda root=None: []), \
                mock.patch.object(F, "quick_sync", lambda k: None):
            t = F.watch_tick(seen)
            os.utime(a, (t + 5, t + 5))
            with mock.patch.object(F, "parse_savedvariables", mock.Mock(side_effect=ValueError("mid-write"))):
                F.watch_tick(seen)
            self.assertEqual(seen[a], t)  # not marked as seen: retried next tick


# ---------------------------------------------------------- weekly + custom
class WeeklyAndCustom(TempData):
    def test_weekly_status(self):
        ws = F.next_reset() - 7 * 86400
        gold = {"a": {"name": "Alpha", "class": "MAGE", "money": 1500000, "last_seen": ws + 100,
                      "week": {"start": ws, "money": 1000000, "exact": True}},
                "b": {"name": "Bravo", "class": "", "money": 200000, "last_seen": ws + 200,
                      "week": {"start": ws + 30, "money": 500000, "exact": True}},
                "c": {"name": "Idle", "money": 9, "last_seen": ws - 9999}}
        banks = {"F1": {"money": 800000, "updated": ws + 50,
                        "week": {"start": ws, "money": 500000, "exact": True}}}
        w = F.weekly_status(gold, banks, {}, None)
        self.assertEqual(w["net"], 500000 - 300000 + 300000)  # moving gold between characters cancels out
        self.assertEqual(w["gross"], 800000)  # gains only
        self.assertFalse(w["partial"])
        self.assertEqual([r["name"] for r in w["contributions"]], ["Alpha", "Warband bank", "Bravo"])
        gold["b"]["week"]["exact"] = False
        self.assertTrue(F.weekly_status(gold, banks, {}, None)["partial"])
        self.assertIsNone(F.weekly_status({"x": {"money": 1}}, {}, {}, None))

    def test_the_newest_weekly_goal_wins(self):
        ws = F.next_reset() - 7 * 86400
        gold = {"a": {"name": "A", "money": 2, "last_seen": ws + 1, "week": {"start": ws, "money": 1, "exact": True}}}
        now = int(time.time())
        g = F.weekly_status(gold, {}, {"weekly_goal": {"copper": 20, "at": now}}, {"copper": 50, "at": now - 60})
        self.assertEqual((g["goal"], g["goal_source"]), (20, "app"))
        g = F.weekly_status(gold, {}, {"weekly_goal": {"copper": 20, "at": now - 60}}, {"copper": 50, "at": now})
        self.assertEqual((g["goal"], g["goal_source"]), (50, "game"))

    def test_custom_view_merges_app_and_game_tasks(self):
        now = int(time.time())
        st = {"custom_tasks": [{"id": "a1", "text": "Craft flasks", "scope": "Alpha-Realm", "reset": "daily", "at": 1},
                               {"id": "g9", "text": "Edited in the app", "scope": "global", "reset": "none", "at": 5}],
              "custom_deleted": {"a7": now}}
        game = {"tasks": {"g9": {"id": "g9", "text": "Old game text", "scope": "global"},
                          "g2": {"id": "g2", "text": "Farm herbs", "scope": "Alpha-Realm"},
                          "a7": {"id": "a7", "text": "Deleted in the app", "scope": "global"}},
                "deleted": {"g3": now}, "done": {"Alpha-Realm": {"g2": now}}}
        v = F.custom_view(st, game)
        self.assertEqual(sorted(t["text"] for t in v["tasks"]), ["Craft flasks", "Edited in the app", "Farm herbs"])
        self.assertEqual(v["done"]["Alpha-Realm"]["g2"], now)

    def test_the_companion_addon_is_written_and_valid_lua(self):
        wow = os.path.join(self.tmp, "wow")
        os.makedirs(os.path.join(wow, "_retail_", "Interface", "AddOns"))
        st = {"wow_path": wow, "weekly_goal": {"copper": 2000000000, "at": 5},
              "custom_tasks": [{"id": "a1", "text": 'Quote "me" \\ ok', "scope": "global", "reset": "weekly", "at": 1}],
              "custom_deleted": {"a7": 1}}
        dest = F.write_companion(st)
        self.assertEqual(os.path.basename(dest), "ForgesLedger_Companion")
        self.assertEqual(sorted(os.listdir(dest)), ["Companion.lua", "ForgesLedger_Companion.toc"])
        lua = open(os.path.join(dest, "Companion.lua"), encoding="utf-8").read()
        try:
            from lupa import lua51
        except ImportError:
            self.skipTest("lupa not installed")
        L = lua51.LuaRuntime()
        L.execute(lua)
        c = L.eval("ForgesLedgerCompanion")
        self.assertEqual(c.companionVersion, 1)
        self.assertEqual(c.weeklyGoal.copper, 2000000000)
        self.assertEqual(c.tasks[1].text, 'Quote "me" \\ ok')
        self.assertEqual(c.deleted[1], "a7")

    def test_no_wow_folder_writes_nothing(self):
        self.assertIsNone(F.write_companion({"wow_path": os.path.join(self.tmp, "nope")}))

    def test_cooldown_ignores(self):
        self.assertEqual(F.cooldown_ignores({370714: False, 1: True, "5": False}), {370714, 5})
        self.assertEqual(F.cooldown_ignores(None), set())
        self.assertEqual(F._cooldowns({"370714": {"name": "T", "profession": "Alchemy", "readyAt": 5}})[0]["id"], 370714)


if __name__ == "__main__":
    unittest.main()
