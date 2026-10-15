-- Forge's Ledger: Professions v1.6 (retail)
-- A companion to Forge's Ledger, and useful on its own: shows your skill in
-- every expansion's tier of a profession, right beside the profession
-- window. It also records those numbers for the Forge's Ledger app.
--
-- Step 1 of the satellite plan: record skills + a simple panel. "Best next
-- craft" and the shopping list come next.
--
-- Rules it follows (see the app's satellite spec):
--   * works without the desktop app and without the core addon
--   * no work every frame - it reads on login and when a profession window
--     opens or changes, never on a timer loop
--   * every game call is checked to exist and pcall-guarded, so an API
--     change can't break the game UI
--   * one save file per account, with a "characters" list, so characters
--     never overwrite each other

local ADDON_NAME = "ForgesLedger_Professions"
local VERSION = "1.6"
local SCHEMA = 1
local PREFIX = "|cffFFD700[Forge's Ledger: Professions]|r "

ForgesLedgerProfessionsDB = ForgesLedgerProfessionsDB or {}

-- Release order of the expansion names the game uses for profession tiers
-- (ProfessionInfo.expansionName), oldest first. Profession IDs do NOT follow
-- release order, so this is what decides "newest" - names the list doesn't
-- know (a future expansion) count as newest rather than being guessed at.
local EXPANSION_ORDER = {
    ["Classic"] = 1, ["Outland"] = 2, ["Northrend"] = 3, ["Cataclysm"] = 4,
    ["Pandaria"] = 5, ["Draenor"] = 6, ["Legion"] = 7, ["Kul Tiras"] = 8,
    ["Zandalar"] = 8,
    -- what the game actually reports for Battle for Azeroth tiers, both seen
    -- in game: "Kul Tiran" (Alliance) and "Zandalari" (Horde)
    ["Kul Tiran"] = 8, ["Zandalari"] = 8, ["Shadowlands"] = 9, ["Dragon Isles"] = 10,
    ["Khaz Algar"] = 11, ["Midnight"] = 12,
}
local function ExpansionRank(name)
    return EXPANSION_ORDER[name or ""] or 99
end

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "Unknown"
    realm = realm:gsub("[%s%'%-]", "")  -- same key style as the core addon
    return (name or "Unknown") .. "-" .. realm
end

local function CharData()
    local db = ForgesLedgerProfessionsDB
    db.schemaVersion = SCHEMA
    db.version = "Retail"
    db.characters = db.characters or {}
    local key = CharKey()
    local c = db.characters[key] or { data = {} }
    c.data = c.data or {}
    c.data.tiers = c.data.tiers or {}
    c.data.professions = c.data.professions or {}
    db.characters[key] = c
    return c
end

-- One expansion tier, e.g. "Midnight Blacksmithing": skill out of max.
-- keepUnlearned: record tiers at 0 too. Only used for professions the
-- character has - the login scan covers every profession in the game, and
-- keeping zeros from it would fill the file with professions you don't have.
local function RecordTier(c, info, keepUnlearned)
    if type(info) ~= "table" or not info.professionName or info.professionName == "" then return end
    if not info.parentProfessionName then return end  -- a base profession, not a tier
    local max = info.maxSkillLevel or 0
    if not keepUnlearned and (info.skillLevel or 0) <= 0 and max <= 0 then return end
    c.data.tiers[info.professionName] = {
        profession = info.parentProfessionName,
        expansion = info.expansionName,
        skill = info.skillLevel or 0,
        maxSkill = max,
        id = info.professionID,
    }
end

-- The newest expansion's tier you've put points into becomes each
-- profession's "current" entry.
local function RebuildCurrent(c)
    local best = {}
    for tierName, t in pairs(c.data.tiers) do
        local cur = best[t.profession]
        local rank = ExpansionRank(t.expansion)
        if t.skill > 0 and (not cur or rank > cur.rank) then
            best[t.profession] = { skill = t.skill, maxSkill = t.maxSkill, tier = tierName, rank = rank }
        end
    end
    for prof, b in pairs(best) do
        c.data.professions[prof] = { skill = b.skill, maxSkill = b.maxSkill, tier = b.tier }
    end
end

-- What the last scan saw, for /flp scan to report (not saved).
local lastSeen = { lines = 0, tiers = 0 }

-- Read every tier of every profession the game will tell us about.
local function Scan()
    local T = C_TradeSkillUI
    if not T then return end
    local c = CharData()
    -- 1. every profession tier in the game. Collected first, because which
    -- unlearned tiers to keep depends on which professions you have.
    local all = {}
    if T.GetAllProfessionTradeSkillLines and T.GetProfessionInfoBySkillLineID then
        local ok, lines = pcall(T.GetAllProfessionTradeSkillLines)
        if ok and type(lines) == "table" then
            lastSeen.lines = #lines
            for _, id in ipairs(lines) do
                local ok2, info = pcall(T.GetProfessionInfoBySkillLineID, id)
                if ok2 and type(info) == "table" and info.parentProfessionName then
                    tinsert(all, info)
                end
            end
        end
    end
    lastSeen.tiers = #all
    -- 2. the professions this character has: any tier with points in it,
    -- anything already on record, and the window that's open right now
    local owned = {}
    for _, info in ipairs(all) do
        if (info.skillLevel or 0) > 0 then owned[info.parentProfessionName] = true end
    end
    for _, t in pairs(c.data.tiers) do owned[t.profession] = true end
    if T.GetBaseProfessionInfo then
        local ok, base = pcall(T.GetBaseProfessionInfo)
        if ok and type(base) == "table" and base.professionName then owned[base.professionName] = true end
    end
    -- 3. record: tiers you haven't learned are kept at 0, but only for
    -- professions you have - not for every profession in the game
    for _, info in ipairs(all) do
        RecordTier(c, info, owned[info.parentProfessionName])
    end
    -- with a profession window open, the game also lists that profession's
    -- tiers directly - the most reliable source for skill numbers
    if T.GetChildProfessionInfos then
        local ok, infos = pcall(T.GetChildProfessionInfos)
        if ok and type(infos) == "table" then
            for _, info in ipairs(infos) do RecordTier(c, info, true) end
        end
    end
    RebuildCurrent(c)
    c.data.lastScan = time()
    c.exportedAt = time()
end

---------------------------------------------------------------- the panel ---

local panel, rows = nil, {}
local ROW_H = 30

local function OpenProfession()
    local T = C_TradeSkillUI
    if not (T and T.GetBaseProfessionInfo) then return nil end
    local ok, info = pcall(T.GetBaseProfessionInfo)
    return ok and type(info) == "table" and info.professionName or nil
end

local function CurrentTierName()
    local T = C_TradeSkillUI
    if not (T and T.GetChildProfessionInfo) then return nil end
    local ok, info = pcall(T.GetChildProfessionInfo)
    return ok and type(info) == "table" and info.professionName or nil
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Frame", nil, panel)
    r:SetSize(204, ROW_H)
    r:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -30 - (i - 1) * ROW_H)
    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.label:SetPoint("TOPLEFT", 0, 0)
    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.value:SetPoint("TOPRIGHT", 0, 0)
    r.bar = CreateFrame("StatusBar", nil, r)
    r.bar:SetPoint("TOPLEFT", 0, -14)
    r.bar:SetSize(204, 8)
    r.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    r.bar.bg = r.bar:CreateTexture(nil, "BACKGROUND")
    r.bar.bg:SetAllPoints()
    r.bar.bg:SetColorTexture(0, 0, 0, 0.5)
    rows[i] = r
    return r
