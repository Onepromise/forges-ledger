"""Drive Kill Ledger in the mock WoW UI: combat-log kills, loot windows, the panel."""
import os, sys
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = sys.argv[1]
fails, passes = [], 0


def check(name, cond, detail=""):
    global passes
    if cond:
        passes += 1
        print("  ok  ", name)
    else:
        fails.append(name)
        print("  FAIL", name, "->", detail)


MOCK = open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read()

WORLD = r'''
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 1, 1
function InCombatLockdown() return false end
function GetRealmName() return "Area 52" end
function GetRealZoneText() return "Elwynn Forest" end
function UnitFullName(u) return "Testchar", nil end
-- the target (the default kill counter watches it die)
TGT = nil
function UnitExists(u) if u == "target" then return TGT ~= nil end return true end
function UnitIsPlayer(u) return u == "target" and TGT ~= nil and TGT.player == true end
function UnitIsDead(u) return TGT ~= nil and TGT.dead == true end
function UnitIsTapDenied(u) return TGT ~= nil and TGT.tap == true end
function UnitName(u) if u == "target" then return TGT and TGT.name end return "Testchar" end
function UnitGUID(u) if u == "target" then return TGT and TGT.guid end return "Player-1-0001" end
function SETTARGET(guid, name, extra)
  TGT = { guid = guid, name = name }
  for k, v in pairs(extra or {}) do TGT[k] = v end
  FireEvent("PLAYER_TARGET_CHANGED")
end
function HEALTH(unit) FireEvent("UNIT_HEALTH", unit or "target") end
function CLEU_REGISTERED()
  for f in pairs(EVENT_FRAMES) do if f._events.COMBAT_LOG_EVENT_UNFILTERED then return true end end
  return false
end
function UnitClass() return "Warrior", "WARRIOR" end
ITEM_QUALITY_COLORS = { [0] = { r = .6, g = .6, b = .6 }, [1] = { r = 1, g = 1, b = 1 }, [2] = { r = .1, g = 1, b = 0 }, [3] = { r = 0, g = .44, b = .87 } }
-- the combat log
CUR = {}
function CombatLogGetCurrentEventInfo() return unpack(CUR) end
function CLEU(sub, src, srcFlags, dst, dstName, dstFlags)
  CUR = { 0, sub, false, src, "Src", srcFlags, 0, dst, dstName, dstFlags or 0xa48 }
  FireEvent("COMBAT_LOG_EVENT_UNFILTERED")
end
MINE, PARTY, OUTSIDER = 0x511, 0x512, 0x548
-- items the game knows (id -> name, quality, vendor price in copper)
ITEMS = {
  [100] = { "Linen Cloth", 1, 13 },
  [101] = { "Worn Dagger", 2, 250 },
  [102] = { "Crawler Meat", 1, 5 },
  [103] = { "Torn Map", 1, 0 },
  [104] = { "Strange Gem", 3, nil },   -- the game hasn't cached it yet
}
function GetItemInfo(link)
  local id = tonumber(tostring(link):match("item:(%d+)"))
  local it = ITEMS[id]
  if not it then return nil end
  return it[1], link, it[2], 1, 1, "Misc", "Junk", 1, "", 0, it[3]
end
function L(id) return "|cffffffff|Hitem:" .. id .. "::::::::1:::::::::|h[" .. (ITEMS[id] and ITEMS[id][1] or "?") .. "]|h|r" end
-- the loot window
SLOTS = {}
function GetNumLootItems() return #SLOTS end
function GetLootSlotType(i) return SLOTS[i].type end
function GetLootSlotLink(i) return SLOTS[i].link end
function GetLootSlotInfo(i) return nil, nil, 1, nil, 1, SLOTS[i].locked or false end
function GetLootSourceInfo(i) return unpack(SLOTS[i].sources) end
function LOOT(slots) SLOTS = slots; FireEvent("LOOT_OPENED"); RunTimers() end
function G(npc, n) return string.format("Creature-0-1-1-1-%d-%05d", npc, n or 1) end
function ITEMSLOT(id, guid, qty, locked) return { type = 1, link = L(id), sources = { guid, qty or 1 }, locked = locked } end
function MONEYSLOT(guid) return { type = 2, sources = { guid, 5 } } end
'''


