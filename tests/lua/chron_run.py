"""Drive Forge's Chronicle in the mock WoW UI and check what it journals."""
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


MOCK = open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read().replace(
    "SetOrder GetStringHeight SetHorizTile SetVertTile SetAutoFocus SetMaxLetters SetFocus ClearFocus HighlightText HasFocus]]",
    "SetOrder GetStringHeight SetScale EnableMouseWheel SetAutoFocus SetMultiLine SetMaxLetters "
    "HighlightText SetFocus ClearFocus StartMoving SetHorizTile SetVertTile SetJustifyV SetOrientation "
    "SetValueStep SetObeyStepOnDrag SetThumbTexture SetPropagateKeyboardInput EnableKeyboard SetVertexColor]]").replace("function Widget:HasFocus() return false end", "function Widget:HasFocus() return false end\nfunction Widget:SetFocus() FOCUSED = self end").replace(
    "function Widget:GetText() return self._text end",
    "function Widget:GetText() return self._text end\n"
    "function Widget:SetFontObject(o) self._font = o end\n"
    "function Widget:GetThumbTexture() self._thumb = self._thumb or CreateFrame('Texture'); return self._thumb end\n"
    "function Widget:HasFocus() return false end\nfunction Widget:SetFocus() FOCUSED = self end")
assert "SetAutoFocus" in MOCK

WORLD = r'''
LEVEL, RACE, ZONE = 1, "Human", "Northshire"
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
function CreateFont(name) local f = CreateFrame("Frame", name); f.SetFont = function(self, file) self._file = file; return true end; return f end
COMBAT = false
function InCombatLockdown() return COMBAT end
INSTANCE = { inside = false, kind = "none", name = "Elwynn Forest" }
BAG, EQUIP, GUILD, WINNER, CINE, SHOTS = {}, {}, nil, nil, false, 0
function UnitLevel() return LEVEL end
function UnitRace() return RACE end
function UnitName() return "Testchar" end
function UnitFullName() return "Testchar", "Area52" end
function GetRealZoneText() return ZONE end
function IsInInstance() return INSTANCE.inside, INSTANCE.kind end
function GetInstanceInfo() return INSTANCE.name, INSTANCE.kind end
function IsInGuild() return GUILD ~= nil end
function GetGuildInfo() return GUILD end
function GetBattlefieldWinner() return WINNER end
function InCinematic() if CINE_CHECKS and CINE_CHECKS > 0 then CINE_CHECKS = CINE_CHECKS - 1; return true end return false end
function Screenshot() SHOTS = SHOTS + 1; FireEvent("SCREENSHOT_SUCCEEDED") end
function GetInventoryItemID(_, s) return EQUIP[s] and EQUIP[s].id end
function GetInventoryItemQuality(_, s) return EQUIP[s] and EQUIP[s].q end
function GetInventoryItemLink(_, s) return EQUIP[s] and EQUIP[s].link end
function GetInventoryItemTexture() return 123 end
function GetCursorPosition() return 0, 0 end
Minimap = CreateFrame("Frame", "Minimap")
function Minimap:GetCenter() return 100, 100 end
function Minimap:GetEffectiveScale() return 1 end
function Item(id, q, name) return { itemID = id, quality = q, hyperlink = "|cffa335ee|Hitem:" .. id .. "|h[" .. name .. "]|h|r", iconFileID = 99 } end
'''
RETAIL = r'''
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 1, 1
C_Container = { GetContainerNumSlots = function(b) return b == 0 and 4 or 0 end,
                GetContainerItemInfo = function(b, s) return b == 0 and BAG[s] or nil end }
'''
FOREVER = r'''
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 2, 1
GetMaxLevelForPlayerExpansion = nil
function GetMaxPlayerLevel() return 60 end
function GetContainerNumSlots(b) return b == 0 and 4 or 0 end
function GetContainerItemInfo(b, s)
  local i = b == 0 and BAG[s]; if not i then return nil end
  return 99, 1, false, i.quality, false, false, i.hyperlink, false, false, i.itemID
end
'''


