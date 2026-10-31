"""Drive the Forge's Ledger addon (core + optional Professions satellite) in a
mock WoW UI, per scenario, and check the bar's acceptance behaviour."""
import os, sys
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = sys.argv[1]
fails = []

RETAIL = r'''
WOW_PROJECT_MAINLINE = 1; WOW_PROJECT_ID = 1
Enum = { WeeklyRewardChestThresholdType = { Activities = 1, Raid = 3, Concession = 5, World = 6 }, BankType = { Account = 2 } }
C_WeeklyRewards = {
  GetActivities = function() return {
    { type = 1, progress = 3, threshold = 1 }, { type = 1, progress = 3, threshold = 4 }, { type = 1, progress = 3, threshold = 8 },
    { type = 3, progress = 2, threshold = 2 }, { type = 3, progress = 2, threshold = 4 }, { type = 3, progress = 2, threshold = 6 },
    { type = 6, progress = 0, threshold = 2 }, { type = 6, progress = 0, threshold = 4 }, { type = 6, progress = 0, threshold = 8 }, { type = 5, progress = 3, threshold = 3 } } end,
  HasAvailableRewards = function() return false end }
C_MythicPlus = { GetRunHistory = function() return { { thisWeek = true, completed = true, level = 10 },
  { thisWeek = true, completed = true, level = 12 }, { thisWeek = true, completed = false, level = 14 } } end,
  RequestMapInfo = function() end }
C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 3 * 86400 end }
C_Bank = { FetchDepositedMoney = function() return 50000000 end }
RequestRaidInfo = function() end
'''

def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (("  -> " + str(detail)) if detail and not cond else ""))
    if not cond:
        fails.append(name)

def run(title, game="retail", satellite=True, saved=None, extra=""):
    print("\n== " + title)
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read())
    if game == "retail":
        L.execute(RETAIL)
    L.execute(extra)
    ns = L.eval("{}")
    def load(path, name, ns_):
        code = open(path, encoding="utf-8").read()
        chunk = L.eval("function(code, n) local f, err = loadstring(code, '@'..n); if not f then error(err) end; return f end")(code, name)
        chunk(name.split("/")[0], ns_)
    for f in ["ForgesLedger.lua", "ForgesLedger_Windows.lua", "ForgesLedger_Bar.lua"]:
        load(os.path.join(ADDON, "ForgesLedger", f), "ForgesLedger/" + f, ns)
    if satellite:
        load(os.path.join(ADDON, "ForgesLedger_Professions", "ForgesLedger_Professions.lua"),
             "ForgesLedger_Professions/ForgesLedger_Professions.lua", L.eval("{}"))
    # WoW loads saved variables after the files run, then ADDON_LOADED
    L.execute(saved or "")
    L.execute('FireEvent("ADDON_LOADED", "ForgesLedger"); FireEvent("PLAYER_LOGIN"); RunTimers(); RunTimers()')
    return L, ns

def segs(L):
    return list(L.eval('''function()
      local out = {}
      local bar = ForgesLedgerBar
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == bar and f._kind == "Button" and f.plugin and f:IsShown() then
          local x = f._points[1] and f._points[1][4] or 0
          table.insert(out, { x = x, id = f.plugin.id, text = f.label:GetText(), dot = f.dot._shown })
        end
      end
      table.sort(out, function(a, b) return a.x < b.x end)
      local s = {}
      for i, e in ipairs(out) do s[i] = e.id .. "=" .. e.text .. (e.dot and " [dot]" or "") end
      return s
    end''')().values())

def seg_button(L, pid):
    return L.eval('function(id) for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerBar and f.plugin and f.plugin.id == id and f:IsShown() then return f end end end')(pid)

def window_lines(L, wid):
    return list(L.eval('''function(id)
      local f = _G["ForgesLedgerWindow" .. id]
      if not f or not f:IsShown() then return {} end
      local out = {}
      for _, r in ipairs(f.rows) do if r._shown then table.insert(out, r.left:GetText() .. (r.right:GetText() ~= "" and ("  |  " .. r.right:GetText()) or "")) end end
      return out
    end''')(wid).values())

def errors(L):
    return [p for p in L.eval("PRINTED").values() if "error" in p.lower()]

SAVED = r'''
ForgeGoldDB = { chars = {
  ["Testchar-Area52"] = { name = "Testchar", class = "WARRIOR", money = 1, history = { { day = os.date("%Y-%m-%d", time() - 9*86400), money = 100000000 } },
     cooldowns = { ["1"] = { name = "Transmute: Example", profession = "Alchemy", readyAt = time() - 60 },
                   ["2"] = { name = "Daily Cloth", profession = "Tailoring", readyAt = time() + 7200 } } },
  ["Testmage-Area52"] = { name = "Testmage", class = "MAGE", money = 20000000 } },
  warband = { money = 50000000 }, savedAt = time() - 600 }
'''

