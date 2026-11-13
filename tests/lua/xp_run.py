"""Forge's Ledger XP bar in the mock WoW UI: progress, rested, pace warm-up, estimates, max level, settings."""
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
NOWT = 5000
function GetTime() return NOWT end
function Advance(s) NOWT = NOWT + s end
LEVEL, XP, XPMAX, RESTED, MAXLEVEL = 34, 4100, 10000, 0, 90
function UnitLevel() return LEVEL end
function UnitXP() return XP end
function UnitXPMax() return XPMAX end
function GetXPExhaustion() if RESTED > 0 then return RESTED end return nil end
function GetMaxLevelForPlayerExpansion() return MAXLEVEL end
function issecretvalue(v) return false end
function UnitFullName() return "Testchar", "Area52" end
-- gain XP the way the game does: the number changes, then PLAYER_XP_UPDATE fires
function GAIN(n, killmsg)
  XP = XP + n
  if killmsg == "before" then FireEvent("CHAT_MSG_COMBAT_XP_GAIN", "Boar dies, you gain " .. n .. " experience.") end
  FireEvent("PLAYER_XP_UPDATE", "player")
  if killmsg == "after" then FireEvent("CHAT_MSG_COMBAT_XP_GAIN", "x") end
end
'''
FOREVER = "GetMaxLevelForPlayerExpansion = nil; IsPlayerAtEffectiveMaxLevel = nil; MAX_PLAYER_LEVEL = 60"


def make(extra="", saved="", forever=False):
    R = lua51.LuaRuntime(unpack_returned_tuples=True)
    R.execute(MOCK)
    R.execute(WORLD)
    if forever:
        R.execute(FOREVER)
    R.execute(extra)
    ns = R.eval("{}")
    R.globals().NS = ns
    for f in ["ForgesLedger.lua", "ForgesLedger_Windows.lua", "ForgesLedger_Bar.lua", "ForgesLedger_XP.lua"]:
        code = open(os.path.join(ADDON, "ForgesLedger", f), encoding="utf-8").read()
        chunk = R.eval("function(code, n) local f, err = loadstring(code, '@'..n); if not f then error(err) end; return f end")(code, f)
        chunk("ForgesLedger", ns)
    R.execute(saved)
    R.execute('FireEvent("ADDON_LOADED", "ForgesLedger"); FireEvent("PLAYER_LOGIN"); FireEvent("PLAYER_ENTERING_WORLD"); RunTimers()')
    return R


def ev(R, s): R.execute(s + "; RunTimers()")
def text(R): return R.eval("ForgesLedgerXPBar.text:GetText()")
def errors(R): return [p for p in R.eval("PRINTED").values() if "error" in p.lower()]


print("== progress, rested, pace")
R = make()
check("the bar exists and is shown by default", R.eval("ForgesLedgerXPBar:IsShown()"))
t = text(R)
check("text: level, % through the level, XP to go", "Lvl 34" in t and "41%" in t and "5,900 to level" in t, t)
check("fill = progress through the level", abs(R.eval("ForgesLedgerXPBar.fill:GetWidth()") - 480 * 0.41) < 0.01, R.eval("ForgesLedgerXPBar.fill:GetWidth()"))
check("no rested XP: no rested segment", not R.eval("ForgesLedgerXPBar.rested._shown"))
check("pace starts as calculating", "calculating" in t, t)

ev(R, "RESTED = 2000; FireEvent('UPDATE_EXHAUSTION')")
check("rested XP shows a distinct segment of the right size", R.eval("ForgesLedgerXPBar.rested._shown") and abs(R.eval("ForgesLedgerXPBar.rested:GetWidth()") - 480 * 0.20) < 0.01, R.eval("ForgesLedgerXPBar.rested:GetWidth()"))
ev(R, "RESTED = 99999; FireEvent('UPDATE_EXHAUSTION')")
check("rested is capped at the bar's end", abs(R.eval("ForgesLedgerXPBar.rested:GetWidth()") - 480 * 0.59) < 0.01)
ev(R, "RESTED = 0; FireEvent('UPDATE_EXHAUSTION')")

ev(R, "Advance(10); GAIN(100, 'before')")
ev(R, "Advance(10); GAIN(100, 'before')")
check("two gains: still calculating", "calculating" in text(R), text(R))
ev(R, "Advance(10); GAIN(100, 'before')")
check("three gains but under a minute: still calculating", "calculating" in text(R), text(R))
ev(R, "Advance(40); GAIN(100, 'before')")
t = text(R)
check("a minute and enough gains: pace appears", "XP/h" in t and "calculating" not in t, t)
rate = R.eval("ForgesLedgerXPBar.model.perHour")
check("XP/hour = gained / elapsed", abs(rate - 400 / 70 * 3600) < 1, rate)
secs = R.eval("ForgesLedgerXPBar.model.secondsToLevel")
check("time to level = remaining / rate", abs(secs - (10000 - 4500) / (400 / 70)) < 1, secs)
check("four kills seen: kills to level shows (>= 3 samples), remaining / average", R.eval("ForgesLedgerXPBar.model.killsToLevel") == 55, R.eval("ForgesLedgerXPBar.model.killsToLevel"))
check("the text carries all three estimates", "XP/h" in t and "to level" in t and "kills" in t, t)

print("\n== kill attribution")
R2 = make()
ev(R2, "Advance(70); GAIN(100, 'after'); Advance(1); GAIN(100, 'after'); Advance(1); GAIN(100, 'after'); Advance(1); GAIN(100, 'after')")
check("kill message arriving AFTER the XP update still pairs", R2.eval("ForgesLedgerXPBar.model.killsToLevel") is not None)

R3 = make()
ev(R3, "Advance(30); GAIN(100, 'before'); Advance(5); GAIN(100, 'before'); Advance(5); GAIN(100, 'before'); Advance(5); GAIN(5000)")
ev(R3, "Advance(40); GAIN(1)")
check("quest-style XP (no kill message) is not counted as a kill", R3.eval("ForgesLedgerXPBar.model.avgKillXP") == 100, R3.eval("ForgesLedgerXPBar.model.avgKillXP"))

R4 = make()
ev(R4, "Advance(70); GAIN(100); GAIN(100); GAIN(100)")
t = text(R4)
check("no kill messages: time shown, no kills figure, no invention", "XP/h" in t and "kills" not in t, t)

print("\n== level up, max level, Forever")
R5 = make()
ev(R5, "XP = 9950; FireEvent('PLAYER_XP_UPDATE','player')")
ev(R5, "Advance(70); LEVEL = 35; XP = 300; XPMAX = 10400; FireEvent('PLAYER_LEVEL_UP', 35); FireEvent('PLAYER_XP_UPDATE','player')")
check("after a level-up the bar restarts at the new level", "Lvl 35" in text(R5) and "2%" in text(R5), text(R5))
ev(R5, "GAIN(10)")
ph = R5.eval("ForgesLedgerXPBar.model.perHour")
check("...and the gain across the level counts once (50 + 300, plus 5850 and 10)", ph is not None and abs(ph - (5850 + 350 + 10) / 70 * 3600) < 60, ph)

R6 = make(extra="LEVEL = 90; XP = 0; XPMAX = 0")
t = text(R6)
check("max level: a clean state", "Max level" in t and "calculating" not in t, t)
ev(R6, "Advance(100); FireEvent('PLAYER_XP_UPDATE','player')")
check("max level: no errors, full bar", not errors(R6) and R6.eval("ForgesLedgerXPBar.fill:GetWidth()") == 480)
R7 = make(extra="LEVEL = 60; XP = 0; XPMAX = 0", forever=True)
check("Forever max level (cap from the client) shows Max level", "Max level" in text(R7), text(R7))
R8 = make(forever=True)
check("Forever: a normal level works without the retail-only calls", "Lvl 34" in text(R8) and not errors(R8), text(R8))
R9 = make(extra="XPMAX = 0; LEVEL = 34")
check("a zero XP max never divides by zero", "Max level" in text(R9) and not errors(R9))
R10 = make(extra="function UnitXP() return nil end function UnitXPMax() return nil end")
check("unreadable XP: no error", not errors(R10))
R11 = make(extra="function issecretvalue(v) return type(v) == 'number' end")
check("secret values: no error", not errors(R11))

print("\n== settings")
R = make()
ev(R, "SlashCmdList.FORGESLEDGER('xp')")
check("/fl xp hides the bar", not R.eval("ForgesLedgerXPBar:IsShown()") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].enabled") is False)
ev(R, "SlashCmdList.FORGESLEDGER('xp')")
check("/fl xp shows it again", R.eval("ForgesLedgerXPBar:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('xp lock')")
check("/fl xp lock locks it", R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].locked") is True)
ev(R, "ForgesLedgerXPBar._scripts.OnDragStart(ForgesLedgerXPBar)")
ev(R, "SlashCmdList.FORGESLEDGER('xp unlock')")
check("/fl xp unlock frees it", R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].locked") is False)
ev(R, "ForgesLedgerXPBar._scripts.OnDragStop(ForgesLedgerXPBar)")
check("dragging saves the position", R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].pos ~= nil"))
ev(R, "SlashCmdList.FORGESLEDGER('help')")
check("/fl help lists the xp command", any("/fl xp" in p for p in R.eval("PRINTED").values()))

saved = "ForgeGoldDB = { xpbar = { ['Testchar-Area52'] = { enabled = true, locked = true, pos = { 'TOP', 'TOP', 10, -50 } } } }"
R = make(saved=saved)
ev(R, "ForgesLedgerXPBar:ClearAllPoints()")
ev(R, "SlashCmdList.FORGESLEDGER('xp lock')")
check("saved settings are used: position and lock", R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].pos[1]") == "TOP" and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].locked") is True)
check("another character gets its own settings", R.eval("ForgeGoldDB.xpbar['Other-Realm']") is None)
R = make(saved="ForgeGoldDB = { xpbar = { ['Testchar-Area52'] = { enabled = false } } }")
check("a saved 'hidden' is respected at login", not R.eval("ForgesLedgerXPBar:IsShown()"))
R = make(saved="ForgeGoldDB = { chars = { } }")
check("an old save with no XP settings gets defaults (shown, unlocked)", R.eval("ForgesLedgerXPBar:IsShown()") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].locked") is False)
ev(R, "SlashCmdList.FORGESLEDGER('settings')")
lines = " ".join(str(v) for v in R.eval("(function() local o = {} for _, f in ipairs(ALL_FRAMES) do if f._text and f._text ~= '' then o[#o+1] = f._text end end return o end)()").values())
check("the Settings window lists the XP bar toggles", "Show the XP bar" in lines and "Lock the XP bar" in lines)
check("no errors", not errors(R))

# ---------------------------------------------------------------- hide the game's XP bar ---
GAMEBAR = r'''
MAXLVL = false
STB = CreateFrame("Frame", "StatusTrackingBarManager")
STB.UpdateBarsShown = function(self) if not MAXLVL then self:Show() end end   -- the game's own refresh
function hooksecurefunc(obj, name, fn)
  local orig = obj[name]
  obj[name] = function(...) local r = orig(...); fn(...); return r end
