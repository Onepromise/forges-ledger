"""The main Ledger window's tabs (core) with Kill Ledger as the first tab, in the mock WoW UI:
register, switch, resize, /kl routing, persistence, old saves, a failing tab, a lines tab."""
import os, re, sys
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


def grab(path, var):
    src = open(os.path.join(HERE, path), encoding="utf-8").read()
    m = re.search(var + r" = r'''(.*?)'''", src, re.S)
    assert m, var
    return m.group(1)


MOCK = open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read()
KLWORLD = grab("kl_run.py", "WORLD")
RETAIL = grab("run.py", "RETAIL")

SAVED_KL = r'''
ForgesLedgerKillLedgerDB = { characters = { ['Testchar-Area52'] = { data = {
  mobs = {
    ['100'] = { name = 'Boar', zone = 'Elwynn Forest', kills = 4, lastKill = 5, items = {
      ['101'] = { name = 'Worn Dagger', dropEvents = 2, qty = 2, price = 250, quality = 2 } } },
    ['200'] = { name = 'Wolf', zone = 'Westfall', kills = 2, lastKill = 9, items = {} } },
  session = { startedAt = 1, mobs = {} } } } } }
'''


def make(core=True, kl=True, saved_core="", saved_kl=SAVED_KL, extra=""):
    R = lua51.LuaRuntime(unpack_returned_tuples=True)
    R.execute(MOCK)
    R.execute(KLWORLD)
    R.execute(RETAIL)
    R.execute("Minimap = CreateFrame('Frame', 'Minimap')")
    R.execute(extra)
    ns = R.eval("{}")
    loader = R.eval("function(code, n) local f, err = loadstring(code, '@'..n); if not f then error(err) end; return f end")
    if core:
        for f in ["ForgesLedger.lua", "ForgesLedger_Windows.lua", "ForgesLedger_Bar.lua", "ForgesLedger_XP.lua"]:
            code = open(os.path.join(ADDON, "ForgesLedger", f), encoding="utf-8").read()
            loader(code, "ForgesLedger/" + f)("ForgesLedger", ns)
    R.execute(saved_core)
    if kl:
        R.execute(saved_kl)
        code = open(os.path.join(ADDON, "ForgesLedger_KillLedger", "ForgesLedger_KillLedger.lua"), encoding="utf-8").read()
        loader(code, "KillLedger.lua")("ForgesLedger_KillLedger", R.eval("{}"))
    R.execute('FireEvent("ADDON_LOADED", "ForgesLedger"); FireEvent("PLAYER_LOGIN"); FireEvent("PLAYER_ENTERING_WORLD", true, false); RunTimers(); RunTimers()')
    return R


def ev(R, s): R.execute(s + "; RunTimers()")
def fl(R, cmd): ev(R, "SlashCmdList.FORGESLEDGER(%s)" % ("[=[" + cmd + "]=]"))
def kl(R, cmd): ev(R, "SlashCmdList.FORGESLEDGERKILLLEDGER(%s)" % ("[=[" + cmd + "]=]"))
def errors(R): return [p for p in R.eval("PRINTED").values() if "error" in p.lower() or "couldn't" in p.lower()]
HOST = "ForgesLedgerWindowledger"
def host_shown(R): return bool(R.eval("%s ~= nil and %s:IsShown()" % (HOST, HOST)))
def tabs(R): return list(R.eval("(function() local o = {} for _, b in ipairs(%s.tabButtons or {}) do if b._shown then o[#o+1] = b.label:GetText() end end return o end)()" % HOST).values())
def active(R): return R.eval("%s.activeTab" % HOST)
def click_tab(R, label):
    ev(R, "for _, b in ipairs(%s.tabButtons) do if b._shown and b.label:GetText() == '%s' then b._scripts.OnClick(b) end end" % (HOST, label))