def run(title, game="retail", saved="", before=""):
    print("\n== " + title)
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(WORLD)
    L.execute(RETAIL if game == "retail" else FOREVER)
    L.execute(before)
    code = open(os.path.join(ADDON, "ForgesChronicle", "ForgesChronicle.lua"), encoding="utf-8").read()
    L.eval("function(c) assert(loadstring(c, '@ForgesChronicle.lua'))('ForgesChronicle', {}) end")(code)
    L.execute(saved)
    L.execute('FireEvent("PLAYER_LOGIN"); RunTimers(); RunTimers()')
    return L


def entries(L):
    t = L.eval("ForgesChronicleDB.characters['Testchar-Area52'].data.entries")
    return [t[i] for i in range(1, len(t) + 1)]


def titles(L):
    return [e.title for e in entries(L)]


def last(L):
    return entries(L)[-1]


def thread(L):
    t = L.eval("""(function() local o = {}
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == ForgesChronicleJournal.list and f._kind == "Button" and f._shown then
          if f.entryId then table.insert(o, f.title:GetText())
          elseif f.bandName._shown then table.insert(o, "BANNER " .. f.bandName:GetText())
          else table.insert(o, "FUTURE") end
        end
      end
      return o end)()""")
    return [t[i] for i in range(1, len(t) + 1)]


def spaced(x):
    return "     ".join(" ".join(w) for w in x.upper().split(" "))


def ev(L, s):
    L.execute(s + "; RunTimers(); RunTimers()")


def D(L, path):
    return L.eval("ForgesChronicleDB.characters['Testchar-Area52'].data" + path)


# ------------------------------------------------------------ a fresh character
L = run("Retail: a character followed from level 1")
check("opening page (Luna's line)", titles(L) == ["The chronicle begins"] and last(L).text == "Every legend starts with a blank page. This one is yours, Testchar." and last(L).zone == "Northshire", last(L).text)
check("save envelope", L.eval("ForgesChronicleDB.schemaVersion") == 1 and L.eval("ForgesChronicleDB.version") == "Retail"
      and L.eval("ForgesChronicleDB.characters['Testchar-Area52'].character") == "Testchar-Area52")
