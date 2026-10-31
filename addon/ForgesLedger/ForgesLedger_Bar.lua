-- Forge's Ledger: the bar (part of the core addon, v2.11)
-- A thin bar docked to the bottom (or top) of the screen with the Ledger's
-- numbers at a glance: an anvil launcher, then one segment per plugin -
-- gold, Todo, Great Vault, and whatever satellites add. Click a segment for
-- its details window. It's a companion to bars like Titan Panel, not a
-- replacement: only Ledger data lives here.
--
-- Plugins (the core's own segments and satellites) register with:
--
--   ForgesLedger.RegisterBarPlugin({
--       id    = "professions",      -- stable id (see "who wins" below)
--       label = "Professions",      -- its name in the settings window
--       order = 50,                 -- left-to-right; core uses 10, 20, 30
--       text  = function()          -- the segment's text; nil or "" hides it
--           return "Professions: 1 ready", true, true
--           -- 2nd value: show the gold dot; 3rd: pulse the segment (a
--           -- "come back, something's ready" nudge; the player can turn
--           -- pulsing off in the bar's Settings)
--       end,
--       roster  = function() return {...} end,  -- optional: hover card across
--                                               -- characters (see ForgesLedger_Windows.lua)
--       tooltip = function(tooltip) end,        -- optional, older style: add
--                                               -- GameTooltip lines (used if no roster)
--       onClick = function(button) end,         -- optional: run this on click
--                                               -- instead of opening a window
--       open = function(toggle) end,            -- optional: the plugin's own window;
--                                               -- /fl <id> calls it (return true if open)
--       window  = { title = "Professions",      -- optional: what a click opens
--                   lines = function() return { { text = "..." } } end },
--       updateEvents = { "SKILL_LINES_CHANGED" }, -- optional: refresh on these
--   })
--
-- It returns true when registered. Window lines are described in
-- ForgesLedger_Windows.lua. Who wins: a satellite registering an id the
-- core already uses replaces the core's version (that's how a future
-- dungeons satellite can take over the Vault segment without a core
-- change). Every call into a plugin is pcall-guarded; one that errors is
-- reported once and switched off until /reload - never fatal.
--
-- Display only - no secure frames, no protected calls - so it's safe in
-- combat. It refreshes when its plugins' events fire, when the core records
-- new data, and once a minute as a backstop. Never every frame.

local _, ns = ...
local C = ns.COLORS
local W = ns.Windows

local BAR_H, PAD, DOT = 24, 14, 12
local ICON_W, ICON_H = 30, 22  -- the anvil art is 4:3
local GOLD_CODE = "|cffe6bf40"  -- the gold color, (0.9, 0.75, 0.25), as a text code
local CHECK = "|TInterface\\Buttons\\UI-CheckBox-Check:16:16|t"
local BOX = "|TInterface\\Buttons\\UI-CheckBox-Up:16:16|t"

local plugins = {}  -- id -> plugin
local failed = {}   -- id -> true once that plugin has errored (until /reload)
local bar, anvil, menu
local segs = {}     -- segment buttons, reused as the layout changes
local refreshQueued = false
local Refresh       -- defined below; QueueRefresh needs it first

----------------------------------------------------------------- settings ---

-- Saved in the core's save file. Every field is optional, so a file from an
-- older version (with no bar settings at all) just gets the defaults.
local function Settings()
    local s = ForgeGoldDB.bar
    if type(s) ~= "table" then
        s = {}
        ForgeGoldDB.bar = s
    end
    if s.enabled == nil then s.enabled = true end
    -- Docked at the top unless the player has picked a side. Older versions
    -- saved "BOTTOM" as their default for everyone, so only a choice made
    -- since v2.7 (anchorChosen) is kept; everyone else moves to the top once.
    if not s.anchorChosen or (s.anchor ~= "TOP" and s.anchor ~= "BOTTOM") then s.anchor = "TOP" end
    if s.align ~= "LEFT" then s.align = "CENTER" end  -- segments centered unless set to left
    if type(s.hidden) ~= "table" then s.hidden = {} end  -- segment id -> true
    if s.pulse == nil then s.pulse = true end  -- segments may pulse when something's ready
    -- "FIT": the bar is only as wide as its anvil and segments (the default
    -- since v2.12 - edge to edge, it covered the minimap clock and anything
    -- else at the screen's corners); "FULL": stretched across the screen.
    if s.width ~= "FULL" then s.width = "FIT" end
    return s
end
ns.BarSettings = Settings

------------------------------------------------------------- plugin host ---

local events = CreateFrame("Frame")

-- Many events can arrive together (a craft fires several); redraw once,
-- a moment after they settle.
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        Refresh()
    end)
end
ns.DataChanged = QueueRefresh  -- the core calls this after recording new data

local function Fail(p, err)
    if failed[p.id] then return end
    failed[p.id] = true
    print(ns.PREFIX .. 'The bar\'s "' .. tostring(p.label) .. '" segment hit an error and is off until /reload: ' .. tostring(err))
end

-- Call one of a plugin's functions. A plugin is someone else's code, so an
-- error must never reach the bar: it's caught, reported once, and the
-- plugin is skipped from then on.
local function Call(p, fn, ...)
    if failed[p.id] or type(fn) ~= "function" then return false end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        Fail(p, a)
        return false
    end
    return true, a, b, c
end

local function Register(def, fromCore)
    if type(def) ~= "table" or type(def.id) ~= "string" or def.id == ""
            or type(def.text) ~= "function" then
        return false
    end
    local old = plugins[def.id]
    if old and fromCore and not old.fromCore then return false end  -- the satellite's version wins
    plugins[def.id] = {
        id = def.id,
        label = type(def.label) == "string" and def.label or def.id,
        -- a replacement without an order keeps the old segment's place
        order = tonumber(def.order) or (old and old.order) or 100,
        text = def.text,
        tooltip = def.tooltip,
        roster = def.roster,
        window = type(def.window) == "table" and def.window or nil,
        onClick = type(def.onClick) == "function" and def.onClick or nil,
        open = type(def.open) == "function" and def.open or nil,
        fromCore = fromCore and true or false,
    }
    failed[def.id] = nil
    if type(def.updateEvents) == "table" then
        for _, e in ipairs(def.updateEvents) do
            -- pcall: an event this client doesn't have just isn't watched
            if type(e) == "string" then pcall(events.RegisterEvent, events, e) end
        end
    end
    QueueRefresh()
    return true
end

ForgesLedger.RegisterBarPlugin = function(def)
    local ok, res = pcall(Register, def, false)
    return ok and res or false
end

-- A copy of a registered plugin's functions, so a satellite can build on
-- the segment it's replacing instead of re-implementing it (the Dungeons
-- satellite keeps the core's vault slot count and adds the keystone).
-- Read it before registering the replacement. nil if there's no such id.
-- Ask the bar to redraw soon, e.g. after a satellite has read new data
-- that its segment shows. Cheap and debounced - call it freely.
ForgesLedger.RefreshBar = function() QueueRefresh() end

ForgesLedger.GetBarPlugin = function(id)
    local p = plugins[id]
    if not p then return nil end
    return { id = p.id, label = p.label, order = p.order, text = p.text, roster = p.roster,
             tooltip = p.tooltip, window = p.window, fromCore = p.fromCore }
end

local function Sorted()
    local list = {}
    for _, p in pairs(plugins) do tinsert(list, p) end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return list
end

------------------------------------------------------------- the windows ---

local function MainLines() return {} end  -- replaced below, once gold helpers exist
local SettingsLines

-- Open a segment's window (toggle = close it if it's open). Also used by
-- /fl, so every window works with the bar hidden. Returns nil if there's
-- no such window (e.g. a satellite that isn't installed).
function ns.OpenWindow(id, toggle)
    local open = toggle and W.Toggle or W.Open
    if id == "ledger" then return open("ledger", "Forge's Ledger", MainLines) end
    if id == "settings" then return open("settings", "Forge's Ledger - Settings", SettingsLines) end
    local p = plugins[id]
    if p and p.open then  -- the plugin draws its own window
        local ok, isOpen = Call(p, p.open, toggle)
        if ok then return isOpen and true or false end
    end
    if not (p and p.window) then return nil end
    return open(id, p.window.title or p.label, function()
        local ok, lines = Call(p, p.window.lines)
        if not ok then return { { text = "This window hit an error and is off until /reload.", dim = true } } end
        return lines
    end)
end

------------------------------------------------------------------ the bar ---

local function ApplyPosition()
    if not bar then return end
    local s = Settings()
    local side = s.anchor
    bar:ClearAllPoints()
    if s.width == "FULL" then
        bar:SetPoint(side .. "LEFT", UIParent, side .. "LEFT", 0, 0)
        bar:SetPoint(side .. "RIGHT", UIParent, side .. "RIGHT", 0, 0)
    elseif s.align == "LEFT" then
        bar:SetPoint(side .. "LEFT", UIParent, side .. "LEFT", 0, 0)
    else
        bar:SetPoint(side, UIParent, side, 0, 0)  -- centered; Refresh sets the width
    end
    -- the gold edge faces the game world: top edge when docked at the bottom
    local edge = side == "TOP" and "BOTTOM" or "TOP"
    bar.edge:ClearAllPoints()
    bar.edge:SetPoint(edge .. "LEFT")
    bar.edge:SetPoint(edge .. "RIGHT")
end

function ns.SetBarAlign(align)
    Settings().align = align == "LEFT" and "LEFT" or "CENTER"
    ApplyPosition()
    QueueRefresh()
end

function ns.SetBarWidth(mode)
    Settings().width = mode == "FULL" and "FULL" or "FIT"
    ApplyPosition()
    QueueRefresh()
end

function ns.SetBarAnchor(side)
    local s = Settings()
    s.anchor = side == "BOTTOM" and "BOTTOM" or "TOP"
    s.anchorChosen = true
    ApplyPosition()
end

function ns.SetBarEnabled(on)
    Settings().enabled = on and true or false
    if bar then bar:SetShown(on) end
    if menu then menu:Hide() end
    ns.HideRoster()
    QueueRefresh()
end

local function TooltipAnchor()
    return Settings().anchor == "TOP" and "ANCHOR_BOTTOM" or "ANCHOR_TOP"
end

local function Seg(i)
    if segs[i] then return segs[i] end
    local s = CreateFrame("Button", nil, bar)
    s:SetHeight(BAR_H)
    s.divider = s:CreateTexture(nil, "ARTWORK")  -- faint gold line on its left
    s.divider:SetPoint("LEFT")
    s.divider:SetSize(1, 14)
    s.divider:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.3)
    -- a gold wash that breathes across the segment when its plugin asks
    s.glow = s:CreateTexture(nil, "BACKGROUND")
    s.glow:SetAllPoints()
    s.glow:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    s.glow:SetAlpha(0)
    s.pulse = s.glow:CreateAnimationGroup()
    s.pulse:SetLooping("BOUNCE")
    local pa = s.pulse:CreateAnimation("Alpha")
    pa:SetFromAlpha(0.04)
    pa:SetToAlpha(0.32)
    pa:SetDuration(0.8)
    s.dot = s:CreateTexture(nil, "ARTWORK")  -- "something's ready" marker
    s.dot:SetSize(6, 6)
    s.dot:SetPoint("LEFT", PAD, 0)
    s.dot:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    s.label = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s.label:SetTextColor(C.bone[1], C.bone[2], C.bone[3])
    local hl = s:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.08)
    s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    s:SetScript("OnClick", function(self, button)
        local p = self.plugin
        if not p then return end
        if p.onClick then
            ns.HideRoster()
            Call(p, p.onClick, button)
        else
            ns.OpenWindow(p.id, true)
        end
    end)
    s:SetScript("OnEnter", function(self)
        local p = self.plugin
        if not p then return end
        if type(p.roster) == "function" then
            -- a failing roster shows "Data unavailable"; it doesn't switch
            -- the whole segment off the way a failing text() does
            local ok, data = pcall(p.roster)
            ns.ShowRoster(self, ok and data or nil, p.label)
            return
        end
        GameTooltip:SetOwner(self, TooltipAnchor())
        GameTooltip:AddLine(p.label, C.gold[1], C.gold[2], C.gold[3])
        if p.tooltip then Call(p, p.tooltip, GameTooltip) end
        if p.window and not p.onClick then GameTooltip:AddLine("Click for details", C.dim[1], C.dim[2], C.dim[3]) end
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function()
        ns.HideRoster()
        GameTooltip_Hide()
    end)
    segs[i] = s
    return s
