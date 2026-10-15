-- Forge's Ledger addon v2.8 (formerly Forge Gold Tracker)
-- One addon for both retail (Midnight) and WoW Forever: every modern-only
-- feature (warband bank, profession cooldowns) checks the game supports it
-- first and quietly switches off where it doesn't.
-- Records each character's gold (plus class/level/faction and a daily
-- history), and the account's warband bank gold, into SavedVariables for Forge's Ledger running on this PC.
--
-- WoW only writes SavedVariables to disk on logout, /reload, or game exit -
-- addons can't write files or use the network while you play, and a reload
-- needs a real key press or click (Blizzard restricts it), so it can't run
-- on a timer. Ways to sync:
--   * automatic: logging out, switching characters, exiting the game
--   * the Sync segment on the bar (turns gold after 5 min with new data)
--   * a keybind (Options > Keybindings > AddOns > Forge's Ledger)
--   * /fl sync
-- The dashboard notices the file change within a couple of seconds.
--
-- Nothing is sent anywhere. All data stays on your PC.
--
-- v2.5 adds the in-game bar (ForgesLedger_Bar.lua) and its windows
-- (ForgesLedger_Windows.lua). The three files share data through `ns`, the
-- private table WoW hands every file of one addon.

local ADDON_NAME, ns = ...
local VERSION = "2.8"
-- The saved-data table keeps its original name on purpose: renaming it
-- would orphan everyone's recorded gold history. (The app copies the old
-- ForgeGoldTracker save file to this addon's new file name on install.)
ForgeGoldDB = ForgeGoldDB or {}

local MAX_HISTORY_DAYS = 120
local NUDGE_AFTER = 5 * 60  -- seconds since last save before the button nudges
local PREFIX = "|cffFFD700[Forge's Ledger]|r "

-- The public object satellites talk to (ForgesLedger.RegisterBarPlugin is
-- added by ForgesLedger_Bar.lua). Satellites check it exists first, so they
-- keep working with an older core that doesn't have it.
ForgesLedger = ForgesLedger or {}
ForgesLedger.version = VERSION
ns.PREFIX, ns.VERSION = PREFIX, VERSION

-- New data was recorded: let the bar redraw (once it's loaded).
local function Changed()
    if ns.DataChanged then ns.DataChanged() end
end

-- labels for the Keybindings screen (Bindings.xml refers to these names)
BINDING_HEADER_FORGESLEDGER = "Forge's Ledger"
BINDING_NAME_FORGESLEDGER_SYNC = "Sync to the app (reloads UI)"

local dirty = false  -- gold/level changed since the file was last written

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "Unknown"
    -- realms can contain spaces/apostrophes; normalize for a stable key
    realm = realm:gsub("[%s%'%-]", "")
    return (name or "Unknown") .. "-" .. realm
end
ns.CharKey = CharKey

-- one history point per day (updates in place if already recorded today)
local function RecordDay(history, money, today)
    local last = history[#history]
    if last and last.day == today then
        last.money = money
    else
        tinsert(history, { day = today, money = money })
        while #history > MAX_HISTORY_DAYS do
            tremove(history, 1)
        end
    end
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
    -- rested XP pool and the XP needed for this level, for the app's
    -- "what do I level tonight" view (0 = not rested)
    c.restedXP = GetXPExhaustion() or 0
    c.xpMax    = UnitXPMax("player") or 0

    c.history = c.history or {}
    RecordDay(c.history, money, today)

    ForgeGoldDB.chars[key] = c
    -- tells the dashboard which character changed, so it can refresh just
    -- that one from Blizzard instead of the whole account
    ForgeGoldDB.lastChar = key
    ForgeGoldDB.lastWrite = now
    ForgeGoldDB.version = VERSION
    Changed()
end

-- Warband bank gold is shared by the whole account, so it's stored once in
-- ForgeGoldDB.warband rather than per character.
--
-- The game may not have the warband bank's balance loaded right after login
-- and can report 0 until it does. So a 0 is only trusted once a bank has
-- been opened this session; otherwise we keep the last known balance rather
-- than overwrite real gold with a 0 (the same failure as the old logout bug).
local bankOpened = false

local function WarbandMoney()
    if not (C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType
            and Enum.BankType.Account) then
        return nil  -- client without a warband bank
    end
    local ok, amount = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    if not ok or type(amount) ~= "number" then return nil end
    -- Midnight's "secret values" can't be compared or stored by addons
    if issecretvalue and issecretvalue(amount) then return nil end
    return amount
end

local function SnapshotWarband()
    local amount = WarbandMoney()
    if amount == nil or (amount == 0 and not bankOpened) then return end
    local now = time()
    local w = ForgeGoldDB.warband or {}
    if w.money ~= amount then dirty = true end
    w.money = amount
    w.updated = now
    w.history = w.history or {}
    RecordDay(w.history, amount, date("%Y-%m-%d", now))
    ForgeGoldDB.warband = w
    Changed()
end

-- Profession cooldowns (e.g. daily transmutes). The game only reports
-- cooldowns for the profession whose window is open, so we read them when
-- you open a profession window or craft. A recipe whose cooldown is ready
-- reports no cooldown at all, so we can only learn a recipe HAS one after
-- you've used it once; from then on it's tracked (readyAt in the past =
-- ready to use again). Everything is pcall-guarded so a changed API can't
-- break the rest of the addon.
local cooldownScanQueued = false

-- Is a profession window showing right now? The cooldown API answers for
-- whichever profession was opened last, so only trust it while one is open.
local function ProfessionWindowOpen()
    return ProfessionsFrame and ProfessionsFrame.IsShown and ProfessionsFrame:IsShown()
end

-- verbose = print what was found (the /fl cooldowns command), so problems
-- can be diagnosed from chat instead of guessed at.
local function ScanCooldowns(verbose)
    cooldownScanQueued = false
    local say = verbose and function(msg) print(PREFIX .. msg) end or function() end
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeCooldown and T.GetRecipeInfo
            and T.GetBaseProfessionInfo) then
        say("This game version doesn't offer the profession cooldown functions.")
        return
    end
    local okP, prof = pcall(T.GetBaseProfessionInfo)
    local profName = okP and type(prof) == "table" and prof.professionName
    if not profName or profName == "" then
        say("Open a profession window first.")
        return
    end
    local ok, ids = pcall(T.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then
        say("Couldn't read the " .. profName .. " recipe list.")
        return
    end
    local c = ForgeGoldDB.chars and ForgeGoldDB.chars[CharKey()]
    if not c then return end
    c.cooldowns = c.cooldowns or {}
    local now, learned, found = time(), 0, 0
    for _, id in ipairs(ids) do
        local okI, info = pcall(T.GetRecipeInfo, id)
        if okI and type(info) == "table" and info.learned then
            learned = learned + 1
            local okC, cd, isDay, charges, maxCharges = pcall(T.GetRecipeCooldown, id)
            -- a running cooldown, or a charge-based recipe with a charge spent
            local spent = type(maxCharges) == "number" and maxCharges > 0
                          and type(charges) == "number" and charges < maxCharges
            if okC and type(cd) == "number" and cd > 0 then
                c.cooldowns[tostring(id)] = {
                    name = info.name, profession = profName,
                    readyAt = now + math.floor(cd),
                }
                dirty = true
                found = found + 1
                say(string.format("  %s: on cooldown, ready in %s%s", info.name or id,
                    SecondsToTime and SecondsToTime(cd) or (math.floor(cd / 60) .. " min"),
                    spent and string.format(" (%d/%d charges)", charges, maxCharges) or ""))
            elseif verbose and spent then
                say(string.format("  %s: %d/%d charges, no timer reported", info.name or id,
                    charges, maxCharges))
            end
        end
    end
    say(string.format("%s: %d recipes known, %d on cooldown%s.", profName, learned, found,
        found > 0 and " - saved; /fl sync to update the app" or ""))
    Changed()
end

-- the list-update event fires in bursts; scan once, a moment after it settles
local function QueueCooldownScan()
    if cooldownScanQueued then return end
    cooldownScanQueued = true
    C_Timer.After(1, ScanCooldowns)
end

-- Todo facts: what the game itself knows about this week's progress, for
-- the app's Todo tab - Great Vault slots, raid and world boss lockouts,
-- Mythic+ runs. Each part checks the game has the function first (Forever
-- only has raid lockouts) and is pcall-guarded; anything missing is simply
-- left out, and the app shows a manual checkbox for it instead. Stored with
-- the time it was read, so the app never trusts last week's numbers.
local todoQueued = false

local function SnapshotTodo()
    todoQueued = false
    local c = ForgeGoldDB.chars and ForgeGoldDB.chars[CharKey()]
    if not c then return end
    local now = time()
    local t = { at = now }
    local W = C_WeeklyRewards
    if W and W.GetActivities then
        local ok, acts = pcall(W.GetActivities)
        if ok and type(acts) == "table" and #acts > 0 then
            -- row names come from the game's own enum, e.g. Raid / Activities / World
            local names = {}
            if Enum and Enum.WeeklyRewardChestThresholdType then
                for k, v in pairs(Enum.WeeklyRewardChestThresholdType) do names[v] = k end
            end
            local rows = {}
            for _, a in ipairs(acts) do
                local n = names[a.type] or tostring(a.type)
                local r = rows[n] or { unlocked = 0, total = 0, progress = 0, max = 0 }
                local prog, need = a.progress or 0, a.threshold or 1
                r.total = r.total + 1
                if prog >= need then r.unlocked = r.unlocked + 1 end
                -- progress toward the row's last slot and what that slot
                -- needs, both from the game (e.g. 3 Mythic+ runs of 8) -
                -- the bar's "Vault: M+ 3/8"
                if prog > r.progress then r.progress = prog end
                if need > r.max then r.max = need end
                rows[n] = r
            end
            t.vault = rows
        end
        if W.HasAvailableRewards then
            local ok2, has = pcall(W.HasAvailableRewards)
            if ok2 then t.vaultClaim = has and true or false end
        end
    end
    if GetNumSavedInstances and GetSavedInstanceInfo then
        local raids = {}
        local okN, n = pcall(GetNumSavedInstances)
        for i = 1, (okN and n or 0) do
            local ok, name, _, reset, _, locked, _, _, isRaid, _, diffName, numEnc, encProg = pcall(GetSavedInstanceInfo, i)
            if ok and name and locked and isRaid then
                tinsert(raids, { name = name, difficulty = diffName, killed = encProg or 0,
                                 total = numEnc or 0, resetAt = now + (reset or 0) })
            end
        end
        t.raids = raids
    end
    if GetNumSavedWorldBosses and GetSavedWorldBossInfo then
        local bosses = {}
        local okN, n = pcall(GetNumSavedWorldBosses)
        for i = 1, (okN and n or 0) do
            local ok, name, _, reset = pcall(GetSavedWorldBossInfo, i)
            if ok and name then tinsert(bosses, { name = name, resetAt = now + (reset or 0) }) end
        end
        t.worldBosses = bosses
    end
    if C_MythicPlus and C_MythicPlus.GetRunHistory then
        local ok, runs = pcall(C_MythicPlus.GetRunHistory, false, true)
        if ok and type(runs) == "table" then
            local count, best = 0, 0
            for _, r in ipairs(runs) do
                if r.thisWeek then
                    count = count + 1
                    if r.completed and (r.level or 0) > best then best = r.level end
                end
            end
            t.mplus = { runs = count, best = best }
        end
    end
    c.todo = t
    Changed()
end

-- several of these events can fire together; read once, a moment later
local function QueueTodoSnapshot()
    if todoQueued then return end
    todoQueued = true
    C_Timer.After(2, SnapshotTodo)
end

-- Is a Timewalking event on today? Read from the in-game calendar (account-
-- wide, so stored once). Matches the event's English title.
local function ScanEvents()
    local C = C_Calendar
    if not (C and C.GetNumDayEvents and C.GetDayEvent) then return end
    local day = tonumber(date("%d"))
    if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
        local ok, ct = pcall(C_DateAndTime.GetCurrentCalendarTime)
        if ok and type(ct) == "table" and ct.monthDay then day = ct.monthDay end
    end
    local okN, n = pcall(C.GetNumDayEvents, 0, day)
    local tw = nil
    for i = 1, (okN and n or 0) do
        local ok, ev = pcall(C.GetDayEvent, 0, day, i)
        if ok and type(ev) == "table" and type(ev.title) == "string"
                and ev.title:lower():find("timewalking") then
            tw = ev.title
        end
    end
    ForgeGoldDB.events = { checkedAt = time(), timewalking = tw }
end

-- Global so the keybinding in Bindings.xml can call it.
function ForgesLedger_Sync()
    if InCombatLockdown() then
        print(PREFIX .. "Can't sync in combat - try again after the fight.")
        return
    end
    Snapshot()
    SnapshotWarband()
    if ProfessionWindowOpen() then ScanCooldowns() end
    SnapshotTodo()
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
ns.SavedText = SavedText

-- Should the bar's Sync segment nudge? Yes once there's new data and the
-- app's copy is at least NUDGE_AFTER old. (The Sync button used to float on
-- its own; since v2.7 it lives on the bar.)
function ns.SyncNudge()
    local since = ForgeGoldDB.savedAt and (time() - ForgeGoldDB.savedAt) or NUDGE_AFTER
    return dirty and since >= NUDGE_AFTER
end

local function UpdateButton() Changed() end  -- the bar redraws the Sync segment

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("BANKFRAME_OPENED")
-- pcall: in case a client doesn't have one of these events
pcall(frame.RegisterEvent, frame, "ACCOUNT_MONEY")          -- warband bank changed
pcall(frame.RegisterEvent, frame, "UPDATE_EXHAUSTION")      -- rested XP changed
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_SHOW")       -- profession opened
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_LIST_UPDATE")
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT") -- a craft finished
pcall(frame.RegisterEvent, frame, "UNIT_SPELLCAST_SUCCEEDED")        -- includes crafting
pcall(frame.RegisterEvent, frame, "UPDATE_INSTANCE_INFO")            -- lockouts refreshed
pcall(frame.RegisterEvent, frame, "WEEKLY_REWARDS_UPDATE")           -- Great Vault changed
pcall(frame.RegisterEvent, frame, "CHALLENGE_MODE_COMPLETED")        -- Mythic+ run finished
pcall(frame.RegisterEvent, frame, "BOSS_KILL")                       -- raid/world boss down
pcall(frame.RegisterEvent, frame, "CALENDAR_UPDATE_EVENT_LIST")      -- calendar loaded
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            ForgeGoldDB.chars = ForgeGoldDB.chars or {}
        end
    elseif event == "PLAYER_LOGIN" then
        -- ask the game to load this week's lockouts, runs and calendar;
        -- the matching events above re-read them once they arrive
        C_Timer.After(3, function()
            if RequestRaidInfo then pcall(RequestRaidInfo) end
            if C_MythicPlus and C_MythicPlus.RequestMapInfo then pcall(C_MythicPlus.RequestMapInfo) end
            if C_Calendar and C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end
            QueueTodoSnapshot()
        end)
        -- slight delay so everything is initialized
        C_Timer.After(2, function() Snapshot(); SnapshotWarband(); UpdateButton() end)
        if ForgeGoldDB.syncPending then
            ForgeGoldDB.syncPending = nil
            C_Timer.After(3, function()
                print(PREFIX .. "Synced - the app is updating now.")
            end)
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- UnitLevel can still report the old level during this event
        C_Timer.After(1, function() Snapshot(); UpdateButton() end)
    elseif event == "PLAYER_MONEY" then
        Snapshot()
        UpdateButton()
    elseif event == "UPDATE_EXHAUSTION" then
        Snapshot()
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE"
            or event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        QueueCooldownScan()
    elseif event == "UPDATE_INSTANCE_INFO" or event == "WEEKLY_REWARDS_UPDATE"
            or event == "CHALLENGE_MODE_COMPLETED" or event == "BOSS_KILL" then
        QueueTodoSnapshot()
    elseif event == "CALENDAR_UPDATE_EVENT_LIST" then
        ScanEvents()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- a crafted recipe's cooldown starts when its cast finishes
        if arg1 == "player" and ProfessionWindowOpen() then QueueCooldownScan() end
    elseif event == "ACCOUNT_MONEY" then
        SnapshotWarband()
        UpdateButton()
    elseif event == "BANKFRAME_OPENED" then
        -- the bank's data is definitely loaded now, so even a 0 is real
        bankOpened = true
        C_Timer.After(0.5, function() SnapshotWarband(); UpdateButton() end)
    elseif event == "PLAYER_LOGOUT" then
        -- fires on logout AND reload, just before WoW writes the file.
        -- Only stamp the time: don't Snapshot here, because character data
        -- may already be torn down (GetMoney() can read 0), and every gold
        -- change was already recorded by PLAYER_MONEY anyway.
        ForgeGoldDB.savedAt = time()
    end
end)

local function CharactersTotal()
    local total, n = 0, 0
    for _, c in pairs(ForgeGoldDB.chars or {}) do
        total = total + (c.money or 0)
        n = n + 1
    end
    return total, n
end

-- /fl        : gold total across recorded characters + warband bank
-- /fl sync   : save now and reload so the app updates immediately
-- /fl cooldowns : list the open profession's cooldowns (diagnostics)
-- /fl bar    : show/hide the bar (/fl bar top | bar bottom moves it,
--              /fl bar center | bar left aligns the segments)
-- /fl ledger | gold | todo | vault | prof | settings : open a window -
--              they all work with the bar hidden
-- /fl help   : list commands
-- /forgesledger works too, in case another addon also claims /fl
-- command -> window id
local WINDOW_COMMANDS = {
    ledger = "ledger", window = "ledger", gold = "gold", todo = "todo", vault = "vault",
    prof = "professions", profs = "professions", professions = "professions",
    settings = "settings", options = "settings",
}

SLASH_FORGESLEDGER1 = "/fl"
SLASH_FORGESLEDGER2 = "/forgesledger"
SlashCmdList["FORGESLEDGER"] = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "sync" then
        ForgesLedger_Sync()
    elseif cmd == "cooldowns" or cmd == "cd" then
        ScanCooldowns(true)
    elseif cmd == "button" then
        -- the old floating button's command; point people at its new home
        print(PREFIX .. "The Sync button is on the bar now. Hide it in /fl settings; /fl sync still works.")
    elseif cmd == "bar" then
        local on = not ns.BarSettings().enabled
        ns.SetBarEnabled(on)
        print(PREFIX .. "Bar " .. (on and "shown." or "hidden. Type /fl bar to show it again."))
    elseif cmd == "bar center" or cmd == "bar left" then
        ns.SetBarAlign(cmd == "bar left" and "LEFT" or "CENTER")
        print(PREFIX .. "Bar segments " .. (cmd == "bar left" and "on the left." or "centered."))
    elseif cmd == "bar top" or cmd == "bar bottom" then
        ns.SetBarAnchor(cmd == "bar top" and "TOP" or "BOTTOM")
        print(PREFIX .. "Bar moved to the " .. (cmd == "bar top" and "top." or "bottom."))
    elseif WINDOW_COMMANDS[cmd] then
        -- toggles like a bar click; nil means there's no such window here
        if ns.OpenWindow(WINDOW_COMMANDS[cmd], true) == nil then
            print(PREFIX .. "That window isn't available here (its addon isn't installed, or this game version doesn't have it).")
        end
    elseif cmd == "help" then
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /fl - gold total (characters + warband bank)")
        print("  /fl sync - update the app now (reloads UI)")
        print("  /fl cooldowns - with a profession window open, list its cooldowns")
        print("  /fl bar - show/hide the bar (/fl bar top or /fl bar bottom to move it)")
        print("  /fl bar center or /fl bar left - center the segments or keep them on the left")
        print("  /fl ledger, /fl gold, /fl todo, /fl vault, /fl prof - open a window")
        print("  /fl settings - bar settings")
        print("  " .. SavedText())
    else
        local total, n = CharactersTotal()
        local bank = ForgeGoldDB.warband and ForgeGoldDB.warband.money
        print(string.format("%s%d character(s): %s", PREFIX, n, GetMoneyString(total)))
        if bank then
            print(string.format("%sWarband bank: %s  |  Total: %s", PREFIX,
                GetMoneyString(bank), GetMoneyString(total + bank)))
        else
            print(PREFIX .. "Warband bank: not recorded yet - open a bank once.")
        end
    end
end
