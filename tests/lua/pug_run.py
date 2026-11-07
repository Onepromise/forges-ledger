"""Drive PUG Lyfe in the mock WoW UI: groups, ratings, reminders, the window."""
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

# A fake group: GROUP.members are the OTHER people (party1.., or raid1..);
# each is { name, realm, class, guild, friend }. TARGET and MOUSE are members too.
WORLD = r'''
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
UNKNOWN = "Unknown"
COMBAT = false
function InCombatLockdown() return COMBAT end
INSTANCE = { inside = false, kind = "none", name = "Elwynn Forest" }
GROUP, TARGET, MOUSE = { raid = false, members = {} }, nil, nil
function GetRealmName() return "Area 52" end
function GetNormalizedRealmName() return "Area52" end
function IsInInstance() return INSTANCE.inside, INSTANCE.kind end
function GetInstanceInfo() return INSTANCE.name, INSTANCE.kind end
function GetRealZoneText() return INSTANCE.name end
function IsInGroup() return #GROUP.members > 0 end
function IsInRaid() return GROUP.raid end
function GetNumGroupMembers() return #GROUP.members > 0 and (#GROUP.members + 1) or 0 end
local function member(unit)
  if unit == "target" then return TARGET end
  if unit == "mouseover" then return MOUSE end
  local kind, n = tostring(unit):match("^(%a+)(%d+)$")
  if kind == (GROUP.raid and "raid" or "party") then return GROUP.members[tonumber(n)] end
end
function UnitExists(unit) if unit == "player" then return true end; return member(unit) ~= nil end
function UnitIsUnit(a, b)
  if a == b then return true end
  local x, y = (a == "player") and "me" or member(a), (b == "player") and "me" or member(b)
  return x ~= nil and x == y
end
function UnitIsPlayer(unit) return unit == "player" or member(unit) ~= nil end
function UnitFullName(unit)
  if unit == "player" then return "Testchar", nil end
  local m = member(unit); if not m then return nil end
  if m.delay and m.delay > 0 then m.delay = m.delay - 1; return nil end
  return m.name, m.realm
end
function UnitClass(unit) local m = member(unit); return m and m.class or "Warrior", m and m.class or "WARRIOR" end
function UnitIsInMyGuild(unit) local m = member(unit); return m and m.guild or false end
function UnitGUID(unit) local m = member(unit); return m and ("Player-1-" .. tostring(m.name)) or nil end
C_FriendList = { IsFriend = function(guid) for _, m in ipairs(GROUP.members) do if "Player-1-" .. tostring(m.name) == guid then return m.friend or false end end return false end }
function GetCursorPosition() return 0, 0 end
LONG = {}
do
  local realAfter = C_Timer.After
  C_Timer.After = function(d, fn) if d >= 10 then table.insert(LONG, fn) else realAfter(d, fn) end end
end
function RUN_LONG() local l = LONG; LONG = {}; for _, f in ipairs(l) do f() end end
Minimap = CreateFrame("Frame", "Minimap")
function Minimap:GetCenter() return 100, 100 end
function Minimap:GetEffectiveScale() return 1 end
function P(name, class, extra) local m = { name = name, class = class or "MAGE" }; for k, v in pairs(extra or {}) do m[k] = v end; return m end
function HIDE() if PugLyfeRate then PugLyfeRate:Hide() end if PugLyfePopup then PugLyfePopup:Hide() end end
TLINES = {}
TOOLTIP = { GetUnit = function() return "name", "mouseover" end, AddLine = function(self, t) table.insert(TLINES, t) end }
'''
RETAIL = r'''
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 1, 1
Enum = Enum or {}
Enum.TooltipDataType = { Unit = 2 }
POSTCALLS = {}
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) POSTCALLS[kind] = fn end }
'''
FOREVER = r'''
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 2, 1
HOOKED = {}
GameTooltip.HookScript = function(self, name, fn) HOOKED[name] = fn end
'''


def run(title, game="retail", saved="", before=""):
    print("\n== " + title)
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(WORLD)
    L.execute(RETAIL if game == "retail" else FOREVER)
    L.execute(before)
    code = open(os.path.join(ADDON, "PugLyfe", "PugLyfe.lua"), encoding="utf-8").read()
    L.eval("function(c) assert(loadstring(c, '@PugLyfe.lua'))('PugLyfe', {}) end")(code)
    L.execute(saved)
    L.execute('FireEvent("PLAYER_LOGIN"); RunTimers(); RunTimers()')
    return L


def ev(L, s):
    L.execute(s + "; RunTimers(); RunTimers()")


def roster(L, lua_members):
    """Set the group and let the addon notice."""
    ev(L, "GROUP.members = " + lua_members + '; FireEvent("GROUP_ROSTER_UPDATE")')


def players(L):
    t = L.eval("PugLyfeDB.players")
    return {k: t[k] for k in t.keys()}


def errors(L):
    return [p for p in L.eval("PRINTED").values() if "error" in p.lower()]


def shown(L, name):
    return bool(L.eval("%s and %s:IsShown()" % (name, name)))


def rate_rows(L):
    t = L.eval("""(function() local o = {}
      for _, r in ipairs(PugLyfeRate.rows) do if r._shown then table.insert(o, r.name:GetText()) end end
      return o end)()""")
    return [t[i] for i in range(1, len(t) + 1)]


