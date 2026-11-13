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
  return it[1], link, it[2], 1, 1, "Misc", "Junk", 1, "", 100000 + id, it[3]
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
HYPER, SOUNDS = nil, {}
GameTooltip.SetHyperlink = function(self, l) HYPER = l end
function PlaySound(id) table.insert(SOUNDS, id) end
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
check("the list shows the most-killed mob first", R.eval(P + ".rows[1].name:GetText()") == "Boar")
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

# ======================================================= UI build (Luna's spec) ===
P = "ForgesLedgerKillLedgerPanel"


def row_names(R, which="rows"):
    return list(R.eval("(function() local o = {} for _, r in ipairs(%s.%s) do if r._shown then o[#o + 1] = r.name:GetText() end end return o end)()" % (P, which)).values())


def texts(R):
    return R.eval("""(function()
      local o = {}
      for _, f in ipairs(ALL_FRAMES) do
        if f._kind == "FontString" and f._text ~= "" and f:IsShown() then o[#o + 1] = f._text end
      end
      return table.concat(o, "\\n")
    end)()""")


def slash(R, cmd):
    ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER(%s)" % ("[=[" + cmd + "]=]"))


R = run("Kill Ledger UI: mob rows, sort, zone, colored drop %")
for n, (npc, name) in enumerate([(1, "Boar"), (2, "Wolf"), (3, "Bear")], 1):
    ev(R, "AdvanceTime(10)")
    for k in range(1, 4 - n + 1):
        kill(R, npc, k, name=name)
ev(R, "LOOT({ ITEMSLOT(100, G(2, 1), 1) })")
slash(R, "")
names = row_names(R)
check("default order: most kills first", names[0] == "Boar" and names[-1] == "Bear", names)
rowtxt = texts(R)
check("each mob row shows its zone", "Elwynn Forest" in rowtxt)
check("each mob row shows its vendor total and top drop", "top" in rowtxt)
topn = [R.eval("%s.rows[%d].top:GetText()" % (P, i)) for i in (1, 2, 3)]
check("the top drop % is colored and sits beside the raw count", any("|cff" in t and "(1/2)" in t for t in topn), topn)
ev(R, "%s.sortBtn._scripts.OnClick()" % P)
names = row_names(R)
check("Sort: recent puts the newest kill first", names[0] == "Bear" and "recent" in R.eval("%s.sortBtn.text:GetText()" % P), names)
ev(R, "%s.sortBtn._scripts.OnClick()" % P)
check("and back to most kills", row_names(R)[0] == "Boar")
slash(R, "sort recent")
check("/kl sort recent does the same", row_names(R)[0] == "Bear" and R.eval("ForgesLedgerKillLedgerDB.ui.sort") == "recent")
check("no errors", not errors(R))

R = run("Kill Ledger UI: mob search")
for npc, name in [(1, "Stonetusk Boar"), (2, "Timber Wolf"), (3, "Young Wolf")]:
    kill(R, npc, 1, name=name)
slash(R, "")
ev(R, '%s.search:SetText("wolf"); %s.search._scripts.OnTextChanged(%s.search)' % (P, P, P))
names = sorted(row_names(R))
check("typing in the search box filters the mob list", names == ["Timber Wolf", "Young Wolf"], names)
check("the hint hides while there is text", not R.eval("%s.searchHint:IsShown()" % P))
ev(R, '%s.search:SetText("elwynn"); %s.search._scripts.OnTextChanged(%s.search)' % (P, P, P))
check("the search reads zones too", len(row_names(R)) == 3)
ev(R, '%s.search:SetText("zzz"); %s.search._scripts.OnTextChanged(%s.search)' % (P, P, P))
check("no match says so", "No mob matches" in R.eval("%s.empty:GetText()" % P) and len(row_names(R)) == 0)
ev(R, '%s.search._scripts.OnEscapePressed(%s.search)' % (P, P))
ev(R, '%s.search._scripts.OnTextChanged(%s.search)' % (P, P))
check("Escape clears the box", len(row_names(R)) == 3 and R.eval("%s.searchHint:IsShown()" % P))

