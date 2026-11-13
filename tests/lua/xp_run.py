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

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