end

-- Redraw the segments left to right, skipping hidden ones and plugins with
-- nothing to show, so the rest close up the gap. The anvil and segments are
-- one group: measured first, then placed at the left edge or centered.
function Refresh()
    if bar and bar:IsShown() then
        local settings = Settings()
        local hidden = settings.hidden
        local x = anvil:GetWidth() + 4
        local n = 0
        for _, p in ipairs(Sorted()) do
            if not hidden[p.id] then
                local ok, text, attention, wantPulse = Call(p, p.text)
                if ok and text ~= nil and text ~= "" then
                    n = n + 1
                    local s = Seg(n)
                    s.plugin = p
                    local inset = PAD + (attention and DOT or 0)
                    s.dot:SetShown(attention and true or false)
                    s.label:ClearAllPoints()
                    s.label:SetPoint("LEFT", inset, 0)
                    s.label:SetText(tostring(text))
                    if wantPulse and Settings().pulse then
                        if not s.pulse:IsPlaying() then s.pulse:Play() end
                    elseif s.pulse:IsPlaying() then
                        s.pulse:Stop()
                        s.glow:SetAlpha(0)
                    end
                    local w = math.ceil(s.label:GetStringWidth()) + inset + PAD
                    s:SetWidth(w)
                    s.x = x  -- position within the group; placed below
                    s:Show()
                    x = x + w
                end
            end
        end
        local start = 6
        if settings.width ~= "FULL" then
            -- fit: the bar is exactly the group plus a margin each side
            local want = x + 12
            if math.abs((bar:GetWidth() or 0) - want) > 0.5 then bar:SetWidth(want) end
        elseif settings.align == "CENTER" then
            start = math.max(6, math.floor((bar:GetWidth() - x) / 2))
        end
        anvil:ClearAllPoints()
        anvil:SetPoint("LEFT", bar, "LEFT", start, 0)
        for i = 1, n do
            segs[i]:ClearAllPoints()
            segs[i]:SetPoint("LEFT", bar, "LEFT", start + segs[i].x, 0)
        end
        for i = n + 1, #segs do
            segs[i].pulse:Stop()
            segs[i].glow:SetAlpha(0)
            segs[i]:Hide()
            segs[i].plugin = nil
        end
    end
    W.RefreshAll()