R = run("Kill Ledger UI: drop rows - icons, tooltips, paging")
ev(R, "for i = 300, 329 do ITEMS[i] = { 'Thing ' .. i, 1, 5 } end")
kill(R, 7, 1, name="Hoarder")
ev(R, "local s = {} for i = 300, 329 do s[#s + 1] = ITEMSLOT(i, G(7, 1)) end LOOT(s)")
slash(R, "")
ev(R, "%s.rows[1]._scripts.OnClick(%s.rows[1])" % (P, P))
n_shown = len(row_names(R, "irows"))
check("12 drop rows on the first page", n_shown == 12, n_shown)
check("the footer line says which items are shown", "Items 1-12 of 30" in R.eval("%s.ipage:GetText()" % P))
ic = R.eval("%s.irows[1].icon._tex" % P)
check("an item row has its icon", ic is not None and ic >= 100000, ic)
ev(R, "%s.irows[1]._scripts.OnEnter(%s.irows[1])" % (P, P))
check("hovering a drop row asks for the real item tooltip", str(R.eval("HYPER")).startswith("item:3"), R.eval("HYPER"))
ev(R, "%s.inext._scripts.OnClick()" % P)
check("the next page shows items 13-24", "Items 13-24 of 30" in R.eval("%s.ipage:GetText()" % P))
ev(R, "%s.inext._scripts.OnClick(); %s.inext._scripts.OnClick()" % (P, P))
check("the last page shows the remaining 6", "Items 25-30 of 30" in R.eval("%s.ipage:GetText()" % P) and len(row_names(R, "irows")) == 6)
check("no errors", not errors(R))

R = run("Kill Ledger UI: the session strip")
slash(R, "")
strip = R.eval("%s.strip:GetText()" % P)
check("the strip shows an empty session", "Session" in strip and "0 kills" in strip, strip)
kill(R, 1, 1, name="Boar")
ev(R, "LOOT({ ITEMSLOT(101, G(1, 1), 2) })")
strip = R.eval("%s.strip:GetText()" % P)
check("kills and vendor gold show at once", "1 kills" in strip, strip)
check("under a minute the pace says so", "per hour: soon" in strip, strip)
ev(R, "AdvanceTime(1800)")
ev(R, "%s._scripts.OnUpdate(%s, 1.2)" % (P, P))
strip = R.eval("%s.strip:GetText()" % P)
check("the strip ticks by itself and shows the duration", "30m" in strip, strip)
check("...and gold per hour once there is a minute of data", "per hour" in strip and "soon" not in strip, strip)
slash(R, "lifetime")
check("the strip stays visible on the Lifetime view", "Session" in R.eval("%s.strip:GetText()" % P))

R = run("Kill Ledger UI: the view is remembered across logins")
slash(R, "lifetime")
slash(R, "sort recent")
saved = R.eval("ForgesLedgerKillLedgerDB.ui")
check("the view and sort are saved", saved["scope"] == "lifetime" and saved["sort"] == "recent")
R = run("Kill Ledger UI: ...and restored", saved="""ForgesLedgerKillLedgerDB = { combatLog = true, ui = { scope = "lifetime", sort = "recent" } }""")
slash(R, "")
check("it opens on Lifetime, sorted by recent", "Lifetime" in R.eval("%s.head3:GetText()" % P) and "recent" in R.eval("%s.sortBtn.text:GetText()" % P))

R = run("Kill Ledger UI: the loot wishlist")
slash(R, "wishlist")
check("/kl wishlist says when it is empty", "empty" in " ".join(R.eval("PRINTED").values()))
ev(R, "PRINTED = {}")
slash(R, "wish " + "|cffffffff|Hitem:104::::::::1:::::::::|h[Strange Gem]|h|r")
check("/kl wish [item link] adds it", R.eval("ForgesLedgerKillLedgerDB.wishlist['104'] ~= nil") and "Added" in " ".join(R.eval("PRINTED").values()), R.eval("PRINTED"))
ev(R, "PRINTED = {}")
slash(R, "wishlist")
check("/kl wishlist lists it in chat", "Strange Gem" in " ".join(R.eval("PRINTED").values()), list(R.eval("PRINTED").values()))
slash(R, "wish 100")
check("an item number works too", R.eval("ForgesLedgerKillLedgerDB.wishlist['100'] ~= nil"))
slash(R, "wish 100")
check("the same command again removes it", R.eval("ForgesLedgerKillLedgerDB.wishlist['100'] == nil"))
slash(R, "unwish 104")
check("/kl unwish removes", R.eval("ForgesLedgerKillLedgerDB.wishlist['104'] == nil"))