def popup_rows(L):
    t = L.eval("""(function() local o = {}
      for _, r in ipairs(PugLyfePopup.rows) do if r._shown then table.insert(o, { r.name:GetText(), r.info:GetText(), r.note:GetText() }) end end
      return o end)()""")
    return [(t[i][1], t[i][2], t[i][3]) for i in range(1, len(t) + 1)]


def click_thumb(L, i, up):
    L.eval("function(i, up) local r = PugLyfeRate.rows[i]; local b = up and r.up or r.down; b._scripts.OnClick(b) end")(i, up)


def list_rows(L):
    t = L.eval("""(function() local o = {}
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == PugLyfeWindow.list and f.thumb and f._shown then table.insert(o, f.name:GetText()) end
      end
      return o end)()""")
    return [t[i] for i in range(1, len(t) + 1)]


def click_row(L, name):
    L.eval("""function(n) for _, f in ipairs(ALL_FRAMES) do
      if f._parent == PugLyfeWindow.list and f.thumb and f._shown and f.name:GetText() == n then f._scripts.OnClick(f); return end end
      error("no row " .. n) end""")(name)


TWO = '{ P("Alpha", "MAGE"), P("Bravo", "WARRIOR") }'

# ------------------------------------------------------------------ recording
L = run("PUG Lyfe: a fresh start")
check("save envelope", L.eval("PugLyfeDB.schemaVersion") == 1 and L.eval("PugLyfeDB.version") == "Retail")
check("settings have their defaults", L.eval("PugLyfeDB.settings.askAfter") and L.eval("PugLyfeDB.settings.popup")
      and L.eval("PugLyfeDB.settings.skipKnown") and L.eval("PugLyfeDB.settings.minimap"))
check("minimap button exists", L.eval("PugLyfeMinimapButton and PugLyfeMinimapButton:IsShown()"))
check("tooltips hooked (retail post-call)", L.eval("POSTCALLS[2]") is not None)

L = run("PUG Lyfe: recording a group")
ev(L, 'INSTANCE = { inside = true, kind = "party", name = "The Mines" }')
roster(L, '{ P("Alpha", "MAGE"), P("Bravo", "WARRIOR"), P("Guildie", "PRIEST", { guild = true }), P("Buddy", "ROGUE", { friend = true }), '
          'P("Farrealm", "DRUID", { realm = "Illidan" }) }')
ps = players(L)
check("strangers are recorded; guildmates and friends skipped", sorted(ps) == ["Alpha-Area52", "Bravo-Area52", "Farrealm-Illidan"], sorted(ps))
a = ps["Alpha-Area52"]
check("a record: name, class, count, where", a.name == "Alpha" and a["class"] == "MAGE" and a.times == 1 and a.contexts[1] == "The Mines" and a.firstSeen == a.lastSeen, dict(a))
check("another realm keeps its realm", ps["Farrealm-Illidan"].realm == "Illidan")
roster(L, '{ P("Alpha", "MAGE"), P("Bravo", "WARRIOR"), P("Farrealm", "DRUID", { realm = "Illidan" }) }')
check("the same group again doesn't count twice", players(L)["Alpha-Area52"].times == 1)
check("nothing is rated yet, so nothing prompts mid-group", not shown(L, "PugLyfeRate"))
ev(L, "PugLyfeDB.settings.skipKnown = false; GROUP.members = { P('Guildie', 'PRIEST', { guild = true }) }; FireEvent('GROUP_ROSTER_UPDATE')")
check("...with 'skip' off they're recorded too", "Guildie-Area52" in players(L), sorted(players(L)))

# ------------------------------------------------------------------ the rate box
L = run("PUG Lyfe: How was the group?")
roster(L, TWO)
roster(L, "{}")
check("the group ends: a rate box offers the two new people", shown(L, "PugLyfeRate") and sorted(rate_rows(L)) == ["Alpha", "Bravo"], rate_rows(L) if shown(L, "PugLyfeRate") else None)
rows = rate_rows(L)
i_alpha = rows.index("Alpha") + 1
click_thumb(L, i_alpha, True)
check("a thumbs-up rates them (saved)", players(L)["Alpha-Area52"].rating == "up")
click_thumb(L, i_alpha, True)
check("clicking it again clears the rating", players(L)["Alpha-Area52"].rating is None)
click_thumb(L, i_alpha, False)
check("a thumbs-down rates them", players(L)["Alpha-Area52"].rating == "down")
check("the thumbs light up for the chosen one", L.eval("PugLyfeRate.rows[%d].down.fill._shown" % i_alpha) and not L.eval("PugLyfeRate.rows[%d].up.fill._shown" % i_alpha))

L = run("PUG Lyfe: never in the middle of a fight")
ev(L, "COMBAT = true")
roster(L, TWO)
roster(L, "{}")
check("in combat: no prompt yet", not shown(L, "PugLyfeRate"))
ev(L, "COMBAT = false; FireEvent('PLAYER_REGEN_ENABLED')")
check("after combat: the rate box appears", shown(L, "PugLyfeRate"))

L = run("PUG Lyfe: Dungeon Finder completion")
roster(L, TWO)
ev(L, "FireEvent('LFG_COMPLETION_REWARD')")
check("a completed run prompts at once", shown(L, "PugLyfeRate") and len(rate_rows(L)) == 2)
ev(L, "HIDE()")
roster(L, "{}")
check("...and leaving afterwards doesn't ask twice", not shown(L, "PugLyfeRate"))