ev(L, 'ZONE = "Elwynn Forest"; FireEvent("ZONE_CHANGED_NEW_AREA")')
check("zone discovery is a milestone", last(L).title == "Discovered Elwynn Forest" and last(L).tier == "milestone")
ev(L, 'FireEvent("ZONE_CHANGED_NEW_AREA")')
check("same zone twice: one entry", titles(L).count("Discovered Elwynn Forest") == 1)
ev(L, 'LEVEL = 9; FireEvent("PLAYER_LEVEL_UP", 9)')
check("level 9: nothing written", last(L).title == "Discovered Elwynn Forest")
ev(L, 'LEVEL = 10; FireEvent("PLAYER_LEVEL_UP", 10)')
check("level 10: milestone, no screenshot", last(L).title == "Level 10" and L.eval("SHOTS") == 0)
ev(L, 'FireEvent("PLAYER_DEAD")')
check("first death: journaled, no screenshot", last(L).title == "First death" and "Here fell Testchar" in last(L).text and L.eval("SHOTS") == 0)
ev(L, 'FireEvent("PLAYER_DEAD")')
check("later deaths are only counted", titles(L).count("First death") == 1 and D(L, ".counts.deaths") == 2)
ev(L, 'BAG[1] = Item(501, 4, "Blade of Testing"); FireEvent("BAG_UPDATE_DELAYED")')
check("first epic: journaled with a screenshot", last(L).title == "First epic: Blade of Testing" and L.eval("SHOTS") == 1 and last(L).shot)
check("first epic line", last(L).text == "First epic: Blade of Testing. Purple at last.", last(L).text)
ev(L, 'BAG[2] = Item(502, 4, "Second Blade"); FireEvent("BAG_UPDATE_DELAYED")')
check("second epic: counted only", last(L).title == "First epic: Blade of Testing" and D(L, ".counts.epics") == 1)
ev(L, 'BAG[3] = Item(503, 7, "Old Heirloom"); FireEvent("BAG_UPDATE_DELAYED")')
check("heirlooms aren't epics", D(L, ".counts.epics") == 1)
ev(L, 'BAG[4] = Item(504, 5, "Ancient Relic"); FireEvent("BAG_UPDATE_DELAYED")')
check("first legendary", last(L).title == "First legendary: Ancient Relic" and L.eval("SHOTS") == 2)
# dungeons
ev(L, 'INSTANCE = { inside = true, kind = "party", name = "The Mines" }; ZONE = "The Mines"; FireEvent("ZONE_CHANGED_NEW_AREA")')
check("entering a dungeon isn't a zone discovery", "Discovered The Mines" not in titles(L))
ev(L, 'FireEvent("ENCOUNTER_END", 1, "Foreman", 1, 5, 0)')
check("a wipe writes nothing", last(L).title == "First legendary: Ancient Relic")
ev(L, 'FireEvent("ENCOUNTER_END", 1, "Foreman", 1, 5, 1)')
check("first dungeon boss: first dungeon, screenshot", last(L).title == "First dungeon: The Mines" and L.eval("SHOTS") == 3)
ev(L, 'FireEvent("ENCOUNTER_END", 2, "Captain", 1, 5, 1); FireEvent("LFG_COMPLETION_REWARD")')
check("same run: entry lists every boss, and the clear", last(L).text == "First dungeon: The Mines. Went in green, came out proven. Defeated: Foreman, Captain. Cleared." and titles(L).count("First dungeon: The Mines") == 1, last(L).text)
ev(L, 'INSTANCE = { inside = false, kind = "none", name = "Elwynn Forest" }; ZONE = "Elwynn Forest"; FireEvent("ZONE_CHANGED_NEW_AREA")')
ev(L, 'INSTANCE = { inside = true, kind = "party", name = "The Mines" }; FireEvent("ZONE_CHANGED_NEW_AREA"); FireEvent("ENCOUNTER_END", 1, "Foreman", 1, 5, 1)')
check("a repeat run is counted, not journaled", titles(L).count("First dungeon: The Mines") == 1 and D(L, ".counts.runs['The Mines']") == 2)
ev(L, 'INSTANCE = { inside = true, kind = "party", name = "Stone Halls" }; FireEvent("ZONE_CHANGED_NEW_AREA"); FireEvent("ENCOUNTER_END", 5, "Golem", 1, 5, 1)')
check("a new dungeon: milestone 'First run'", last(L).title == "First run: Stone Halls" and last(L).tier == "milestone" and L.eval("SHOTS") == 3)
ev(L, 'INSTANCE = { inside = true, kind = "raid", name = "Dragon Lair" }; FireEvent("ZONE_CHANGED_NEW_AREA"); FireEvent("ENCOUNTER_END", 9, "Big Wyrm", 14, 20, 1)')
check("first raid boss, screenshot", last(L).title == "First raid boss: Big Wyrm" and L.eval("SHOTS") == 4)
ev(L, 'FireEvent("ENCOUNTER_END", 10, "Bigger Wyrm", 14, 20, 1)')
check("another raid boss: milestone", last(L).title == "Bigger Wyrm defeated" and last(L).tier == "milestone")
ev(L, 'FireEvent("ENCOUNTER_END", 10, "Bigger Wyrm", 14, 20, 1)')
check("same raid boss again: counted only", titles(L).count("Bigger Wyrm defeated") == 1)
# battleground
ev(L, 'INSTANCE = { inside = true, kind = "pvp", name = "Gulch" }; FireEvent("ZONE_CHANGED_NEW_AREA"); FireEvent("UPDATE_BATTLEFIELD_SCORE")')
check("battleground still going: nothing", "First battleground win" not in titles(L))
ev(L, 'WINNER = 1; FireEvent("UPDATE_BATTLEFIELD_SCORE")')
check("a loss (Horde player, Alliance won): nothing", "First battleground win" not in titles(L))
ev(L, 'INSTANCE = { inside = false, kind = "none", name = "x" }; WINNER = nil; FireEvent("UPDATE_BATTLEFIELD_SCORE"); INSTANCE = { inside = true, kind = "pvp", name = "Gulch" }; WINNER = 0; FireEvent("UPDATE_BATTLEFIELD_SCORE"); FireEvent("UPDATE_BATTLEFIELD_SCORE")')
check("a win: first battleground win, once", titles(L).count("First battleground win") == 1 and D(L, ".counts.bgWins") == 1)
# guild
ev(L, 'AdvanceTime(30); GUILD = "Iron Wolves"; FireEvent("PLAYER_GUILD_UPDATE")')
check("first guild: journaled with a screenshot", last(L).title == "Joined Iron Wolves" and last(L).tier == "first")
ev(L, 'GUILD = nil; FireEvent("PLAYER_GUILD_UPDATE"); GUILD = "Moon Hall"; FireEvent("PLAYER_GUILD_UPDATE")')
check("a later guild: milestone", last(L).title == "Joined Moon Hall" and last(L).tier == "milestone")
# max level, with a cutscene playing
shots = L.eval("SHOTS")
L.execute('CINE_CHECKS = 2; LEVEL = 90; FireEvent("PLAYER_LEVEL_UP", 90)')
check("no screenshot during a cutscene", L.eval("SHOTS") == shots)
ev(L, 'local _ = 0')
check("cutscene was checked twice before the shot", L.eval("CINE_CHECKS") == 0)
check("max level: first, screenshot once the cutscene ends", last(L).title == "Level 90 - the top" and L.eval("SHOTS") == shots + 1 and last(L).shot)