# drops
kill(R, 1, 1, name="Boar"); kill(R, 1, 2, name="Boar")
slash(R, "wish 101")
ev(R, "SOUNDS = {}; LOOT({ ITEMSLOT(100, G(1, 1), 1) })")
check("an item that is NOT wishlisted gives no toast", not shown(R, "ForgesLedgerKillLedgerToast") and R.eval("#SOUNDS") == 0)
ev(R, "LOOT({ ITEMSLOT(101, G(1, 2), 2) })")
check("a wishlisted drop shows a toast", shown(R, "ForgesLedgerKillLedgerToast"))
check("...with the item, the count and the mob", "Worn Dagger" in R.eval("ForgesLedgerKillLedgerToast.item:GetText()") and "from Boar" in R.eval("ForgesLedgerKillLedgerToast.sub:GetText()"), R.eval("ForgesLedgerKillLedgerToast.sub:GetText()"))
check("...and a sound", R.eval("#SOUNDS") == 1)
ev(R, "LOOT({ ITEMSLOT(101, G(1, 2), 2) })")
check("reopening the same corpse does not toast again", R.eval("#SOUNDS") == 1)
T = "ForgesLedgerKillLedgerToast"
ev(R, "%s._scripts.OnUpdate(%s, 0.1)" % (T, T))
a1 = R.eval("%s._alpha" % T)
ev(R, "%s._scripts.OnUpdate(%s, 1.0)" % (T, T))
check("the toast fades in and holds", a1 is not None and a1 < 1 and R.eval("%s._alpha" % T) == 1, a1)
ev(R, "%s._scripts.OnUpdate(%s, 5)" % (T, T))
check("then it goes away by itself", not shown(R, T))
# AoE loot over two corpses: one toast, summed
ev(R, "SOUNDS = {}")
kill(R, 1, 3, name="Boar"); kill(R, 1, 4, name="Boar")
ev(R, "LOOT({ ITEMSLOT(101, G(1, 3), 1), ITEMSLOT(101, G(1, 4), 2) })")
check("AoE loot of the same wishlisted item gives ONE toast with the total", R.eval("#SOUNDS") == 1 and " x3" in R.eval("%s.item:GetText()" % T), R.eval("%s.item:GetText()" % T))
ev(R, "%s._scripts.OnUpdate(%s, 9)" % (T, T))
# two different wishlisted items in one window: shown one at a time
slash(R, "wish 100")
ev(R, "SOUNDS = {}")
kill(R, 1, 5, name="Boar")
ev(R, "LOOT({ ITEMSLOT(100, G(1, 5), 1), ITEMSLOT(101, G(1, 5), 1) })")
check("two wishlisted items: the first shows, the second waits its turn", R.eval("#SOUNDS") == 1, R.eval("#SOUNDS"))
ev(R, "%s._scripts.OnUpdate(%s, 9)" % (T, T))
check("...and the second follows", R.eval("#SOUNDS") == 2, R.eval("#SOUNDS"))
ev(R, "%s._scripts.OnUpdate(%s, 9)" % (T, T))
check("...then it is gone", not shown(R, T))

# the window
slash(R, "")
ev(R, "%s.tabWish._scripts.OnClick()" % P)
wn = row_names(R, "wrows")
check("the Wishlist tab lists the entries", len(wn) == 2, wn)
ev(R, "%s.wrows[1].remove._scripts.OnClick()" % P)
check("Remove takes one off", len(row_names(R, "wrows")) == 1)
ev(R, "%s.tabSession._scripts.OnClick()" % P)
ev(R, "%s.rows[1]._scripts.OnClick(%s.rows[1])" % (P, P))
wid = R.eval("%s.irows[1].id" % P)
was = R.eval("ForgesLedgerKillLedgerDB.wishlist[%s.irows[1].id] ~= nil" % P)
ev(R, "%s.irows[1].wish._scripts.OnClick()" % P)
now = R.eval("ForgesLedgerKillLedgerDB.wishlist[%r] ~= nil" % wid)
check("the Wish button on a drop row toggles that item", now != was, (wid, was, now))
check("no errors", not errors(R))