end

local function UpdatePanel()
    if not panel then return end
    local prof = OpenProfession()
    if ForgesLedgerProfessionsDB.hidePanel or not prof or not (ProfessionsFrame and ProfessionsFrame:IsShown()) then
        panel:Hide()
        return
    end
    local c = CharData()
    local list = {}
    for tierName, t in pairs(c.data.tiers) do
        if t.profession == prof then
            tinsert(list, { name = t.expansion or tierName, tier = tierName, skill = t.skill,
                            max = t.maxSkill, rank = ExpansionRank(t.expansion) })
        end
    end
    -- newest expansion first (by release order, not profession ID)
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.name < b.name
    end)
    local current = CurrentTierName()
    panel.title:SetText(prof)
    for i, t in ipairs(list) do
        local r = GetRow(i)
        local maxed = t.max > 0 and t.skill >= t.max
        local unlearned = t.skill <= 0
        r.label:SetText((t.tier == current and "> " or "") .. t.name)
        -- not learned yet: 0, with the tier's max when the game reports one
        r.value:SetText(t.max > 0 and (t.skill .. " / " .. t.max) or tostring(t.skill))
        r.bar:SetMinMaxValues(0, math.max(1, t.max))
        r.bar:SetValue(t.skill)
        r.label:SetAlpha(unlearned and 0.5 or 1)
        r.value:SetAlpha(unlearned and 0.5 or 1)
        if maxed then
            r.bar:SetStatusBarColor(0.30, 0.85, 0.45)  -- green: done
        elseif t.tier == current then
            r.bar:SetStatusBarColor(1.00, 0.82, 0.25)  -- gold: the tier you're on
        else
            r.bar:SetStatusBarColor(0.45, 0.58, 1.00)
        end
        r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    panel.empty:SetShown(#list == 0)
    panel:SetHeight(40 + math.max(1, #list) * ROW_H)
    panel:Show()
end

local function CreatePanel()
    if panel or not ProfessionsFrame then return end
    panel = CreateFrame("Frame", "ForgesLedgerProfessionsPanel", ProfessionsFrame, "BackdropTemplate")
    panel:SetSize(224, 80)
    panel:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 4, -24)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0.06, 0.07, 0.10, 0.92)
    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.empty:SetPoint("TOPLEFT", 10, -32)
    panel.empty:SetText("No skill recorded yet for this profession.")
    panel:Hide()
end

---------------------------------------------------------------- events ---

local queued = false
local function QueueScan()
    if queued then return end
    queued = true
    C_Timer.After(1, function()
        queued = false
        Scan()
        CreatePanel()
        UpdatePanel()
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
-- pcall: in case a client doesn't have one of these events
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_SHOW")
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_CLOSE")
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_LIST_UPDATE")
pcall(frame.RegisterEvent, frame, "SKILL_LINES_CHANGED")      -- skill went up
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(5, Scan)  -- give the game a moment to load profession data
    elseif event == "TRADE_SKILL_CLOSE" then
        if panel then panel:Hide() end
    else
        QueueScan()
    end
end)

---------------------------------------------------------------- the bar ---
-- With the core addon v2.5+ installed, this adds the "Professions" segment
-- to its bar: how many profession cooldowns are ready, across every
-- character the core addon has seen. The cooldowns themselves are recorded
-- by the core (they stay there so they work without this addon); this only
-- reads them. With no core, or an older one, this block does nothing.

local function Cooldowns()
    local ready, waiting, now = {}, {}, time()
    local chars = type(ForgeGoldDB) == "table" and ForgeGoldDB.chars  -- the core's save data
    if type(chars) ~= "table" then return ready, waiting end
    for key, ch in pairs(chars) do
        if type(ch) == "table" and type(ch.cooldowns) == "table" then
            for _, cd in pairs(ch.cooldowns) do
                if type(cd) == "table" and type(cd.readyAt) == "number" then
                    tinsert(cd.readyAt <= now and ready or waiting,
                            { who = ch.name or key, class = ch.class, name = cd.name or "?",
                              profession = cd.profession, readyAt = cd.readyAt })
                end
            end
        end
    end
    table.sort(ready, function(a, b) return a.who < b.who end)
    table.sort(waiting, function(a, b) return a.readyAt < b.readyAt end)
    return ready, waiting
end

local function BarWindowLines()
    local ready, waiting = Cooldowns()
    local now = time()
    local lines = { { text = "Cooldowns ready", header = true } }
    for _, e in ipairs(ready) do
        tinsert(lines, { text = e.name, right = e.who, indent = true })
    end
    if #ready == 0 then tinsert(lines, { text = "None ready right now", dim = true, indent = true }) end
    if #waiting > 0 then
        tinsert(lines, { text = "On cooldown", header = true })
        for _, e in ipairs(waiting) do
            tinsert(lines, { text = e.name .. " - " .. e.who, right = SecondsToTime(e.readyAt - now, true),
                             indent = true })
        end
    end
    if #ready + #waiting == 0 then
        tinsert(lines, { text = "A cooldown shows up after you use it once - the game", dim = true })
        tinsert(lines, { text = "only reports one while it's running.", dim = true })
    end
    -- this character's skills, from this addon's own scans
    tinsert(lines, { text = "This character", header = true })
    local profs, names = CharData().data.professions, {}
    for prof in pairs(profs) do tinsert(names, prof) end
    table.sort(names)
    for _, prof in ipairs(names) do
        local p = profs[prof]
        tinsert(lines, { text = prof, right = (p.skill or 0) .. " / " .. (p.maxSkill or 0), indent = true })
    end
    if #names == 0 then
        tinsert(lines, { text = "Open a profession window once to record it.", dim = true, indent = true })
    end
    return lines
end

if type(ForgesLedger) == "table" and type(ForgesLedger.RegisterBarPlugin) == "function" then
    ForgesLedger.RegisterBarPlugin({
        id = "professions", label = "Professions", order = 50,
        updateEvents = { "TRADE_SKILL_LIST_UPDATE", "SKILL_LINES_CHANGED", "TRADE_SKILL_CLOSE" },
        text = function()
            local ready, waiting = Cooldowns()
            if #ready + #waiting == 0 then return "Professions" end
            return "Professions: " .. #ready .. " ready", #ready > 0
        end,
        -- hover card (core v2.6+): who has something ready right now
        roster = function()
            local ready, waiting = Cooldowns()
            local rows, footer = {}, {}
            for i, e in ipairs(ready) do
                if i > 12 then break end
                tinsert(rows, { name = e.who, class = e.class, pulse = true,
                                value = (e.profession and (e.profession .. ": ") or "") .. e.name
                                        .. "  |cffe6bf40ready now|r", valueColor = { 0.92, 0.90, 0.85 } })
            end
            if #ready > 12 then tinsert(footer, "+" .. (#ready - 12) .. " more") end
            return { title = "Cooldowns ready", rows = rows, footer = footer,
                     empty = #waiting > 0 and "All cooldowns used." or "No cooldowns tracked yet." }
        end,
        -- older cores (v2.5) use this game-tooltip version instead
        tooltip = function(tt)
            local ready = Cooldowns()
            for i, e in ipairs(ready) do
                if i > 10 then
                    tt:AddLine("and " .. (#ready - 10) .. " more - click for all", 0.55, 0.55, 0.55)
                    break
                end
                tt:AddDoubleLine(e.name, e.who, 0.92, 0.90, 0.85, 0.90, 0.75, 0.25)
            end
            if #ready == 0 then tt:AddLine("No cooldowns ready", 0.92, 0.90, 0.85) end
        end,
        window = { title = "Professions", lines = BarWindowLines },
    })
end

---------------------------------------------------------------- /flp ---

SLASH_FORGESLEDGERPROF1 = "/flp"
SlashCmdList["FORGESLEDGERPROF"] = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "panel" then
        ForgesLedgerProfessionsDB.hidePanel = not ForgesLedgerProfessionsDB.hidePanel
        print(PREFIX .. "Panel " .. (ForgesLedgerProfessionsDB.hidePanel and "hidden." or "shown."))
        UpdatePanel()
    elseif cmd == "scan" then
        Scan()
        local n = 0
        for _ in pairs(CharData().data.tiers) do n = n + 1 end
        print(PREFIX .. n .. " profession tiers recorded for this character.")
        -- what the game itself reported, so a missing tier can be told apart
        -- from one the addon dropped
        print(PREFIX .. "The game listed " .. lastSeen.lines .. " profession lines, "
              .. lastSeen.tiers .. " of them expansion tiers.")
        UpdatePanel()
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /flp panel - show/hide the panel beside the profession window")
        print("  /flp scan - re-read your profession skills now")
    end
end