def size(R): return (R.eval("%s:GetWidth()" % HOST), R.eval("%s:GetHeight()" % HOST))
def klshown(R): return bool(R.eval("ForgesLedgerKillLedgerPanel ~= nil and ForgesLedgerKillLedgerPanel:IsShown()"))
def rows(R):
    return list(R.eval("(function() local o = {} for _, r in ipairs(%s.rows) do if r._shown then o[#o+1] = r.left:GetText() end end return o end)()" % HOST).values())


print("== registration")
R = make()
check("loads without errors", not errors(R))
check("the core exposes the tab API", R.eval("type(ForgesLedger.RegisterTab) == 'function' and type(ForgesLedger.OpenTab) == 'function'"))
fl(R, "ledger")
check("/fl ledger opens the main window", host_shown(R))
check("with Kill Ledger installed a tab row shows: Ledger and Kill Ledger", tabs(R) == ["Ledger", "Kill Ledger"], tabs(R))
check("it opens on the home tab", active(R) == "home")
check("the home tab is the old Ledger window: native width", size(R)[0] == 360, size(R))
check("...with its usual lines", len(rows(R)) > 1, rows(R))
check("the Kill Ledger panel is not shown on the home tab", not klshown(R))
check("the title is the Ledger's", R.eval("%s.title:GetText()" % HOST) == "Forge's Ledger")
check("Escape closes the window", R.eval("(function() for _, n in ipairs(UISpecialFrames) do if n == '%s' then return true end end end)()" % HOST))
check("the Kill Ledger panel is no longer a separate Escape-closable window", not R.eval("(function() for _, n in ipairs(UISpecialFrames) do if n == 'ForgesLedgerKillLedgerPanel' then return true end end end)()"))

print("\n== /kl routes to the tab")
fl(R, "ledger")
check("/fl ledger toggles it closed", not host_shown(R))
kl(R, "")
check("/kl opens the main window", host_shown(R))
check("...on the Kill Ledger tab", active(R) == "killledger")
check("the Kill Ledger panel is up, inside the window's body", klshown(R) and R.eval("ForgesLedgerKillLedgerPanel:GetParent() == %s.body" % HOST))
w, h = size(R)
check("the window grew to the panel's size (940x540 + frame)", w == 940 + 12 and h == 540 + 58 + 6, (w, h))
check("the list scroll of the home tab is out of the way", not R.eval("%s.scroll._shown" % HOST))
check("the panel has no close button, no drag of its own", R.eval("ForgesLedgerKillLedgerPanel.close") is None and not R.eval("ForgesLedgerKillLedgerPanel._scripts.OnDragStart"))
ev(R, "ForgesLedgerKillLedgerPanel.tabLife._scripts.OnClick()")
check("the panel drew itself: the lifetime mob list has its two mobs", len(list(R.eval("(function() local o = {} for _, r in ipairs(ForgesLedgerKillLedgerPanel.rows) do if r._shown then o[#o+1] = r.name:GetText() end end return o end)()").values())) == 2)
ev(R, "ForgesLedgerKillLedgerPanel.tabSession._scripts.OnClick()")
kl(R, "")
check("/kl again closes the window (it is open on that tab)", not host_shown(R))
kl(R, "lifetime")
check("/kl lifetime opens the tab on the Lifetime view", host_shown(R) and active(R) == "killledger" and "Lifetime" in R.eval("ForgesLedgerKillLedgerPanel.head3:GetText()"), R.eval("ForgesLedgerKillLedgerPanel.head3:GetText()"))
kl(R, "session")
check("/kl session switches the view", "This session" in R.eval("ForgesLedgerKillLedgerPanel.head3:GetText()"))