end

local function CreateMenu()
    menu = CreateFrame("Frame", "ForgesLedgerBarMenu", UIParent)
    menu:SetFrameStrata("DIALOG")
    menu:EnableMouse(true)
    local bg = menu:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.iron[1], C.iron[2], C.iron[3], 0.98)
    ns.Trim(menu, 0.8)
    local entries = {
        { "Hide the bar", function()
            ns.SetBarEnabled(false)
            print(ns.PREFIX .. "Bar hidden. Type /fl bar to show it again.")
        end },
        -- label follows where the bar is now (see OnShow below)
        { function() return Settings().anchor == "TOP" and "Move to bottom" or "Move to top" end,
          function() ns.SetBarAnchor(Settings().anchor == "TOP" and "BOTTOM" or "TOP") end },
        { function() return Settings().align == "LEFT" and "Center the segments" or "Align segments left" end,
          function() ns.SetBarAlign(Settings().align == "LEFT" and "CENTER" or "LEFT") end },
        { function() return Settings().width == "FULL" and "Fit the bar to its segments" or "Stretch the bar full width" end,
          function() ns.SetBarWidth(Settings().width == "FULL" and "FIT" or "FULL") end },
        { "Settings", function() ns.OpenWindow("settings") end },
        { "Sync now (reloads UI)", function() ForgesLedger_Sync() end },
    }
    local buttons = {}
    for i, e in ipairs(entries) do
        local b = CreateFrame("Button", nil, menu)
        buttons[i] = b
        b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 20)
        b:SetPoint("RIGHT", -6, 0)
        b:SetHeight(20)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("LEFT", 6, 0)
        b.label, b.getLabel = t, e[1]
        t:SetTextColor(C.bone[1], C.bone[2], C.bone[3])
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.15)
        b:SetScript("OnClick", function()
            menu:Hide()
            e[2]()
        end)
    end
    menu:SetSize(190, #entries * 20 + 12)
    -- close on a click anywhere else (an event only newer clients have;
    -- Escape and clicking the anvil again work everywhere)
    menu.buttons = buttons
    menu:SetScript("OnShow", function(self)
        for _, b in ipairs(self.buttons) do
            b.label:SetText(type(b.getLabel) == "function" and b.getLabel() or b.getLabel)
        end
        pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
    end)
    menu:SetScript("OnHide", function(self) pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    menu:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not anvil:IsMouseOver() then self:Hide() end
    end)
    tinsert(UISpecialFrames, "ForgesLedgerBarMenu")
    menu:Hide()
end

local function ToggleMenu()
    if not menu then CreateMenu() end
    if menu:IsShown() then
        menu:Hide()
        return
    end
    menu:ClearAllPoints()
    if Settings().anchor == "TOP" then
        menu:SetPoint("TOPLEFT", anvil, "BOTTOMLEFT", 0, -4)
    else
        menu:SetPoint("BOTTOMLEFT", anvil, "TOPLEFT", 0, 4)
    end
    menu:Show()
end

local function CreateBar()
    bar = CreateFrame("Frame", "ForgesLedgerBar", UIParent)
    bar:SetHeight(BAR_H)
    -- below the action bars, so if the two ever overlap the action buttons
    -- stay on top and clickable
    bar:SetFrameStrata("LOW")
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.iron[1], C.iron[2], C.iron[3], C.iron[4])
    bar.edge = bar:CreateTexture(nil, "BORDER")
    bar.edge:SetHeight(1)
    bar.edge:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.85)

    anvil = CreateFrame("Button", "ForgesLedgerBarAnvil", bar)
    anvil:SetSize(ICON_W + 8, BAR_H)
    anvil:SetPoint("LEFT", bar, "LEFT", 6, 0)
    local icon = anvil:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    -- the addon's own anvil art (made from the app's icon). The art is 4:3,
    -- stored in rows 8-56 of a 64x64 texture (WoW wants power-of-two
    -- sizes), so only that band is drawn - nearly the bar's full height.
    -- The game's blacksmithing icon stands in if the file is ever missing.
    if icon:SetTexture(ns.ANVIL_ART) == false then
        icon:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
        icon:SetSize(BAR_H - 6, BAR_H - 6)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        icon:SetSize(ICON_W, ICON_H)
        icon:SetTexCoord(0, 1, 8 / 64, 56 / 64)
    end
    local hl = anvil:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(icon)
    hl:SetColorTexture(1, 1, 1, 0.15)
    anvil:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    anvil:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ToggleMenu()
        else
            ns.OpenWindow("ledger", true)
        end
    end)
    anvil:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, TooltipAnchor())
        GameTooltip:AddLine("Forge's Ledger", C.gold[1], C.gold[2], C.gold[3])
        GameTooltip:AddLine("Click: open the Ledger", C.bone[1], C.bone[2], C.bone[3])
        GameTooltip:AddLine("Right-click: options", C.bone[1], C.bone[2], C.bone[3])
        GameTooltip:AddLine(ns.SavedText(), C.dim[1], C.dim[2], C.dim[3])
        GameTooltip:Show()
    end)
    anvil:SetScript("OnLeave", GameTooltip_Hide)

    ApplyPosition()
    bar:SetScript("OnSizeChanged", QueueRefresh)  -- keep centered if the screen/UI scale changes
    bar:SetShown(Settings().enabled)