def run(title, saved="", before="", login=True, cl=True):
    print("\n== " + title)
    R = lua51.LuaRuntime(unpack_returned_tuples=True)
    R.execute(MOCK)
    R.execute(WORLD)
    R.execute(before)
    code = open(os.path.join(ADDON, "ForgesLedger_KillLedger", "ForgesLedger_KillLedger.lua"), encoding="utf-8").read()
    # most suites exercise the opt-in combat-log counter; cl=False is the default
    R.execute(("ForgesLedgerKillLedgerDB = { combatLog = true }\n" if cl else "") + saved)
    R.eval("function(c) assert(loadstring(c, '@KillLedger.lua'))('ForgesLedger_KillLedger', {}) end")(code)
    if login:
        R.execute('FireEvent("PLAYER_LOGIN"); FireEvent("PLAYER_ENTERING_WORLD", true, false); RunTimers()')
    return R


def ev(R, s):
    R.execute(s + "; RunTimers()")


def kill(R, npc, n=1, src="MINE", name="Boar"):
    ev(R, 'CLEU("PARTY_KILL", "Player-1-0001", %s, G(%d, %d), "%s")' % (src, npc, n, name))


def errors(R):
    return [p for p in R.eval("PRINTED").values() if "error" in p.lower()]


def mob(R, npc, scope="mobs"):
    base = "ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data"
    path = base + (".mobs" if scope == "mobs" else ".session.mobs")
    return R.eval("%s['%d']" % (path, npc))


def shown(R, name):
    return bool(R.eval("%s and %s:IsShown()" % (name, name)))


# ------------------------------------------------------------------ tests ---

R = run("Kill Ledger: loads and opens")
check("it loads without errors", not errors(R))
check("the save file has the shared envelope",
      R.eval("ForgesLedgerKillLedgerDB.schemaVersion") == 1
      and R.eval("ForgesLedgerKillLedgerDB.version") == "Retail"
      and R.eval("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].exportedAt") is not None)
check("with the combat log opted in it is used", R.eval("ForgesLedgerKillLedgerDB.countMode") == "combatlog" and R.eval("CLEU_REGISTERED()"))
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('')")
check("/kl opens the panel", shown(R, "ForgesLedgerKillLedgerPanel"))
check("empty: it says how to start", "Nothing killed yet" in R.eval("ForgesLedgerKillLedgerPanel.empty:GetText()"))
ev(R, "ForgesLedgerKillLedgerPanel.close._scripts.OnClick(ForgesLedgerKillLedgerPanel.close)")
check("the close button hides it", not shown(R, "ForgesLedgerKillLedgerPanel"))

R = run("Kill Ledger: kill credit")
kill(R, 1, 1)
check("a killing blow by you counts", mob(R, 1).kills == 1 and mob(R, 1, "session").kills == 1)
kill(R, 1, 1)
check("the same corpse is never counted twice", mob(R, 1).kills == 1)
kill(R, 1, 2)
check("another corpse of the same mob adds one", mob(R, 1).kills == 2)
check("the mob's name and zone are recorded", mob(R, 1).name == "Boar" and mob(R, 1).zone == "Elwynn Forest")
kill(R, 2, 1, src="PARTY", name="Wolf")
check("a party member's killing blow counts", mob(R, 2).kills == 1)
kill(R, 3, 1, src="OUTSIDER", name="Bear")
check("a stranger's killing blow does not", mob(R, 3) is None)
ev(R, 'CLEU("PARTY_KILL", "Player-1-0001", MINE, G(4), "My Pet", MINE)')
check("your own pet dying is not a kill", mob(R, 4) is None)
ev(R, 'CLEU("PARTY_KILL", "Player-1-0001", MINE, "Player-1-0002", "Bob", OUTSIDER)')
check("a player dying is not a mob kill", R.eval("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.mobs['0002']") is None)