R = run("Kill Ledger UI: the wishlist is saved", saved="""ForgesLedgerKillLedgerDB = { combatLog = true, wishlist = { ["101"] = { name = "Worn Dagger", addedAt = 5 } } }""")
kill(R, 1, 1, name="Boar")
ev(R, "SOUNDS = {}; LOOT({ ITEMSLOT(101, G(1, 1), 1) })")
check("a wishlist from an earlier session still celebrates", R.eval("#SOUNDS") == 1)

R = run("Kill Ledger UI: pace in the export for the dashboard")
kill(R, 1, 1, name="Boar")
ev(R, "LOOT({ ITEMSLOT(101, G(1, 1), 4) })")
ev(R, "AdvanceTime(3600)")
kill(R, 1, 2, name="Boar")
pace = R.eval("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.session.pace")
check("pace: kills, value, seconds and per hour", pace["kills"] == 2 and pace["value"] == 4 * 250 and pace["seconds"] >= 3600 and pace["perHour"] is not None, dict(pace))
check("per hour is value / hours", abs(pace["perHour"] - 1000) <= 2, pace["perHour"])

R = run("Kill Ledger: WoW Forever", before="WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 2, 1")
check("it works on Forever and says so in the save file", R.eval("ForgesLedgerKillLedgerDB.version") == "Forever")

# ---------------------------------------------------------------- item search ---
R = run("Kill Ledger UI: item search ranked by drop chance")
# Boar 1/4 = 25%, Wolf 2/4 = 50%, Cat 1/2 = 50% (tie with Wolf, fewer kills), Bear 1/1 = 100%
for n in range(1, 5): kill(R, 1, n, name="Boar")
for n in range(1, 5): kill(R, 2, n, name="Wolf")
for n in range(1, 3): kill(R, 3, n, name="Cat")
kill(R, 4, 1, name="Bear")
ev(R, "LOOT({ ITEMSLOT(101, G(1, 1), 1) })")
ev(R, "LOOT({ ITEMSLOT(101, G(2, 1), 1) })"); ev(R, "LOOT({ ITEMSLOT(101, G(2, 2), 1) })")
ev(R, "LOOT({ ITEMSLOT(101, G(3, 1), 1) })")
ev(R, "LOOT({ ITEMSLOT(101, G(4, 1), 1) })")
ev(R, "LOOT({ ITEMSLOT(102, G(1, 2), 2) })")
# an older mob that only exists in lifetime
ev(R, "ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.mobs['9'] = { name = 'Old Boar', zone = 'Westfall', kills = 10, items = { ['101'] = { name = 'Worn Dagger', dropEvents = 9, qty = 9, price = 250, quality = 2 } } }")
slash(R, "")
ev(R, "%s.tabItem._scripts.OnClick()" % P)
check("the Find item tab opens the item search", R.eval("%s.isearch:IsShown()" % P) and not R.eval("%s.search:IsShown()" % P))
check("the mob list is hidden while searching items", not any(R.eval("%s.rows[%d]:IsShown()" % (P, i)) for i in range(1, 13)))
check("empty search says what to do", "Type an item name" in R.eval("%s.iempty:GetText()" % P))

def isearch(text):
    ev(R, "%s.isearch:SetText(%r)" % (P, text))
    ev(R, "%s.isearch._scripts.OnTextChanged(%s.isearch)" % (P, P))

