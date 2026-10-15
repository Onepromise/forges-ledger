-- Forge's Ledger: the bar (part of the core addon, v2.5)
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
--           return "Professions: 1 ready", true  -- true = show the gold dot
--       end,
--       tooltip = function(tooltip) end,        -- optional: add GameTooltip lines
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

local BAR_H, PAD, ICON, DOT = 24, 14, 18, 12
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
    if s.anchor ~= "TOP" then s.anchor = "BOTTOM" end
    if type(s.hidden) ~= "table" then s.hidden = {} end  -- segment id -> true
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
    local ok, a, b = pcall(fn, ...)
    if not ok then
        Fail(p, a)
        return false
    end
    return true, a, b
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
        window = type(def.window) == "table" and def.window or nil,
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
    local side = Settings().anchor
    bar:ClearAllPoints()
    bar:SetPoint(side .. "LEFT", UIParent, side .. "LEFT", 0, 0)
    bar:SetPoint(side .. "RIGHT", UIParent, side .. "RIGHT", 0, 0)
    -- the gold edge faces the game world: top edge when docked at the bottom
    local edge = side == "TOP" and "BOTTOM" or "TOP"
    bar.edge:ClearAllPoints()
    bar.edge:SetPoint(edge .. "LEFT")
    bar.edge:SetPoint(edge .. "RIGHT")
end

function ns.SetBarAnchor(side)
    Settings().anchor = side == "TOP" and "TOP" or "BOTTOM"
    ApplyPosition()
end

function ns.SetBarEnabled(on)
    Settings().enabled = on and true or false
    if bar then bar:SetShown(on) end
    if menu then menu:Hide() end
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
    s.dot = s:CreateTexture(nil, "ARTWORK")  -- "something's ready" marker
    s.dot:SetSize(6, 6)
    s.dot:SetPoint("LEFT", PAD, 0)
    s.dot:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    s.label = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s.label:SetTextColor(C.bone[1], C.bone[2], C.bone[3])
    local hl = s:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.08)
    s:SetScript("OnClick", function(self)
        if self.plugin then ns.OpenWindow(self.plugin.id, true) end
    end)
    s:SetScript("OnEnter", function(self)
        local p = self.plugin
        if not p then return end
        GameTooltip:SetOwner(self, TooltipAnchor())
        GameTooltip:AddLine(p.label, C.gold[1], C.gold[2], C.gold[3])
        if p.tooltip then Call(p, p.tooltip, GameTooltip) end
        if p.window then GameTooltip:AddLine("Click for details", C.dim[1], C.dim[2], C.dim[3]) end
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", GameTooltip_Hide)
    segs[i] = s
    return s
end

-- Redraw the segments left to right, skipping hidden ones and plugins with
-- nothing to show, so the rest close up the gap.
function Refresh()
    if bar and bar:IsShown() then
        local hidden = Settings().hidden
        local x = 6 + anvil:GetWidth() + 4
        local n = 0
        for _, p in ipairs(Sorted()) do
            if not hidden[p.id] then
                local ok, text, attention = Call(p, p.text)
                if ok and text ~= nil and text ~= "" then
                    n = n + 1
                    local s = Seg(n)
                    s.plugin = p
                    local inset = PAD + (attention and DOT or 0)
                    s.dot:SetShown(attention and true or false)
                    s.label:ClearAllPoints()
                    s.label:SetPoint("LEFT", inset, 0)
                    s.label:SetText(tostring(text))
                    local w = math.ceil(s.label:GetStringWidth()) + inset + PAD
                    s:SetWidth(w)
                    s:ClearAllPoints()
                    s:SetPoint("LEFT", bar, "LEFT", x, 0)
                    s:Show()
                    x = x + w
                end
            end
        end
        for i = n + 1, #segs do
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
    anvil:SetSize(BAR_H + 6, BAR_H)
    anvil:SetPoint("LEFT", bar, "LEFT", 6, 0)
    local ring = CreateFrame("Frame", nil, anvil)  -- thin gold frame round the icon
    ring:SetSize(ICON + 2, ICON + 2)
    ring:SetPoint("CENTER")
    ns.Trim(ring, 0.9)
    local icon = anvil:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("CENTER")
    -- a built-in blacksmithing icon until the custom anvil art exists
    icon:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
            tinsert(list, { name = c.name or key, class = c.class, money = money, history = c.history })
        end
    end
    table.sort(list, function(a, b) return a.money > b.money end)
    local bank = type(ForgeGoldDB.warband) == "table" and tonumber(ForgeGoldDB.warband.money) or nil
    return list, chars, bank, chars + (bank or 0)
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
    local lines = { { text = "Characters", header = true } }
    for _, e in ipairs(list) do
        local right = Money(e.money)
        local d = withChange and WeekChange(e)
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
        tinsert(lines, { text = "Green/red: change over the last 7 days.", dim = true })
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
    tooltip = function(tt)
        local list, _, bank, total = GoldData()
        for i, e in ipairs(list) do
            if i > 15 then
                tt:AddLine("and " .. (#list - 15) .. " more - click for all", C.dim[1], C.dim[2], C.dim[3])
                break
            end
            local cc = ClassColor(e.class) or C.bone
            tt:AddDoubleLine(e.name, Money(e.money), cc[1], cc[2], cc[3], C.gold[1], C.gold[2], C.gold[3])
        end
        if bank then
            tt:AddDoubleLine("Warband bank", Money(bank), C.bone[1], C.bone[2], C.bone[3], C.gold[1], C.gold[2], C.gold[3])
        end
        tt:AddDoubleLine("Total", Money(total), C.gold[1], C.gold[2], C.gold[3], C.gold[1], C.gold[2], C.gold[3])
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

local function Facts()
    local c = ForgeGoldDB.chars and ForgeGoldDB.chars[ns.CharKey()]
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
-- data, for the character you're on. Items the game can't report (weekly
-- quests, knowledge treasures) are ticked in the app, so they aren't here.
local function TodoItems()
    local items = {}
    local f, c = Facts()
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
    tooltip = function(tt)
        for _, it in ipairs((TodoItems())) do
            local col = it.done and C.dim or C.bone
            tt:AddDoubleLine((it.done and CHECK or BOX) .. " " .. it.label, it.detail,
                col[1], col[2], col[3], C.gold[1], C.gold[2], C.gold[3])
        end
    end,
    window = { title = "Todo", lines = function()
        local items, fresh = TodoItems()
        local lines = { { text = "This character", header = true } }
        for _, it in ipairs(items) do
            tinsert(lines, { text = (it.done and CHECK or BOX) .. " " .. it.label, right = it.detail,
                             color = it.done and C.dim or nil })
        end
        if not fresh then
            tinsert(lines, { text = "This week's progress updates a few seconds after login.", dim = true })
        end
        tinsert(lines, { text = "Only what the game reports is listed here.", dim = true })
        tinsert(lines, { text = "Tick weekly quests and the rest in the app's Todo tab.", dim = true })
        return lines
    end },
}, true)

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
        tooltip = function(tt)
            local f = Facts()
            if not (f and type(f.vault) == "table") then return end
            for name, r in pairs(f.vault) do
                if type(r) == "table" and name ~= VAULT_ALT then
                    tt:AddDoubleLine(VAULT_NAMES[name] or name, (r.unlocked or 0) .. "/" .. (r.total or 0) .. " slots",
                        C.bone[1], C.bone[2], C.bone[3], C.gold[1], C.gold[2], C.gold[3])
                end
            end
            if f.vaultClaim then tt:AddLine("Rewards waiting to be claimed", C.gold[1], C.gold[2], C.gold[3]) end
        end,
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
    return lines
end