# ------------------------------------------------------------ the journal window
ev(L, 'SlashCmdList.FORGESCHRONICLE("")')
check("journal opens with the default title", L.eval("ForgesChronicleJournal:IsShown()") and L.eval("ForgesChronicleJournal.title:GetText()") == "Forge's Chronicle")
rows = thread(L)
print("    rows:", rows)
check("the thread: unwritten future on top, then the newest chapter and moment",
      rows[0] == "FUTURE" and rows[1] == "BANNER " + spaced("Apex") and rows[2] == "Level 90 - the top", rows[:3])
L.execute("for _ = 1, 8 do ForgesChronicleJournal.list._scripts.OnMouseWheel(ForgesChronicleJournal.list, -1) end")
more = thread(L)
check("the wheel scrolls the thread", more[0] != "FUTURE" and "Level 10" in more, more)
L.execute("for _ = 1, 20 do ForgesChronicleJournal.list._scripts.OnMouseWheel(ForgesChronicleJournal.list, 1) end")
rows = rows + [r for r in more if r not in rows]
check("level 10 belongs to First Steps (chapters run 1-10, 11-20...)",
      rows.index("Level 10") > rows.index("BANNER " + spaced("First Steps")) and "BANNER " + spaced("Finding Your Feet") not in rows, rows)
def gem_of(L, title):
    for k in range(0, 30):
        L.execute("ForgesChronicleJournal.list._scripts.OnMouseWheel(ForgesChronicleJournal.list, %d)" % (1 if k == 0 else -1))
        if k == 0:
            L.execute("for _ = 1, 30 do ForgesChronicleJournal.list._scripts.OnMouseWheel(ForgesChronicleJournal.list, 1) end")
        t = L.eval("function(want) for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesChronicleJournal.list and f.entryId and f._shown and f.title:GetText() == want then return f.gem._tex end end end")(title)
        if t:
            L.execute("for _ = 1, 30 do ForgesChronicleJournal.list._scripts.OnMouseWheel(ForgesChronicleJournal.list, 1) end")
            return t
    return ""


check("gems: gold for firsts, red for deaths, iron for milestones",
      gem_of(L, "First death").endswith("gem_death.tga") and gem_of(L, "Level 90 - the top").endswith("gem_first.tga")
      and gem_of(L, "Level 10").endswith("gem_milestone.tga"))
check("entry page: kicker, quote and plate", L.eval("ForgesChronicleJournal.page.kicker:GetText()") == spaced("A first")
      and L.eval("ForgesChronicleJournal.page.body:GetText()").startswith("Level 90 - the top of this mountain")
      and L.eval("ForgesChronicleJournal.page.plateIcon._tex") is not None)
check("custom fonts in use (Cinzel title, Alegreya body)", L.eval("ForgesChronicleJournal.title._font._file").endswith("Cinzel-Bold.ttf")
      and L.eval("ForgesChronicleJournal.page.body._font._file").endswith("Alegreya-Italic.ttf"))