isearch("WORN")
check("partial, case-insensitive match finds the item", row_names(R, "mrows") == ["Worn Dagger"], row_names(R, "mrows"))
isearch("e")
check("a short partial lists several matching items", len(row_names(R, "mrows")) >= 2, row_names(R, "mrows"))
isearch("worn")
check("the first match is selected and the best source named", R.eval("%s.sname:GetText()" % P) == "Worn Dagger" and "Best source: Bear" in R.eval("%s.ssub:GetText()" % P), R.eval("%s.ssub:GetText()" % P))
mobs_ = row_names(R, "srows")
check("one item across several mobs: ranked by drop %, tie goes to more kills", mobs_ == ["Bear", "Wolf", "Cat", "Boar"], mobs_)
t2 = R.eval("%s.srows[2].pct:GetText()" % P)
check("drop % sits beside the raw n/kills", "50%" in t2 and "(2/4)" in t2, t2)
check("the best source row is highlighted, the others are not", R.eval("%s.srows[1].best._shown" % P) and not R.eval("%s.srows[2].best._shown" % P))
check("each row has avg qty and vendor price", R.eval("%s.srows[1].avg:GetText()" % P) == "1.0" and R.eval("%s.srows[1].each:GetText()" % P) != "?", R.eval("%s.srows[1].each:GetText()" % P))
check("the scope line says it is only his recorded data", "not a drop database" in R.eval("%s.foot:GetText()" % P))
check("the session view does not show the mob that is lifetime-only", "Old Boar" not in row_names(R, "srows"))
ev(R, "%s.tabLife._scripts.OnClick()" % P)
check("scope switch keeps the item search open", R.eval("%s.isearch:IsShown()" % P))
life = row_names(R, "srows")
check("Lifetime adds the older mob and ranks it by drop % (90%, behind Bear's 100%)", life == ["Bear", "Old Boar", "Wolf", "Cat", "Boar"], life)
ev(R, "%s.tabSession._scripts.OnClick()" % P)
before = R.eval("ForgesLedgerKillLedgerDB.wishlist and ForgesLedgerKillLedgerDB.wishlist['101'] ~= nil") or False
ev(R, "%s.srows[1].wish._scripts.OnClick()" % P)
check("Wish on a result row wishlists the item", R.eval("ForgesLedgerKillLedgerDB.wishlist['101'] ~= nil") and not before)
check("...and the row now reads On list", R.eval("%s.srows[3].wish.text:GetText()" % P) == "On list")
ev(R, "%s.srows[2].wish._scripts.OnClick()" % P)
check("pressing it again removes it", R.eval("ForgesLedgerKillLedgerDB.wishlist['101'] == nil"))
isearch("crawler")
check("a different item lists its own mob", row_names(R, "srows") == ["Boar"], row_names(R, "srows"))
isearch("zzz")
check("no match says it has not dropped yet in this view", "has not dropped for you yet" in R.eval("%s.iempty:GetText()" % P) and "this session" in R.eval("%s.iempty:GetText()" % P), R.eval("%s.iempty:GetText()" % P))
check("...and shows no result rows", row_names(R, "srows") == [] and row_names(R, "mrows") == [])
isearch("worn")
ev(R, "%s.srows[2]._scripts.OnClick(%s.srows[2])" % (P, P))
check("clicking a result mob opens that mob's detail", not R.eval("%s.isearch:IsShown()" % P) and R.eval("%s.dname:GetText()" % P) == "Wolf", R.eval("%s.dname:GetText()" % P))
ev(R, "%s.tabItem._scripts.OnClick()" % P)
ev(R, "%s.tabItem._scripts.OnClick()" % P)
check("the Find item tab toggles back to the mob view", R.eval("%s.search:IsShown()" % P))
ev(R, "%s.tabWish._scripts.OnClick()" % P)
check("the Wishlist tab closes the item search", not R.eval("%s.isearch:IsShown()" % P))
ev(R, "%s.tabItem._scripts.OnClick()" % P)
check("opening Find item from the Wishlist returns to the item search", R.eval("%s.isearch:IsShown()" % P) and R.eval("%s.wishEmpty:IsShown()" % P) is False)
check("no errors", not errors(R))

