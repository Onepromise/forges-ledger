"""Drive the Totem Range Step 0 probe in the mock WoW UI: it must never error, whatever the client lacks."""
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
BASE = r'''
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function UnitClass() return "Shaman", "SHAMAN" end
Minimap = CreateFrame("Frame", "Minimap")
'''
FULL = r'''
MAX_TOTEMS = 4
TOTEMS = { { true, "Test Totem", 100, 120, 134000, 12345 }, { false, "", 0, 0, 0 } }
function GetTotemInfo(slot) local t = TOTEMS[slot]; if t then return unpack(t) end return false, "", 0, 0, 0 end
function GetTotemTimeLeft(slot) return slot == 1 and 90 or 0 end
function UnitPosition() return 100.5, 200.25, 0, 1 end
function IsInInstance() return false, "none" end
C_Map = { GetBestMapForUnit = function() return 1429 end,
          GetPlayerMapPosition = function() return { GetXY = function() return 0.4, 0.5 end } end,
          GetWorldPosFromMapPos = function() return 0, { x = 1, y = 2 } end }
C_Minimap = { GetViewRadius = function() return 233 end }
C_Spell = { GetSpellDescription = function(id) return "Heals allies within 30 yards of the totem. Lasts 15 sec." end,
            GetSpellInfo = function(id) return { name = "Test Totem Spell" } end }
function issecretvalue(v) return false end
'''


def run(title, extra=""):
    print("\n== " + title)
    R = lua51.LuaRuntime(unpack_returned_tuples=True)
    R.execute(MOCK)
    R.execute(BASE)
    R.execute(extra)
    code = open(os.path.join(ADDON, "TotemRange_Probe", "TotemRange_Probe.lua"), encoding="utf-8").read()
    R.eval("function(c) assert(loadstring(c, '@Probe.lua'))('TotemRange_Probe', {}) end")(code)
    return R


def said(R):
    return "\n".join(R.eval("PRINTED").values())


def slash(R, cmd):
    R.execute("SlashCmdList.TOTEMRANGEPROBE(%s); RunTimers()" % ("[=[" + cmd + "]=]"))


R = run("probe on a client with everything", FULL)
slash(R, "")
out = said(R)
check("it prints a report without erroring", "Totem Range probe report" in out and "error" not in out.lower(), out[-300:])
check("it names the functions it found", "GetTotemInfo" in out and "UnitPosition" in out)
check("it shows the totem slot values", "name=Test Totem" in out)
check("it shows the position", "100.5" in out and "mapID=1429" in out)
check("it shows the minimap view radius", "viewRadius=233" in out)
R.execute('FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 777); RunTimers()')
out = said(R)
check("a cast is logged with the yards parsed from the game's own description", "yards in description: 30" in out, out[-200:])
check("the log is saved with position and totem slots", R.eval("#TotemRangeProbeDB.log") == 1 and R.eval("TotemRangeProbeDB.log[1].totems ~= nil and TotemRangeProbeDB.log[1].position ~= nil"))
check("the slots are looked at again after the cast", R.eval("TotemRangeProbeDB.log[1].totemsAfter ~= nil"))
R.execute('FireEvent("UNIT_SPELLCAST_SUCCEEDED", "party1", "guid", 778); RunTimers()')
check("other units' casts are ignored", R.eval("#TotemRangeProbeDB.log") == 1)
slash(R, "log")
check("/trprobe log lists casts", "Test Totem Spell" in said(R))
slash(R, "clear")
check("/trprobe clear empties it", R.eval("#TotemRangeProbeDB.log") == 0)
check("no combat-log registration", R.eval("(function() for f in pairs(EVENT_FRAMES) do if f._events.COMBAT_LOG_EVENT_UNFILTERED then return true end end return false end)()") is False)

R = run("probe on a client with none of it")
slash(R, "")
out = said(R)
check("every missing function is reported, nothing errors", "MISSING" in out and "GetTotemInfo" in out and "Totem Range probe report" in out, out[-300:])
R.execute('FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 777); RunTimers()')
check("a cast with no spell data still logs", R.eval("#TotemRangeProbeDB.log") == 1)
check("no errors", "lua error" not in said(R).lower())

R = run("secret values are reported as unreadable", FULL + 'function issecretvalue(v) return type(v) == "number" end')
slash(R, "")
check("it says position is secret when it is", "SECRET" in said(R))
R.execute('FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 777); RunTimers()')
check("a secret spell id is skipped, not stored", R.eval("#TotemRangeProbeDB.log") == 0)

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