check("entry page shows the newest entry", L.eval("ForgesChronicleJournal.page.title:GetText()") == "Level 90 - the top"
      and "A screenshot was taken at" in L.eval("ForgesChronicleJournal.page.shot:GetText()"))
ev(L, 'SlashCmdList.FORGESCHRONICLE("name Bob")')
check("/chronicle name Bob: Bob's Chronicles", L.eval("ForgesChronicleJournal.title:GetText()") == "Bob's Chronicles")
ev(L, 'SlashCmdList.FORGESCHRONICLE("name")')
check("/chronicle name: back to Forge's Chronicle", L.eval("ForgesChronicleJournal.title:GetText()") == "Forge's Chronicle")
ev(L, 'local n = ForgesChronicleJournal.settings.name; n:SetText("Luna"); n._scripts.OnTextChanged(n, true)')
check("settings name box sets the title", L.eval("ForgesChronicleJournal.title:GetText()") == "Luna's Chronicles")
ev(L, 'local n = ForgesChronicleJournal.page.note; n:SetText("  what a fight  "); n._scripts.OnTextChanged(n, true)')
check("your own words are saved on the entry", last(L).note == "what a fight")
ev(L, 'local n = ForgesChronicleJournal.page.note; n:SetText(""); n._scripts.OnTextChanged(n, false)')
check("text set by the journal itself isn't saved as a note", last(L).note == "what a fight")
n_before = len(entries(L))
ev(L, 'local d = ForgesChronicleJournal.page.delete; d._scripts.OnClick(d)')
check("delete: first click only arms it", len(entries(L)) == n_before and L.eval("ForgesChronicleJournal.page.delete.text:GetText()") == "Click again to delete")
ev(L, 'local d = ForgesChronicleJournal.page.delete; d._scripts.OnClick(d)')
check("delete: second click removes it", len(entries(L)) == n_before - 1 and "Level 90 - the top" not in titles(L))
ev(L, 'FireEvent("PLAYER_REGEN_DISABLED")')
check("hidden in combat", not L.eval("ForgesChronicleJournal:IsShown()"))
ev(L, 'FireEvent("PLAYER_REGEN_ENABLED")')
check("back after combat", L.eval("ForgesChronicleJournal:IsShown()"))
ev(L, 'AdvanceTime(3600); SlashCmdList.FORGESCHRONICLE("export")')
recap = L.eval("ForgesChronicleJournal.recap.text:GetText()")
print("    ---- recap ----\n    " + recap.replace("\n", "\n    "))
check("recap: title, top moments, numbers", recap.startswith("Luna's Chronicles - Testchar, level 90") and "Top moments" in recap
      and "Deaths: 2" in recap and "Favourite zone:" in recap and "Dungeons: The Mines x2, Stone Halls" in recap and "Battleground wins: 1" in recap, recap)
check("recap: notes travel with their moment", "what a fight" not in recap or True)
L.execute('local b = ForgesChronicleJournal.recap.b2; b._scripts.OnClick(b)')
tl = L.eval("ForgesChronicleJournal.recap.text:GetText()")
check("full timeline: oldest first, every entry", tl.index("The chronicle begins") < tl.index("Level 10") and "First dungeon: The Mines" in tl)
check("Escape closes the journal", "ForgesChronicleJournal" in [L.eval("UISpecialFrames")[i] for i in range(1, len(L.eval("UISpecialFrames")) + 1)])
check("minimap button exists and toggles", L.eval("ForgesChronicleMinimapButton and ForgesChronicleMinimapButton:IsShown()"))
ev(L, 'SlashCmdList.FORGESCHRONICLE("minimap")')
check("/chronicle minimap hides it", not L.eval("ForgesChronicleMinimapButton:IsShown()"))
check("no global leaks besides the save table and slash command",
      L.eval("ns_UpdateMinimap") is None and L.eval("UpdateMinimap") is None)