print("\n== switching tabs")
click_tab(R, "Ledger")
check("back to the home tab: native width, lines return", active(R) == "home" and size(R)[0] == 360 and len(rows(R)) > 1 and R.eval("%s.scroll._shown" % HOST))
check("...and the Kill Ledger panel is hidden", not klshown(R))
h_home = size(R)[1]
click_tab(R, "Kill Ledger")
check("Kill Ledger again: panel back, window resized", klshown(R) and size(R) == (952, 604))
check("the active tab button is highlighted", R.eval("(function() for _, b in ipairs(%s.tabButtons) do if b.label:GetText() == 'Kill Ledger' then return b.active end end end)()" % HOST) is True)
check("the choice is remembered in the save", R.eval("ForgeGoldDB.ui.tab") == "killledger")
ev(R, "%s:Hide()" % HOST)
fl(R, "ledger")
check("reopening the main window returns to the last tab", active(R) == "killledger" and klshown(R))
ev(R, "%s:Hide()" % HOST)
fl(R, "ledger")

print("\n== Kill Ledger itself is untouched")
kl(R, "")
kl(R, "")
kl(R, "")
check("the data is the same save file", R.eval("ForgesLedgerKillLedgerDB.characters['Testchar-Area52'].data.mobs['100'].kills") == 4)
ev(R, "ForgesLedgerKillLedgerPanel.tabLife._scripts.OnClick()")
ev(R, "ForgesLedgerKillLedgerPanel.rows[1]._scripts.OnClick(ForgesLedgerKillLedgerPanel.rows[1])")
check("selecting a mob shows its drops (the panel works inside the tab)", R.eval("ForgesLedgerKillLedgerPanel.dname:GetText()") in ("Boar", "Wolf"))
ev(R, "for i = 1, 12 do local r = ForgesLedgerKillLedgerPanel.irows[i]; if r._shown and r.id == '101' then r.wish._scripts.OnClick() end end")
check("the Wish button works and writes the wishlist", R.eval("ForgesLedgerKillLedgerDB.wishlist ~= nil and ForgesLedgerKillLedgerDB.wishlist['101'] ~= nil"))
ev(R, "ForgesLedgerKillLedgerPanel.tabItem._scripts.OnClick()")
ev(R, "ForgesLedgerKillLedgerPanel.isearch:SetText('worn'); ForgesLedgerKillLedgerPanel.isearch._scripts.OnTextChanged(ForgesLedgerKillLedgerPanel.isearch)")
check("Find item works inside the tab", "Worn Dagger" in list(R.eval("(function() local o = {} for _, r in ipairs(ForgesLedgerKillLedgerPanel.mrows) do if r._shown then o[#o+1] = r.name:GetText() end end return o end)()").values()))
ev(R, "ForgesLedgerKillLedgerPanel.tabWish._scripts.OnClick()")
check("the Wishlist view works inside the tab", R.eval("ForgesLedgerKillLedgerPanel.wishEmpty:IsShown() or #ForgesLedgerKillLedgerPanel.wrows > 0"))
kl(R, "tooltip off")
check("/kl subcommands still work", R.eval("ForgesLedgerKillLedgerDB.tooltip") is False)
check("no errors", not errors(R))

print("\n== persistence across a restart, old saves")
R = make(saved_core="ForgeGoldDB = { ui = { tab = 'killledger' } }")
fl(R, "ledger")
check("a saved tab choice opens on that tab after a restart", active(R) == "killledger" and klshown(R))
R = make(saved_core="ForgeGoldDB = { ui = { tab = 'gone' } }")
fl(R, "ledger")
check("a saved tab that no longer exists falls back to home", active(R) == "home")
R = make(saved_core="ForgeGoldDB = { chars = {} }")
fl(R, "ledger")
check("an old save with no window state opens on home", active(R) == "home" and not errors(R))
R = make(saved_kl="ForgesLedgerKillLedgerDB = { combatLog = true }")
kl(R, "")
check("an empty Kill Ledger save opens fine in the tab", host_shown(R) and klshown(R) and not errors(R))