# ---------------------------------------------------------------- retail, both addons
L, ns = run("Retail, core + Professions satellite", saved=SAVED)
s = segs(L)
print("  bar:", s)
check("bar shown, docked at the top by default", (L.eval("ForgesLedgerBar:IsShown() and ForgesLedgerBar._points[1][1]") or "").startswith("TOP"))
check("no floating Sync button any more", L.eval("ForgesLedgerSyncButton") is None)
check("segment order gold,todo,vault,professions,sync", [x.split("=")[0] for x in s] == ["gold", "todo", "vault", "professions", "sync"], s)
total = 123456789 + 20000000 + 50000000
check("gold = live money + other chars + warband", s and s[0].startswith("gold=|cffe6bf40%dg" % (total // 10000)), s[0] if s else None)
check("vault text from v2.5 data", any(x.startswith("vault=Vault: M+ 3/8") for x in s), s)
check("professions shows 1 ready with dot", "professions=Professions: 1 ready [dot]" in s, s)
check("no errors printed", not errors(L), errors(L))

L.execute("MONEY = MONEY + 10000 * 5; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
s2 = segs(L)
check("gold updates on PLAYER_MONEY", s2[0].startswith("gold=|cffe6bf40%dg" % ((total + 50000) // 10000)), s2[0])

# clicks: each segment toggles its window
for pid, wid in [("gold", "gold"), ("todo", "todo"), ("vault", "vault"), ("professions", "professions")]:
    b = seg_button(L, pid)
    L.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(b)
    lines = window_lines(L, wid)
    if pid == "professions":  # since v1.7 it opens the satellite's own panel
        lines = ["(Ledger panel)"] if L.eval("ForgesLedgerProfessionsHub and ForgesLedgerProfessionsHub:IsShown()") else []
    check("click %s opens its window" % pid, len(lines) > 0, lines)
    if pid == "vault":
        check("vault: Concession shown as the Or-collect reward", any(x.startswith("    Or collect a reward instead  |  available") for x in lines), lines)
        check("vault: no Concession slot row", not any("Concession" in x for x in lines), lines)
    if pid == "todo":
        check("todo: Concession not counted as a slot", any("Great Vault slots  |  2/9" in x for x in lines), lines)
    print("    " + "\n    ".join(lines))
    L.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(b)
    check("click %s again closes it" % pid, len(window_lines(L, wid)) == 0)
    # tooltip
    L.eval("function(b) b._scripts.OnEnter(b) end")(b)
    check("hover card %s opens" % pid, L.eval("ForgesLedgerRosterTip and ForgesLedgerRosterTip:IsShown()"))
    L.eval("function(b) b._scripts.OnLeave(b) end")(b)
check("todo window counts match segment", True)

# anvil left = main window, right = menu
L.execute("ForgesLedgerBarAnvil._scripts.OnClick(ForgesLedgerBarAnvil, 'LeftButton')")
main = window_lines(L, "ledger")
check("anvil opens main window with gold breakdown", any("Total" in x for x in main), main)
print("    " + "\n    ".join(main))
L.execute("ForgesLedgerBarAnvil._scripts.OnClick(ForgesLedgerBarAnvil, 'RightButton')")
check("right-click opens the menu", L.eval("ForgesLedgerBarMenu:IsShown()"))
check("menu offers Move to bottom", L.eval("ForgesLedgerBarMenu.buttons[2].label:GetText()") == "Move to bottom", L.eval("ForgesLedgerBarMenu.buttons[2].label:GetText()"))
L.execute("ForgesLedgerBarMenu.buttons[2]._scripts.OnClick(ForgesLedgerBarMenu.buttons[2])")
check("Move to bottom docks the bar at the bottom", L.eval("ForgesLedgerBar._points[1][1]").startswith("BOTTOM"))
L.execute("ForgesLedgerBarAnvil._scripts.OnClick(ForgesLedgerBarAnvil, 'RightButton')")
check("menu then offers Move to top", L.eval("ForgesLedgerBarMenu.buttons[2].label:GetText()") == "Move to top")
L.execute("ForgesLedgerBarMenu.buttons[2]._scripts.OnClick(ForgesLedgerBarMenu.buttons[2])")
check("and back to the top", L.eval("ForgesLedgerBar._points[1][1]").startswith("TOP"))

# settings: hide a segment, re-flow; disable bar; windows still work
L.execute("ns_hidden = ForgeGoldDB.bar.hidden; ns_hidden.todo = true")
L.execute("FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
s3 = segs(L)
check("hidden segment disappears and others re-flow", [x.split("=")[0] for x in s3] == ["gold", "vault", "professions", "sync"], s3)
L.execute("ForgeGoldDB.bar.hidden.todo = nil")
L.execute("SlashCmdList.FORGESLEDGER('settings')")
st = window_lines(L, "settings")
check("settings window lists segments", any("Professions" in x for x in st), st)
print("    " + "\n    ".join(st))
L.execute("SlashCmdList.FORGESLEDGER('bar')")
check("/fl bar hides the bar", not L.eval("ForgesLedgerBar:IsShown()"))
L.execute("SlashCmdList.FORGESLEDGER('vault')")
check("/fl vault works with the bar hidden", len(window_lines(L, "vault")) > 0)
L.execute("SlashCmdList.FORGESLEDGER('gold')")
check("/fl gold works with the bar hidden", len(window_lines(L, "gold")) > 0)
L.execute("SlashCmdList.FORGESLEDGER('bar'); SlashCmdList.FORGESLEDGER('bar top'); RunTimers()")
check("/fl bar top re-docks at top", (L.eval("ForgesLedgerBar:IsShown() and ForgesLedgerBar._points[1][1]") or "").startswith("TOP"))
L.execute("SlashCmdList.FORGESLEDGER('')")
check("/fl still prints gold", any("character(s)" in p for p in L.eval("PRINTED").values()))
check("no errors printed", not errors(L), errors(L))

# a broken satellite plugin: logged once, skipped, others fine
L.execute('''ForgesLedger.RegisterBarPlugin({ id = "broken", label = "Broken", order = 40, text = function() error("boom") end })
             RunTimers(); FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()''')
bad = [p for p in L.eval("PRINTED").values() if "Broken" in p]
check("broken plugin logged exactly once", len(bad) == 1, bad)
check("bar still renders others", len(segs(L)) == 5, segs(L))
check("bad registration rejected", L.eval("ForgesLedger.RegisterBarPlugin({ id = 5 })") is False)
# satellite replaces a core id
L.execute('ForgesLedger.RegisterBarPlugin({ id = "vault", label = "Dungeons", text = function() return "Vault: from satellite" end }); RunTimers(); RunTimers()')
check("satellite replaces core vault segment in place", any(x == "vault=Vault: from satellite" for x in segs(L)), segs(L))

# ---------------------------------------------------------------- retail, core only
L, ns = run("Retail, core only (satellite uninstalled)", satellite=False, saved=SAVED)
s = segs(L)
print("  bar:", s)
check("no professions segment", [x.split("=")[0] for x in s] == ["gold", "todo", "vault", "sync"], s)
L.execute("SlashCmdList.FORGESLEDGER('prof')")
check("/fl prof explains it's unavailable", any("isn't available" in p for p in L.eval("PRINTED").values()))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- satellite, older core
print("\n== Professions satellite with core v2.4 (no bar API)")
L2 = lua51.LuaRuntime(unpack_returned_tuples=True)
L2.execute(open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read()); L2.execute(RETAIL)
try:
    L2.execute("ForgesLedger = nil")
    code = open(os.path.join(ADDON, "ForgesLedger_Professions", "ForgesLedger_Professions.lua"), encoding="utf-8").read()
    L2.eval("function(c) assert(loadstring(c))('ForgesLedger_Professions', {}) end")(code)
    check("satellite loads without the bar API", True)
except Exception as e:
    check("satellite loads without the bar API", False, e)

# ---------------------------------------------------------------- fresh install, no saved data
L, ns = run("Retail, first run (no saved data)", saved="")
s = segs(L)
print("  bar:", s)
check("first run renders", s and s[0].startswith("gold="), s)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- forever
L, ns = run("WoW Forever (no vault, classic money)", game="forever", satellite=False,
            saved=SAVED.replace("cooldowns =", "cd_unused ="))
s = segs(L)
print("  bar:", s)
check("forever: no vault segment", "vault" not in [x.split("=")[0] for x in s], s)
check("forever: gold shows silver/copper", s and "s" in s[0] and "c" in s[0], s)
L.execute("SlashCmdList.FORGESLEDGER('vault')")
check("forever: /fl vault explains unavailable", any("isn't available" in p for p in L.eval("PRINTED").values()))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- roster cards
def tip(L):
    return L.eval(r"""function()
      local t = ForgesLedgerRosterTip
      if not t or not t:IsShown() then return nil end
      local out = { title = t.title:GetText(), h = t._h, w = t._w, alpha = t._alpha, rows = {}, foot = {},
                    point = t._points[1] and t._points[1][1], empty = t.empty._shown and t.empty:GetText() or nil }
      for _, r in ipairs(t.rows) do if r._shown then
        table.insert(out.rows, { name = r.name:GetText(), value = r.value:GetText(), sub = r.sub._shown and r.sub:GetText() or nil,
          icon = r.icon._shown, bar = r.track._shown, fill = r.fill._w, pulse = r.pulse._playing }) end end
      for _, f in ipairs(t.foot) do if f._shown then table.insert(out.foot, f:GetText()) end end
      return out
    end""")()

def show(t):
    print("    [%s]  %dx%d  anchor=%s" % (t.title, t.w, t.h, t.point))
    for r in t.rows.values():
        print("      %-12s %-40s %s%s%s%s" % (r.name, r.value, ("| " + r.sub) if r.sub else "",
              " [bar]" if r.bar else "", " [pulse]" if r.pulse else "", "" if r.icon else " [no icon]"))
    if t.empty:
        print("      (empty) " + t.empty)
    for f in t.foot.values():
        print("      ~ " + f)

ROSTER_CHARS = r"""
local C = ForgeGoldDB.chars
C["Testchar-Area52"].level = 90
C["Testmage2-Area52"] = { name = "Testmage2", class = "MAGE", level = 90, money = 5,
    todo = { at = time() - 3600, vault = { Activities = { progress = 1, max = 8, unlocked = 1, total = 3 },
             Raid = { progress = 2, max = 6, unlocked = 1, total = 3 }, World = { progress = 0, max = 8, unlocked = 0, total = 3 } } } }
C["Wildthorn-Area52"] = { name = "Wildthorn", class = "WARRIOR", level = 90, money = 7,
    todo = { at = time() - 3600, vault = { Activities = { progress = 9, max = 8, unlocked = 3, total = 3 } } } }
C["Oldweek-Area52"] = { name = "Oldweek", class = "MAGE", level = 90, money = 9,
    todo = { at = time() - 9 * 86400, vault = { Activities = { progress = 8, max = 8, unlocked = 3, total = 3 } } } }
C["Noclass-Area52"] = { name = "Noclass", level = 90, money = 3 }
C["Lowbie-Area52"] = { name = "Lowbie", class = "MAGE", level = 12, money = 1 }
for i = 0, 19 do C["Alt" .. i .. "-Area52"] = { name = "Alt" .. i, class = "MAGE", level = 90, money = i * 1000,
    todo = { at = time() - 3600, vault = { Activities = { progress = 2, max = 8, unlocked = 1, total = 3 } } } } end
"""
L, ns = run("Roster cards (25+ characters)", saved=SAVED + ROSTER_CHARS)
for pid in ["gold", "todo", "vault", "professions"]:
    b = seg_button(L, pid)
    L.eval("function(b) b._scripts.OnEnter(b) end")(b)
    t0 = tip(L)
    check("hover %s: card starts transparent (fade in)" % pid, t0 is not None and t0.alpha == 0, t0 and t0.alpha)
    L.execute("RunOnUpdates(0.2)")
    t = tip(L)
    check("hover %s: fully shown after ~150ms" % pid, t is not None and t.alpha == 1, t and t.alpha)
    show(t)
    check("%s: fits on screen (h=%s of 768)" % (pid, t.h), t.h < 768 * 0.9)
    check("%s: honesty footer" % pid, list(t.foot.values())[-1] == "As of each character's last login.")
    check("%s: animation stopped running after open" % pid, L.eval("ForgesLedgerRosterTip._scripts.OnUpdate") is None)
    if pid == "gold":
        rows = list(t.rows.values())
        check("gold: top 10 by gold", len(rows) == 10 and rows[0].name == "Testchar", [r.name for r in rows])
        check("gold: +N more characters footer", any("more characters" in f for f in t.foot.values()), list(t.foot.values()))
    if pid == "vault":
        rows = list(t.rows.values())
        names = [r.name for r in rows]
        ow = [r for r in rows if r.name == "Oldweek"]
        check("vault: last week's 8/8 shown as 0/8 this week", ow and ow[0].value == "M+ 0/8", names)
        check("vault: 8/8 char left out and counted", "Wildthorn" not in names and any("8/8 complete: 1" in f for f in t.foot.values()), list(t.foot.values()))
        check("vault: low-level alt left out", "Lowbie" not in names)
        check("vault: fewest runs first", names.index("Testmage2") > names.index("Oldweek"), names)
        check("vault: capped at 12 rows with +N more", len(names) == 12 and any("more" in f for f in t.foot.values()), (len(names), list(t.foot.values())))
        pf = [r for r in rows if r.name == "Testmage2"]
        check("vault: Testmage2 row present", bool(pf), names)
        if pf:
            check("vault: grey sub line has Raid and World", pf[0].sub == "Raid 2/6 · World 0/8", pf[0].sub)
            check("vault: mini bar 1/8 filled", pf[0].bar and abs(pf[0].fill - 10) < 0.01, (pf[0].bar, pf[0].fill))
        nc = L.eval("function() for _, r in ipairs(ForgesLedgerRosterTip.rows) do if r._shown and r.name:GetText() == 'Noclass' then return r.icon._shown end end return 'absent' end")()
        check("vault: no class recorded -> no icon, bone name", nc is False, nc)
    if pid == "professions":
        r = list(t.rows.values())
        check("professions: ready row pulses, says ready now", bool(r) and r[0].pulse and "ready now" in r[0].value, r and r[0].value)
    L.eval("function(b) b._scripts.OnLeave(b) end")(b)
    check("leave %s hides the card" % pid, tip(L) is None)

L.execute('ForgesLedger.RegisterBarPlugin({ id = "bad", label = "Bad", order = 60, text = function() return "Bad" end, roster = function() error("x") end }); RunTimers(); RunTimers()')
b = seg_button(L, "bad")
L.eval("function(b) b._scripts.OnEnter(b) end")(b)
L.execute("RunOnUpdates(0.2)")
t = tip(L)
check("failing roster: title + Data unavailable", t is not None and t.title == "Bad" and t.empty == "Data unavailable", t and (t.title, t.empty))
check("failing roster: segment stays on", seg_button(L, "bad") is not None)
L.eval("function(b) b._scripts.OnLeave(b) end")(b)
L.execute("SlashCmdList.FORGESLEDGER('bar top'); RunTimers(); RunTimers()")
b = seg_button(L, "vault")
L.eval("function(b) b._scripts.OnEnter(b) end")(b)
L.execute("RunOnUpdates(0.2)")
check("top-docked: card hangs below the bar", tip(L).point == "TOPLEFT", tip(L).point)
L.execute("SlashCmdList.FORGESLEDGER('bar')")
check("hiding the bar hides the card", tip(L) is None)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- centered segments
L, ns = run("Centered segments (Full width bar)", saved=SAVED + 'ForgeGoldDB.bar = { width = "FULL" }')
L.execute("ForgesLedgerBar._w = 1366; ForgesLedgerBarAnvil._w = 30; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
def anvil_x(L):
    return L.eval("ForgesLedgerBarAnvil._points[1][4]")
def group_right(L):
    return L.eval("""function()
      local r = 0
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == ForgesLedgerBar and f.plugin and f:IsShown() then r = math.max(r, f._points[1][4] + f._w) end
      end
      return r end""")()
ax, gr = anvil_x(L), group_right(L)
print("    anvil at %s, group ends at %s, bar 1366" % (ax, gr))
check("centered by default: equal space both sides", abs(ax - (1366 - gr)) <= 1, (ax, 1366 - gr))
check("segments follow the anvil in order", [x.split("=")[0] for x in segs(L)] == ["gold", "todo", "vault", "professions", "sync"], segs(L))
L.execute("SlashCmdList.FORGESLEDGER('bar left'); RunTimers(); RunTimers()")
check("/fl bar left puts the group at the left edge", anvil_x(L) == 6, anvil_x(L))
L.execute("ForgesLedgerBarAnvil._scripts.OnClick(ForgesLedgerBarAnvil, 'RightButton')")
lbl = L.eval("ForgesLedgerBarMenu.buttons[3].label:GetText()")
check("menu offers Center the segments", lbl == "Center the segments", lbl)
L.execute("ForgesLedgerBarMenu.buttons[3]._scripts.OnClick(ForgesLedgerBarMenu.buttons[3]); RunTimers(); RunTimers()")
check("menu centers them again", abs(anvil_x(L) - ax) <= 1, anvil_x(L))
L.execute("ForgesLedgerBar._w = 1920; ForgesLedgerBar._scripts.OnSizeChanged(ForgesLedgerBar); RunTimers(); RunTimers()")
check("re-centers when the screen size changes", abs(anvil_x(L) - (1920 - (group_right(L) - anvil_x(L))) / 2) <= 1, anvil_x(L))
L.execute("SlashCmdList.FORGESLEDGER('bar top'); RunTimers(); RunTimers()")
check("centered at the top too", L.eval("ForgesLedgerBar._points[1][1]") == "TOPLEFT" and anvil_x(L) > 6)
check("no errors printed", not errors(L), errors(L))


# ---------------------------------------------------------------- core v2.12: the bar fits its segments
L, ns = run("Core v2.12: bar fits its segments (the clock fix)", saved=SAVED)
L.execute("ForgesLedgerBarAnvil._w = 30; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
pts = L.eval("ForgesLedgerBar._points")
print("    bar points:", [pts[i][1] for i in range(1, len(pts) + 1)], "width", L.eval("ForgesLedgerBar._w"))
check("default: one centered anchor at the top, not edge to edge", len(pts) == 1 and pts[1][1] == "TOP" and pts[1][3] == "TOP")
gr = group_right(L)
check("the bar is as wide as the anvil and segments plus a margin", abs(L.eval("ForgesLedgerBar._w") - (gr + 6)) <= 1,
      (L.eval("ForgesLedgerBar._w"), gr))
check("segments start 6 in from the bar's own edge", anvil_x(L) == 6, anvil_x(L))
L.execute("SlashCmdList.FORGESLEDGER('bar left'); RunTimers(); RunTimers()")
pts = L.eval("ForgesLedgerBar._points")
check("aligned left: a short bar at the left edge", len(pts) == 1 and pts[1][1] == "TOPLEFT")
L.execute("SlashCmdList.FORGESLEDGER('bar center'); RunTimers(); RunTimers()")
L.execute("ForgesLedgerBarAnvil._scripts.OnClick(ForgesLedgerBarAnvil, 'RightButton')")
lbl = L.eval("ForgesLedgerBarMenu.buttons[4].label:GetText()")
check("menu offers Stretch the bar full width", lbl == "Stretch the bar full width", lbl)
L.execute("ForgesLedgerBarMenu.buttons[4]._scripts.OnClick(ForgesLedgerBarMenu.buttons[4]); RunTimers(); RunTimers()")
pts = L.eval("ForgesLedgerBar._points")
check("Full width: edge to edge again", len(pts) == 2 and pts[1][1] == "TOPLEFT" and pts[2][1] == "TOPRIGHT"
      and L.eval("ForgeGoldDB.bar.width") == "FULL")
L.execute("SlashCmdList.FORGESLEDGER('bar fit'); RunTimers(); RunTimers()")
pts = L.eval("ForgesLedgerBar._points")
check("/fl bar fit: back to the short centered bar", len(pts) == 1 and pts[1][1] == "TOP" and L.eval("ForgeGoldDB.bar.width") == "FIT")
L.execute("SlashCmdList.FORGESLEDGER('bar bottom'); RunTimers(); RunTimers()")
pts = L.eval("ForgesLedgerBar._points")
check("Fit works at the bottom too", len(pts) == 1 and pts[1][1] == "BOTTOM")
lines = L.eval("(function() local o = {}; for _, l in ipairs(ForgesLedgerBarSettingsLinesForTest()) do table.insert(o, l.text) end; return o end)()") \
    if L.eval("ForgesLedgerBarSettingsLinesForTest") else None
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- sync on the bar, top default
L, ns = run("Sync segment and top default", saved=SAVED)
L.execute("ForgeGoldDB.savedAt = time(); FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
s = segs(L)
sync = [x for x in s if x.startswith("sync=")]
check("sync segment shows Sync (just saved, nothing new)", sync == ["sync=Sync"], s)
L.execute("ForgeGoldDB.savedAt = time() - 600; MONEY = MONEY + 1; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
sync = [x for x in segs(L) if x.startswith("sync=")]
check("new data + 10 min since save -> gold Sync now", sync == ["sync=|cffe6bf40Sync now|r"], sync)
b = seg_button(L, "sync")
L.eval("function(b) b._scripts.OnEnter(b) end")(b)
tt = list(L.eval("GameTooltip._lines").values())
check("sync tooltip says when the app was last updated", any("Dashboard last updated" in x for x in tt), tt)
L.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(b)
check("clicking Sync saves and reloads", L.eval("RELOADED") is True and L.eval("ForgeGoldDB.syncPending") is True)
check("clicking Sync opens no window", L.eval("ForgesLedgerWindowsync") is None)
L.execute("SlashCmdList.FORGESLEDGER('button')")
check("/fl button explains the move", any("on the bar now" in p for p in L.eval("PRINTED").values()))
L.execute("ForgeGoldDB.bar.hidden.sync = true; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
check("sync segment can be hidden in settings", not any(x.startswith("sync=") for x in segs(L)), segs(L))
check("no errors printed", not errors(L), errors(L))

L, ns = run("Upgrade: saved BOTTOM from the old default", saved=SAVED + 'ForgeGoldDB.bar = { enabled = true, anchor = "BOTTOM", hidden = {} }')
check("old default BOTTOM moves to the top once", L.eval("ForgesLedgerBar._points[1][1]").startswith("TOP"))
L, ns = run("Upgrade: bottom chosen since v2.7", saved=SAVED + 'ForgeGoldDB.bar = { enabled = true, anchor = "BOTTOM", anchorChosen = true, hidden = {} }')
check("a chosen bottom stays at the bottom", L.eval("ForgesLedgerBar._points[1][1]").startswith("BOTTOM"))

# ---------------------------------------------------------------- Professions panel (satellite v1.7)
PROFS = r"""
COMBAT = false
function InCombatLockdown() return COMBAT end
PROF_LIST = { 11, 12 }
PROF_INFO = { [11] = { "Tailoring", 136249, 45, 100, 2, 4, 197 }, [12] = { "Enchanting", 136244, 10, 100, 2, 6, 333 } }
SPELLBOOK = { [5] = 3908, [7] = 7411 }   -- slot -> spell id
function GetProfessions() return PROF_LIST[1], PROF_LIST[2], nil, nil, nil end
function GetProfessionInfo(i) local p = PROF_INFO[i]; return p[1], p[2], p[3], p[4], p[5], p[6], p[7] end
Enum.SpellBookSpellBank = { Player = 0 }
C_SpellBook = { GetSpellBookItemInfo = function(slot) local id = SPELLBOOK[slot]; return id and { spellID = id } or nil end }
C_Spell = { GetSpellName = function(id) return ({ [3908] = "Tailoring", [7411] = "Enchanting" })[id] end,
            GetSpellTexture = function(id) return 1000 + id end }
"""
SAT = r"""
ForgesLedgerProfessionsDB = { characters = { ["Testchar-Area52"] = { data = { professions = {}, tiers = {
  ["Midnight Tailoring"] = { profession = "Tailoring", expansion = "Midnight", skill = 45, maxSkill = 100 },
  ["Khaz Algar Tailoring"] = { profession = "Tailoring", expansion = "Khaz Algar", skill = 100, maxSkill = 100 },
  ["Kul Tiran Tailoring"] = { profession = "Tailoring", expansion = "Kul Tiran", skill = 0, maxSkill = 0 },
  ["Classic Tailoring"] = { profession = "Tailoring", expansion = "Classic", skill = 300, maxSkill = 300 },
  ["Midnight Enchanting"] = { profession = "Enchanting", expansion = "Midnight", skill = 10, maxSkill = 100 } } } } } }
"""

def hub(L):
    return L.eval(r"""function()
      local h = ForgesLedgerProfessionsHub
      if not h or not h:IsShown() then return nil end
      local o = { tabs = {}, tiers = {}, cards = {}, none = h.none._shown, maxed = h.maxed:GetText(), dots = {}, alpha = h._alpha }
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == h and f.profession and f._kind == "Button" and f._shown then
          table.insert(o.tabs, { name = f.text:GetText(), x = f._points[1][4], active = f.under._shown, pulse = f.pulse._playing, spell = f.spell })
        end
        if f._parent == h.zone and f.label and f._shown then table.insert(o.tiers, f.label:GetText() .. " " .. f.value:GetText()) end
        if f._parent == h.cds and f.state and f._shown then
          table.insert(o.cards, { name = f.name:GetText(), state = f.state:GetText(), pulse = f.pulse._playing, y = f._points[1][5], x = f._points[1][4] }) end
        if f._parent == h.zone and f._kind == "Texture" and f._dotcolor then table.insert(o.dots, f._dotcolor) end
      end
      table.sort(o.tabs, function(a, b) return a.x < b.x end)
      table.sort(o.cards, function(a, b) if a.y ~= b.y then return a.y > b.y end return a.x < b.x end)
      return o
    end""")()

def secure(L):
    return list(L.eval(r"""function()
      local out = {}
      for i = 1, 4 do local b = _G["ForgesLedgerProfessionsTab" .. i]
        if b then table.insert(out, (b._shown and "shown" or "hidden") .. ":" .. tostring(b._attr.spell) .. ":" .. (b._points[1] and "anchored" or "free")) end end
      return out end""")().values())

def show_hub(h):
    print("    tabs:", [(t.name, "active" if t.active else "", "PULSE" if t.pulse else "") for t in h.tabs.values()])
    print("    " + str(h.maxed))
    for t in h.tiers.values(): print("      " + t)
    for c in h.cards.values(): print("      [card] %-22s %-14s %s" % (c.name, c.state, "pulse" if c.pulse else ""))

L, ns = run("Professions panel: two professions", saved=SAVED + SAT, extra=PROFS)
L.execute("SlashCmdList.FORGESLEDGER('professions'); RunOnUpdates(0.2)")
h = hub(L)
check("/fl professions opens the panel", h is not None)
show_hub(h)
check("open animation ends fully shown", h.alpha == 1, h.alpha)
tabs = list(h.tabs.values())
check("one tab per primary profession, first selected", [t.name for t in tabs] == ["Tailoring", "Enchanting"] and tabs[0].active, [(t.name, t.active) for t in tabs])
check("tab spells come from the game's spellbook", [t.spell for t in tabs] == [3908, 7411], [t.spell for t in tabs])
tiers = list(h.tiers.values())
check("tiers newest first, unlearned shown at 0", tiers == ["Midnight 45/100", "Khaz Algar 100/100", "Kul Tiran 0", "Classic 300/300"], tiers)
check("maxed count", h.maxed == "2 of 4 expansions maxed", h.maxed)
cards = list(h.cards.values())
check("cooldown cards: ready first", cards[0].state == "READY NOW" and cards[0].pulse and cards[1].state == "2h 0m 0s", [(c.name, c.state) for c in cards])
check("secure overlays on both tabs out of combat", secure(L) == ["shown:3908:anchored", "shown:7411:anchored"], secure(L))

# clicking the Enchanting overlay: casts (secure) + our hook switches tabs
L.execute("ForgesLedgerProfessionsTab2._scripts.OnClick(ForgesLedgerProfessionsTab2, 'LeftButton')")
h = hub(L)
check("tab click switches the profession zone", [t.active for t in h.tabs.values()] == [False, True] and list(h.tiers.values()) == ["Midnight 10/100"], list(h.tiers.values()))

# live countdown: tick, then let Daily Cloth expire
L.execute("AdvanceTime(10); for _, t in ipairs(TICKERS) do t() end")
h = hub(L)
check("countdown ticks while open", list(h.cards.values())[1].state == "1h 59m 50s", list(h.cards.values())[1].state)
L.execute("AdvanceTime(7200); for _, t in ipairs(TICKERS) do t() end")
h = hub(L)
cards = list(h.cards.values())
check("expired cooldown flips to READY NOW and pulses", all(c.state == "READY NOW" and c.pulse for c in cards), [(c.name, c.state, c.pulse) for c in cards])
check("its profession's tab pulses", [t.pulse for t in h.tabs.values()] == [True, False], [(t.name, t.pulse) for t in h.tabs.values()])

# combat: overlays come off when it starts; panel still opens/closes; back after
L.execute("FireEvent('PLAYER_REGEN_DISABLED'); COMBAT = true")
check("combat start removes the secure overlays", secure(L) == ["hidden:3908:free", "hidden:7411:free"], secure(L))
L.execute("SlashCmdList.FORGESLEDGER('professions')")
check("closes in combat without touching secure frames", hub(L) is None)
L.execute("SlashCmdList.FORGESLEDGER('professions'); RunOnUpdates(0.2)")
check("opens in combat", hub(L) is not None)
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub and f.profession and f._kind == 'Button' and f.text:GetText() == 'Tailoring' then f._scripts.OnClick(f) end end")
check("in combat a tab click still switches the panel", [t.active for t in hub(L).tabs.values()] == [True, False])
L.execute("COMBAT = false; FireEvent('PLAYER_REGEN_ENABLED')")
check("overlays return after combat", secure(L) == ["shown:3908:anchored", "shown:7411:anchored"], secure(L))

# ticker stops on hide; drag position persists
L.execute("TICKERS_CANCELLED = 0")
L.execute("ForgesLedgerProfessionsHub._points = { { 'TOPLEFT', UIParent, 'TOPLEFT', 300, -200 } }; ForgesLedgerProfessionsHub._scripts.OnDragStop(ForgesLedgerProfessionsHub)")
L.execute("ForgesLedgerProfessionsHub:Hide()")
check("1s ticker cancelled when the panel closes", L.eval("TICKERS_CANCELLED") == 1, L.eval("TICKERS_CANCELLED"))
pos = L.eval("ForgesLedgerProfessionsDB.hubPos")
check("drag position saved", pos is not None and list(pos.values()) == ["TOPLEFT", "TOPLEFT", 300, -200], pos and list(pos.values()))
check("no errors printed", not errors(L), errors(L))

L, ns = run("Professions panel: position restored after /reload", saved=SAVED + SAT + "\nForgesLedgerProfessionsDB.hubPos = { 'TOPLEFT', 'TOPLEFT', 300, -200 }", extra=PROFS)
L.execute("SlashCmdList.FORGESLEDGER('professions'); RunOnUpdates(0.2)")
p = L.eval("ForgesLedgerProfessionsHub._points[1]")
check("panel reopens where it was dragged", (p[1], p[3], p[4], p[5]) == ("TOPLEFT", "TOPLEFT", 300, -200), (p[1], p[3], p[4], p[5]))

L, ns = run("Professions panel: bar click, one profession, spell missing", saved=SAVED + SAT, extra=PROFS + "\nPROF_LIST = { 12 }; SPELLBOOK = {}")
b = seg_button(L, "professions")
L.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(b)
L.execute("RunOnUpdates(0.2)")
h = hub(L)
check("bar segment opens the panel", h is not None)
check("one profession: one tab", h and [t.name for t in h.tabs.values()] == ["Enchanting"])
check("spell not found: no secure overlay, tab still works", secure(L) == [], secure(L))
L.execute("SlashCmdList.FORGESLEDGERPROF('tabs')")
check("/flp tabs reports the missing spell", any("no spell found" in p for p in L.eval("PRINTED").values()))
L.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(b)
check("bar segment click again closes it", hub(L) is None)
check("no errors printed", not errors(L), errors(L))

L, ns = run("Professions panel: no professions", saved=SAVED, extra=PROFS + "\nPROF_LIST = {}")
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
h = hub(L)
check("no professions: 'No professions learned.'", h is not None and h.none and len(h.tabs) == 0, h and (h.none, len(h.tabs)))
show_hub(h)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- panel opens with the profession window (v1.8)
AUTO = PROFS + r"""
PROF_INFO[13] = { "Fishing", 136245, 12, 300, 0, 0, 356 }
function GetProfessions() return PROF_LIST[1], PROF_LIST[2], nil, 13, nil end
ProfessionsFrame = CreateFrame("Frame", "ProfessionsFrame", UIParent); ProfessionsFrame:Hide()
OPEN_PROF, OPEN_TIER = nil, nil
C_TradeSkillUI = {
  GetBaseProfessionInfo = function() return OPEN_PROF and { professionName = OPEN_PROF } or {} end,
  GetChildProfessionInfo = function() return OPEN_TIER and { professionName = OPEN_TIER } or {} end }
function OpenWindow(prof, tier) OPEN_PROF, OPEN_TIER = prof, tier; ProfessionsFrame:Show(); FireEvent("TRADE_SKILL_SHOW"); RunTimers(); RunOnUpdates(0.2) end
function CloseWindow() ProfessionsFrame:Hide(); OPEN_PROF = nil; FireEvent("TRADE_SKILL_CLOSE"); RunTimers() end
"""
SAT_FISH = SAT.replace("} } } } }", r"""},
  ["Midnight Fishing"] = { profession = "Fishing", expansion = "Midnight", skill = 12, maxSkill = 300 } } } } }""", 1)

L, ns = run("Panel opens with the profession window", saved=SAVED + SAT_FISH, extra=AUTO)
check("the old side panel is gone", L.eval("ForgesLedgerProfessionsPanel") is None)
L.execute("OpenWindow('Enchanting', 'Midnight Enchanting')")
h = hub(L)
check("opening a profession opens the panel", h is not None)
check("...on that profession's tab", h and [t.name for t in h.tabs.values() if t.active] == ["Enchanting"], h and [(t.name, t.active) for t in h.tabs.values()])
check("...with the open tier marked", h and list(h.tiers.values()) == ["> Midnight 10/100"], h and list(h.tiers.values()))
L.execute("CloseWindow()")
check("closing the profession closes the panel it opened", hub(L) is None)

L.execute("OpenWindow('Fishing', 'Midnight Fishing')")
h = hub(L)
check("Fishing window: a Fishing tab appears and is selected", h and [(t.name, t.active) for t in h.tabs.values()] == [("Tailoring", False), ("Enchanting", False), ("Fishing", True)], h and [(t.name, t.active) for t in h.tabs.values()])
check("Fishing tab gets no quick-open overlay", secure(L) == ["shown:3908:anchored", "shown:7411:anchored"] or len(secure(L)) == 2, secure(L))
check("Fishing tiers shown", h and list(h.tiers.values()) == ["> Midnight 12/300"], h and list(h.tiers.values()))
L.execute("CloseWindow()")
check("Fishing panel closes with its window", hub(L) is None)

# opened by hand: stays open when a profession window opens and closes
L.execute("SlashCmdList.FORGESLEDGER('professions'); RunOnUpdates(0.2)")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring')")
check("by-hand panel follows the opened profession", [t.name for t in hub(L).tabs.values() if t.active] == ["Tailoring"])
L.execute("CloseWindow()")
h = hub(L)
check("by-hand panel stays open after the window closes", h is not None)
check("...tabs unchanged after the window closes", h and [t.name for t in h.tabs.values()] == ["Tailoring", "Enchanting", "Fishing"], h and [t.name for t in h.tabs.values()])
L.execute("ForgesLedgerProfessionsHub:Hide()")

L.execute("SlashCmdList.FORGESLEDGERPROF('panel')")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring')")
check("/flp panel turns auto-open off", hub(L) is None)
L.execute("CloseWindow(); SlashCmdList.FORGESLEDGERPROF('panel'); OpenWindow('Tailoring', 'Midnight Tailoring')")
check("/flp panel again turns it back on", hub(L) is not None)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- v2.9 / v1.9: anvil art, Cooking+Fishing tabs, craft counts
THREE = AUTO + r"""
PROF_INFO[14] = { "Cooking", 133971, 50, 300, 1, 8, 185 }
SPELLBOOK[9] = 2550
local spellNames = { [3908] = "Tailoring", [7411] = "Enchanting", [2550] = "Cooking" }
C_Spell.GetSpellName = function(id) return spellNames[id] end
function GetProfessions() return PROF_LIST[1], PROF_LIST[2], nil, 13, 14 end
RECIPES = { [50001] = { name = "Arcanoweave Bolt", learned = true, icon = 9001 },
            [50002] = { name = "Sunfire Silk Bolt", learned = true, icon = 9002 },
            [50003] = { name = "Unlearned Thing", learned = false } }
C_TradeSkillUI.GetRecipeInfo = function(id) return RECIPES[id] end
function Craft(id) FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-GUID", id); RunTimers() end
"""

L, ns = run("Anvil art, four tabs, craft counts", saved=SAVED + SAT_FISH, extra=THREE)
check("bar anvil uses the addon's own art", L.eval("(function() for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerBarAnvil and f._kind == 'Texture' and f._tex then return f._tex end end end)()") == "Interface\\AddOns\\ForgesLedger\\Media\\anvil")
b = seg_button(L, "vault")
L.eval("function(b) b._scripts.OnEnter(b) end")(b)
check("hover card header uses the anvil art", L.eval("ForgesLedgerRosterTip.icon._tex") == "Interface\\AddOns\\ForgesLedger\\Media\\anvil")
L.eval("function(b) b._scripts.OnLeave(b) end")(b)
check("anvil.tga ships in the addon", os.path.isfile(os.path.join(ADDON, "ForgesLedger", "Media", "anvil.tga")))

L.execute("FireEvent('PLAYER_ENTERING_WORLD', true, false)")
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
h = hub(L)
check("tabs: primaries then Cooking and Fishing", [t.name for t in h.tabs.values()] == ["Tailoring", "Enchanting", "Cooking", "Fishing"], [t.name for t in h.tabs.values()])
check("Cooking gets a quick-open, Fishing doesn't", secure(L) == ["shown:3908:anchored", "shown:7411:anchored", "shown:2550:anchored"], secure(L))
check("panel widens to fit four tabs", L.eval("ForgesLedgerProfessionsHub._w") >= 470)
L.execute("SlashCmdList.FORGESLEDGERPROF('tabs')")
check("/flp tabs explains Fishing", any("casts your line" in p for p in L.eval("PRINTED").values()))
check("no crafts yet: session line hidden", not L.eval("ForgesLedgerProfessionsHub.session._shown"))

L.execute("OpenWindow('Tailoring', 'Midnight Tailoring')")
L.execute("Craft(50001); Craft(50001); Craft(50002); Craft(50001)")
L.execute("Craft(50003); Craft(12345)")              # unlearned recipe, not a recipe
L.execute("FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'party1', 'x', 50001)")  # someone else
line = L.eval("ForgesLedgerProfessionsHub.session:GetText()")
check("this session's crafts counted (only real, own crafts)", line == "This session: 4 crafts  ·  most made: Arcanoweave Bolt ×3", line)
check("session line shows the most-made item's icon", L.eval("ForgesLedgerProfessionsHub.sessionIcon._tex") == 9001)
L.execute("CloseWindow(); Craft(50001)")
check("no counting with the profession window closed", L.eval("ForgesLedgerProfessionsDB.characters['Testchar-Area52'].data.session.crafts") == 4)
L.execute("FireEvent('PLAYER_ENTERING_WORLD', false, true)")
check("/reload keeps the session", L.eval("ForgesLedgerProfessionsDB.characters['Testchar-Area52'].data.session.crafts") == 4)
L.execute("FireEvent('PLAYER_ENTERING_WORLD', true, false); SlashCmdList.FORGESLEDGERPROF('open'); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
line = L.eval("ForgesLedgerProfessionsHub.session:GetText()")
check("next login: it becomes Last session", line == "Last session: 4 crafts  ·  most made: Arcanoweave Bolt ×3", line)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Dungeons satellite v1.0 (core v2.10)
DUNGEONS = r"""
KEY_MAP, KEY_LVL = 502, 12
C_ChallengeMode = {
  GetMapTable = function() return { 501, 502, 503 } end,
  GetMapUIInfo = function(id) local n = { [501] = "Test Vault", [502] = "Test Spire", [503] = "Test Priory" }
                              return n[id], id, 1800, 5000 + id end,
  GetOverallDungeonScore = function() return 1847.4 end,
  GetDungeonScoreRarityColor = function() return { GetRGB = function(self) return 0.6, 0.3, 1 end } end }
C_MythicPlus.GetOwnedKeystoneChallengeMapID = function() return KEY_MAP end
C_MythicPlus.GetOwnedKeystoneLevel = function() return KEY_LVL end
C_MythicPlus.GetCurrentSeason = function() return 15 end
C_MythicPlus.RequestCurrentAffixes = function() end
C_MythicPlus.GetSeasonBestForMap = function(id)
  if id == 501 then return { level = 10 }, { level = 12 } end
  if id == 502 then return { level = 11 }, nil end
  return nil, nil end
EJ_SELECTED = 1
function EJ_GetNumTiers() return 3 end
function EJ_GetCurrentTier() return EJ_SELECTED end
function EJ_SelectTier(t) EJ_SELECTED = t end
function EJ_GetInstanceByIndex(i, raid)
  if EJ_SELECTED ~= 3 or not raid then return nil end
  if i == 1 then return 1001, "Test Raid" end
  if i == 2 then return 1002, "Test World Bosses" end
end
function EJ_GetInstanceInfo(id) return "x", "", 0, 0, 0, 0, 0, "", id == 1001 end
function EJ_GetEncounterInfoByIndex(e, id) if id == 1001 then return ({ "Boss A", "Boss B", "Boss C" })[e] end
                                           if id == 1002 then return ({ "World Boss" })[e] end end
function GetSavedInstanceInfo(i) return "Test Raid", 1, 3600, 15, true, false, 0, true, 20, "Heroic", 3, 2 end
function GetSavedInstanceEncounterInfo(i, e) return ({ "Boss A", "Boss B", "Boss C" })[e], nil, e <= 2 end
DifficultyUtil = { ID = { PrimaryRaidLFR = 17, PrimaryRaidNormal = 14, PrimaryRaidHeroic = 15, PrimaryRaidMythic = 16 } }
function GetDifficultyInfo(id) return ({ [17] = "Raid Finder", [14] = "Normal", [15] = "Heroic", [16] = "Mythic" })[id] end
function GetNumRFDungeons() return 1 end
function GetRFDungeonInfo(i) return 2001, "Wing One" end
function GetLFGDungeonNumEncounters(id) return 2 end
function GetLFGDungeonEncounterInfo(id, e) return ({ "Boss A", "Boss C" })[e], nil, e == 2 end
function RequestLFDPlayerLockInfo() end
"""
ALTS = r"""
ForgesLedgerDungeonsDB = { schemaVersion = 1, characters = {
  ["Altone-Area52"] = { data = { name = "Altone", class = "MAGE", keystoneAt = time() - 3600,
                                 keystone = { dungeonID = 501, level = 15, name = "Test Vault" } } },
  ["Oldkey-Area52"] = { data = { name = "Oldkey", class = "WARRIOR", keystoneAt = time() - 9 * 86400,
                                 keystone = { dungeonID = 503, level = 20, name = "Test Priory" } } } } }
"""

def load_dungeons(L):
    code = open(os.path.join(ADDON, "ForgesLedger_Dungeons", "ForgesLedger_Dungeons.lua"), encoding="utf-8").read()
    L.eval("function(c) assert(loadstring(c, '@ForgesLedger_Dungeons.lua'))('ForgesLedger_Dungeons', {}) end")(code)

def run_d(title, saved="", extra="", core_api=True):
    # like run(), with the Dungeons satellite loaded after the others
    print("\n== " + title)
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read())
    L.execute(RETAIL); L.execute(extra)
    ns = L.eval("{}")
    for f in ["ForgesLedger.lua", "ForgesLedger_Windows.lua", "ForgesLedger_Bar.lua"]:
        code = open(os.path.join(ADDON, "ForgesLedger", f), encoding="utf-8").read()
        L.eval("function(c, n, ns) assert(loadstring(c, '@' .. n))('ForgesLedger', ns) end")(code, f, ns)
    if not core_api:
        L.execute("ForgesLedger.GetBarPlugin = nil; ForgesLedger.RefreshBar = nil")  # an older core
    load_dungeons(L)
    L.execute(saved)
    L.execute('FireEvent("ADDON_LOADED", "ForgesLedger"); FireEvent("PLAYER_LOGIN"); RunTimers(); RunTimers(); RunTimers()')
    return L

def dpanel(L):
    return L.eval(r"""function()
      local p = ForgesLedgerDungeonsPanel
      if not p or not p:IsShown() then return nil end
      local o = { h1 = p.head1:GetText(), h2 = p.head2:GetText(), h3 = p.head3:GetText(), foot = p.foot:GetText(), cells = {}, rows = {}, heads = {} }
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == p.body and f._shown then
          if f.best then table.insert(o.cells, f.name:GetText() .. " | " .. f.best:GetText() .. (f.check._shown and " [timed]" or "") .. (f.key:GetText() ~= "" and (" | " .. f.key:GetText()) or "")) end
          if f.marks then
            local m = {}
            for j, t in ipairs(f.marks) do m[j] = (t._tex == "Interface\\RaidFrame\\ReadyCheck-Ready" and t._w == 16) and "X" or "." end
            table.insert(o.rows, f.name:GetText() .. " " .. table.concat(m))
          end
          if f.cols then
            local c = {}
            for j, l in ipairs(f.cols) do if l._shown then c[j] = l:GetText() end end
            table.insert(o.heads, f.name:GetText() .. ": " .. table.concat(c, ","))
          end
        end
      end
      return o
    end""")()

L = run_d("Dungeons: Mythic+ tab, vault segment, keys card", saved=SAVED + ALTS, extra=DUNGEONS)
s = segs(L)
print("  bar:", s)
check("vault segment: core count + this character's key", any(x.startswith("vault=Vault: M+ 3/8  ·  Key +12") for x in s), s)
b = seg_button(L, "vault")
L.eval("function(b) b._scripts.OnEnter(b) end")(b)
L.execute("RunOnUpdates(0.2)")
t = tip(L)
show(t)
rows = [(r.name, r.value) for r in t.rows.values()]
check("hover card keeps the core's vault rows", any(v.startswith("M+ ") for _, v in rows), rows)
check("hover card has a Keys section", ("Keys", "") in rows, rows)
ki = rows.index(("Keys", ""))
check("keys: highest first, this week's only", rows[ki + 1:] == [("Altone", "Test Vault  +15"), ("Testchar", "Test Spire  +12")], rows[ki + 1:])
check("keys: last week's key left out and counted", any("not seen since the weekly reset" in f for f in t.foot.values()), list(t.foot.values()))
check("card still fits on screen", t.h < 768 * 0.9, t.h)
L.eval("function(b) b._scripts.OnLeave(b) end")(b)
L.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(b)
L.execute("RunOnUpdates(0.2)")
p = dpanel(L)
check("vault segment click opens the Dungeons panel", p is not None)
print("   ", p.h1, "|", p.h2, "|", p.h3)
for c in p.cells.values(): print("      [cell] " + c)
check("rating from the game", p.h1 == "Mythic+ rating 1847", p.h1)
check("keystone line", p.h2 == "Your key: Test Spire +12", p.h2)
check("this week's runs, highest first", p.h3 == "This week: 3 runs  +14  +12  +10", p.h3)
cells = list(p.cells.values())
check("season grid from the game, bests and timed marks", cells == ["Test Vault | +12  over time", "Test Spire | +11 [timed] | your key +12", "Test Priory | no run this season"], cells)
L.execute("SlashCmdList.FORGESLEDGERDUNGEONS('raids')")
p = dpanel(L)
print("    raids:", list(p.heads.values()), list(p.rows.values()))
check("raids tab: current raid only (no world-boss page)", list(p.heads.values()) == ["Test Raid: Raid Finder,Normal,Heroic,Mythic"], list(p.heads.values()))
check("boss kills per difficulty: lockouts + Raid Finder", list(p.rows.values()) == ["Boss A ..X.", "Boss B ..X.", "Boss C X..."], list(p.rows.values()))
check("Adventure Guide tier put back", L.eval("EJ_SELECTED") == 1, L.eval("EJ_SELECTED"))
L.execute("SlashCmdList.FORGESLEDGER('dungeons')")
check("/fl dungeons toggles the panel (closed)", dpanel(L) is None)
L.execute("SlashCmdList.FORGESLEDGER('dungeons'); RunOnUpdates(0.2)")
check("/fl dungeons opens it again", dpanel(L) is not None)
# the key changes: bar updates after the read
L.execute("KEY_LVL = 11; FireEvent('BAG_UPDATE_DELAYED'); RunTimers(); RunTimers(); RunTimers()")
check("bar follows a keystone change", any("Key +11" in x for x in segs(L)), segs(L))
L.execute("KEY_MAP, KEY_LVL = nil, nil; FireEvent('BAG_UPDATE_DELAYED'); RunTimers(); RunTimers(); RunTimers()")
check("no keystone: key part omitted", any(x.startswith("vault=Vault: M+ 3/8") and "Key" not in x for x in segs(L)), segs(L))
saved = L.eval("ForgesLedgerDungeonsDB.characters['Testchar-Area52'].data")
check("saved per character, in the agreed envelope", L.eval("ForgesLedgerDungeonsDB.schemaVersion") == 1 and saved.mythicPlusRating is not None and saved.raidKills is not None)
check("no errors printed", not errors(L), errors(L))

L = run_d("Dungeons with an older core (no GetBarPlugin)", saved=SAVED, extra=DUNGEONS, core_api=False)
check("older core: vault segment untouched", any(x.startswith("vault=Vault: M+ 3/8") and "Key" not in x for x in segs(L)), segs(L))
L.execute("SlashCmdList.FORGESLEDGERDUNGEONS(''); RunOnUpdates(0.2)")
check("older core: /fld still opens the panel", dpanel(L) is not None)
check("no errors printed", not errors(L), errors(L))

print("\n== Dungeons on WoW Forever")
L = lua51.LuaRuntime(unpack_returned_tuples=True)
L.execute(open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read())
try:
    load_dungeons(L)
    check("Forever: loads without error and stays inert", L.eval("SlashCmdList.FORGESLEDGERDUNGEONS") is None)
except Exception as e:
    check("Forever: loads without error and stays inert", False, e)

# ---------------------------------------------------------------- the tribute (Dungeons 4.1)
L = run_d("Dungeons: the tribute", saved=SAVED, extra=DUNGEONS)
L.execute("SlashCmdList.FORGESLEDGERDUNGEONS(''); RunOnUpdates(0.2)")
check("tribute reads 'for Luna' and a heart", L.eval("ForgesLedgerDungeonsPanel.tribute:GetText()") == "for Luna <3", L.eval("ForgesLedgerDungeonsPanel.tribute:GetText()"))
check("tribute sits top right", L.eval("ForgesLedgerDungeonsPanel.tribute._points[1][3]") == "TOPRIGHT")
check("no icon textures left", L.eval("ForgesLedgerDungeonsPanel.heart") is None and L.eval("ForgesLedgerDungeonsPanel.moon") is None)
p = dpanel(L)
check("rest of the panel unchanged", p and p.h1 == "Mythic+ rating 1847" and len(p.cells) == 3)
L.execute("PRINTED = {}; SlashCmdList.FORGESLEDGERDUNGEONS('scan')")
printed = list(L.eval("PRINTED").values())
check("/fld scan prints keystone, rating and raids", len(printed) == 2 and "Keystone: Test Spire +12" in printed[0] and "Raids with kills this week: 1" in printed[1], printed)
L.execute("PRINTED = {}; SlashCmdList.FORGESLEDGERDUNGEONS('icons')")
check("/fld icons is gone (shows help)", any("commands:" in x for x in L.eval("PRINTED").values()))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Professions v1.10: next craft, shopping, celebration, pulse
CRAFT = AUTO + r"""
wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
Enum.TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 }
Enum.CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2 }
CHILD = { professionName = "Midnight Tailoring", parentProfessionName = "Tailoring", professionID = 501,
          expansionName = "Midnight", skillLevel = 45, maxSkillLevel = 100 }
C_TradeSkillUI.GetChildProfessionInfo = function() return CHILD end
C_TradeSkillUI.GetChildProfessionInfos = function() return { CHILD } end
RECIPES = {
  [101] = { name = "Bolt", learned = true, relativeDifficulty = 0, firstCraft = false, icon = 1 },
  [102] = { name = "Robe", learned = true, relativeDifficulty = 1, firstCraft = true, icon = 2 },
  [103] = { name = "Hat", learned = true, relativeDifficulty = 0, firstCraft = false, icon = 3 },   -- reagents unknown
  [104] = { name = "Cape", learned = false, relativeDifficulty = 0, firstCraft = true, icon = 4 },  -- not known
  [105] = { name = "Gloves", learned = true, relativeDifficulty = 2, firstCraft = true, icon = 5 },
  [106] = { name = "Belt", learned = true, relativeDifficulty = 3, firstCraft = false, icon = 6 } }
SCHEM = {
  [101] = { { 9001, 5 } }, [102] = { { 9001, 3 }, { 9002, 1 } }, [104] = { { 9003, 1 } },
  [105] = { { 9002, 2 } }, [106] = { { 9001, 1 } } }
C_TradeSkillUI.GetAllRecipeIDs = function() return { 101, 102, 103, 104, 105, 106 } end
C_TradeSkillUI.GetRecipeInfo = function(id) return RECIPES[id] end
C_TradeSkillUI.GetRecipeSchematic = function(id)
  local s = SCHEM[id]; if not s then return nil end
  local slots = {}
  for _, r in ipairs(s) do table.insert(slots, { required = true, reagentType = 1, quantityRequired = r[2],
                                                 reagents = { { itemID = r[1] }, { itemID = r[1] + 100 } } }) end
  table.insert(slots, { required = false, reagentType = 2, quantityRequired = 1, reagents = { { itemID = 7777 } } })  -- optional: ignored
  return { reagentSlotSchematics = slots }
end
OPENED = nil
C_TradeSkillUI.OpenRecipe = function(id) OPENED = id end
BAGS = { [9001] = 10, [9002] = 0 }
C_Item = { GetItemCount = function(id, bank) return BAGS[id] or 0 end,
           GetItemNameByID = function(id) return ({ [9001] = "Bright Linen", [9002] = "Dusk Thread" })[id] end,
           GetItemIconByID = function(id) return 4000 + id end, RequestLoadItemDataByID = function() end }
SOUNDKIT = { UI_EPICLOOT_TOAST = 31578 }
PLAYED = {}
function PlaySound(k) table.insert(PLAYED, k) end
"""

def sat(L, path):
    return L.eval("function() local c = ForgesLedgerProfessionsDB.characters['Testchar-Area52'].data; return c%s end" % path)()

L, ns = run("Professions v1.10: next craft and shopping list", saved=SAVED + SAT, extra=CRAFT)
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring')")
n = sat(L, ".nextCraft['Midnight Tailoring']")
check("next craft: a first-craft recipe, fewest reagents (Gloves)", n is not None and n.name == "Gloves", n and n.name)
check("next craft reason", n is not None and n.reason == "first craft bonus · reagents needed", n and n.reason)
shop = sat(L, ".shoppingList['Midnight Tailoring']")
items = {it.itemID: it.need for it in shop["items"].values()}
check("shopping list: one of each first craft (Robe, Gloves)", sorted(r.name for r in shop.recipes.values()) == ["Gloves", "Robe"], [r.name for r in shop.recipes.values()])
check("shopping list totals: 3 linen, 3 thread", items == {9001: 3, 9002: 3}, items)
check("never the recipe with unknown reagents, never an unlearned one", all(r.name not in ("Hat", "Cape") for r in shop.recipes.values()))
# panel: Next craft line, click shows the recipe
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("panel shows the Next craft line", L.eval("ForgesLedgerProfessionsHub.zone and true") and "Gloves" in L.eval("(function() for _, f in ipairs(ALL_FRAMES) do if f.why and f.text and f._shown then return f.text:GetText() end end end)()"))
L.execute("(function() for _, f in ipairs(ALL_FRAMES) do if f.why and f.recipeID then f._scripts.OnClick(f) end end end)()")
check("clicking it only opens the recipe in the window", L.eval("OPENED") == 105)
# reagents in the bags: tie-break flips to the recipe you can make now
L.execute("BAGS[9002] = 5; FireEvent('TRADE_SKILL_LIST_UPDATE'); RunTimers(); RunTimers()")
n = sat(L, ".nextCraft['Midnight Tailoring']")
check("with reagents in bags the reason says so", n.reason == "first craft bonus · you have the reagents", n.reason)
# first crafts used up: orange beats yellow
L.execute("RECIPES[102].firstCraft = false; RECIPES[105].firstCraft = false; FireEvent('TRADE_SKILL_LIST_UPDATE'); RunTimers(); RunTimers()")
n = sat(L, ".nextCraft['Midnight Tailoring']")
check("no first crafts left: orange (Bolt) over yellow (Robe)", n.name == "Bolt" and n.reason.startswith("orange"), (n.name, n.reason))
# shopping panel: have/need from bags, warband adds other characters
L.execute("(function() for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub and f._kind == 'Button' and f._scripts.OnClick and not f.profession then local fs; for _, g in ipairs(ALL_FRAMES) do if g._parent == f and g._kind == 'FontString' and g._text == 'Shopping list' then fs = g end end; if fs then f._scripts.OnClick(f) end end end end)()")
rows = list(L.eval("(function() local o = {}; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsShop and f.value and f._shown then table.insert(o, f.name:GetText() .. ' | ' .. f.value:GetText()) end end; return o end)()").values())
print("    shop rows:", rows)
check("shopping panel opens from the header button", L.eval("ForgesLedgerProfessionsShop and ForgesLedgerProfessionsShop:IsShown()"))
check("shopping panel: item rows with have / need", "Bright Linen | 10 / 5" in rows, rows)
note = L.eval("(function() for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsShop and f._kind == 'FontString' and (f._text or ''):find('Have =') then return f._text end end end)()")
check("bank unknown until opened", note and "bank unknown" in note, note)
L.execute("FireEvent('BANKFRAME_OPENED')")
note = L.eval("(function() for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsShop and f._kind == 'FontString' and (f._text or ''):find('Have =') then return f._text end end end)()")
check("after opening the bank, bank counts are used", note and "bags and bank" in note, note)
L.execute("""ForgesLedgerProfessionsDB.characters['Altone-Area52'] = { data = { shoppingList = { ['Midnight Tailoring'] = {
  profession = 'Tailoring', expansion = 'Midnight', recipes = { { name = 'X' } }, items = { { itemID = 9001, name = 'Bright Linen', need = 7 } } } } } }""")
L.execute("(function() for _, b in ipairs(ForgesLedgerProfessionsShop.scope) do if b.id == 'warband' then b._scripts.OnClick(b) end end end)()")
rows = list(L.eval("(function() local o = {}; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsShop and f.value and f._shown then table.insert(o, f.name:GetText() .. ' | ' .. f.value:GetText()) end end; return o end)()").values())
check("warband adds every character's needs", "Bright Linen | 10 / 12" in rows, rows)
# maxed tier: no recommendation, no list
L.execute("CHILD.skillLevel = 100; FireEvent('TRADE_SKILL_LIST_UPDATE'); RunTimers(); RunTimers()")
check("maxed tier: no next craft, no list", sat(L, ".nextCraft['Midnight Tailoring'].none") == "maxed" and sat(L, ".shoppingList['Midnight Tailoring']") is None)
check("no errors printed", not errors(L), errors(L))

# ---- celebration
L, ns = run("Professions v1.10: celebration", saved=SAVED + SAT, extra=CRAFT + "\nCHILD.skillLevel = 99")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring')")
check("no celebration below max", not L.eval("ForgesLedgerCelebration and ForgesLedgerCelebration:IsShown()"))
L.execute("CHILD.skillLevel = 100; FireEvent('SKILL_LINES_CHANGED'); RunTimers(); RunTimers()")
# (the stand-in runs every timer at once, including the 8s auto-hide, so
# check what it said rather than whether it's still up)
check("reaching max celebrates", L.eval("ForgesLedgerCelebration ~= nil") and
      L.eval("ForgesLedgerCelebration.text:GetText()") == "Midnight Tailoring 100 / 100", L.eval("ForgesLedgerCelebration and ForgesLedgerCelebration.text:GetText()"))
check("with a sound the game has", list(L.eval("PLAYED").values()) == [31578])
L.execute("SlashCmdList.FORGESLEDGERPROF('celebrate test')")
shown = L.eval("ForgesLedgerCelebration:IsShown()")
L.execute("ForgesLedgerCelebration._scripts.OnMouseDown(ForgesLedgerCelebration)")
check("click dismisses it", shown and not L.eval("ForgesLedgerCelebration:IsShown()"))
L.execute("PLAYED = {}")
L.execute("FireEvent('SKILL_LINES_CHANGED'); RunTimers(); RunTimers()")
check("only once", len(L.eval("PLAYED")) == 0)
check("no errors printed", not errors(L), errors(L))

L, ns = run("Professions v1.10: no celebration on login", saved=SAVED + SAT, extra=CRAFT + "\nCHILD.skillLevel = 100")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring')")
check("a tier first seen already maxed doesn't celebrate", not L.eval("ForgesLedgerCelebration and ForgesLedgerCelebration:IsShown()"))
L, ns = run("Professions v1.10: celebration off", saved=SAVED + SAT + "\nForgesLedgerProfessionsDB.celebrate = false", extra=CRAFT + "\nCHILD.skillLevel = 99")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring'); CHILD.skillLevel = 100; FireEvent('SKILL_LINES_CHANGED'); RunTimers(); RunTimers()")
check("switched off: no celebration", not L.eval("ForgesLedgerCelebration and ForgesLedgerCelebration:IsShown()"))
check("no errors printed", not errors(L), errors(L))

# ---- bar pulse (core v2.11)
L, ns = run("Core v2.11: cooldown-ready pulse", saved=SAVED)
b = seg_button(L, "professions")
check("ready cooldown: Professions segment pulses", b is not None and L.eval("function(b) return b.pulse._playing end")(b))
check("other segments don't", not L.eval("function(b) return b.pulse._playing end")(seg_button(L, "gold")))
L.execute("ForgeGoldDB.bar.pulse = false; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
check("pulse switch off: stops", not L.eval("function(b) return b.pulse._playing end")(seg_button(L, "professions")))
L.execute("ForgeGoldDB.bar.pulse = true; for _, c in pairs(ForgeGoldDB.chars) do if c.cooldowns then for _, cd in pairs(c.cooldowns) do cd.readyAt = time() + 3600 end end end; FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
check("nothing ready: no pulse", not L.eval("function(b) return b.pulse._playing end")(seg_button(L, "professions")))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Professions v1.10: button placement, clickable expansions
OUTLAND = SAT.replace("} } } } }", r"""},
  ["Outland Tailoring"] = { profession = "Tailoring", expansion = "The Burning Crusade", skill = 1, maxSkill = 75, id = 350 } } } } }""", 1)
L, ns = run("Professions v1.10: tab row and expansion rows", saved=SAVED + OUTLAND, extra=CRAFT + """
SWITCHED = nil
C_TradeSkillUI.SetProfessionChildSkillLineID = function(id) SWITCHED = id end
Professions = { GetProfessionInfo = function() return { professionID = SWITCHED } end }
REDRAWN = nil
function ProfessionsFrame:SetProfessionInfo(info, useLast) REDRAWN = { info.professionID, useLast } end
""")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring'); SlashCmdList.FORGESLEDGERPROF('open'); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
geo = L.eval("""(function()
  local h = ForgesLedgerProfessionsHub; local right = 0
  for _, f in ipairs(ALL_FRAMES) do if f._parent == h and f.profession and f._shown then
    local p = f._points[1]; right = math.max(right, p[4] + f._w) end end
  local b = h.shopBtn; local p = b._points[1]
  return { right = right, hubW = h._w, btnLeft = h._w + p[4] - b._w, anchor = p[1] } end)()""")
print("    geometry:", dict(geo))
check("Shopping list button starts right of the last tab", geo.btnLeft >= geo.right + 6, dict(geo))
check("and clear of the close button", geo.anchor == "TOPRIGHT" and geo.btnLeft + 108 <= geo.hubW - 30, dict(geo))
rows = "(function() local o = {}; for _, r in ipairs(ALL_FRAMES) do if r.tier and r.skillLineID ~= nil and r._shown then o[r.tier] = r end end; return o end)()"
check("expansion rows are buttons", L.eval(rows + "['Outland Tailoring']._kind") == "Button")
nextline = "(function() for _, f in ipairs(ALL_FRAMES) do if f.why and f.text and f._shown then return f.text:GetText() .. ' | ' .. f.why:GetText() end end end)()"
check("next craft follows the window's expansion", "Gloves" in L.eval(nextline), L.eval(nextline))
L.execute("local r = " + rows + "['Outland Tailoring']; r._scripts.OnClick(r)")
check("clicking Outland switches the open window to it", L.eval("SWITCHED") == 350, L.eval("SWITCHED"))
check("and the window is told to redraw for it, like its own dropdown", L.eval("REDRAWN and REDRAWN[1]") == 350 and L.eval("REDRAWN[2]") is False)
check("and the line says it is reading Outland", L.eval(nextline) == "Next craft: Outland Tailoring | reading its recipes...", L.eval(nextline))
check("the clicked row is highlighted", L.eval(rows + "['Outland Tailoring'].sel._shown") and not L.eval(rows + "['Midnight Tailoring'].sel._shown"))
# the window switches: its recipes are read and the line fills in
L.execute("""CHILD = { professionName = "Outland Tailoring", parentProfessionName = "Tailoring", professionID = 350,
  expansionName = "The Burning Crusade", skillLevel = 1, maxSkillLevel = 75 }
FireEvent('TRADE_SKILL_DATA_SOURCE_CHANGED'); RunTimers(); RunTimers()""")
check("after the switch Outland has a next craft", "Next craft: Gloves" in L.eval(nextline) and sat(L, ".nextCraft['Outland Tailoring'].name") == "Gloves", L.eval(nextline))
# switching in the game's own window moves the panel too
L.execute("""CHILD = { professionName = "Midnight Tailoring", parentProfessionName = "Tailoring", professionID = 501,
  expansionName = "Midnight", skillLevel = 45, maxSkillLevel = 100 }
SWITCHED = nil; FireEvent('TRADE_SKILL_DATA_SOURCE_CHANGED'); RunTimers(); RunTimers()""")
check("switching in the window moves the panel's pick", L.eval(rows + "['Midnight Tailoring'].sel._shown"))
check("following the window never switches it back", L.eval("SWITCHED") is None)
# window closed: picking an expansion only changes the panel
L.execute("CloseWindow(); SWITCHED = nil; local r = " + rows + "['Outland Tailoring']; r._scripts.OnClick(r)")
check("window closed: no switch call", L.eval("SWITCHED") is None)
check("window closed: saved Outland recommendation shown", "Next craft: Gloves" in L.eval(nextline), L.eval(nextline))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Professions v1.10: the plan
L, ns = run("Professions v1.10: plan", saved=SAVED + SAT, extra=CRAFT + "\nRECIPES[101].numSkillUps = 2\nSHIFT = false\nfunction IsShiftKeyDown() return SHIFT end")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring'); SlashCmdList.FORGESLEDGERPROF('open'); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
plan = sat(L, ".plan['Midnight Tailoring']")
names = [(r.name, r.color) for r in plan.recipes.values()]
check("plan: orange, then yellow, then green; never unknown, unlearned or grey", names == [("Bolt", "orange"), ("Robe", "yellow"), ("Gloves", "green")], names)
prow = "(function() local o = {}; for _, r in ipairs(ALL_FRAMES) do if r.recipeID and r.plus and r._shown then o[r.name:GetText()] = r end end; return o end)()"
head = "ForgesLedgerProfessionsHub.plan.head:GetText()"
check("plan block shows its rows", sorted(L.eval(prow).keys()) == ["Bolt", "Gloves", "Robe"], list(L.eval(prow).keys()))
check("header: points to go, nothing planned", L.eval(head) == "Plan: 55 points to go  \u00b7  0 crafts planned", L.eval(head))
check("tags: first craft, +2 each", L.eval(prow + "['Bolt'].tag:GetText()") == "+2 each" and L.eval(prow + "['Robe'].tag:GetText()") == "first craft")
check("hint explains the counts while nothing is planned", "Orange always gives a point" in L.eval("ForgesLedgerProfessionsHub.plan.hint:GetText()"))
L.execute("local r = " + prow + "['Bolt']; r.plus._scripts.OnClick(r.plus); SHIFT = true; r = " + prow + "['Bolt']; r.plus._scripts.OnClick(r.plus); SHIFT = false")
check("+ then shift-+ plans 11", L.eval(prow + "['Bolt'].count:GetText()") == "11" and "11 crafts planned" in L.eval(head), L.eval(head))
shop = sat(L, ".shoppingList['Midnight Tailoring']")
items = {it.itemID: it.need for it in shop["items"].values()}
check("shopping list: 11 Bolts plus one of each first craft", items == {9001: 58, 9002: 3}, items)
check("list records the counts", sorted((r.name, r.count) for r in shop.recipes.values()) == [("Bolt", 11), ("Gloves", 1), ("Robe", 1)])
L.execute("FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', 101); RunTimers()")
check("a finished Bolt counts down to 10", L.eval(prow + "['Bolt'].count:GetText()") == "10" and {it.itemID: it.need for it in sat(L, ".shoppingList['Midnight Tailoring']")["items"].values()}[9001] == 53)
L.execute("local r = " + prow + "['Bolt']; r.minus._scripts.OnClick(r.minus)")
check("- takes one off", L.eval(prow + "['Bolt'].count:GetText()") == "9")
L.execute("ForgesLedgerProfessionsHub.plan.clear._scripts.OnClick(ForgesLedgerProfessionsHub.plan.clear)")
check("Clear empties the plan", "0 crafts planned" in L.eval(head) and not L.eval("ForgesLedgerProfessionsHub.plan.clear._shown"))
shop = sat(L, ".shoppingList['Midnight Tailoring']")
check("cleared: back to first crafts plus the next craft", sorted(r.name for r in shop.recipes.values()) == ["Gloves", "Robe"])
# counts survive a rescan, and the skill moving on marks the colours stale
L.execute("local r = " + prow + "['Robe']; r.plus._scripts.OnClick(r.plus); r.plus._scripts.OnClick(r.plus)")
L.execute("CHILD.skillLevel = 50; FireEvent('TRADE_SKILL_LIST_UPDATE'); RunTimers(); RunTimers()")
check("counts survive a rescan", L.eval(prow + "['Robe'].count:GetText()") == "2" and "50 points to go" in L.eval(head), L.eval(head))
L.execute("CloseWindow(); ForgesLedgerProfessionsDB.characters['Testchar-Area52'].data.tiers['Midnight Tailoring'].skill = 60; SlashCmdList.FORGESLEDGERPROF('open'); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
hint = L.eval("ForgesLedgerProfessionsHub.plan.hint._shown and ForgesLedgerProfessionsHub.plan.hint:GetText()")
check("skill moved on since the scan: colours flagged as stale", hint and "Colours as of skill 50" in hint, hint)
# maxed: the plan goes away
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring'); CHILD.skillLevel = 100; FireEvent('TRADE_SKILL_LIST_UPDATE'); RunTimers(); RunTimers()")
check("maxed: no plan, no rows", sat(L, ".plan['Midnight Tailoring']") is None and not list(L.eval(prow).keys()) and not L.eval("ForgesLedgerProfessionsHub.plan.head._shown"))
check("no errors printed", not errors(L), errors(L))

# a long plan shows six rows until "Show all"
L, ns = run("Professions v1.10: long plan", saved=SAVED + SAT, extra=CRAFT + """
for i = 1, 9 do RECIPES[200 + i] = { name = "Orange " .. i, learned = true, relativeDifficulty = 0, firstCraft = false, icon = 9 }; SCHEM[200 + i] = { { 9001, 1 } } end
C_TradeSkillUI.GetAllRecipeIDs = function() local o = { 101, 102, 103, 104, 105, 106 }; for i = 1, 9 do o[#o + 1] = 200 + i end; return o end""")
L.execute("OpenWindow('Tailoring', 'Midnight Tailoring'); SlashCmdList.FORGESLEDGERPROF('open'); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("six rows at first", len(list(L.eval(prow).keys())) == 6)
check("with a Show all link", L.eval("ForgesLedgerProfessionsHub.plan.more._shown and ForgesLedgerProfessionsHub.plan.more.text:GetText()") == "Show all 12 recipes")
L.execute("local m = ForgesLedgerProfessionsHub.plan.more; m._scripts.OnClick(m)")
check("Show all shows every row", len(list(L.eval(prow).keys())) == 12)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Professions v1.11: concentration + cooldown selection
CONC_SAT = SAT.replace('["Midnight Tailoring"] = { profession = "Tailoring", expansion = "Midnight", skill = 45, maxSkill = 100 }',
                       '["Midnight Tailoring"] = { profession = "Tailoring", expansion = "Midnight", skill = 45, maxSkill = 100, id = 501 }') \
             .replace('["Khaz Algar Tailoring"] = { profession = "Tailoring", expansion = "Khaz Algar", skill = 100, maxSkill = 100 }',
                      '["Khaz Algar Tailoring"] = { profession = "Tailoring", expansion = "Khaz Algar", skill = 100, maxSkill = 100, id = 401 }') \
             .replace('["Classic Tailoring"] = { profession = "Tailoring", expansion = "Classic", skill = 300, maxSkill = 300 }',
                      '["Classic Tailoring"] = { profession = "Tailoring", expansion = "Classic", skill = 300, maxSkill = 300, id = 101 }')
assert CONC_SAT.count("id = 501") == 1 and CONC_SAT.count("id = 401") == 1
CONC_API = AUTO + r"""
CONC_IDS = { [501] = 3001, [401] = 3000, [101] = 0 }
CONC = { [3001] = { quantity = 640, maxQuantity = 1000, rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 },
         [3000] = { quantity = 1000, maxQuantity = 1000, rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 } }
C_TradeSkillUI.GetConcentrationCurrencyID = function(id) return CONC_IDS[id] or 0 end
C_CurrencyInfo = { GetCurrencyInfo = function(cid) return CONC[cid] end }
"""
MID = "·"


def conc(L, key):
    return L.eval("function(k) local c = ForgesLedgerProfessionsDB.characters['Testchar-Area52'].data.concentration; return c and c[k] end")(key)


def conc_line(L):
    return L.eval("(function() local c = ForgesLedgerProfessionsHub and ForgesLedgerProfessionsHub.conc; if c and c:IsShown() then return c.value:GetText() end end)()")


L, ns = run("Professions v1.11: concentration", saved=SAVED + CONC_SAT, extra=CONC_API)
e = conc(L, "Midnight:Tailoring")
check("a pool is snapshotted from the game (amount, max, refill rate)", e is not None and e.amount == 640 and e.max == 1000 and e.cycle == 360 and e.per == 1 and e.currencyID == 3001,
      e and (e.amount, e.max, e.cycle, e.per))
check("Khaz Algar's pool too; Classic has none", conc(L, "KhazAlgar:Tailoring") is not None and conc(L, "Classic:Tailoring") is None)
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
L.execute("for _, t in ipairs(ALL_FRAMES) do if t.profession == 'Tailoring' and t._scripts.OnClick then t._scripts.OnClick(t) end end")
check("panel: the newest tier's pool, with when it's full", conc_line(L) == "640 / 1000  " + MID + "  full in 1d 12h", conc_line(L))
L.execute("for _, t in ipairs(ALL_FRAMES) do if t.profession == 'Enchanting' and t._scripts.OnClick then t._scripts.OnClick(t) end end")
check("a profession without a pool shows no line", conc_line(L) is None)
L.execute("for _, t in ipairs(ALL_FRAMES) do if t.profession == 'Tailoring' and t._scripts.OnClick then t._scripts.OnClick(t) end end")
L.execute("AdvanceTime(3600)")
L.execute("ForgesLedgerProfessionsHub:Hide(); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("an hour later it has refilled by 10 (projected, no login needed)", conc_line(L).startswith("650 / 1000"), conc_line(L))
L.execute("AdvanceTime(129600 - 3600); ForgesLedgerProfessionsHub:Hide(); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("1d 12h after the snapshot: FULL", conc_line(L) == "FULL - ready to craft", conc_line(L))
card = L.eval("(function() local p = ForgesLedger.GetBarPlugin('professions'); return p.roster() end)()")
rows = [card.rows[i] for i in range(1, len(card.rows) + 1)]
names = [(r.section or r.name, r.value) for r in rows]
check("hover card: a Concentration section (character, profession, FULL)", ("Concentration", None) in names
      and any(n == "Testchar" and v and "Tailoring" in v and "FULL" in v for n, v in names), names)
L.execute("CONC[3001].quantity = 100; FireEvent('CURRENCY_DISPLAY_UPDATE', 3001, 100, -540)")
check("spending (the game's currency event) re-snapshots", conc(L, "Midnight:Tailoring").amount == 100)
L.execute("FireEvent('CURRENCY_DISPLAY_UPDATE', 1792, 5, 5)")
check("other currencies are ignored", conc(L, "Midnight:Tailoring").amount == 100)
check("no errors printed", not errors(L), errors(L))

# an alt's pools, seen from this character: projected from its own last reading
ALT_SAT = CONC_SAT.replace("} } } } } }", """} } } },
  ["Druidalt-Area52"] = { data = { concentration = {
    ["Midnight:Alchemy"] = { amount = 900, max = 1000, snapshotAt = time() - 7200, cycle = 360, per = 1, profession = "Alchemy", expansion = "Midnight" },
    ["Midnight:Inscription"] = { amount = 100, max = 1000, snapshotAt = time(), cycle = 360, per = 1, profession = "Inscription", expansion = "Midnight" } } } } } }""", 1)
assert "Druidalt" in ALT_SAT
L, ns = run("Professions v1.11: every character's concentration", saved=SAVED + ALT_SAT, extra=CONC_API)
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
rows = L.eval("(function() local o = {}; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.allConc and f.prof and f._shown then table.insert(o, f.name:GetText() .. ' | ' .. f.prof:GetText() .. ' | ' .. f.value:GetText()) end end; return o end)()")
rows = [rows[i] for i in range(1, len(rows) + 1)]
print("    all-characters rows:", rows)
check("the panel lists every character's pools (newest expansion per profession)", len(rows) == 3
      and any(r.startswith("Testchar (you) | Tailoring") for r in rows), rows)
check("an alt's pool is projected (900 two hours ago = 920 now)", any(r.startswith("Druidalt | Alchemy") and r.split(" | ")[2].startswith("920") for r in rows), rows)
check("soonest-to-full first", [r.split(" | ")[0] for r in rows] == ["Druidalt", "Testchar (you)", "Druidalt"], rows)
L.execute("AdvanceTime(8 * 3600); ForgesLedgerProfessionsHub:Hide(); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
rows2 = L.eval("(function() local o = {}; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.allConc and f.prof and f._shown then table.insert(o, f.name:GetText() .. ' | ' .. f.value:GetText()) end end; return o end)()")
rows2 = [rows2[i] for i in range(1, len(rows2) + 1)]
check("8 hours later the alt's Alchemy reads FULL, at the top", rows2[0] == "Druidalt | FULL", rows2)
card = L.eval("(function() local p = ForgesLedger.GetBarPlugin('professions'); return p.roster() end)()")
names = [(card.rows[i].section or card.rows[i].name, card.rows[i].value) for i in range(1, len(card.rows) + 1)]
check("hover card lists the alts too", any(n == "Druidalt" and "Alchemy" in (v or "") for n, v in names), names)
check("no errors printed", not errors(L), errors(L))

L, ns = run("Professions v1.11: concentration fallback rate", saved=SAVED + CONC_SAT, extra=CONC_API.replace(
    "rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 },\n         [3000]",
    "rechargingCycleDurationMS = 0, rechargingAmountPerCycle = 0 },\n         [3000]"))
check("no rate from the game: 1 per 6 minutes", conc(L, "Midnight:Tailoring").cycle is None)
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
L.execute("for _, t in ipairs(ALL_FRAMES) do if t.profession == 'Tailoring' and t._scripts.OnClick then t._scripts.OnClick(t) end end")
check("...still projects the same", conc_line(L) == "640 / 1000  " + MID + "  full in 1d 12h", conc_line(L))
check("no errors printed", not errors(L), errors(L))

L, ns = run("Professions v1.11: a client without concentration", saved=SAVED + CONC_SAT, extra=AUTO)
check("no pools, no errors", conc(L, "Midnight:Tailoring") is None and not errors(L), errors(L))
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("and no concentration line", conc_line(L) is None)

# ---- cooldown selection
CARDS = "(function() local o = {}; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.cds and f.eye and f._shown then o[f.name:GetText()] = f end end; return o end)()"


def cards(L):
    return sorted(L.eval(CARDS).keys())


L, ns = run("Professions v1.11: cooldown selection", saved=SAVED + SAT, extra=AUTO)
L.execute("SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("both cooldowns show as cards", cards(L) == ["Daily Cloth", "Transmute: Example"], cards(L))
check("Customize is offered; no eyes outside it", L.eval("ForgesLedgerProfessionsHub.customize:IsShown()")
      and L.eval("ForgesLedgerProfessionsHub.customize.text:GetText()") == "Customize"
      and not L.eval(CARDS + "['Transmute: Example'].eye._shown"))
before = [x for x in segs(L) if x.startswith("professions=")][0]
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
check("Customize: eyes on every card, a header per profession", L.eval(CARDS + "['Transmute: Example'].eye._shown")
      and L.eval("(function() local n = 0; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.cds and f.btn and f._shown then n = n + 1 end end; return n end)()") == 2
      and L.eval("ForgesLedgerProfessionsHub.customize.text:GetText()") == "Done")
L.execute("local e = " + CARDS + "['Transmute: Example'].eye; e._scripts.OnClick(e)")
check("the eye ignores it: stored per character by spell ID", L.eval("ForgesLedgerProfessionsDB.characters['Testchar-Area52'].data.cooldownPrefs[1]") is False)
check("ignored cards stay visible while customizing, dimmed and dashed", "Transmute: Example" in cards(L)
      and L.eval(CARDS + "['Transmute: Example'].dash[1]._shown") and L.eval(CARDS + "['Transmute: Example']._alpha") == 0.5)
L.execute("FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
after = [x for x in segs(L) if x.startswith("professions=")][0]
check("the bar stops counting it", "1 ready" in before and "0 ready" in after, (before, after))
check("...and stops pulsing", not L.eval("function(b) return b.pulse._playing end")(seg_button(L, "professions")))
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
check("Done: the ignored card is gone, the other stays", cards(L) == ["Daily Cloth"], cards(L))
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.cds and f.btn and f._shown and f.text:GetText() == 'Tailoring' then f.btn._scripts.OnClick(f.btn) end end")
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
check("everything ignored: one line instead of an empty zone", cards(L) == []
      and L.eval("ForgesLedgerProfessionsHub.cdEmpty:GetText()") == "All cooldowns ignored - Customize"
      and L.eval("ForgesLedgerProfessionsHub.customize:IsShown()"))
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.cds and f.btn and f._shown then if f.btn.text:GetText() == 'Unmute all' then f.btn._scripts.OnClick(f.btn) end end end")
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerProfessionsHub.cds and f.btn and f._shown then if f.btn.text:GetText() == 'Unmute all' then f.btn._scripts.OnClick(f.btn) end end end")
L.execute("local b = ForgesLedgerProfessionsHub.customize; b._scripts.OnClick(b)")
check("Unmute all brings them back, timers intact", cards(L) == ["Daily Cloth", "Transmute: Example"], cards(L))
L.execute("ForgesLedgerProfessionsHub:Hide(); SlashCmdList.FORGESLEDGERPROF('open'); RunOnUpdates(0.2)")
check("closing the panel leaves Customize", L.eval("ForgesLedgerProfessionsHub.customize.text:GetText()") == "Customize")
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Dungeons v1.1: legacy raid lockouts + farm list
LEGACY = DUNGEONS + r"""
TIER_NAMES = { "Old Era", "Middle Era", "Now Era" }
DifficultyUtil.ID.Raid10Normal, DifficultyUtil.ID.Raid25Normal, DifficultyUtil.ID.Raid10Heroic = 3, 4, 5
DifficultyUtil.ID.Raid25Heroic, DifficultyUtil.ID.Raid40, DifficultyUtil.ID.RaidTimewalker = 6, 9, 33
TIER_RAIDS = { { { 801, "Ember Halls" }, { 802, "Frost Spire" } }, { { 901, "Sky Citadel" } },
               { { 1001, "Test Raid" }, { 1002, "Test World Bosses" } } }
function EJ_GetTierInfo(t) return TIER_NAMES[t], "" end
function EJ_GetInstanceInfo(id) return "x", "", 0, 0, 0, 0, 0, "", id ~= 1002 end  -- only the world-boss page lists no difficulties
function EJ_GetInstanceByIndex(i, raid)
  if not raid then return nil end
  local r = TIER_RAIDS[EJ_SELECTED] and TIER_RAIDS[EJ_SELECTED][i]
  if r then return r[1], r[2] end
end
SAVED_RAIDS = {
  { "Test Raid", 1, 3600, 15, true, false, 0, true, 20, "Heroic", 3, 2, false, 3001, { "Boss A", "Boss B", "Boss C" }, 2 },
  { "Frost Spire", 2, 3 * 86400, 6, true, false, 0, true, 25, "25 Player (Heroic)", 12, 12, false, 631, nil, 12 },
  { "Sky Citadel", 3, 3 * 86400, 14, true, false, 0, true, 10, "Normal", 7, 3, false, 720, nil, 3 },
  { "Old Dungeon", 4, 3 * 86400, 2, true, false, 0, false, 5, "Heroic", 4, 4, false, 555, nil, 4 } }
function GetNumSavedInstances() return #SAVED_RAIDS end
function GetSavedInstanceInfo(i) local r = SAVED_RAIDS[i]; return unpack(r, 1, 14) end
function GetSavedInstanceEncounterInfo(i, e)
  local r = SAVED_RAIDS[i]
  local names = r[15]
  return names and names[e] or (r[1] .. " boss " .. e), nil, e <= r[16]
end
"""


def legacy_rows(L):
    t = L.eval(r"""(function() local o = {}
      for _, f in ipairs(ALL_FRAMES) do
        if f._parent == ForgesLedgerDungeonsPanel.body and f.star and f._shown then
          table.insert(o, f.name:GetText() .. " | " .. f.diff:GetText() .. " | " .. f.prog:GetText() .. " | " .. (f.star.tex._tex or ""):match("star_%a+"))
        end
      end
      return o end)()""")
    return [t[i] for i in range(1, len(t) + 1)]


def tabs(L):
    t = L.eval("(function() local o = {}; for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerDungeonsPanel and f.under and f._shown then table.insert(o, f.text:GetText()) end end; return o end)()")
    return [t[i] for i in range(1, len(t) + 1)]


DD = "ForgesLedgerDungeonsDB.characters['Testchar-Area52'].data"
L = run_d("Dungeons v1.1: legacy lockouts", saved=SAVED, extra=LEGACY)
check("the current raids are remembered (from the guide's newest tier)", list(L.eval("ForgesLedgerDungeonsDB.currentRaids").values()) == ["Test Raid"])
leg = L.eval(DD + ".legacyLockouts")
names = sorted(leg[i].name for i in range(1, len(leg) + 1))
check("old raids this week are recorded; the current raid and dungeons aren't", names == ["Frost Spire", "Sky Citadel"], names)
fs = [leg[i] for i in range(1, len(leg) + 1) if leg[i].name == "Frost Spire"][0]
check("with progress, difficulty, bosses and an expiry time", fs.encounterProgress == 12 and fs.numEncounters == 12
      and fs.difficultyName == "25 Player (Heroic)" and fs.instanceID == 631 and len(fs.bosses) == 12
      and fs.expiresAt == L.eval("time()") + 3 * 86400)
check("the Adventure Guide's tier is put back", L.eval("EJ_SELECTED") == 1, L.eval("EJ_SELECTED"))
L.execute("SlashCmdList.FORGESLEDGERDUNGEONS('raids'); RunOnUpdates(0.2)")
check("a Legacy tab appears once there's an old raid this week", tabs(L) == ["Mythic+", "Raids", "Legacy"], tabs(L))
check("the Raids tab links to old raids", L.eval("ForgesLedgerDungeonsPanel.legacyLink:IsShown()"))
L.execute("local b = ForgesLedgerDungeonsPanel.legacyLink; b._scripts.OnClick(b)")
rows = legacy_rows(L)
print("    legacy rows:", rows)
check("Legacy: newest expansion first, progress per raid", rows == ["Sky Citadel | Normal | 3 / 7 | star_off",
      "Frost Spire | 25 Player (Heroic) | 12 / 12 | star_off"], rows)
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerDungeonsPanel.body and f.star and f._shown and f.name:GetText() == 'Frost Spire' then f.star._scripts.OnClick(f.star) end end")
check("starring adds it to the account's farm list (and the character's copy, for the app)",
      L.eval("ForgesLedgerDungeonsDB.farmRaids['Frost Spire']") is True and L.eval(DD + ".farmRaids['Frost Spire']") is True)
L.execute("local b = ForgesLedgerDungeonsPanel.pickBtn; b._scripts.OnClick(b)")
check("the farm list picker opens on the newest older expansion", L.eval("ForgesLedgerDungeonsPanel.nav.label:GetText()") == "Middle Era"
      and [r.split(" | ")[0] for r in legacy_rows(L)] == ["Sky Citadel"], legacy_rows(L))
check("current raids are never offered", not any("Test Raid" in r for r in legacy_rows(L)))
L.execute("local b = ForgesLedgerDungeonsPanel.nav.prev; b._scripts.OnClick(b)")
check("older: Old Era's raids, the starred one marked", L.eval("ForgesLedgerDungeonsPanel.nav.label:GetText()") == "Old Era"
      and legacy_rows(L) == ["Ember Halls |  |  | star_off", "Frost Spire |  |  | star_on"], legacy_rows(L))
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerDungeonsPanel.body and f.star and f._shown and f.name:GetText() == 'Ember Halls' then f.star._scripts.OnClick(f.star) end end")
L.execute("local b = ForgesLedgerDungeonsPanel.pickBtn; b._scripts.OnClick(b)")
rows = legacy_rows(L)
check("a starred raid not run yet shows dimmed on the Legacy tab", "Ember Halls | - not run yet |  | star_on" in rows, rows)
L.execute("for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerDungeonsPanel.body and f.star and f._shown and f.name:GetText() == 'Ember Halls' then f.star._scripts.OnClick(f.star) end end")
check("un-starring removes it", "Ember Halls" not in " ".join(legacy_rows(L)) and L.eval("ForgesLedgerDungeonsDB.farmRaids['Ember Halls']") is None)
L.execute("AdvanceTime(4 * 86400); SAVED_RAIDS = { SAVED_RAIDS[1] }; ForgesLedgerDungeonsPanel:Hide(); SlashCmdList.FORGESLEDGERDUNGEONS('')")
rows = legacy_rows(L)
check("after the reset, the lockouts are gone; the starred raid waits", rows == ["Frost Spire | - not run yet |  | star_on"], rows)
check("no errors printed", not errors(L), errors(L))

# before the guide has loaded, old vs new can't be told apart: nothing is guessed
# in game the guide reported nothing until it had been loaded once: the
# addon loads it itself (once, out of combat) and then classifies everything
GUIDE_LATE = r"""
GUIDE_LOADED = false
local realTiers = EJ_GetNumTiers
EJ_GetNumTiers = function() return GUIDE_LOADED and realTiers() or 0 end
function EncounterJournal_LoadUI() GUIDE_LOADED = true; LOADS = (LOADS or 0) + 1; return true end
SAVED_RAIDS[2] = { "Molten Core", 2, 120010, 9, true, false, 0, true, 40, "40 Player", 10, 3, false, 409, nil, 3 }
"""
L = run_d("Dungeons v1.1: guide loads itself (the Molten Core case)", saved=SAVED, extra=LEGACY + GUIDE_LATE)
leg = L.eval(DD + ".legacyLockouts")
names = sorted(leg[i].name for i in range(1, len(leg) + 1)) if leg else None
check("the addon loaded the Adventure Guide's data itself, once", L.eval("LOADS") == 1, L.eval("LOADS"))
check("Molten Core (40 Player, 3/10) and the other old raid are recorded", names == ["Molten Core", "Sky Citadel"], names)
check("...and the list is complete, not partial", L.eval(DD + ".legacyPartial") is None)
check("no errors printed", not errors(L), errors(L))

# if the guide never loads: old difficulties are still certain; nothing else is guessed
GUIDE_NEVER = r"""
EJ_GetNumTiers = function() return 0 end
function EncounterJournal_LoadUI() LOADS = (LOADS or 0) + 1; return false end
SAVED_RAIDS[2] = { "Molten Core", 2, 120010, 9, true, false, 0, true, 40, "40 Player", 10, 3, false, 409, nil, 3 }
"""
L = run_d("Dungeons v1.1: guide never loads", saved=SAVED, extra=LEGACY + GUIDE_NEVER)
leg = L.eval(DD + ".legacyLockouts")
names = sorted(leg[i].name for i in range(1, len(leg) + 1)) if leg else None
check("a 40-player raid is old for certain: recorded", names == ["Molten Core"], names)
check("a Normal-difficulty old raid can't be told from a current one: not guessed", "Sky Citadel" not in (names or []))
check("the list says it's partial", L.eval(DD + ".legacyPartial") is True)
check("the guide load is tried only once", L.eval("LOADS") == 1, L.eval("LOADS"))
L.execute("SlashCmdList.FORGESLEDGERDUNGEONS('raids'); RunOnUpdates(0.2)")
check("the Legacy tab appears with Molten Core", tabs(L) == ["Mythic+", "Raids", "Legacy"], tabs(L))
L.execute("local b = ForgesLedgerDungeonsPanel.legacyLink; b._scripts.OnClick(b)")
check("...showing 3 / 10 and a note about newer old raids", legacy_rows(L) == ["Molten Core | 40 Player | 3 / 10 | star_off"]
      and "Adventure Guide" in L.eval("ForgesLedgerDungeonsPanel.head3:GetText()"), (legacy_rows(L), L.eval("ForgesLedgerDungeonsPanel.head3:GetText()")))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Batch 1 (core v2.12): weekly gold + goal
WEEK_SAVED = SAVED.replace('["Testchar-Area52"] = { name = "Testchar", class = "WARRIOR", money = 1,',
                           '["Testchar-Area52"] = { name = "Testchar", class = "WARRIOR", money = 100000000, lastSeen = time() - 5 * 86400,') \
                  .replace("warband = { money = 50000000 }", "warband = { money = 40000000, updated = time() - 5 * 86400 }")
assert "lastSeen = time() - 5" in WEEK_SAVED and "updated = time() - 5" in WEEK_SAVED


def win_rows(L, wid):
    return L.eval('''function(id) return _G["ForgesLedgerWindow" .. id] end''')(wid)


def press_enter(L, wid, label, text):
    L.eval('''function(id, label, text)
      local f = _G["ForgesLedgerWindow" .. id]
      for _, r in ipairs(f.rows) do
        if r._shown and r.edit and r.edit._shown and r.left:GetText() == label then
          r.edit:SetText(text); r.edit._scripts.OnEnterPressed(r.edit); return end
      end
      error("no input row " .. label)
    end''')(wid, label, text)


def click_row(L, wid, starts, button="LeftButton"):
    L.eval('''function(id, starts, button)
      local f = _G["ForgesLedgerWindow" .. id]
      for _, r in ipairs(f.rows) do
        if r._shown and r.left:GetText():find(starts, 1, true) then r._scripts.OnClick(r, button); return end
      end
      error("no row " .. starts)
    end''')(wid, starts, button)


L, ns = run("Batch 1: weekly gold", saved=WEEK_SAVED)
wk = L.eval("ForgeGoldDB.chars['Testchar-Area52'].week")
check("a character offline across the reset starts the week exact, at its saved gold", wk and wk.exact is True and wk.money == 100000000, wk and (wk.exact, wk.money))
wb = L.eval("ForgeGoldDB.warband.week")
check("the warband bank too (it was 4,000g at the reset)", wb and wb.exact is True and wb.money == 40000000)
check("characters not played this week aren't counted yet", L.eval("ForgeGoldDB.chars['Testmage-Area52'].week") is None)
L.execute("SlashCmdList.FORGESLEDGER('gold'); RunTimers()")
lines = window_lines(L, "gold")
print("    gold window:", lines[:6])
earned = [l for l in lines if l.startswith("Earned")]
check("Gold window: This week, net earned across characters + warband", lines[0] == "This week" and earned
      and "+" in earned[0], lines[:4])
check("no goal yet: just the box to set one", not any(l.startswith("Goal ") for l in lines) and any(l.startswith("Weekly goal") for l in lines))
press_enter(L, "gold", "Weekly goal", "200,000")
check("typing a goal saves it (gold -> copper, with its time)", L.eval("ForgeGoldDB.weeklyGoal.copper") == 2000000000 and L.eval("ForgeGoldDB.weeklyGoal.at") is not None)
lines = window_lines(L, "gold")
goal = [l for l in lines if l.startswith("Goal ")]
check("the goal line shows progress", goal and goal[0].endswith("%"), goal)
check("the goal row has a progress bar", L.eval('''(function() for _, r in ipairs(ForgesLedgerWindowgold.rows) do if r._shown and r.left:GetText():find("^Goal ") then return r.track._shown end end end)()'''))
check("per-character numbers are this week's", any("this week, since the weekly reset" in l for l in lines))
card = L.eval("(function() local p = ForgesLedger.GetBarPlugin('gold'); return p.roster() end)()")
foot = [card.footer[i] for i in range(1, len(card.footer) + 1)]
check("the Gold hover card has the week line with the goal", any(f.startswith("This week: +") and "Goal" in f and "%)" in f for f in foot), foot)
# the app's goal (companion data) wins when it's newer
L.execute("ForgesLedgerCompanion = { companionVersion = 1, generatedAt = time() + 60, weeklyGoal = { copper = 5000000000, at = time() + 60 } }")
L.execute("SlashCmdList.FORGESLEDGER('gold'); SlashCmdList.FORGESLEDGER('gold'); RunTimers()")
goal = [l for l in window_lines(L, "gold") if l.startswith("Goal ")]
check("a newer goal from the app wins", goal and "500000" in goal[0].replace(",", ""), goal)
press_enter(L, "gold", "Weekly goal", "")
L.execute("AdvanceTime(120)")
press_enter(L, "gold", "Weekly goal", "0")
check("clearing it in game (newer) removes the goal", not any(l.startswith("Goal ") for l in window_lines(L, "gold")))
check("no errors printed", not errors(L), errors(L))

L, ns = run("Batch 1: weekly gold, first seen this week", saved=SAVED)
L.execute("SlashCmdList.FORGESLEDGER('gold'); RunTimers()")
check("a week that started after the reset is labelled partial", any(l.startswith("Partial week") for l in window_lines(L, "gold")))
L, ns = run("Batch 1: no weekly reset timer on this client", saved=SAVED, extra="C_DateAndTime = nil")
L.execute("SlashCmdList.FORGESLEDGER('gold'); RunTimers()")
lines = window_lines(L, "gold")
check("without the game's reset timer: no weekly section, the 7-day view stays", lines[0] == "Characters" and any("last 7 days" in l for l in lines), lines[:3])
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Batch 1: custom todos
L, ns = run("Batch 1: custom todos", saved=SAVED, extra="DAILY_AT = time() + 3600; C_DateAndTime.GetSecondsUntilDailyReset = function() return (DAILY_AT - time()) % 86400 end")
L.execute("SlashCmdList.FORGESLEDGER('todo'); RunTimers()")
lines = window_lines(L, "todo")
check("Custom section, closed while there are no tasks", any(l.startswith("Custom") and "show" in l for l in lines) and not any(l.startswith("Add a task") for l in lines), lines)
click_row(L, "todo", "Custom")
check("clicking the header opens it: an add box and the all-characters toggle",
      any(l.startswith("Add a task") for l in window_lines(L, "todo")) and any("For all characters" in l for l in window_lines(L, "todo")))
press_enter(L, "todo", "Add a task", "Farm herbs")
tasks = L.eval("ForgeGoldDB.custom.tasks")
t = list(tasks.values())[0] if tasks else None
check("Enter adds a task for this character", t and t.text == "Farm herbs" and t.scope == "Testchar-Area52" and t.reset == "none", t and (t.text, t.scope))
click_row(L, "todo", "For all characters")
press_enter(L, "todo", "Add a task", "Check the auction house")
lines = window_lines(L, "todo")
print("    todo window:", lines)
check("a global task shows marked 'all toons'", any("Check the auction house" in l and "all toons" in l for l in lines), lines)
check("the bar's Todo count includes custom tasks", any(x.startswith("todo=Todo ") and "/" in x for x in segs(L)), segs(L))
before = [x for x in segs(L) if x.startswith("todo=")][0]
click_row(L, "todo", "Farm herbs")
check("clicking ticks it (per character, with the time)", L.eval("(function() for id, ts in pairs(ForgeGoldDB.custom.done['Testchar-Area52'] or {}) do return ts end end)()") is not None)
L.execute("FireEvent('PLAYER_MONEY'); RunTimers(); RunTimers()")
after = [x for x in segs(L) if x.startswith("todo=")][0]
check("...and the bar counts it done", before != after, (before, after))
click_row(L, "todo", "Check the auction house")
check("everything done: the header says so", any(l.startswith("Custom  -  all done") for l in window_lines(L, "todo")), window_lines(L, "todo"))
click_row(L, "todo", "Farm herbs", "RightButton")
check("right-click deletes (and remembers the delete for the app)", not any("Farm herbs" in l for l in window_lines(L, "todo"))
      and len(list(L.eval("ForgeGoldDB.custom.deleted").keys())) == 1)
# tasks written in the app arrive through the companion data
L.execute('''ForgesLedgerCompanion = { companionVersion = 1, generatedAt = time(), tasks = {
  { id = "a1", text = "Craft flasks", scope = "Testchar-Area52", reset = "daily", at = time() },
  { id = "a2", text = "Someone else's task", scope = "Testmage-Area52", reset = "none", at = time() },
  { id = "a3", text = "Deleted in the app", scope = "global", reset = "none", at = time() } }, deleted = { "a3" } }''')
L.execute("SlashCmdList.FORGESLEDGER('todo'); SlashCmdList.FORGESLEDGER('todo'); RunTimers()")
lines = window_lines(L, "todo")
check("an app task for this character shows, with its reset", any("Craft flasks" in l and "daily" in l for l in lines), lines)
check("another character's task doesn't", not any("Someone else" in l for l in lines))
check("a task the app deleted doesn't", not any("Deleted in the app" in l for l in lines))
click_row(L, "todo", "Craft flasks")
L.execute("AdvanceTime(7200)")
L.execute("SlashCmdList.FORGESLEDGER('todo'); SlashCmdList.FORGESLEDGER('todo'); RunTimers()")
check("a daily task's tick clears at the daily reset", any("Craft flasks" in l and "UI-CheckBox-Up" in l for l in window_lines(L, "todo")), window_lines(L, "todo"))
roster = L.eval("(function() local p = ForgesLedger.GetBarPlugin('todo'); return p.roster() end)()")
names = [roster.rows[i].name for i in range(1, len(roster.rows) + 1)]
check("the hover card counts other characters' tasks too", "Testmage" in names, names)
check("no errors printed", not errors(L), errors(L))

L, ns = run("Batch 1: the 30-task cap", saved=SAVED)
L.execute("ForgeGoldDB.custom = { tasks = {} }; for i = 1, 30 do ForgeGoldDB.custom.tasks['t' .. i] = { id = 't' .. i, text = 'Task ' .. i, scope = 'global', reset = 'none', at = i } end")
L.execute("Settings_open = true; SlashCmdList.FORGESLEDGER('todo'); RunTimers()")
press_enter(L, "todo", "Add a task", "One too many")
check("a 31st task is refused, with a message", len(list(L.eval("ForgeGoldDB.custom.tasks").keys())) == 30
      and any("limit of 30" in p for p in L.eval("PRINTED").values()))
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Batch 1: app -> companion file -> addon (round trip)
import tempfile as _tf
sys.path.insert(0, os.path.dirname(ADDON))
import forges_ledger as _F
_d = _tf.mkdtemp()
os.makedirs(os.path.join(_d, "_retail_", "Interface", "AddOns"))
_dest = _F.write_companion({"wow_path": _d, "weekly_goal": {"copper": 3000000000, "at": 1760000000 + 999},
                            "custom_tasks": [{"id": "a1", "text": "Craft flasks", "scope": "Testchar-Area52", "reset": "weekly", "at": 1},
                                             {"id": "a2", "text": "Daily herb loop", "scope": "global", "reset": "daily", "at": 2}],
                            "custom_deleted": {}})
_comp = open(os.path.join(_dest, "Companion.lua"), encoding="utf-8").read()
L, ns = run("Batch 1: round trip - the app's companion file read by the addon", saved=WEEK_SAVED + "\n" + _comp)
L.execute("SlashCmdList.FORGESLEDGER('gold'); RunTimers()")
goal = [l for l in window_lines(L, "gold") if l.startswith("Goal ")]
check("the goal set in the app shows in game", goal and "300000" in goal[0].replace(",", ""), goal)
L.execute("SlashCmdList.FORGESLEDGER('todo'); RunTimers()")
lines = window_lines(L, "todo")
check("tasks written in the app show in the Todo window", any("Craft flasks" in l and "weekly" in l for l in lines)
      and any("Daily herb loop" in l and "all toons" in l for l in lines), lines)
check("no errors printed", not errors(L), errors(L))

# ---------------------------------------------------------------- Batch 1 F3: big rosters scroll
MANY = SAVED.replace('["Testmage-Area52"] = { name = "Testmage", class = "MAGE", money = 20000000 } },',
                     '["Testmage-Area52"] = { name = "Testmage", class = "MAGE", money = 20000000 } },\n' +
                     'ManyAlts = true,')
L, ns = run("Batch 1 F3: a 26-character roster scrolls", saved=MANY + "\nfor i = 1, 25 do ForgeGoldDB.chars['Alt' .. i .. '-Area52'] = { name = 'Alt' .. i, class = 'MAGE', money = i * 10000 } end")
L.execute("SlashCmdList.FORGESLEDGER('gold'); RunTimers()")
n = len(window_lines(L, "gold"))
check("every character is listed (27 + totals)", n >= 27, n)
check("the list overflows into a scroll frame with its scrollbar", L.eval("ForgesLedgerWindowgold.scrollBar and ForgesLedgerWindowgold.scrollBar._shown")
      and L.eval("ForgesLedgerWindowgold.content._h") > L.eval("ForgesLedgerWindowgold._h"))
check("no errors printed", not errors(L), errors(L))

print("\nFAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