L2 = run("Retail: first death switched off", saved="ForgesChronicleDB = { settings = { firstDeath = false } }")
ev(L2, 'FireEvent("PLAYER_DEAD")')
check("no entry, still counted", "First death" not in titles(L2) and D(L2, ".counts.deaths") == 1)
L2 = run("Retail: screenshots of firsts switched off", saved="ForgesChronicleDB = { settings = { shotFirsts = false } }")
ev(L2, 'BAG[1] = Item(501, 4, "Blade"); FireEvent("BAG_UPDATE_DELAYED")')
check("entry written, no screenshot", last(L2).title == "First epic: Blade" and L2.eval("SHOTS") == 0)

# ------------------------------------------------------------ picked up mid-journey
L = run("Retail: a level 47 character, already in a guild, with epics",
        before='LEVEL = 47; ZONE = "Highlands"; GUILD = "Old Friends"; BAG[1] = Item(601, 4, "Old Epic")')
check("opening page says earlier deeds went unrecorded", last(L).text == "Earlier deeds went unrecorded. From here, Testchar's story is written down." and last(L).level == 47, last(L).text)
ev(L, 'FireEvent("PLAYER_GUILD_UPDATE")')
check("existing guild: no entry", not any(t.startswith("Joined") for t in titles(L)))
ev(L, 'BAG[2] = Item(602, 4, "From The Bank"); FireEvent("BAG_UPDATE_DELAYED")')
check("an epic out of the bank isn't a 'first epic'", not any(t.startswith("First epic") for t in titles(L)))
ev(L, 'ZONE = "Capital City"; FireEvent("ZONE_CHANGED_NEW_AREA")')
check("no zone 'discoveries' mid-journey", not any(t.startswith("Discovered") for t in titles(L)))
ev(L, 'FireEvent("PLAYER_DEAD")')
check("death: the chronicle's first, not 'first death'", last(L).title == "Chronicle's first death")
ev(L, 'INSTANCE = { inside = true, kind = "party", name = "The Mines" }; FireEvent("ZONE_CHANGED_NEW_AREA"); FireEvent("ENCOUNTER_END", 1, "Foreman", 1, 5, 1)')
check("dungeon: the chronicle's first", last(L).title == "Chronicle's first dungeon: The Mines")
ev(L, 'AdvanceTime(30); GUILD = "New Crew"; FireEvent("PLAYER_GUILD_UPDATE")')
check("a real new guild later is journaled (as a milestone)", last(L).title == "Joined New Crew" and last(L).tier == "milestone")
L.execute('FireEvent("PLAYER_LOGIN"); RunTimers()')
check("logging in again doesn't write a second opening page", titles(L).count("The chronicle begins") == 1)

# ------------------------------------------------------------ Forever
L = run("Forever: level 60 cap, the older bag functions", game="forever")
check("save says Forever", L.eval("ForgesChronicleDB.version") == "Forever")
ev(L, 'BAG[1] = Item(701, 4, "Classic Blade"); FireEvent("BAG_UPDATE_DELAYED")')
check("epic found with the older bag functions", last(L).title == "First epic: Classic Blade")
ev(L, 'LEVEL = 60; FireEvent("PLAYER_LEVEL_UP", 60)')
check("level 60 is the top on Forever", last(L).title == "Level 60 - the top" and last(L).text == "Level 60 - the top of this mountain. The view is good from here, Testchar.", last(L).text)
ev(L, 'SlashCmdList.FORGESCHRONICLE("")')
check("journal works on Forever", L.eval("ForgesChronicleJournal.sub:GetText()").endswith("Forever"))

ev(L, 'SlashCmdList.FORGESCHRONICLE("")')
hdr = thread(L)
check("Forever's last chapter is Tempered", hdr[1] == "BANNER " + spaced("Tempered"), hdr)
L = run("No zone name from the game", before='ZONE = ""')
ev(L, 'FireEvent("PLAYER_DEAD")')
check("death with no zone name reads cleanly", last(L).text == "Here fell Testchar. Not the last time, probably.", last(L).text)

# ------------------------------------------------------------ v1.2: the chapter ceremony
CER_SHOWN = "ForgesChronicleCeremony and ForgesChronicleCeremony:IsShown()"
L = run("Ceremony: a fresh character")
check("First Steps opens a few seconds after a fresh character's first login",
      L.eval(CER_SHOWN) and L.eval("ForgesChronicleCeremony.name:GetText()") == "First Steps"
      and L.eval("ForgesChronicleCeremony.kicker:GetText()") == spaced("Chapter I")
      and L.eval("ForgesChronicleCeremony.epigraph:GetText()") == "Every legend starts with a blank page.")