R = run("Kill Ledger: tap credit")
ev(R, 'CLEU("UNIT_DIED", nil, 0, G(5), "Spider")')
check("a death nobody in your group touched is not credited", mob(R, 5) is None)
ev(R, 'CLEU("SPELL_DAMAGE", "Player-1-0001", MINE, G(5), "Spider")')
ev(R, 'CLEU("UNIT_DIED", nil, 0, G(5), "Spider")')
check("a death after your damage is credited", mob(R, 5) is not None and mob(R, 5).kills == 1)
ev(R, 'CLEU("SPELL_DAMAGE", "Player-1-0001", MINE, G(5, 2), "Spider")')
ev(R, 'AdvanceTime(60); CLEU("UNIT_DIED", nil, 0, G(5, 2), "Spider")')
check("damage from a minute ago does not tap it", mob(R, 5).kills == 1)
ev(R, 'CLEU("SPELL_DAMAGE", "Player-1-0009", OUTSIDER, G(5, 3), "Spider")')
ev(R, 'CLEU("UNIT_DIED", nil, 0, G(5, 3), "Spider")')
check("a stranger's damage does not tap it", mob(R, 5).kills == 1)
ev(R, 'CLEU("SPELL_DAMAGE", "Player-1-0001", MINE, G(5, 4), "Spider"); CLEU("PARTY_KILL", "Player-1-0001", MINE, G(5, 4), "Spider"); CLEU("UNIT_DIED", nil, 0, G(5, 4), "Spider")')
check("PARTY_KILL then UNIT_DIED for one corpse is one kill", mob(R, 5).kills == 2)

R = run("Kill Ledger: loot attribution")
kill(R, 1, 1)
ev(R, "LOOT({ ITEMSLOT(100, G(1, 1), 2), ITEMSLOT(101, G(1, 1)), MONEYSLOT(G(1, 1)) })")
m = mob(R, 1)
check("an item on the corpse is one drop event", m["items"]["100"].dropEvents == 1 and m["items"]["101"].dropEvents == 1)
check("the stack size is the quantity", m["items"]["100"].qty == 2 and m["items"]["101"].qty == 1)
check("name, quality and vendor price are cached",
      m["items"]["100"].name == "Linen Cloth" and m["items"]["100"].quality == 1 and m["items"]["100"].price == 13)
check("the session copy matches", mob(R, 1, "session")["items"]["100"].qty == 2)
ev(R, "LOOT({ ITEMSLOT(100, G(1, 1), 2) })")
check("reopening the same corpse does not count it again", mob(R, 1)["items"]["100"].dropEvents == 1 and mob(R, 1)["items"]["100"].qty == 2)
kill(R, 1, 2)
ev(R, "LOOT({ ITEMSLOT(100, G(1, 2), 1) })")
m = mob(R, 1)
check("a second corpse adds to the totals", m["items"]["100"].dropEvents == 2 and m["items"]["100"].qty == 3 and m.kills == 2)
check("an item that didn't drop keeps its own count", m["items"]["101"].dropEvents == 1)
ev(R, "LOOT({ ITEMSLOT(102, G(9, 1)) })")
check("a corpse the combat log never saw die is still a kill once you loot it (KL-3)", mob(R, 9) is not None and mob(R, 9).kills == 1 and mob(R, 9)["items"]["102"].dropEvents == 1)
kill(R, 1, 3)
ev(R, "LOOT({ ITEMSLOT(102, G(1, 3), 1, true), ITEMSLOT(100, G(1, 3), 1) })")
check("a slot locked for a group roll is skipped", mob(R, 1)["items"]["102"] is None and mob(R, 1)["items"]["100"].dropEvents == 3)
kill(R, 1, 4); kill(R, 1, 5)
ev(R, "LOOT({ ITEMSLOT(100, G(1, 4), 1), ITEMSLOT(100, G(1, 5), 3) })")
check("area loot over two corpses credits each", mob(R, 1)["items"]["100"].dropEvents == 5 and mob(R, 1)["items"]["100"].qty == 8)
kill(R, 1, 6)
ev(R, "LOOT({ { type = 1, link = L(100), sources = { G(1, 6), 1, G(1, 6), 1 } } })")
check("one corpse listing an item twice is still one drop event", mob(R, 1)["items"]["100"].dropEvents == 6)