# ------------------------------------------------------------ enemy hover tooltip ---
TIPWORLD = r'''
POSTCALLS = {}
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) POSTCALLS[kind] = fn end }
Enum = { TooltipDataType = { Unit = 2 } }
MOUSE = nil   -- { guid =, player = }
local realGUID = UnitGUID
function UnitGUID(u) if u == "mouseover" then return MOUSE and MOUSE.guid end return realGUID(u) end
local realIsPlayer = UnitIsPlayer
function UnitIsPlayer(u) if u == "mouseover" then return MOUSE ~= nil and MOUSE.player == true end return realIsPlayer(u) end
TIP = { lines = {}, GetUnit = function() return "name", "mouseover" end,
        AddLine = function(self, t) table.insert(self.lines, t) end,
        AddDoubleLine = function(self, a, b) table.insert(self.lines, a .. " || " .. b) end }
function HOVER(guid, player) MOUSE = guid and { guid = guid, player = player or false } or nil; TIP.lines = {}; POSTCALLS[2](TIP) end
'''
R = run("Kill Ledger: enemy hover tooltip", before=TIPWORLD)
check("the tooltip is hooked through the unit post-call", R.eval("POSTCALLS[2]") is not None)
for n in range(1, 5): kill(R, 1, n, name="Boar")
ev(R, "LOOT({ ITEMSLOT(101, G(1, 1), 1) })"); ev(R, "LOOT({ ITEMSLOT(101, G(1, 2), 1) })")
ev(R, "LOOT({ ITEMSLOT(102, G(1, 3), 1) })"); ev(R, "LOOT({ ITEMSLOT(103, G(1, 4), 1) })")
def tip(guid=None, player=False):
    R.execute("HOVER(%s, %s)" % (("G(%s)" % guid) if guid else "nil", "true" if player else "false"))
    return list(R.eval("TIP.lines").values())
lines = tip("1, 9")
check("a mob with data gets a header with its lifetime kills", lines and "Kill Ledger" in lines[0] and "4 kills" in lines[0], lines)
check("drops are ranked by drop %, highest first", "Worn Dagger" in lines[1] and "Crawler Meat" in lines[2], lines)
check("drop % sits beside the raw drops/kills", "50%" in lines[1] and "(2/4)" in lines[1], lines[1])
check("the vendor price is on the line", "2" in lines[1].split("||")[1], lines[1])
check("a no-sell item says so", any("Torn Map" in l and "no sell" in l for l in lines) or any("Torn Map" in l for l in lines), lines)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('wish 101')")
lines = tip("1, 9")
check("a wishlisted drop is marked", "wish" in lines[1] and "wish" not in lines[2], lines)
R2 = run("Kill Ledger: tooltip with many drops", before=TIPWORLD)
kill(R2, 5, 1, name="Hoarder")
R2.execute("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.mobs['5'].items = { }")
for i in range(1, 8):
    R2.execute("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.mobs['5'].items['%d'] = { name = 'Item %d', dropEvents = 1, qty = 1, price = 10, quality = 1 }" % (200 + i, i))
R2.execute("HOVER(G(5, 1))")
l2 = list(R2.eval("TIP.lines").values())
check("at most 5 drops are listed, then '+N more'", len(l2) == 1 + 5 + 1 and "+2 more" in l2[-1], l2)
check("tie on % keeps a stable order (name)", "Item 1" in l2[1] and "Item 5" in l2[5], l2)
check("no recorded data adds no lines at all", tip("7, 1") == [])
check("a player unit adds no lines", tip("1, 9", player=True) == [])
R.execute("HOVER('Player-1-0001', false)")
check("a non-creature guid adds no lines", list(R.eval("TIP.lines").values()) == [])
check("no unit under the mouse adds no lines", tip(None) == [])
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('tooltip off')")
check("tooltip off adds no lines", tip("1, 9") == [])
check("the setting is saved", R.eval("ForgesLedgerKillLedgerDB.tooltip") is False)
ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER('tooltip on')")
check("tooltip on brings them back", len(tip("1, 9")) > 1 and R.eval("ForgesLedgerKillLedgerDB.tooltip") is True)
R3 = run("Kill Ledger: tooltip setting survives a login", before=TIPWORLD, saved="ForgesLedgerKillLedgerDB = { combatLog = true, tooltip = false }")
kill(R3, 1, 1, name="Boar")
R3.execute("HOVER(G(1, 9))")
check("a saved 'off' is respected after login", R3.eval("ForgesLedgerKillLedgerDB.tooltip") is False and list(R3.eval("TIP.lines").values()) == [])
R4 = run("Kill Ledger: old save without the setting", before=TIPWORLD)
kill(R4, 1, 1, name="Boar")
R4.execute("HOVER(G(1, 9))")
check("a save with no setting defaults to on", len(list(R4.eval("TIP.lines").values())) >= 1)
check("no errors", not errors(R) and not errors(R2) and not errors(R4))

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