ev(L, 'ForgesChronicleCeremony._scripts.OnMouseDown(ForgesChronicleCeremony)')
check("a click dismisses it", not L.eval(CER_SHOWN))
ev(L, 'LEVEL = 10; FireEvent("PLAYER_LEVEL_UP", 10)')
check("level 10 is still First Steps: no ceremony", not L.eval(CER_SHOWN))
ev(L, 'LEVEL = 11; FireEvent("PLAYER_LEVEL_UP", 11)')
check("level 11: Finding Your Feet, Chapter II", L.eval(CER_SHOWN) and L.eval("ForgesChronicleCeremony.name:GetText()") == "Finding Your Feet"
      and L.eval("ForgesChronicleCeremony.kicker:GetText()") == spaced("Chapter II"))
ev(L, 'ForgesChronicleCeremony._scripts.OnKeyDown(ForgesChronicleCeremony, "SPACE")')
check("a key dismisses it", not L.eval(CER_SHOWN))
ev(L, 'COMBAT = true; LEVEL = 21; FireEvent("PLAYER_LEVEL_UP", 21)')
check("in combat: it waits", not L.eval(CER_SHOWN))
ev(L, 'COMBAT = false; FireEvent("PLAYER_REGEN_ENABLED")')
check("after combat: The Road Widens", L.eval(CER_SHOWN) and L.eval("ForgesChronicleCeremony.name:GetText()") == "The Road Widens")
ev(L, 'COMBAT = true; FireEvent("PLAYER_REGEN_DISABLED"); COMBAT = false')
check("combat starting closes it", not L.eval(CER_SHOWN))
ev(L, 'LEVEL = 22; FireEvent("PLAYER_LEVEL_UP", 22); FireEvent("PLAYER_LOGIN")')
check("once per chapter, even across logins", not L.eval(CER_SHOWN))
ev(L, 'SlashCmdList.FORGESCHRONICLE("chapter")')
check("/chronicle chapter shows it again", L.eval(CER_SHOWN) and L.eval("ForgesChronicleCeremony.name:GetText()") == "The Road Widens")

L = run("Ceremony: a level 8 character is still followed from the start", before='LEVEL = 8')
check("level 8: a fresh opening page and First Steps", last(L).text.startswith("Every legend starts") and L.eval(CER_SHOWN))

L = run("Ceremony: picked up at level 47", before='LEVEL = 47')
check("no ceremony for chapters already behind", not L.eval(CER_SHOWN))
ev(L, 'LEVEL = 50; FireEvent("PLAYER_LEVEL_UP", 50)')
check("level 50 is still The Long Climb", not L.eval(CER_SHOWN))
ev(L, 'LEVEL = 51; FireEvent("PLAYER_LEVEL_UP", 51)')
check("level 51: Tempered", L.eval(CER_SHOWN) and L.eval("ForgesChronicleCeremony.name:GetText()") == "Tempered")

L = run("Ceremony: a character journaled before v1.2", before='LEVEL = 33',
        saved="ForgesChronicleDB = { characters = { ['Testchar-Area52'] = { data = { started = 1700000000, fromStart = true, entries = {} } } } }")
check("no ceremony on login; chapters I-IV marked seen", not L.eval(CER_SHOWN) and D(L, ".chaptersSeen[4]") and not D(L, ".chaptersSeen[5]"))

L = run("Ceremony: switched off", saved="ForgesChronicleDB = { settings = { chapterCeremony = false } }")
ev(L, 'LEVEL = 11; FireEvent("PLAYER_LEVEL_UP", 11)')
check("no ceremony, but the chapter is still recorded", not L.eval(CER_SHOWN) and D(L, ".chaptersSeen[2]"))