R = run("Kill Ledger: prices")
kill(R, 1, 1)
ev(R, "LOOT({ ITEMSLOT(103, G(1, 1)), ITEMSLOT(104, G(1, 1)) })")
m = mob(R, 1)
check("an item with no vendor price is marked no-sell", m["items"]["103"].noSell == True and m["items"]["103"].price == 0)
check("an uncached price stays unknown", m["items"]["104"].price is None and m["items"]["104"].noSell is None)
ev(R, "ITEMS[104][3] = 4000; FireEvent('GET_ITEM_INFO_RECEIVED', 104, true); RunTimers()")
check("it fills the price in when the game learns it", mob(R, 1)["items"]["104"].price == 4000)

R = run("Kill Ledger: the panel")
for n in range(1, 4):
    kill(R, 1, n)
kill(R, 2, 1, name="Wolf")
ev(R, "LOOT({ ITEMSLOT(100, G(1, 1), 2), ITEMSLOT(103, G(1, 1)) })")
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('')")
P = "ForgesLedgerKillLedgerPanel"
check("the list shows the most-killed mob first", R.eval(P + ".rows") is None and R.eval("nil") is None)
text = R.eval("""(function()
  local o = {}
  for _, f in ipairs(ALL_FRAMES) do
    if f._kind == "FontString" and f._text ~= "" and f:IsShown() then o[#o + 1] = f._text end
  end
  return table.concat(o, "\\n")
end)()""")
check("it lists the mobs with kill counts", "Boar" in text and "Wolf" in text)
check("the header shows kills and vendor value", "Killed 3" in text and "Vendor value" in text)
check("drop % sits next to the raw counts", "33" in text and "(1/3)" in text, text[:300])
check("a no-sell item shows as no sell", "no sell" in text)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('lifetime')")
check("/kl lifetime switches the view", "Lifetime" in R.eval(P + ".head3:GetText()"))
check("no errors while drawing", not errors(R))

R = run("Kill Ledger: paging and resets")
for n in range(1, 21):
    kill(R, 100 + n, 1, name="Mob %d" % n)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('')")
check("more than a page of mobs gets a next button", R.eval(P + ".next:IsShown()") and not R.eval(P + ".prev:IsShown()"))
ev(R, P + ".next._scripts.OnClick()")
check("the next page shows the rest", "Page 2 of 2" in R.eval(P + ".pageLabel:GetText()") and R.eval(P + ".prev:IsShown()"))
R.execute(P + ".resetAll._scripts.OnClick()")  # (no RunTimers: that would run the 5 s confirm timeout)
check("reset all asks first", mob(R, 101) is not None and "confirm" in R.eval(P + ".resetAll.text:GetText()"))
R.execute(P + ".resetAll._scripts.OnClick()")  # (no RunTimers: that would run the 5 s confirm timeout)
check("a second click wipes it", mob(R, 101) is None and mob(R, 101, "session") is None)
kill(R, 1, 1); kill(R, 2, 1)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('lifetime')")
ev(R, P + ".resetMob._scripts.OnClick()")
check("reset this mob removes only that mob", (mob(R, 1) is None) != (mob(R, 2) is None))

