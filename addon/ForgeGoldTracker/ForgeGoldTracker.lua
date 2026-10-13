-- ForgeGoldTracker v1.3
-- Records each character's gold (plus class/level/faction and a daily
-- history) into SavedVariables for Forge's Ledger running on this PC.
--
-- WoW only writes SavedVariables to disk on logout, /reload, or game exit -
-- addons can't write files or use the network while you play, and a reload
-- needs a real key press or click (Blizzard restricts it), so it can't run
-- on a timer. Ways to sync:
--   * automatic: logging out, switching characters, exiting the game
--   * the on-screen Sync button (turns gold after 5 min with new data)
--   * a keybind (Options > Keybindings > AddOns > Forge Gold Tracker)
--   * /fgt sync
-- The dashboard notices the file change within a couple of seconds.
--
-- Nothing is sent anywhere. All data stays on your PC.

local ADDON_NAME = "ForgeGoldTracker"
local VERSION = "1.3"
ForgeGoldDB = ForgeGoldDB or {}

local MAX_HISTORY_DAYS = 120
local NUDGE_AFTER = 5 * 60  -- seconds since last save before the button nudges
local PREFIX = "|cffFFD700[ForgeGold]|r "

-- labels for the Keybindings screen (Bindings.xml refers to these names)
BINDING_HEADER_FORGEGOLD = "Forge Gold Tracker"
BINDING_NAME_FORGEGOLD_SYNC = "Sync to dashboard (reloads UI)"

local dirty = false  -- gold/level changed since the file was last written
local syncButton

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "Unknown"
    -- realms can contain spaces/apostrophes; normalize for a stable key
    realm = realm:gsub("[%s%'%-]", "")
    return (name or "Unknown") .. "-" .. realm
end

local function Snapshot()
    local key = CharKey()
    local money = GetMoney()
    local level = UnitLevel("player") or 0
    local now = time()
    local today = date("%Y-%m-%d", now)

    ForgeGoldDB.chars = ForgeGoldDB.chars or {}
    local c = ForgeGoldDB.chars[key] or {}
    if c.money ~= money or c.level ~= level then
        dirty = true
    end

    c.money   = money
    c.class   = select(2, UnitClass("player")) or "UNKNOWN"
    c.level   = level
    c.faction = UnitFactionGroup("player") or "Neutral"
    c.name    = UnitName("player") or key
    c.lastSeen = now

    -- one history point per day (updates in place if already recorded today)
    c.history = c.history or {}
    local last = c.history[#c.history]
    if last and last.day == today then
        last.money = money
    else
        tinsert(c.history, { day = today, money = money })
        while #c.history > MAX_HISTORY_DAYS do
            tremove(c.history, 1)
        end
    end

    ForgeGoldDB.chars[key] = c
    -- tells the dashboard which character changed, so it can refresh just
    -- that one from Blizzard instead of the whole account
    ForgeGoldDB.lastChar = key
    ForgeGoldDB.lastWrite = now
    ForgeGoldDB.version = VERSION
end

-- Global so the keybinding in Bindings.xml can call it.
function ForgeGoldTracker_Sync()
    if InCombatLockdown() then
        print(PREFIX .. "Can't sync in combat - try again after the fight.")
        return
    end
    Snapshot()
    -- the reload wipes chat, so leave a note and confirm after it
    ForgeGoldDB.syncPending = true
    ReloadUI()
end

local function Ago(seconds)
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. " min ago" end
    if seconds < 172800 then return math.floor(seconds / 3600) .. " h ago" end
    return math.floor(seconds / 86400) .. " days ago"
end

local function SavedText()
    if not ForgeGoldDB.savedAt then return "Not saved yet this session" end
    return "Dashboard last updated " .. Ago(time() - ForgeGoldDB.savedAt)
end

local function UpdateButton()
    if not syncButton then return end
    local since = ForgeGoldDB.savedAt and (time() - ForgeGoldDB.savedAt) or NUDGE_AFTER
    if dirty and since >= NUDGE_AFTER then
        syncButton:SetText("|cffFFD700Sync now|r")
    else
        syncButton:SetText("Sync")
    end
end

local function CreateSyncButton()
    local b = CreateFrame("Button", "ForgeGoldSyncButton", UIParent, "UIPanelButtonTemplate")
    b:SetSize(86, 22)
    local p = ForgeGoldDB.buttonPos
    if p then
        b:SetPoint(p[1], UIParent, p[1], p[2], p[3])
    else
        b:SetPoint("TOP", UIParent, "TOP", 0, -6)
    end
    b:SetMovable(true)
    b:SetClampedToScreen(true)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then self:StartMoving() end
    end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        ForgeGoldDB.buttonPos = { point, x, y }
    end)
    b:SetScript("OnClick", function()
        -- releasing a shift-drag also counts as a click; don't reload on it
        if IsShiftKeyDown() then return end
        ForgeGoldTracker_Sync()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Forge Gold Tracker")
        GameTooltip:AddLine(SavedText(), 1, 1, 1)
        GameTooltip:AddLine("Click to update the dashboard now (reloads your UI).", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Shift-drag to move. /fgt button to hide.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    if ForgeGoldDB.hideButton then b:Hide() end
    syncButton = b
    UpdateButton()
    C_Timer.NewTicker(15, UpdateButton)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            ForgeGoldDB.chars = ForgeGoldDB.chars or {}
        end
    elseif event == "PLAYER_LOGIN" then
        CreateSyncButton()
        -- slight delay so everything is initialized
        C_Timer.After(2, function() Snapshot(); UpdateButton() end)
        if ForgeGoldDB.syncPending then
            ForgeGoldDB.syncPending = nil
            C_Timer.After(3, function()
                print(PREFIX .. "Synced - the dashboard is updating now.")
            end)
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitLevel can still report the old level during this event
        C_Timer.After(1, function() Snapshot(); UpdateButton() end)
    elseif event == "PLAYER_MONEY" then
        Snapshot()
        UpdateButton()
    elseif event == "PLAYER_LOGOUT" then
        -- fires on logout AND reload, just before WoW writes the file.
        -- Only stamp the time: don't Snapshot here, because character data
        -- may already be torn down (GetMoney() can read 0), and every gold
        -- change was already recorded by PLAYER_MONEY anyway.
        ForgeGoldDB.savedAt = time()
    end
end)

local function WarbandTotal()
    local total, n = 0, 0
    for _, c in pairs(ForgeGoldDB.chars or {}) do
        total = total + (c.money or 0)
        n = n + 1
    end
    return total, n
end

-- /fgt        : warband gold total across all recorded characters
-- /fgt sync   : save now and reload so the dashboard updates immediately
-- /fgt button : show/hide the on-screen Sync button
-- /fgt help   : list commands
SLASH_FORGEGOLD1 = "/fgt"
SlashCmdList["FORGEGOLD"] = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "sync" then
        ForgeGoldTracker_Sync()
    elseif cmd == "button" then
        ForgeGoldDB.hideButton = not ForgeGoldDB.hideButton
        if syncButton then syncButton:SetShown(not ForgeGoldDB.hideButton) end
        print(PREFIX .. "Sync button " .. (ForgeGoldDB.hideButton and "hidden." or "shown."))
    elseif cmd == "help" then
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /fgt - warband gold total")
        print("  /fgt sync - update the dashboard now (reloads UI)")
        print("  /fgt button - show/hide the Sync button (shift-drag to move it)")
        print("  " .. SavedText())
    else
        local total, n = WarbandTotal()
        print(string.format("%s%d character(s) recorded. Warband total: %s",
            PREFIX, n, GetMoneyString(total)))
    end
end