end

events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        CreateBar()
        Refresh()
        -- backstop for things no event announces, like a cooldown running out
        C_Timer.NewTicker(60, QueueRefresh)
    else
        QueueRefresh()
    end
end)

----------------------------------------------------- core segment: gold ---

local function IsRetail()
    return WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
end

-- Retail amounts are large, so whole gold reads cleaner; WoW Forever shows
-- silver and copper too, as the app does.
local function Money(copper)
    copper = math.floor(tonumber(copper) or 0)
    if IsRetail() then copper = copper - copper % 10000 end
    local ok, s = pcall(GetMoneyString, copper, true)
    if ok and type(s) == "string" then return s end
    return GetCoinTextureString(copper)
end

local function ClassColor(class)
    local cc = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    return cc and { cc.r, cc.g, cc.b } or nil
end

-- Every character this addon has recorded on this account, plus the
-- warband bank. The character you're on uses the live amount, so the bar is
-- right the moment money changes.
local function GoldData()
    local me = ns.CharKey()
    local list, chars = {}, 0
    for key, c in pairs(ForgeGoldDB.chars or {}) do
        if type(c) == "table" then
            local money = key == me and GetMoney() or tonumber(c.money) or 0
            chars = chars + money
            tinsert(list, { key = key, name = c.name or key, class = c.class, money = money, history = c.history })
        end
    end
    table.sort(list, function(a, b) return a.money > b.money end)
    local bank = type(ForgeGoldDB.warband) == "table" and tonumber(ForgeGoldDB.warband.money) or nil
    return list, chars, bank, chars + (bank or 0)
end

-- The desktop app's companion data (goals and tasks you set in the app),
-- if its small companion addon is installed: ForgesLedger_Companion, which
-- the app writes. Read only - the app regenerates it; nil without it.
local function Companion()
    local c = ForgesLedgerCompanion
    if type(c) == "table" and tonumber(c.companionVersion) then return c end
end

-- This week's gold: per character (and the warband bank), the change since
-- the week began. Only records that have this week's start count. net =
-- the sum; partial = some character's week started after the reset (first
-- seen this week), so the number may be short. nil where the game doesn't
-- report the weekly reset.
local function WeekGold()
    local ws = ns.WeekStartEpoch and ns.WeekStartEpoch()
    if not ws then return nil end
    local me = ns.CharKey()
    local net, partial, per = 0, false, {}
    local function add(key, rec, money)
        local w = type(rec) == "table" and rec.week
        if type(w) == "table" and math.abs((tonumber(w.start) or 0) - ws) < 3600 and tonumber(w.money) then
            local d = (tonumber(money) or 0) - w.money
            net = net + d
            per[key] = d
            if not w.exact then partial = true end
        end
    end
    for key, c in pairs(ForgeGoldDB.chars or {}) do
        if type(c) == "table" then add(key, c, key == me and GetMoney() or c.money) end
    end
    if type(ForgeGoldDB.warband) == "table" then add("warband", ForgeGoldDB.warband, ForgeGoldDB.warband.money) end
    return net, partial, per
end

-- The weekly gold goal, in copper (nil = none). Set in game (here) or in
-- the app (companion data): whichever was set last wins.
local function WeeklyGoal()
    local g = type(ForgeGoldDB.weeklyGoal) == "table" and tonumber(ForgeGoldDB.weeklyGoal.copper) and ForgeGoldDB.weeklyGoal
    local comp = Companion()
    local cg = comp and type(comp.weeklyGoal) == "table" and tonumber(comp.weeklyGoal.copper) and comp.weeklyGoal
    local pick = g
    if cg and (not g or (tonumber(cg.at) or tonumber(comp.generatedAt) or 0) > (tonumber(g.at) or 0)) then pick = cg end
    local copper = pick and tonumber(pick.copper) or 0
    return copper > 0 and copper or nil
end

-- "200000", "200,000g", "200 000" -> 200000 gold; empty or 0 clears the goal
local function SetWeeklyGoal(text)
    local digits = tostring(text or ""):gsub("[^%d]", "")
    local gold = tonumber(digits) or 0
    ForgeGoldDB.weeklyGoal = { copper = gold * 10000, at = time() }
    print(ns.PREFIX .. (gold > 0 and ("Weekly gold goal: " .. Money(gold * 10000) .. ".") or "Weekly gold goal cleared."))
end

-- "This week: +128,400g  ·  Goal 200,000g (64%)"
local function WeekLine(net, goal)
    local sign = net >= 0 and "+" or "-"
    local t = "This week: " .. sign .. Money(math.abs(net))
    if goal then t = t .. "  \194\183  Goal " .. Money(goal) .. " (" .. math.floor(math.max(0, net) * 100 / goal) .. "%)" end
    return t
end

-- Change since 7 days ago, from the daily history the addon keeps. nil if
-- there's no history that old yet.
local function WeekChange(e)
    if type(e.history) ~= "table" then return nil end
    local cutoff = date("%Y-%m-%d", time() - 7 * 86400)
    local base
    for _, pt in ipairs(e.history) do
        if type(pt) == "table" and type(pt.day) == "string" and pt.day <= cutoff then
            base = tonumber(pt.money)
        end
    end
    return base and (e.money - base) or nil