print("\n== no extra tabs: the window is exactly as before")
R = make(kl=False)
fl(R, "ledger")
check("only the home tab: no tab row", tabs(R) == [] and active(R) == "home")
check("...and the usual height (44 + rows x 18)", size(R)[1] == 44 + min(len(rows(R)), 22) * 18, (size(R), len(rows(R))))
fl(R, "gold")
check("other windows (gold) are unchanged", bool(R.eval("ForgesLedgerWindowgold ~= nil and ForgesLedgerWindowgold:IsShown()")))

print("\n== Kill Ledger without a tab-capable core")
R = make(core=False)
kl(R, "")
check("the standalone window still works", klshown(R) and R.eval("ForgesLedgerKillLedgerPanel.close ~= nil") and not errors(R))
R = make(core=False, extra="ForgesLedger = { }")
kl(R, "")
check("an old core object without tabs also falls back", klshown(R) and R.eval("ForgesLedgerKillLedgerPanel:GetParent() == UIParent"))

print("\n== the API is general: any satellite can add a tab")
R = make()
ev(R, "ForgesLedger.RegisterTab({ id = 'demo', label = 'Demo', order = 5, build = function() return { { text = 'hello demo' }, { text = 'second', dim = true } } end })")
fl(R, "ledger")
check("a lines tab registers and orders itself by `order`", tabs(R) == ["Ledger", "Demo", "Kill Ledger"], tabs(R))
click_tab(R, "Demo")
check("selecting it shows its lines at the native width", rows(R) == ["hello demo", "second"] and size(R)[0] == 360, (rows(R), size(R)))
check("...and the height fits its lines under the tab row", size(R)[1] == 32 + 26 + 12 + 2 * 18, size(R))
ev(R, "ForgesLedger.RegisterTab({ id = 'broken', label = 'Broken', order = 6, panel = function() error('boom') end, width = 300, height = 200 })")
click_tab(R, "Broken")
check("a panel tab that errors shows a plain message, not a broken window", host_shown(R) and any("couldn't load" in r for r in rows(R)), rows(R))
click_tab(R, "Ledger")
check("the window recovers", active(R) == "home" and len(rows(R)) > 1)
check("a registration with nothing to show is refused", R.eval("ForgesLedger.RegisterTab({ id = 'x', label = 'X' })") is False)
check("a duplicate id replaces, it does not duplicate", (lambda: (ev(R, "ForgesLedger.RegisterTab({ id = 'demo', label = 'Demo2', build = function() return {{text='v2'}} end })"), tabs(R).count("Demo2") == 1 and "Demo" not in tabs(R))[1])())
panel_spec = "ForgesLedger.RegisterTab({ id = 'wide', label = 'Wide', order = 7, width = 700, height = 300, panel = function(parent) local f = CreateFrame('Frame', 'WideTabPanel', parent); local t = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormal'); t:SetText('wide!'); return f end, onShow = function() WIDE_SHOWN = (WIDE_SHOWN or 0) + 1 end })"
ev(R, panel_spec)
click_tab(R, "Wide")
check("a generic panel tab: built into the body, window resized to its size", R.eval("WideTabPanel:IsShown()") and size(R) == (712, 300 + 58 + 6) and R.eval("WIDE_SHOWN") == 1, size(R))
click_tab(R, "Ledger"); click_tab(R, "Wide")
check("the panel is built once, onShow runs each time", R.eval("WIDE_SHOWN") == 2)
check("no errors beyond the deliberate ones", len([e for e in errors(R) if "boom" not in e and "couldn't load" not in e]) == 0)

print("\n== the bar")
R = make()
btn = R.eval("(function() for _, f in ipairs(ALL_FRAMES) do if f._parent == ForgesLedgerBar and f._scripts.OnClick and f._kind == 'Button' and not f.plugin then return f end end end)()")
R.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(btn)
check("the anvil on the bar opens the main window", host_shown(R))
R.eval("function(b) b._scripts.OnClick(b, 'LeftButton') end")(btn)
check("...and a second click closes it", not host_shown(R))

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