L = run("PUG Lyfe: 'ask me' switched off, /pug rate still works")
ev(L, "PugLyfeDB.settings.askAfter = false")
roster(L, TWO)
roster(L, "{}")
check("no automatic prompt", not shown(L, "PugLyfeRate"))
ev(L, "SlashCmdList.PUGLYFE('rate')")
check("/pug rate asks about the group that just ended", shown(L, "PugLyfeRate") and len(rate_rows(L)) == 2)

L = run("PUG Lyfe: battlegrounds are skipped")
ev(L, 'INSTANCE = { inside = true, kind = "pvp", name = "Test Gulch" }')
roster(L, TWO)
check("nobody recorded in a battleground", len(players(L)) == 0)

# ------------------------------------------------------------------ re-encounters
L = run("PUG Lyfe: someone you rated joins again")
roster(L, '{ P("Alpha", "MAGE") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'up'; PugLyfeDB.players['Alpha-Area52'].note = 'great healer'")
roster(L, "{}")
ev(L, "HIDE(); AdvanceTime(3 * 86400)")
roster(L, '{ P("Alpha", "MAGE"), P("Stranger", "ROGUE") }')
check("a reminder appears for the rated player only", shown(L, "PugLyfePopup") and len(popup_rows(L)) == 1, popup_rows(L) if shown(L, "PugLyfePopup") else None)
row = popup_rows(L)[0]
check("it names them, your rating, how often, when, and your note", row[0] == "Alpha" and row[1].startswith("Group again")
      and "1 group before" in row[1] and "last 3 days ago" in row[1] and row[2] == '"great healer"', row)
check("the reminder hides itself after 15 seconds", (L.execute("RUN_LONG()") or True) and not shown(L, "PugLyfePopup"))
roster(L, '{ P("Alpha", "MAGE"), P("Stranger", "ROGUE"), P("Third", "PRIEST") }')
check("one reminder per group: a roster change doesn't repeat it", not shown(L, "PugLyfePopup"))
ev(L, "PugLyfeDB.settings.popup = false")
roster(L, "{}")
roster(L, '{ P("Alpha", "MAGE") }')
check("reminders can be switched off", not shown(L, "PugLyfePopup"))

L = run("PUG Lyfe: reminders wait out a fight")
roster(L, '{ P("Alpha", "MAGE") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'down'")
roster(L, "{}")
ev(L, "HIDE(); COMBAT = true")
roster(L, '{ P("Alpha", "MAGE") }')
check("in combat: no popup", not shown(L, "PugLyfePopup"))
ev(L, "COMBAT = false; FireEvent('PLAYER_REGEN_ENABLED')")
check("after: the popup, marked Avoid", shown(L, "PugLyfePopup") and popup_rows(L)[0][1].startswith("Avoid"))

L = run("PUG Lyfe: targeting someone you know")
roster(L, '{ P("Alpha", "MAGE") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].note = 'ninja looter'")
roster(L, "{}")
ev(L, "HIDE(); HIDE(); TARGET = P('Alpha', 'MAGE'); FireEvent('PLAYER_TARGET_CHANGED')")
check("targeting them shows the reminder", shown(L, "PugLyfePopup") and popup_rows(L)[0][2] == '"ninja looter"')
ev(L, "HIDE(); FireEvent('PLAYER_TARGET_CHANGED')")
check("...not again within ten minutes", not shown(L, "PugLyfePopup"))
ev(L, "AdvanceTime(601); FireEvent('PLAYER_TARGET_CHANGED')")
check("...but after ten minutes, yes", shown(L, "PugLyfePopup"))
ev(L, "HIDE(); PugLyfeDB.settings.targetPopup = false; AdvanceTime(601); FireEvent('PLAYER_TARGET_CHANGED')")
check("target reminders can be switched off", not shown(L, "PugLyfePopup"))
ev(L, "PugLyfeDB.settings.targetPopup = true; TARGET = P('Nobody', 'MAGE'); AdvanceTime(601); FireEvent('PLAYER_TARGET_CHANGED')")
check("a stranger gets no reminder", not shown(L, "PugLyfePopup"))

L = run("PUG Lyfe: tooltips")
roster(L, '{ P("Alpha", "MAGE") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'down'; PugLyfeDB.players['Alpha-Area52'].note = 'left mid-boss'; MOUSE = P('Alpha', 'MAGE')")
ev(L, "POSTCALLS[2](TOOLTIP)")
check("a known player's tooltip gets a PUG Lyfe line", len(list(L.eval("TLINES").values())) == 1 and "thumbs down" in L.eval("TLINES[1]") and "left mid-boss" in L.eval("TLINES[1]"), L.eval("TLINES"))
ev(L, "TLINES = {}; MOUSE = P('Stranger', 'MAGE'); POSTCALLS[2](TOOLTIP)")
check("a stranger's doesn't", len(list(L.eval("TLINES").values())) == 0)
ev(L, "PugLyfeDB.settings.tooltip = false; MOUSE = P('Alpha', 'MAGE'); POSTCALLS[2](TOOLTIP)")
check("tooltip lines can be switched off", len(list(L.eval("TLINES").values())) == 0)

# ------------------------------------------------------------------ slash commands
L = run("PUG Lyfe: slash commands")
ev(L, "SlashCmdList.PUGLYFE('up')")
check("/pug up with no target says so", any("Target a player" in p for p in L.eval("PRINTED").values()))
ev(L, "TARGET = P('Zed', 'ROGUE', { realm = 'Illidan' }); SlashCmdList.PUGLYFE('up fast and friendly')")
z = players(L).get("Zed-Illidan")
check("/pug up rates the target and saves a note", z and z.rating == "up" and z.note == "fast and friendly" and z.realm == "Illidan", dict(z) if z else None)
ev(L, "SlashCmdList.PUGLYFE('down')")
check("/pug down flips the rating, keeps the note", players(L)["Zed-Illidan"].rating == "down" and players(L)["Zed-Illidan"].note == "fast and friendly")
ev(L, "SlashCmdList.PUGLYFE('note ' .. string.rep('x', 300))")
check("a note is capped at 120 characters", len(players(L)["Zed-Illidan"].note) == 120)
ev(L, "SlashCmdList.PUGLYFE('note   ')")
check("an empty note clears it", players(L)["Zed-Illidan"].note is None)
ev(L, "SlashCmdList.PUGLYFE('help')")
check("/pug help lists the commands", any("/pug export" in p for p in L.eval("PRINTED").values()))
ev(L, "SlashCmdList.PUGLYFE('minimap')")
check("/pug minimap hides the button", not L.eval("PugLyfeMinimapButton:IsShown()"))
check("no errors printed", not errors(L), errors(L))

# ------------------------------------------------------------------ the window
L = run("PUG Lyfe: the window")
roster(L, '{ P("Alpha", "MAGE"), P("Bravo", "WARRIOR") }')
ev(L, "AdvanceTime(100)")
roster(L, '{ P("Alpha", "MAGE"), P("Bravo", "WARRIOR"), P("Cora", "PRIEST") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'up'; PugLyfeDB.players['Bravo-Area52'].rating = 'down'")
roster(L, "{}")
ev(L, "HIDE(); SlashCmdList.PUGLYFE('')")
check("/pug opens the window with everyone, newest first", shown(L, "PugLyfeWindow") and list_rows(L)[0] == "Cora" and sorted(list_rows(L)) == ["Alpha", "Bravo", "Cora"], list_rows(L))
ev(L, "PugLyfeWindow.filters.up._scripts.OnClick(PugLyfeWindow.filters.up)")
check("filter: Group again", list_rows(L) == ["Alpha"], list_rows(L))
ev(L, "PugLyfeWindow.filters.down._scripts.OnClick(PugLyfeWindow.filters.down)")
check("filter: Avoid", list_rows(L) == ["Bravo"], list_rows(L))
ev(L, "PugLyfeWindow.filters.new._scripts.OnClick(PugLyfeWindow.filters.new)")
check("filter: Unrated", list_rows(L) == ["Cora"], list_rows(L))
ev(L, "PugLyfeWindow.filters.all._scripts.OnClick(PugLyfeWindow.filters.all); local s = PugLyfeWindow.search; s:SetText('br'); s._scripts.OnTextChanged(s, true)")
check("search narrows the list", list_rows(L) == ["Bravo"], list_rows(L))
ev(L, "local s = PugLyfeWindow.search; s:SetText(''); s._scripts.OnTextChanged(s, true)")
click_row(L, "Cora")
check("clicking a row shows the player", L.eval("PugLyfeWindow.detail.name:GetText()") == "Cora" and "Grouped 1 time" in L.eval("PugLyfeWindow.detail.meta:GetText()"))
check("...with where you met", "Seen in: Elwynn Forest" == L.eval("PugLyfeWindow.detail.where:GetText()"), L.eval("PugLyfeWindow.detail.where:GetText()"))
ev(L, "local b = PugLyfeWindow.detail.up; b._scripts.OnClick(b)")
check("the big thumbs rate them", players(L)["Cora-Area52"].rating == "up" and L.eval("PugLyfeWindow.detail.state:GetText()") == "Group again")
ev(L, "local n = PugLyfeWindow.detail.note; n:SetText('  carries the heals  '); n._scripts.OnTextChanged(n, true)")
check("typing a note saves it", players(L)["Cora-Area52"].note == "carries the heals")
ev(L, "local n = PugLyfeWindow.detail.note; n:SetText(''); n._scripts.OnTextChanged(n, false)")
check("text the window sets itself isn't saved over your note", players(L)["Cora-Area52"].note == "carries the heals")
ev(L, "local f = PugLyfeWindow.detail.forget; f._scripts.OnClick(f)")
check("forgetting takes two clicks", "Cora-Area52" in players(L))
ev(L, "local f = PugLyfeWindow.detail.forget; f._scripts.OnClick(f)")
check("...the second one does it", "Cora-Area52" not in players(L) and "Cora" not in list_rows(L))
ev(L, "PugLyfeWindow.gear._scripts.OnClick(PugLyfeWindow.gear)")
check("Settings opens in place of the detail", L.eval("PugLyfeWindow.settings:IsShown()") and not L.eval("PugLyfeWindow.detail:IsShown()"))
ev(L, "local t = PugLyfeWindow.settings.toggles[1]; assert(t.key == 'askAfter')")
ev(L, "PugLyfeWindow.settings.toggles[1].state._parent._scripts.OnClick(PugLyfeWindow.settings.toggles[1].state._parent)")
check("a settings row flips its setting", L.eval("PugLyfeDB.settings.askAfter") is False and L.eval("PugLyfeWindow.settings.toggles[1].state:GetText()") == "Off")
ev(L, "PugLyfeWindow.settings.toggles[10].state._parent._scripts.OnClick(PugLyfeWindow.settings.toggles[10].state._parent)")
check("the minimap toggle shows/hides the button", not L.eval("PugLyfeMinimapButton:IsShown()"))
ev(L, "SlashCmdList.PUGLYFE('export')")
text = L.eval("PugLyfeWindow.export.text:GetText()")
check("export lists rated players and notes as copyable text", L.eval("PugLyfeWindow.export:IsShown()") and "Alpha-Area52 | group again" in text
      and "Bravo-Area52 | avoid" in text and "Cora" not in text, text)
ev(L, "SlashCmdList.PUGLYFE('find alp')")
check("/pug find searches", list_rows(L) == ["Alpha"] and L.eval("PugLyfeWindow.detail:IsShown()"), list_rows(L))
check("no errors printed", not errors(L), errors(L))

# ------------------------------------------------------------------ housekeeping
L = run("PUG Lyfe: the list can't grow without end")
ev(L, """local db = PugLyfeDB
  db.players['Keeper-Area52'] = { name = 'Keeper', realm = 'Area 52', rating = 'up', lastSeen = 1, firstSeen = 1, times = 1 }
  for i = 1, 305 do db.players['Seen' .. i .. '-Area52'] = { name = 'Seen' .. i, realm = 'Area 52', lastSeen = 1000 + i, firstSeen = 1, times = 1 } end""")
roster(L, '{ P("Newcomer", "MAGE") }')
ps = players(L)
unrated = [k for k, v in ps.items() if v.rating is None and not v.note]
check("only the newest 300 unrated are kept", len(unrated) == 300 and "Newcomer-Area52" in ps and "Seen1-Area52" not in ps and "Seen305-Area52" in ps, len(unrated))
check("anyone you rated is never pruned", "Keeper-Area52" in ps)

L = run("PUG Lyfe: names the game hides or hasn't loaded")
ev(L, "SECRET = {}; issecretvalue = function(v) return v == SECRET end")
roster(L, '{ P(SECRET, "MAGE") }')
check("a hidden (secret) name is skipped, not stored", len(players(L)) == 0 and not errors(L))
roster(L, '{ P(nil, "MAGE") }')
check("a name that hasn't loaded isn't stored", len(players(L)) == 0)
roster(L, "{}")
roster(L, '{ P("Late", "MAGE", { delay = 2 }) }')
check("a name that loads a moment later is picked up by the retry", "Late-Area52" in players(L), sorted(players(L)))

L = run("PUG Lyfe: raids", before="")
ev(L, "GROUP.raid = true")
roster(L, '{ P("R1", "MAGE"), P("R2", "WARRIOR"), P("R3", "PRIEST") }')
check("raid rosters (raid1...) are read", sorted(players(L)) == ["R1-Area52", "R2-Area52", "R3-Area52"], sorted(players(L)))

L = run("PUG Lyfe: WoW Forever", game="forever")
check("save says Forever", L.eval("PugLyfeDB.version") == "Forever")
check("tooltip falls back to the older hook", L.eval("HOOKED.OnTooltipSetUnit") is not None)
roster(L, TWO)
check("groups are recorded the same way", sorted(players(L)) == ["Alpha-Area52", "Bravo-Area52"])
roster(L, "{}")
check("and the rate box works", shown(L, "PugLyfeRate"))
check("no errors printed", not errors(L), errors(L))

L = run("PUG Lyfe: the Ledger bar", before='ForgesLedger = { RegisterBarPlugin = function(d) BARPLUGIN = d; return true end }')
check("it registers a bar segment", L.eval("BARPLUGIN and BARPLUGIN.id") == "puglyfe")
check("the segment has text", L.eval("BARPLUGIN.text()") == "PUG Lyfe")
card = L.eval("BARPLUGIN.roster()")
check("empty: the hover card says how to start", "Nobody rated" in card.empty and card.noAsOf)
roster(L, "{ P('Alpha', 'MAGE') }")
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'up'; PugLyfeDB.players['Alpha-Area52'].note = 'great healer'")
card = L.eval("BARPLUGIN.roster()")
check("the hover card lists rated players", len(card.rows) >= 1 and not errors(L), len(card.rows))
L.execute("BARPLUGIN.onClick()")
check("clicking the segment opens the list", shown(L, "PugLyfeWindow"))
L.execute("BARPLUGIN.onClick()")
check("and again closes it", not shown(L, "PugLyfeWindow"))

# the Settings rows stay inside the window (BUG PUG-1)
L = run("PUG Lyfe: settings layout")
ev(L, "SlashCmdList.PUGLYFE('')")
ev(L, "PugLyfeWindow.gear._scripts.OnClick(PugLyfeWindow.gear)")
ok = True
for i in range(1, 11):
    ok = ok and L.eval("""(function()
        local t = PugLyfeWindow.settings.toggles[%d]
        local row, sp = t.state._parent, PugLyfeWindow.settings
        local function pts(f) local o = {} for _, p in ipairs(f._points or {}) do o[p[1]] = p[2] end return o end
        local rp = pts(row)
        return rp.TOPRIGHT == sp and rp.TOPLEFT == sp
    end)()""" % i)
check("every settings row is pinned to both edges of the panel", ok)

# ============================================================ v1.1 recognition ===
V11_WORLD = r"""
CHATFILTERS = {}
function ChatFrame_AddMessageEventFilter(ev, fn) CHATFILTERS[ev] = fn end
C_FriendList.GetFriendInfo = function(name) if name == "Pal" or name == "Pal-Area52" then return { name = name } end end
function Ambiguate(n) return n end
"""


def chat(L, event, author, msg="hello", guid="Player-1-0099"):
    """Run the registered chat filter; returns (hidden, message)."""
    L.execute("CF_R = { CHATFILTERS[%r](nil, %r, %r, %r, 'lang', '', '', '', 0, 0, '', 0, 1, %r) }" % (event, event, msg, author, guid))
    hidden = L.eval("CF_R[1]")
    return hidden, L.eval("CF_R[2]")


def said(L):
    return " ".join(L.eval("PRINTED").values())


# ---------------------------------------------- v1.0 surfaces, verified first
L = run("PUG Lyfe v1.1: the two v1.0 surfaces fire as specced (Task 1)")
roster(L, '{ P("Alpha", "MAGE") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'down'; PugLyfeDB.players['Alpha-Area52'].note = 'left mid-boss'")
roster(L, "{}")
ev(L, "HIDE(); AdvanceTime(86400)")
roster(L, '{ P("Alpha", "MAGE") }')
check("v1.0 on-join reminder fires for a rated player", shown(L, "PugLyfePopup") and popup_rows(L)[0][0] == "Alpha")
ev(L, "TLINES = {}; MOUSE = P('Alpha', 'MAGE'); POSTCALLS[2](TOOLTIP)")
check("v1.0 tooltip line fires for a rated player", len(list(L.eval("TLINES").values())) == 1 and "left mid-boss" in L.eval("TLINES[1]"))

# ------------------------------------------------------------ surface 1: join
L = run("PUG Lyfe v1.1: joining a group (every member, mid-run joins)", before=V11_WORLD)
roster(L, '{ P("Alpha", "MAGE"), P("Beta", "ROGUE") }')
ev(L, "PugLyfeDB.players['Alpha-Area52'].rating = 'down'; PugLyfeDB.players['Alpha-Area52'].note = 'left mid-boss'")
ev(L, "PugLyfeDB.players['Beta-Area52'].rating = 'up'")
roster(L, "{}")
ev(L, "HIDE(); PRINTED = {}; AdvanceTime(86400)")
roster(L, '{ P("Alpha", "MAGE"), P("Beta", "ROGUE"), P("Stranger", "PRIEST") }')
out = said(L)
check("every rated member gets a chat line with the block", "Alpha joined" in out and "thumbs down" in out and "grouped 1x" in out and "left mid-boss" in out, out)
check("...for the second rated member too", "Beta joined" in out and "thumbs up" in out, out)
check("a stranger gets none", "Stranger" not in out)
ev(L, "PRINTED = {}")
roster(L, '{ P("Alpha", "MAGE"), P("Beta", "ROGUE"), P("Stranger", "PRIEST"), P("Late", "MAGE") }')
ev(L, "PugLyfeDB.players['Late-Area52'] = { name = 'Late', realm = 'Area52', rating = 'up', times = 2, lastSeen = time() - 86400, contexts = {} }")
ev(L, "PRINTED = {}; GROUP.members = { P('Alpha', 'MAGE'), P('Beta', 'ROGUE'), P('Stranger', 'PRIEST'), P('Late', 'MAGE'), P('Mid', 'ROGUE') }")
ev(L, "PugLyfeDB.players['Mid-Area52'] = { name = 'Mid', realm = 'Area52', rating = 'down', times = 1, lastSeen = time() - 86400, contexts = {} }")
ev(L, 'FireEvent("GROUP_ROSTER_UPDATE")')
out = said(L)
check("someone who joins mid-run is checked too", "Mid" in out and "joined" in out and "Alpha" not in out, out)
ev(L, "PugLyfeDB.settings.joinChat = false; PRINTED = {}; GROUP.members = {}; FireEvent('GROUP_ROSTER_UPDATE')")
ev(L, "AdvanceTime(86400); PugLyfeDB.settings.joinChat = false; PRINTED = {}; GROUP.members = { P('Alpha', 'MAGE') }; FireEvent('GROUP_ROSTER_UPDATE')")
check("the chat line can be switched off", "joined" not in said(L))

# ------------------------------------------------- surface 2: about to join
L = run("PUG Lyfe v1.1: group invites", before=V11_WORLD)
ev(L, "PugLyfeDB.players['Alpha-Area52'] = { name = 'Alpha', realm = 'Area52', rating = 'down', note = 'left mid-boss', times = 3, lastSeen = time(), contexts = {} }")
ev(L, "PugLyfeDB.players['Beta-Area52'] = { name = 'Beta', realm = 'Area52', times = 2, lastSeen = time(), contexts = {} }")
ev(L, "PugLyfeDB.players['Pal-Area52'] = { name = 'Pal', realm = 'Area52', rating = 'up', times = 5, lastSeen = time(), contexts = {} }")
ev(L, "PRINTED = {}; FireEvent('PARTY_INVITE_REQUEST', 'Alpha-Area52', false, false, true, true, false, 'Player-1-0001')")
out = said(L)
check("an invite from someone you rated shows the block", "Invite from Alpha-Area52" in out and "thumbs down" in out and "grouped 3x" in out and "left mid-boss" in out, out)
ev(L, "PRINTED = {}; FireEvent('PARTY_INVITE_REQUEST', 'Beta', false, false, true, true, false, 'Player-1-0002')")
out = said(L)
check("...and for someone grouped with but unrated (name without realm)", "Invite from Beta" in out and "not rated yet" in out and "grouped 2x" in out, out)
ev(L, "PRINTED = {}; FireEvent('PARTY_INVITE_REQUEST', 'Nobody-Area52', false, false, true, true, false, 'Player-1-0003')")
check("a stranger's invite says nothing", "Invite from" not in said(L))
ev(L, "PRINTED = {}; FireEvent('PARTY_INVITE_REQUEST', 'Pal-Area52', false, false, true, true, false, 'Player-1-0004')")
check("a friend's invite is skipped (default)", "Invite from" not in said(L))
ev(L, "PugLyfeDB.settings.skipKnown = false; PRINTED = {}; FireEvent('PARTY_INVITE_REQUEST', 'Pal-Area52', false, false, true, true, false, 'Player-1-0004')")
check("...unless that setting is off", "Invite from Pal" in said(L))
ev(L, "PugLyfeDB.settings.inviteLine = false; PRINTED = {}; FireEvent('PARTY_INVITE_REQUEST', 'Alpha-Area52', false, false, true, true, false, 'Player-1-0001')")
check("the invite line can be switched off", "Invite from" not in said(L))
check("no errors", not errors(L))

# ------------------------------------------------------------- surface 3: hover
L = run("PUG Lyfe v1.1: tooltips (rated, grouped-before, strangers)", before=V11_WORLD)
ev(L, "PugLyfeDB.players['Alpha-Area52'] = { name = 'Alpha', realm = 'Area52', rating = 'up', note = 'great healer', times = 2, lastSeen = time(), contexts = {} }")
ev(L, "PugLyfeDB.players['Beta-Area52'] = { name = 'Beta', realm = 'Area52', times = 2, lastSeen = time(), contexts = {} }")
ev(L, "TLINES = {}; MOUSE = P('Alpha', 'MAGE'); POSTCALLS[2](TOOLTIP)")
line = L.eval("TLINES[1]")
check("a rated player: thumb, times grouped, note", "thumbs up" in line and "grouped 2x" in line and "great healer" in line, line)
ev(L, "TLINES = {}; MOUSE = P('Beta', 'MAGE'); POSTCALLS[2](TOOLTIP)")
line = L.eval("TLINES[1]")
check("grouped before but unrated: 'grouped 2x · not rated yet'", "grouped 2x" in line and "not rated yet" in line, line)
ev(L, "TLINES = {}; MOUSE = P('Stranger', 'MAGE'); POSTCALLS[2](TOOLTIP)")
check("a stranger gets no line", len(list(L.eval("TLINES").values())) == 0)
ev(L, "TLINES = {}; MOUSE = P('Alpha', 'MAGE', { guild = true }); POSTCALLS[2](TOOLTIP)")
check("a guildmate is skipped (default)", len(list(L.eval("TLINES").values())) == 0)
ev(L, "PugLyfeDB.settings.skipKnown = false; TLINES = {}; MOUSE = P('Alpha', 'MAGE', { guild = true }); POSTCALLS[2](TOOLTIP)")
check("...unless that setting is off", len(list(L.eval("TLINES").values())) == 1)

# ----------------------------------------------------------------- surface 4: chat
L = run("PUG Lyfe v1.1: chat tags", before=V11_WORLD)
check("the filter is registered for group, raid, whisper, say and yell",
      all(L.eval("CHATFILTERS[%r] ~= nil" % e) for e in ["CHAT_MSG_PARTY", "CHAT_MSG_RAID", "CHAT_MSG_WHISPER", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_INSTANCE_CHAT"]))
ev(L, "PugLyfeDB.players['Alpha-Area52'] = { name = 'Alpha', realm = 'Area52', rating = 'down', times = 3, lastSeen = time(), contexts = {} }")
ev(L, "PugLyfeDB.players['Beta-Area52'] = { name = 'Beta', realm = 'Area52', times = 2, lastSeen = time(), contexts = {} }")
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Alpha-Area52", "pull now")
check("a rated player's line gets a thumb in front", hidden is False and "thumb_down" in msg and msg.endswith("pull now"), msg)
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Beta-Area52", "ready")
check("an unrated player you've grouped with gets '[grouped 2x]'", "grouped 2x" in msg and msg.endswith("ready"), msg)
hidden, msg = chat(L, "CHAT_MSG_WHISPER", "Beta", "hi")
check("a name without a realm is found too (whisper)", "grouped 2x" in msg)
hidden, msg = chat(L, "CHAT_MSG_SAY", "Nobody-Area52", "hello")
check("a stranger's line is left exactly as it was", hidden is False and msg is None)
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Testchar", "me")
check("your own lines are not tagged", msg is None)
ev(L, "C_FriendList.IsFriend = function(g) return g == 'Player-1-FRIEND' end")
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Alpha-Area52", "hi", guid="Player-1-FRIEND")
check("a friend is skipped (default)", msg is None)
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Alpha-Area52", 42)
check("an odd message (not text) is passed through untouched", hidden is False and msg is None)
ev(L, "PugLyfeDB.settings.chatTags = false")
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Alpha-Area52", "pull now")
check("chat tags can be switched off (live)", msg is None)
check("no errors", not errors(L))

# ------------------------------------------------- retail Premade Groups marks
L = run("PUG Lyfe v1.1: Premade Groups marks (retail)", before=V11_WORLD + r"""
HOOKS = {}
function hooksecurefunc(name, fn) HOOKS[name] = fn end
function LFGListSearchEntry_Update() end
function LFGListApplicationViewer_UpdateApplicantMember() end
C_LFGList = { GetSearchResultInfo = function(id) return { leaderName = "Alpha-Area52" } end,
              GetApplicantMemberInfo = function(app, i) return "Beta-Area52" end }
""")
ev(L, "PugLyfeDB.players['Alpha-Area52'] = { name = 'Alpha', realm = 'Area52', rating = 'down', times = 3, lastSeen = time(), contexts = {} }")
ev(L, "PugLyfeDB.players['Beta-Area52'] = { name = 'Beta', realm = 'Area52', times = 2, lastSeen = time(), contexts = {} }")
check("both Blizzard functions are post-hooked, not replaced", L.eval("HOOKS.LFGListSearchEntry_Update ~= nil and HOOKS.LFGListApplicationViewer_UpdateApplicantMember ~= nil"))
ev(L, "ENTRY = CreateFrame('Button'); ENTRY.resultID = 7; HOOKS.LFGListSearchEntry_Update(ENTRY)")
check("a search result whose leader you rated gets a mark", L.eval("rawget(ENTRY, 'PugLyfeMark') ~= nil") and "grouped 3x" in L.eval("rawget(ENTRY, 'PugLyfeMark'):GetText()"))
ev(L, "MEMBER = CreateFrame('Button'); HOOKS.LFGListApplicationViewer_UpdateApplicantMember(MEMBER, 1, 1)")
check("an applicant you've grouped with gets a mark", L.eval("rawget(MEMBER, 'PugLyfeMark') ~= nil") and "grouped 2x" in L.eval("rawget(MEMBER, 'PugLyfeMark'):GetText()"))
ev(L, "C_LFGList.GetSearchResultInfo = function() return { leaderName = 'Nobody-Area52' } end; HOOKS.LFGListSearchEntry_Update(ENTRY)")
check("a recycled row for a stranger loses its mark", not L.eval("rawget(ENTRY, 'PugLyfeMark'):IsShown()"))
ev(L, "PugLyfeDB.settings.lfgMarks = false; C_LFGList.GetSearchResultInfo = function() return { leaderName = 'Alpha-Area52' } end; HOOKS.LFGListSearchEntry_Update(ENTRY)")
check("the marks can be switched off", not L.eval("rawget(ENTRY, 'PugLyfeMark'):IsShown()"))
check("no errors", not errors(L))

L = run("PUG Lyfe v1.1: WoW Forever skips the Premade Groups part", game="forever", before=V11_WORLD + r"""
HOOKS = {}
function hooksecurefunc(name, fn) HOOKS[name] = fn end
function LFGListSearchEntry_Update() end
""")
check("nothing is hooked on Forever", L.eval("next(HOOKS) == nil"))
ev(L, "PugLyfeDB.players['Alpha-Area52'] = { name = 'Alpha', realm = 'Area52', rating = 'up', times = 1, lastSeen = time(), contexts = {} }")
hidden, msg = chat(L, "CHAT_MSG_PARTY", "Alpha-Area52", "hi")
check("...but chat tags work there", "thumb_up" in msg)
check("no errors", not errors(L))

# ---------------------------------------------------------------- settings + data
L = run("PUG Lyfe v1.1: settings and data")
ev(L, "SlashCmdList.PUGLYFE(''); PugLyfeWindow.gear._scripts.OnClick(PugLyfeWindow.gear)")
keys = [L.eval("PugLyfeWindow.settings.toggles[%d].key" % i) for i in range(1, 11)]
check("the four new toggles are in Settings", all(k in keys for k in ["joinChat", "inviteLine", "lfgMarks", "chatTags"]), keys)
check("all four default to on", all(L.eval("PugLyfeDB.settings.%s" % k) is True for k in ["joinChat", "inviteLine", "lfgMarks", "chatTags"]))
L = run("PUG Lyfe v1.1: a v1.0 save file upgrades untouched",
        saved="""PugLyfeDB = { schemaVersion = 1, version = "Retail", settings = { askAfter = true, popup = false, tooltip = true, skipKnown = true, minimap = true, angle = 215 },
          players = { ["Old-Area52"] = { name = "Old", realm = "Area52", rating = "up", note = "kept", times = 4, lastSeen = 5, firstSeen = 1, contexts = {} } } }""")
p = players(L)["Old-Area52"]
check("ratings, notes and counts are untouched", p.rating == "up" and p.note == "kept" and p.times == 4)
check("old settings are kept and new ones get their defaults", L.eval("PugLyfeDB.settings.popup") is False and L.eval("PugLyfeDB.settings.chatTags") is True)

print("\n%d passed" % passes)
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