end

local function GoldLines(withChange)
    local list, chars, bank, total = GoldData()
    local lines = {}
    -- this week (since the weekly reset): net, the goal, and where to set it
    local net, partial, per = WeekGold()
    if withChange and net then
        local goal = WeeklyGoal()
        tinsert(lines, { text = "This week", header = true })
        tinsert(lines, { text = "Earned (all characters + warband bank)",
                         right = (net >= 0 and "+" or "-") .. Money(math.abs(net)),
                         rightColor = net >= 0 and { 0.25, 0.75, 0.25 } or { 0.82, 0.25, 0.25 } })
        if goal then
            tinsert(lines, { text = "Goal " .. Money(goal), right = math.floor(math.max(0, net) * 100 / goal) .. "%",
                             bar = math.max(0, net) / goal })
        end
        tinsert(lines, { text = "Weekly goal", input = { placeholder = goal and "change it: gold, then Enter" or "gold, e.g. 200000, then Enter",
                                                          value = "", onEnter = SetWeeklyGoal } })
        if partial then
            tinsert(lines, { text = "Partial week: some characters were first seen after the reset.", dim = true })
        end
    end
    tinsert(lines, { text = "Characters", header = true })
    for _, e in ipairs(list) do
        local right = Money(e.money)
        local d
        if withChange and net then d = per[e.key] else d = withChange and WeekChange(e) end
        if d and math.abs(d) >= (IsRetail() and 10000 or 1) then
            right = (d > 0 and "|cff40c040+" or "|cffd04040-") .. Money(math.abs(d)) .. "|r    " .. right
        end
        tinsert(lines, { text = e.name, right = right, indent = true, color = ClassColor(e.class) })
    end
    tinsert(lines, { text = "All characters", right = Money(chars) })
    if bank then
        tinsert(lines, { text = "Warband bank", right = Money(bank) })
    elseif IsRetail() then
        tinsert(lines, { text = "Warband bank: open a bank once to record it", dim = true })
    end
    tinsert(lines, { text = "Total", right = Money(total), header = true })
    if withChange then
        tinsert(lines, { text = net and "Green/red: change this week, since the weekly reset."
                                    or "Green/red: change over the last 7 days.", dim = true })
    end
    return lines
end

Register({
    id = "gold", label = "Gold", order = 10,
    updateEvents = { "PLAYER_MONEY", "ACCOUNT_MONEY" },
    text = function()
        local _, _, _, total = GoldData()
        return GOLD_CODE .. Money(total) .. "|r"
    end,
    -- "Where is my gold?" - the 10 richest characters
    roster = function()
        local list, _, bank, total = GoldData()
        local rows, footer = {}, {}
        for i, e in ipairs(list) do
            if i > 10 then break end
            tinsert(rows, { name = e.name, class = e.class, value = Money(e.money) })
        end
        local net = WeekGold()
        if net then tinsert(footer, WeekLine(net, WeeklyGoal())) end
        if #list > 10 then tinsert(footer, "+" .. (#list - 10) .. " more characters") end
        if bank then tinsert(footer, "Includes the warband bank: " .. Money(bank)) end
        return { title = "Warband gold: " .. Money(total), icon = "Interface\\Icons\\INV_Misc_Coin_01",
                 rows = rows, empty = "No characters recorded yet.", footer = footer }
    end,
    window = { title = "Gold", lines = function() return GoldLines(true) end },
}, true)

------------------------------------------- core segments: Todo and Vault ---

local sessionStart = time()

-- This week's facts for the character you're on, or nil if they were read
-- before the weekly reset (last week's vault isn't this week's).
local function WeekStart()
    local CD = C_DateAndTime
    if CD and CD.GetSecondsUntilWeeklyReset then
        local ok, s = pcall(CD.GetSecondsUntilWeeklyReset)
        if ok and type(s) == "number" then return time() + s - 7 * 86400 end
    end
    return sessionStart  -- can't tell when the week began: trust only this session's reads
end

-- c = a character's saved record (default: the one you're on)
local function Facts(c)
    c = c or (ForgeGoldDB.chars and ForgeGoldDB.chars[ns.CharKey()])
    local f = type(c) == "table" and c.todo
    if type(f) == "table" and (tonumber(f.at) or 0) >= WeekStart() then return f, c end
    return nil, c
end

-- The game's name for the Mythic+ row is "Activities"; the app shows it as
-- Dungeons. Other rows keep the game's own name.
local VAULT_NAMES = { Activities = "Dungeons" }
-- "Concession" is the vault's "Or collect" reward, taken instead of
-- choosing a slot - it isn't a slot to earn, so it's listed separately and
-- left out of slot counts.
local VAULT_ALT = "Concession"

local function VaultTotals(vault)
    local unlocked, total = 0, 0
    for name, r in pairs(vault) do
        if type(r) == "table" and name ~= VAULT_ALT then
            unlocked = unlocked + (tonumber(r.unlocked) or 0)
            total = total + (tonumber(r.total) or 0)
        end
    end
    return unlocked, total
end

-- The same automatic items the app's Todo tab answers from this addon's
-- data, for one character (default: the one you're on). Items the game
-- can't report (weekly quests, knowledge treasures) are ticked in the app,
-- so they aren't here.
------------------------------------------------------------ custom todos ---
-- Tasks you write yourself: for every character (global) or one character,
-- ticked by hand. Some are added here in game, some in the app (they come
-- through the companion data). Ticks are per character and clear when the
-- task's reset comes round (none, daily, weekly - the game's own resets).

local MAX_TASKS = 30

local function CustomDB()
    local db = type(ForgeGoldDB.custom) == "table" and ForgeGoldDB.custom or {}
    db.tasks = type(db.tasks) == "table" and db.tasks or {}
    db.done = type(db.done) == "table" and db.done or {}
    db.deleted = type(db.deleted) == "table" and db.deleted or {}
    ForgeGoldDB.custom = db
    return db
end

local function DayStart()
    local CD = C_DateAndTime
    if CD and CD.GetSecondsUntilDailyReset then
        local ok, s = pcall(CD.GetSecondsUntilDailyReset)
        if ok and type(s) == "number" then return time() + s - 86400 end
    end
    return sessionStart
end