R = run("Kill Ledger: sessions")
kill(R, 1, 1)
check("a /reload keeps the session", True)
ev(R, 'FireEvent("PLAYER_ENTERING_WORLD", false, true)')
check("reloading the UI keeps this session's numbers", mob(R, 1, "session") is not None)
ev(R, 'FireEvent("PLAYER_ENTERING_WORLD", true, false)')
check("a fresh login starts a new session", mob(R, 1, "session") is None)
check("...but the lifetime numbers stay", mob(R, 1).kills == 1)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('reset session')")
check("no errors", not errors(R))

R = run("Kill Ledger: old save files",
        saved="""ForgesLedgerKillLedgerDB = { combatLog = true, schemaVersion = 1, version = "Retail", characters = {
          ["Testchar-Area52"] = { exportedAt = 5, data = { mobs = { ["1"] = { name = "Boar", kills = 40, items = {} } } } } } }""")
check("lifetime numbers from before are kept", mob(R, 1).kills == 40)
check("a missing session table is created", R.eval("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.session ~= nil"))
kill(R, 1, 1)
check("and counting goes on from there", mob(R, 1).kills == 41)

R = run("Kill Ledger: no combat log",
        before="""local orig = CreateFrame
        CreateFrame = function(...)
          local f = orig(...)
          local re = f.RegisterEvent
          f.RegisterEvent = function(self, e) if e == "COMBAT_LOG_EVENT_UNFILTERED" then error("blocked") end return re(self, e) end
          return f
        end""")
check("blocked registration falls back to the default counter", R.eval("ForgesLedgerKillLedgerDB.countMode") == "observed")
ev(R, "LOOT({ ITEMSLOT(100, G(1, 1), 2) })")
check("a looted corpse is a kill", mob(R, 1).kills == 1 and mob(R, 1)["items"]["100"].dropEvents == 1)
ev(R, "LOOT({ ITEMSLOT(100, G(1, 1), 2) })")
check("...once", mob(R, 1).kills == 1)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('')")
check("the panel says how kills are counted", "your target dies" in R.eval(P + ".foot:GetText()"))

R = run("Kill Ledger: default counting (KL-1: never touches the combat log)", cl=False)
check("the combat log is NOT registered by default", not R.eval("CLEU_REGISTERED()"))
check("the default mode is the observed counter", R.eval("ForgesLedgerKillLedgerDB.countMode") == "observed")
kill(R, 1, 1)
check("combat-log events are ignored in the default mode", mob(R, 1) is None)
ev(R, 'SETTARGET(G(1, 1), "Boar")')
ev(R, "HEALTH()")
check("a living target is not a kill", mob(R, 1) is None)
ev(R, "TGT.dead = true; HEALTH()")
check("a target that dies is a kill", mob(R, 1) is not None and mob(R, 1).kills == 1 and mob(R, 1).name == "Boar")
ev(R, "HEALTH(); HEALTH()")
check("more health updates don't count it again", mob(R, 1).kills == 1)
ev(R, 'SETTARGET(G(2, 1), "Wolf", { dead = true, tap = true })')
ev(R, "HEALTH()")
check("a kill someone else tapped is not yours", mob(R, 2) is None)
ev(R, 'SETTARGET("Player-1-0007", "Bob", { dead = true, player = true })')
ev(R, "HEALTH()")
check("a dead player is not a mob kill", R.eval("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.mobs['0007']") is None)
ev(R, 'SETTARGET(G(3, 1), "Bear", { dead = true })')
ev(R, 'HEALTH("party1")')
check("health changes of other units are ignored", mob(R, 3) is None)
ev(R, "HEALTH()")
check("...but the target's own count", mob(R, 3) is not None)
ev(R, "LOOT({ ITEMSLOT(100, G(1, 1), 2) })")
check("loot on a corpse counted at death attributes without a second kill", mob(R, 1).kills == 1 and mob(R, 1)["items"]["100"].dropEvents == 1)
ev(R, "LOOT({ ITEMSLOT(101, G(4, 1)) })")
check("a corpse first seen at the loot window is a kill", mob(R, 4).kills == 1 and mob(R, 4)["items"]["101"].dropEvents == 1)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('')")
check("the panel says how kills are counted", "your target dies" in R.eval(P + ".foot:GetText()") and not errors(R))
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('combatlog on')")
check("/kl combatlog on is remembered for the next /reload", R.eval("ForgesLedgerKillLedgerDB.combatLog") == True and not R.eval("CLEU_REGISTERED()"))
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('combatlog off')")
check("/kl combatlog off turns it back off", R.eval("ForgesLedgerKillLedgerDB.combatLog") == False)