end
'''
print("\n== hide the game's XP bar")
R = make(extra=GAMEBAR)
check("off by default: the game bar is left alone", R.eval("STB:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz on')")
check("hideblizz on hides the game bar (our bar is shown)", not R.eval("STB:IsShown()") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].hideBlizz") is True)
ev(R, "STB:Show()")
check("when the game shows it again, it is hidden again", not R.eval("STB:IsShown()"))
ev(R, "STB:UpdateBarsShown()")
check("...including the manager's own refresh", not R.eval("STB:IsShown()"))
ev(R, "STB:Show(); FireEvent('PLAYER_XP_UPDATE', 'player')")
check("...and after an XP update", not R.eval("STB:IsShown()"))
ev(R, "STB:Show(); FireEvent('ZONE_CHANGED_NEW_AREA')")
check("...and after a zone change", not R.eval("STB:IsShown()"))
ev(R, "STB:Show(); FireEvent('PLAYER_ENTERING_WORLD')")
check("...and on entering the world", not R.eval("STB:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('xp')")
check("our bar off: the game bar goes back to the game (its refresh shows it)", R.eval("STB:IsShown()") and not R.eval("ForgesLedgerXPBar:IsShown()"))
ev(R, "STB:Hide(); STB:Show()")
check("...and it is no longer being hidden", R.eval("STB:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('xp')")
check("our bar back on: hiding resumes (toggle still on)", not R.eval("STB:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz off')")
check("hideblizz off: stock behaviour returns", R.eval("STB:IsShown()") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].hideBlizz") is False)
ev(R, "STB:Show(); STB:Show()")
check("...and it is never hidden again while off", R.eval("STB:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz')")
check("bare 'hideblizz' toggles", R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].hideBlizz") is True and not R.eval("STB:IsShown()"))
ev(R, "SlashCmdList.FORGESLEDGER('settings')")
lines = " ".join(str(v) for v in R.eval("(function() local o = {} for _, f in ipairs(ALL_FRAMES) do if f._text and f._text ~= '' then o[#o+1] = f._text end end return o end)()").values())
check("the Settings window has the toggle", "Hide the game" in lines)
check("no errors", not errors(R))

R = make(extra=GAMEBAR + "MAXLVL = true; STB:Hide()")
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz on')")
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz off')")
check("at max level the toggle never force-Shows the game bar", not R.eval("STB:IsShown()"))

R = make(extra=GAMEBAR + "function InCombatLockdown() return true end; STB.IsProtected = function() return true end")
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz on')")
check("in combat lockdown a protected frame is not touched", R.eval("STB:IsShown()"))
ev(R, "function InCombatLockdown() return false end; FireEvent('PLAYER_REGEN_ENABLED')")
check("...it is hidden when the lockdown lifts", not R.eval("STB:IsShown()"))

R = make()
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz on')")
check("a client with neither frame: loads clean, the command works, nothing happens", not errors(R) and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].hideBlizz") is True)
R = make(extra="MainMenuExpBar = CreateFrame('Frame', 'MainMenuExpBar')")
ev(R, "SlashCmdList.FORGESLEDGER('xp hideblizz on')")
check("the classic-style frame name is found too", not R.eval("MainMenuExpBar:IsShown()"))
R = make(extra=GAMEBAR, saved="ForgeGoldDB = { xpbar = { ['Testchar-Area52'] = { hideBlizz = true } } }")
check("a saved 'on' hides it at login", not R.eval("STB:IsShown()"))
R = make(extra=GAMEBAR, saved="ForgeGoldDB = { chars = { } }")
check("an old save defaults to off", R.eval("STB:IsShown()") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].hideBlizz") is False)

# ---------------------------------------------------------------- quest XP preview ---
QUESTS = r'''
QUESTLIST = {}
C_QuestLog = {
  GetNumQuestLogEntries = function() return #QUESTLIST, #QUESTLIST end,
  GetInfo = function(i) local q = QUESTLIST[i]; return q and { questID = q.id, isHeader = q.header or false } end,
  ReadyForTurnIn = function(id) for _, q in ipairs(QUESTLIST) do if q.id == id then return q.ready end end end,
  GetQuestLogRewardXP = function(id) for _, q in ipairs(QUESTLIST) do if q.id == id then return q.xp end end end,
}
'''
SOME = "QUESTLIST = { {id=900, header=true}, {id=1, ready=true, xp=500}, {id=2, ready=true, xp=300}, {id=3, ready=false, xp=9999}, {id=4, ready=true, xp=0}, {id=5, ready=true} }"
print("\n== quest XP preview")
R = make(extra=QUESTS + SOME)
w = lambda: R.eval("ForgesLedgerXPBar.ghost:GetWidth()")
check("only complete quests with a readable reward are summed (800 from 2 quests)", R.eval("ForgesLedgerXPBar.model.pending") == 800 and R.eval("ForgesLedgerXPBar.model.pendingQuests") == 2, (R.eval("ForgesLedgerXPBar.model.pending"), R.eval("ForgesLedgerXPBar.model.pendingQuests")))
check("the ghost segment is sized to the pending XP", abs(w() - 480 * 0.08) < 0.01 and R.eval("ForgesLedgerXPBar.ghost._shown"), w())
check("...and starts where the XP fill ends", abs(R.eval("ForgesLedgerXPBar.ghost._points[1][4]") - 480 * 0.41) < 0.01, R.eval("ForgesLedgerXPBar.ghost._points[1][4]"))
R.execute("ForgesLedgerXPBar._scripts.OnEnter(ForgesLedgerXPBar)")
tip = " | ".join(R.eval("GameTooltip._lines").values())
check("the tooltip says how much, how many quests and where it takes you", "+800 XP ready" in tip and "2 quests" in tip and "takes you to 49%" in tip, tip)
ev(R, "QUESTLIST[2].ready = false; FireEvent('QUEST_LOG_UPDATE')")
check("a quest-log change refreshes the figure", R.eval("ForgesLedgerXPBar.model.pending") == 300 and R.eval("ForgesLedgerXPBar.model.pendingQuests") == 1)
ev(R, "QUESTLIST = { }; FireEvent('QUEST_TURNED_IN')")
check("nothing ready: no segment", not R.eval("ForgesLedgerXPBar.ghost._shown"))
R.execute("ForgesLedgerXPBar._scripts.OnEnter(ForgesLedgerXPBar)")
check("...and no zero line", "XP ready" not in " | ".join(R.eval("GameTooltip._lines").values()))
ev(R, "QUESTLIST = { {id=1, ready=true, xp=20000} }; FireEvent('QUEST_ACCEPTED')")
check("pending >= remaining: the segment fills the bar and is capped", abs(w() - 480 * 0.59) < 0.01 and R.eval("ForgesLedgerXPBar.model.enough"), w())
R.execute("ForgesLedgerXPBar._scripts.OnEnter(ForgesLedgerXPBar)")
tip = " | ".join(R.eval("GameTooltip._lines").values())
check("...worded 'enough to level', with no overflow figure", "enough to level" in tip and "takes you" not in tip, tip)
ev(R, "QUESTLIST = { {id=1, ready=true, xp=500} }; XPMAX = 5000; FireEvent('PLAYER_LEVEL_UP', 35); FireEvent('PLAYER_XP_UPDATE', 'player')")
check("a level-up refreshes it against the new bar", abs(w() - 480 * 0.10) < 0.01, w())
ev(R, "SlashCmdList.FORGESLEDGER('xp questxp off')")
check("questxp off: no segment", not R.eval("ForgesLedgerXPBar.ghost._shown") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].questXP") is False)
R.execute("ForgesLedgerXPBar._scripts.OnEnter(ForgesLedgerXPBar)")
check("...and no tooltip line", "XP ready" not in " | ".join(R.eval("GameTooltip._lines").values()))
ev(R, "SlashCmdList.FORGESLEDGER('xp questxp on')")
check("questxp on brings it back", R.eval("ForgesLedgerXPBar.ghost._shown"))
check("the API in use is reported", R.eval("NS.XP.QuestAPI()") == "C_QuestLog.GetQuestLogRewardXP", R.eval("NS.XP.QuestAPI()"))
ev(R, "SlashCmdList.FORGESLEDGER('settings')")
lines = " ".join(str(v) for v in R.eval("(function() local o = {} for _, f in ipairs(ALL_FRAMES) do if f._text and f._text ~= '' then o[#o+1] = f._text end end return o end)()").values())
check("the Settings window has the toggle", "quest XP" in lines)
check("no errors", not errors(R))

R = make(extra=QUESTS + SOME + "LEVEL = 90; XP = 0; XPMAX = 0")
check("max level: no segment, no line", not R.eval("ForgesLedgerXPBar.ghost._shown") and R.eval("ForgesLedgerXPBar.model.pending") == 0 and not errors(R))
R = make(extra="")
check("no reward API on the client: quietly absent, no error", not R.eval("ForgesLedgerXPBar.ghost._shown") and R.eval("NS.XP.QuestAPI()") is None and not errors(R))
R.execute("ForgesLedgerXPBar._scripts.OnEnter(ForgesLedgerXPBar)")
check("...and no tooltip line either", "XP ready" not in " | ".join(R.eval("GameTooltip._lines").values()))
CLASSIC = r'''
C_QuestLog = nil
CQ = { {"Header", true, false, nil}, {"Done", false, true, 11}, {"Open", false, false, 12} }
function GetNumQuestLogEntries() return #CQ, #CQ end
function GetQuestLogTitle(i) local q = CQ[i]; return q[1], 10, "", q[2], false, q[3] and 1 or -1, "", q[4] end
function GetQuestLogRewardXP(id) if id == 11 then return 700 end return 4000 end
'''
R = make(extra=CLASSIC)
check("the older global API works too (complete quests only)", R.eval("ForgesLedgerXPBar.model.pending") == 700 and R.eval("NS.XP.QuestAPI()") == "GetQuestLogRewardXP", R.eval("ForgesLedgerXPBar.model.pending"))
R = make(extra=QUESTS + SOME, saved="ForgeGoldDB = { xpbar = { ['Testchar-Area52'] = { questXP = false } } }")
check("a saved 'off' is respected", not R.eval("ForgesLedgerXPBar.ghost._shown"))
R = make(extra=QUESTS + SOME, saved="ForgeGoldDB = { chars = { } }")
check("an old save defaults to on", R.eval("ForgesLedgerXPBar.ghost._shown") and R.eval("ForgeGoldDB.xpbar['Testchar-Area52'].questXP") is True)
R = make(extra=QUESTS + "function C_QuestLog.GetQuestLogRewardXP() error('boom') end " + SOME)
check("a reward call that errors is excluded, not fatal", not errors(R) and R.eval("ForgesLedgerXPBar.model.pending") == 0)

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