-- every live task (game's and app's), oldest first; deleted ones never come back
local function CustomTasks()
    local db, comp = CustomDB(), Companion()
    local gone = {}
    for id in pairs(db.deleted) do gone[id] = true end
    if comp and type(comp.deleted) == "table" then
        for _, id in pairs(comp.deleted) do gone[tostring(id)] = true end
    end
    local out, seen = {}, {}
    local function take(list, by)
        for _, t in pairs(type(list) == "table" and list or {}) do
            if type(t) == "table" and t.id and t.text and not gone[tostring(t.id)] and not seen[tostring(t.id)] then
                seen[tostring(t.id)] = true
                tinsert(out, { id = tostring(t.id), text = tostring(t.text), scope = t.scope or "global",
                               reset = t.reset or "none", by = by, at = tonumber(t.at) or 0 })
            end
        end
    end
    take(comp and comp.tasks, "app")
    take(db.tasks, "game")
    table.sort(out, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
    return out
end

local function TaskApplies(t, key) return t.scope == "global" or t.scope == key end

local function TaskDone(t, key)
    local ts = tonumber((CustomDB().done[key] or {})[t.id])
    if not ts then return false end
    if t.reset == "daily" then return ts >= DayStart() end
    if t.reset == "weekly" then return ts >= WeekStart() end
    return true
end

local function ToggleTask(t)
    local done = CustomDB().done
    local me = ns.CharKey()
    done[me] = done[me] or {}
    done[me][t.id] = (not TaskDone(t, me)) and time() or nil
    QueueRefresh()
end

local function DeleteTask(t)
    local db = CustomDB()
    db.deleted[t.id] = time()
    db.tasks[t.id] = nil
    for _, d in pairs(db.done) do if type(d) == "table" then d[t.id] = nil end end
    print(ns.PREFIX .. "Deleted: " .. t.text)
    QueueRefresh()
end

local function AddTask(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return end
    if #CustomTasks() >= MAX_TASKS then
        print(ns.PREFIX .. "That's the limit of " .. MAX_TASKS .. " tasks - delete one first.")
        return
    end
    local db = CustomDB()
    local id = "g" .. time() .. math.random(1000, 9999)
    db.tasks[id] = { id = id, text = text, scope = Settings().customAll and "global" or ns.CharKey(),
                     reset = "none", at = time() }
    QueueRefresh()
end

local function TodoItems(char)
    local items = {}
    local f, c = Facts(char)
    local function add(label, done, detail)
        tinsert(items, { label = label, done = done and true or false, detail = detail })
    end
    if type(c) == "table" and type(c.cooldowns) == "table" and next(c.cooldowns) then
        local ready, now = 0, time()
        for _, cd in pairs(c.cooldowns) do
            if type(cd) == "table" and (tonumber(cd.readyAt) or 0) <= now then ready = ready + 1 end
        end
        add("Profession cooldowns", ready == 0, ready > 0 and (ready .. " ready") or "all used")
    end
    if not f then return items, false end
    if type(f.vault) == "table" and next(f.vault) then
        local unlocked, total = VaultTotals(f.vault)
        add("Great Vault slots", total > 0 and unlocked >= total, unlocked .. "/" .. total)
    end
    if f.vaultClaim ~= nil then
        add("Claim last week's Vault", not f.vaultClaim, f.vaultClaim and "rewards waiting" or "nothing waiting")
    end
    local act = type(f.vault) == "table" and f.vault.Activities
    local need = type(act) == "table" and tonumber(act.max)  -- runs for the last slot, from the game
    if type(f.mplus) == "table" and need and need > 0 then
        local runs = tonumber(f.mplus.runs) or 0
        local best = tonumber(f.mplus.best) or 0
        add("Mythic+ runs", runs >= need, runs .. "/" .. need .. (best > 0 and (", best +" .. best) or ""))
    end
    local now = time()
    if type(f.raids) == "table" then
        local n = 0
        for _, r in ipairs(f.raids) do
            if type(r) == "table" and (tonumber(r.resetAt) or 0) > now then n = n + 1 end
        end
        add("Raid lockouts", n > 0, n > 0 and (n .. " this week") or "none yet")
    end
    if type(f.worldBosses) == "table" then
        local n = 0
        for _, b in ipairs(f.worldBosses) do
            if type(b) == "table" and (tonumber(b.resetAt) or 0) > now then n = n + 1 end
        end
        add("World boss", n > 0, n > 0 and "killed" or "not killed yet")
    end
    return items, true
end

-- the game's items plus this character's custom tasks (they count on the bar)
local GameTodoItems = TodoItems
TodoItems = function(char, key)
    local items, fresh = GameTodoItems(char)
    key = key or ns.CharKey()
    for _, t in ipairs(CustomTasks()) do
        if TaskApplies(t, key) then
            tinsert(items, { label = t.text, done = TaskDone(t, key), custom = t })
        end
    end
    return items, fresh
end

Register({
    id = "todo", label = "Todo", order = 20,
    updateEvents = { "WEEKLY_REWARDS_UPDATE", "UPDATE_INSTANCE_INFO", "CHALLENGE_MODE_COMPLETED", "BOSS_KILL" },
    text = function()
        local items = TodoItems()
        if #items == 0 then return nil end
        local done = 0
        for _, it in ipairs(items) do if it.done then done = done + 1 end end
        return "Todo " .. done .. "/" .. #items
    end,
    -- "What's left today?" - characters with something left, most first
    roster = function()
        local list = {}
        for key, c in pairs(ForgeGoldDB.chars or {}) do
            if type(c) == "table" then
                local items = TodoItems(c, key)
                local done = 0
                for _, it in ipairs(items) do if it.done then done = done + 1 end end
                if #items > 0 and done < #items then
                    tinsert(list, { name = c.name or key, class = c.class, done = done, total = #items })
                end
            end
        end
        table.sort(list, function(a, b)
            local ra, rb = a.total - a.done, b.total - b.done
            if ra ~= rb then return ra > rb end
            return a.name < b.name
        end)
        local rows, footer = {}, {}
        for i, e in ipairs(list) do
            if i > 10 then break end
            tinsert(rows, { name = e.name, class = e.class, value = e.done .. "/" .. e.total,
                            progress = e.done / e.total })
        end
        if #list > 10 then tinsert(footer, "+" .. (#list - 10) .. " more") end
        return { title = "Today's todos", rows = rows, footer = footer,
                 empty = "Nothing left that the game reports." }
    end,
    window = { title = "Todo", lines = function()
        local items, fresh = TodoItems()
        local lines = { { text = "This character", header = true } }
        local mine = {}
        for _, it in ipairs(items) do
            if it.custom then
                tinsert(mine, it)
            else
                tinsert(lines, { text = (it.done and CHECK or BOX) .. " " .. it.label, right = it.detail,
                                 color = it.done and C.dim or nil })
            end
        end
        if not fresh then
            tinsert(lines, { text = "This week's progress updates a few seconds after login.", dim = true })
        end
        -- Custom: your own tasks (closed by default while there are none)
        local s = Settings()
        local open = s.customOpen
        if open == nil then open = #mine > 0 end
        local left = 0
        for _, it in ipairs(mine) do if not it.done then left = left + 1 end end
        tinsert(lines, { text = "Custom" .. ((#mine > 0 and left == 0) and ("  -  all done " .. CHECK) or ""), header = true,
                         right = (open and "hide" or "show") .. (#mine > 0 and ("  (" .. (#mine - left) .. "/" .. #mine .. ")") or ""),
                         rightColor = C.dim, onClick = function() Settings().customOpen = not open end })
        if open then
            for _, it in ipairs(mine) do
                local t = it.custom
                tinsert(lines, { text = (it.done and CHECK or BOX) .. " " .. t.text, indent = true,
                                 right = t.scope == "global" and "all toons" or (t.reset ~= "none" and t.reset or nil),
                                 rightColor = C.dim, color = it.done and C.dim or nil,
                                 onClick = function() ToggleTask(t) end,
                                 onRightClick = function() DeleteTask(t) end })
            end
            tinsert(lines, { text = "Add a task", input = { placeholder = s.customAll and "for all characters, then Enter"
                                                                   or "for this character, then Enter", onEnter = AddTask } })
            tinsert(lines, { text = (s.customAll and CHECK or BOX) .. " For all characters", indent = true,
                             onClick = function() Settings().customAll = not Settings().customAll end })
            tinsert(lines, { text = "Click a task to tick it, right-click to delete it.", dim = true })
        end
        tinsert(lines, { text = "Weekly quests and more: the app's Todo tab.", dim = true })
        return lines
    end },
}, true)

-- "Who needs runs?" Every max-level character below the last Mythic+ vault
-- slot, fewest runs first. A character whose record is from before this
-- week's reset is at 0 - the vault starts over each week - so it's shown
-- as 0, not as last week's numbers. The run targets (8 for Mythic+, ...)
-- come from the game: this character's own record, or what the game
-- reported this week on the character you're on.
local VAULT_ROWS = { { "Activities", "M+" }, { "Raid", "Raid" }, { "World", "World" } }

local function VaultRoster()
    local mine = Facts()
    local targets = {}
    for _, row in ipairs(VAULT_ROWS) do
        local r = mine and type(mine.vault) == "table" and mine.vault[row[1]]
        targets[row[1]] = type(r) == "table" and tonumber(r.max) or nil
    end
    local maxLevel
    if GetMaxLevelForPlayerExpansion then
        local ok, n = pcall(GetMaxLevelForPlayerExpansion)
        maxLevel = ok and tonumber(n) or nil
    end
    local list, complete = {}, 0
    for key, c in pairs(ForgeGoldDB.chars or {}) do
        if type(c) == "table" and (not maxLevel or (tonumber(c.level) or 0) >= maxLevel) then
            local f = Facts(c)  -- nil: nothing read since the reset
            local parts, mplus = {}, nil
            for _, row in ipairs(VAULT_ROWS) do
                local r = f and type(f.vault) == "table" and f.vault[row[1]]
                local need = type(r) == "table" and tonumber(r.max) or targets[row[1]]
                local prog
                if not f then
                    prog = 0
                elseif type(r) == "table" then
                    prog = tonumber(r.progress)  -- nil from an older addon version
                end
                if need and need > 0 and prog then
                    prog = math.min(prog, need)
                    tinsert(parts, row[2] .. " " .. prog .. "/" .. need)
                    if row[1] == "Activities" then mplus = { prog, need } end
                end
            end
            if mplus then
                if mplus[1] >= mplus[2] then
                    complete = complete + 1
                else
                    tinsert(list, { name = c.name or key, class = c.class, prog = mplus[1], need = mplus[2],
                                    sub = table.concat(parts, " · ", 2) })
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.prog ~= b.prog then return a.prog < b.prog end
        return a.name < b.name
    end)
    local rows, footer, more = {}, {}, {}
    for i, e in ipairs(list) do
        if i > 12 then break end
        tinsert(rows, { name = e.name, class = e.class, value = "M+ " .. e.prog .. "/" .. e.need,
                        progress = e.prog / e.need, sub = e.sub ~= "" and e.sub or nil })
    end
    if complete > 0 then
        local t = targets.Activities and (targets.Activities .. "/" .. targets.Activities) or "M+"
        tinsert(more, t .. " complete: " .. complete .. (complete == 1 and " character" or " characters"))
    end
    if #list > 12 then tinsert(more, "+" .. (#list - 12) .. " more") end
    if #more > 0 then tinsert(footer, table.concat(more, " · ")) end
    return { title = "Great Vault - M+",
             rows = rows, footer = footer,
             empty = complete > 0 and "Every character has finished their runs." or "No max-level characters recorded yet." }
end

-- The Great Vault only exists on retail; WoW Forever doesn't get this segment.
if C_WeeklyRewards then
    Register({
        id = "vault", label = "Great Vault", order = 30,
        updateEvents = { "WEEKLY_REWARDS_UPDATE", "CHALLENGE_MODE_COMPLETED" },
        text = function()
            local f = Facts()
            if not (f and type(f.vault) == "table" and next(f.vault)) then return nil end
            local waiting = f.vaultClaim == true
            local a = f.vault.Activities
            local prog, need = type(a) == "table" and tonumber(a.progress), type(a) == "table" and tonumber(a.max)
            if prog and need and need > 0 then
                return "Vault: M+ " .. math.min(prog, need) .. "/" .. need, waiting
            end
            local unlocked, total = VaultTotals(f.vault)  -- saved by an older version: slots only
            if total == 0 then return nil end
            return "Vault: " .. unlocked .. "/" .. total, waiting
        end,
        roster = VaultRoster,
        window = { title = "Great Vault", lines = function()
            local f = Facts()
            if not f then
                return { { text = "This week's progress updates a few seconds after login.", dim = true } }
            end
            local now = time()
            local lines = { { text = "Great Vault", header = true } }
            local names = {}
            for name in pairs(type(f.vault) == "table" and f.vault or {}) do
                if name ~= VAULT_ALT then tinsert(names, name) end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                local r = f.vault[name]
                if type(r) == "table" then
                    local right = (r.unlocked or 0) .. "/" .. (r.total or 0) .. " slots"
                    if tonumber(r.progress) and tonumber(r.max) then
                        right = math.min(r.progress, r.max) .. "/" .. r.max .. "    " .. right
                    end
                    tinsert(lines, { text = VAULT_NAMES[name] or name, right = right, indent = true })
                end
            end
            local alt = type(f.vault) == "table" and f.vault[VAULT_ALT]
            if type(alt) == "table" then
                tinsert(lines, { text = "Or collect a reward instead", indent = true,
                                 right = (tonumber(alt.unlocked) or 0) > 0 and "available" or "not yet",
                                 rightColor = (tonumber(alt.unlocked) or 0) > 0 and C.gold or C.dim })
            end
            if f.vaultClaim then tinsert(lines, { text = "Rewards waiting to be claimed", indent = true }) end
            if type(f.mplus) == "table" then
                tinsert(lines, { text = "Mythic+", header = true })
                tinsert(lines, { text = "Runs this week", right = tonumber(f.mplus.runs) or 0, indent = true })
                if (tonumber(f.mplus.best) or 0) > 0 then
                    tinsert(lines, { text = "Best key", right = "+" .. f.mplus.best, indent = true })
                end
            end
            tinsert(lines, { text = "Raid lockouts", header = true })
            local any = false
            for _, r in ipairs(type(f.raids) == "table" and f.raids or {}) do
                if type(r) == "table" and (tonumber(r.resetAt) or 0) > now then
                    any = true
                    tinsert(lines, { text = tostring(r.name) .. (r.difficulty and (" (" .. r.difficulty .. ")") or ""),
                                     right = (r.killed or 0) .. "/" .. (r.total or 0), indent = true })
                end
            end
            if not any then tinsert(lines, { text = "None this week", dim = true, indent = true }) end
            if type(f.worldBosses) == "table" and #f.worldBosses > 0 then
                tinsert(lines, { text = "World bosses", header = true })
                for _, b in ipairs(f.worldBosses) do
                    if type(b) == "table" and (tonumber(b.resetAt) or 0) > now then
                        tinsert(lines, { text = tostring(b.name), right = "killed", indent = true })
                    end
                end
            end
            return lines
        end },
    }, true)
end

------------------------------------------------------ core segment: sync ---

-- Saves this character's data and reloads the UI so the app updates now -
-- what the old floating Sync button did. WoW only writes an addon's file
-- on reload or logout, and only allows a reload from a real click or key
-- press, so this can't happen on its own. Turns gold once there's new data
-- the app hasn't seen for 5+ minutes. Last on the bar.
Register({
    id = "sync", label = "Sync", order = 90,
    updateEvents = { "PLAYER_MONEY" },
    text = function()
        return ns.SyncNudge() and (GOLD_CODE .. "Sync now|r") or "Sync"
    end,
    onClick = function() ForgesLedger_Sync() end,
    tooltip = function(tt)
        tt:AddLine(ns.SavedText(), C.bone[1], C.bone[2], C.bone[3])
        tt:AddLine("Click to update the app now (reloads your UI).", C.dim[1], C.dim[2], C.dim[3], true)
        tt:AddLine("Also: the keybind, or /fl sync.", C.dim[1], C.dim[2], C.dim[3], true)
    end,
}, true)

----------------------------------------------- main and settings windows ---

function MainLines()
    local lines = GoldLines(false)
    tinsert(lines, { text = "At a glance", header = true })
    for _, p in ipairs(Sorted()) do
        if p.id ~= "gold" then
            local ok, text = Call(p, p.text)
            if ok and text and text ~= "" then
                tinsert(lines, { text = tostring(text), indent = true, right = p.window and "details" or nil,
                                 rightColor = C.dim,
                                 onClick = p.window and function() ns.OpenWindow(p.id) end or nil })
            end
        end
    end
    tinsert(lines, { text = ns.SavedText(), dim = true })
    tinsert(lines, { text = "Right-click the anvil for options. /fl help for commands.", dim = true })
    return lines
end

function SettingsLines()
    local s = Settings()
    local lines = {
        { text = "Bar", header = true },
        { text = (s.enabled and CHECK or BOX) .. " Show the bar",
          onClick = function() ns.SetBarEnabled(not Settings().enabled) end },
        { text = "Docked at the " .. (s.anchor == "TOP" and "top" or "bottom") .. " of the screen",
          right = "click to switch", rightColor = C.dim,
          onClick = function() ns.SetBarAnchor(Settings().anchor == "TOP" and "BOTTOM" or "TOP") end },
        { text = "Segments " .. (s.align == "LEFT" and "on the left" or "centered"),
          right = "click to switch", rightColor = C.dim,
          onClick = function() ns.SetBarAlign(Settings().align == "LEFT" and "CENTER" or "LEFT") end },
        { text = s.width == "FULL" and "Bar stretched across the screen" or "Bar fits its segments",
          right = "click to switch", rightColor = C.dim,
          onClick = function() ns.SetBarWidth(Settings().width == "FULL" and "FIT" or "FULL") end },
        { text = (s.pulse and CHECK or BOX) .. " Pulse a segment when something is ready",
          onClick = function() Settings().pulse = not Settings().pulse; QueueRefresh() end },
        { text = "Segments", header = true },
    }
    for _, p in ipairs(Sorted()) do
        tinsert(lines, { text = (s.hidden[p.id] and BOX or CHECK) .. " " .. p.label,
                         onClick = function()
                             local h = Settings().hidden
                             h[p.id] = (not h[p.id]) or nil
                             QueueRefresh()
                         end })
    end
    tinsert(lines, { text = "/fl bar shows or hides the bar; /fl help lists the windows.", dim = true })
    tinsert(lines, { text = "With the bar hidden, sync with /fl sync or the keybind.", dim = true })
    return lines
end