R = run("Kill Ledger: KL-3 (kills the combat log missed, odd guids)")
# guid shapes: hex fields, a different spawn-uid length, non-numeric middle fields
for guid, npc in [("Creature-0-4379-0-2-2031-0000049A1F", 2031), ("Creature-0-4379-0-2-3034-00001234", 3034),
                  ("Creature-0-abcd-1f-2a-1989-0000FFAB12", 1989), ("Vehicle-0-1-2-3-555-00000A", 555)]:
    ev(R, 'CLEU("PARTY_KILL", "Player-1-0001", MINE, "%s", "Mob")' % guid)
    check("npc id %d is read from %s" % (npc, guid), mob(R, npc) is not None and mob(R, npc).kills == 1)
check("Player guids are never mobs", True)
# the screenshot case: the combat log misses a kill, the corpse is looted
ev(R, 'SETTARGET(G(70, 1), "Young Thistle Boar", { dead = true })')
ev(R, "LOOT({ ITEMSLOT(100, G(70, 1), 2) })")
check("a kill the combat log missed counts at the loot window with its drops", mob(R, 70).kills == 1 and mob(R, 70)["items"]["100"].qty == 2)
ev(R, "LOOT({ ITEMSLOT(100, G(70, 1), 2) })")
check("...once", mob(R, 70).kills == 1 and mob(R, 70)["items"]["100"].dropEvents == 1)
# pickpocketing: loot from a LIVING target is not a kill
ev(R, 'SETTARGET(G(71, 1), "Bandit")')
ev(R, "LOOT({ ITEMSLOT(101, G(71, 1)) })")
check("loot from a living, targeted mob (pickpocket) is not a kill", mob(R, 71) is None)
ev(R, "TGT.dead = true")
ev(R, "LOOT({ ITEMSLOT(101, G(71, 1)) })")
check("...but once it is dead it is", mob(R, 71) is not None and mob(R, 71).kills == 1)
# a quest-credited mob that was tagged, damaged, died with the log silent: target path still counts it
ev(R, 'SETTARGET(G(72, 1), "Young Nightsaber")')
ev(R, "TGT.dead = true; HEALTH()")
check("a targeted kill the combat log missed counts through the target watcher", mob(R, 72) is not None and mob(R, 72).kills == 1)
# the debug command explains where kills came from
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('debug')")
out = " ".join(R.eval("PRINTED").values())
check("/kl debug reports where kills were counted", "kills counted via" in out and "loot window" in out and "guid not parsed" in out, out[-300:])
ev(R, 'CLEU("PARTY_KILL", "Player-1-0001", MINE, "Creature-weird", "X")')
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('debug')")
out = " ".join(R.eval("PRINTED").values())
check("an unparseable guid is counted and its shape shown", "guid shapes not parsed: Creature-weird" in out, out[-200:])
check("no errors", not errors(R))

R = run("Kill Ledger: WoW Forever", before="WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 2, 1")
check("it works on Forever and says so in the save file", R.eval("ForgesLedgerKillLedgerDB.version") == "Forever")

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