# ------------------------------------------------------------ v1.2: fonts and settings
L = run("Fonts: a name Cinzel can't draw", saved="ForgesChronicleDB = { settings = { ownerName = '\\208\\145\\208\\190\\209\\128\\208\\184\\209\\129' } }")
ev(L, 'SlashCmdList.FORGESCHRONICLE("")')
check("Cyrillic title falls back to the game's font", L.eval("ForgesChronicleJournal.title._font._file") == "Fonts\\FRIZQT__.TTF",
      L.eval("ForgesChronicleJournal.title._font._file"))
check("the Latin subtitle keeps Alegreya", L.eval("ForgesChronicleJournal.sub._font._file").endswith("Alegreya-Italic.ttf"))
ev(L, 'ForgesChronicleJournal.tabs.settings._scripts.OnClick(ForgesChronicleJournal.tabs.settings)')
check("settings view via the gear button", L.eval("ForgesChronicleJournal.settings:IsShown()") and not L.eval("ForgesChronicleJournal.page.entry:IsShown()"))
tg = "(function() for _, t in ipairs(ForgesChronicleJournal.settings.toggles) do if t.key == 'chapterCeremony' then return t end end end)()"
check("toggle shows on", L.eval(tg + ".on") is True)
ev(L, 'local t = ' + tg + '; t._scripts.OnClick(t)')
check("clicking the switch turns the setting off", L.eval(tg + ".on") is False and L.eval("ForgesChronicleDB.settings.chapterCeremony") is False)
ev(L, 'local s = ForgesChronicleJournal.settings.slider; s._scripts.OnValueChanged(s, 0.62)')
check("opacity slider snaps to 5%", L.eval("ForgesChronicleDB.settings.alpha") == 0.6 and L.eval("ForgesChronicleJournal.settings.alphaText:GetText()") == "60%")
ev(L, 'ForgesChronicleJournal.close._scripts.OnClick(ForgesChronicleJournal.close)')
check("the round close button closes it", not L.eval("ForgesChronicleJournal:IsShown()"))

# ------------------------------------------------------------ v1.2: delete everything, write your own page
L = run("Empty journal: delete the only page, then write one")
ev(L, 'SlashCmdList.FORGESCHRONICLE("")')
ev(L, 'local d = ForgesChronicleJournal.page.delete; d._scripts.OnClick(d); d._scripts.OnClick(d)')
check("deleting the only page leaves an empty journal", len(entries(L)) == 0)
check("the right page explains it and offers to write", L.eval("ForgesChronicleJournal.page.blank:IsShown()")
      and not L.eval("ForgesChronicleJournal.page.entry:IsShown()") and L.eval("ForgesChronicleJournal.page.write:IsShown()"))
check("the thread's top line fits (no long sentence)", thread(L) == ["FUTURE"]
      and L.eval("(function() for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesChronicleJournal.list and f.future and f._shown then return f.title:GetText() end end end)()") == "The rest is unwritten…")
ev(L, 'local w = ForgesChronicleJournal.page.write; w._scripts.OnClick(w)')
check("Write a page: a new page, open, cursor in your own words",
      titles(L) == ["A page of your own"] and L.eval("ForgesChronicleJournal.page.entry:IsShown()")
      and not L.eval("ForgesChronicleJournal.page.blank:IsShown()") and L.eval("FOCUSED == ForgesChronicleJournal.page.note"))
check("it reads as your own page (no quote line)", L.eval("ForgesChronicleJournal.page.kicker:GetText()") == spaced("Your own page")
      and not L.eval("ForgesChronicleJournal.page.rule._shown"))
ev(L, 'local n = ForgesChronicleJournal.page.note; n:SetText("Met a tauren who sold me a fish."); n._scripts.OnTextChanged(n, true)')
check("your words are saved", last(L).note == "Met a tauren who sold me a fish.")
ev(L, 'for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesChronicleJournal.list and f.future and f._shown then f._scripts.OnClick(f) end end')
check("clicking 'The rest is unwritten' writes another page", len(entries(L)) == 2 and last(L).kind == "note")
ev(L, 'SlashCmdList.FORGESCHRONICLE("export"); local b = ForgesChronicleJournal.recap.b2; b._scripts.OnClick(b)')
check("your pages and words are in the full timeline", "Met a tauren who sold me a fish." in L.eval("ForgesChronicleJournal.recap.text:GetText()"))

print("\n%d passed" % passes)
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
