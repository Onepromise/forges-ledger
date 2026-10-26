-- Forge's Ledger: Dungeons v1.1 (retail)
-- A companion to Forge's Ledger, and useful on its own: your Mythic+
-- keystone, rating, season bests and this week's runs, and which raid
-- bosses you've killed this week on each difficulty - in a panel, and (with
-- the core addon v2.10+) on the bar's Great Vault segment, whose hover card
-- then also answers "who has which key?" across your characters.
--
-- Rules it follows (see the app's satellite spec and DUNGEONS_SPEC):
--   * nothing hard-coded: dungeons, key levels, ratings, raids and boss
--     names all come from the game
--   * every game call is checked to exist and pcall-guarded, so an API
--     change can't break the game UI
--   * a character's data only ever comes from that character's own
--     sessions; anything shown for other characters is as of their last login
--   * the Great Vault's slot count stays in the core addon - this only adds
--     the keystone and detail on top
--   * one save file per account, with a "characters" list, so characters
--     never overwrite each other
--   * no work every frame: it reads on login and when the game reports a
--     change (a run finished, a boss died, your bags changed)

local VERSION = "1.1"
local SCHEMA = 1
local PREFIX = "|cffFFD700[Forge's Ledger: Dungeons]|r "

-- Retail only: WoW Forever has no Mythic+ or modern raid lockout data.
if not (C_ChallengeMode and C_MythicPlus)
        or (WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE) then
    return
end

ForgesLedgerDungeonsDB = ForgesLedgerDungeonsDB or {}

------------------------------------------------------------- game calls ---

-- Call a game function safely: nil if it's missing or errors.
local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { n = 0 }
    local function keep(ok, ...)
        r.ok, r.n = ok, select("#", ...)
        for i = 1, r.n do r[i] = (select(i, ...)) end
    end
    keep(pcall(fn, ...))
    if not r.ok then return nil end
    return unpack(r, 1, r.n)
end

-- Midnight's "secret values" can't be stored or compared by addons.
local function Plain(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "Unknown"
    realm = realm:gsub("[%s%'%-]", "")  -- same key style as the core addon
    return (name or "Unknown") .. "-" .. realm
end

local function CharData()
    local db = ForgesLedgerDungeonsDB
    db.schemaVersion = SCHEMA
    db.version = "Retail"
    db.characters = db.characters or {}
    local key = CharKey()
    local c = db.characters[key] or { data = {} }
    c.data = c.data or {}
    db.characters[key] = c
    return c
end

-- When this week began (the weekly reset), from the game.
local sessionStart = time()
local function WeekStart()
    local CD = C_DateAndTime
    local s = CD and Plain(Try(CD.GetSecondsUntilWeeklyReset))
    if type(s) == "number" then return time() + s - 7 * 86400 end
    return sessionStart  -- can't tell: trust only this session's reads
end

local function MapName(id)
    local name, _, _, icon = Try(C_ChallengeMode.GetMapUIInfo, id)
    return Plain(name), Plain(icon)
end

----------------------------------------------------------------- reading ---

local function ReadMythicPlus(d)
    local CM, MP = C_ChallengeMode, C_MythicPlus
    local now = time()
    -- the keystone in your bags
    local mapID = Plain(Try(MP.GetOwnedKeystoneChallengeMapID))
    local level = Plain(Try(MP.GetOwnedKeystoneLevel))
    if type(mapID) == "number" and type(level) == "number" and level > 0 then
        d.keystone = { dungeonID = mapID, level = level, name = (MapName(mapID)) }
    else
        d.keystone = nil
    end
    d.keystoneAt = now
    -- overall Mythic+ rating
    local score = Plain(Try(CM.GetOverallDungeonScore))
    if type(score) == "number" then d.mythicPlusRating = score end
    -- this season's dungeons and your best key in each
    local maps = Try(CM.GetMapTable)
    if type(maps) == "table" and #maps > 0 then
        local dungeons, bests = {}, {}
        for _, id in ipairs(maps) do
            local name, icon = MapName(id)
            tinsert(dungeons, { id = id, name = name, icon = icon })
            local intime, overtime = Try(MP.GetSeasonBestForMap, id)
            local best, timed = 0, false
            if type(intime) == "table" and (tonumber(Plain(intime.level)) or 0) > 0 then
                best, timed = intime.level, true
            end
            if type(overtime) == "table" and (tonumber(Plain(overtime.level)) or 0) > best then
                best, timed = overtime.level, false
            end
            if best > 0 then bests[id] = { level = best, timed = timed } end
        end
        d.seasonDungeons = dungeons
        d.seasonBests = bests
        d.season = Plain(Try(MP.GetCurrentSeason))
    end
    -- key levels run this week (the vault's rewards depend on them)
    local runs = Try(MP.GetRunHistory, false, true)
    if type(runs) == "table" then
        local week = {}
        for _, r in ipairs(runs) do
            local lvl = type(r) == "table" and tonumber(Plain(r.level))
            if lvl and r.thisWeek then tinsert(week, lvl) end
        end
        table.sort(week, function(a, b) return a > b end)
        d.weeklyRuns = week
    end
    d.mythicPlusAt = now
end

-- The Adventure Guide's data isn't there until its window has been loaded
-- once (seen in game: "current raids in the guide: 0"). If it's missing,
-- load it - once per session, never in combat - with the game's own loader
-- (the same one the guide's button uses). It opens nothing on screen.
local guideTried = false
local function EnsureGuide()
    local tiers = Plain(Try(EJ_GetNumTiers))
    if type(tiers) == "number" and tiers > 0 then return true end
    if guideTried or InCombatLockdown() then return false end
    guideTried = true
    if type(EncounterJournal_LoadUI) == "function" then
        Try(EncounterJournal_LoadUI)
    elseif C_AddOns and C_AddOns.LoadAddOn then
        Try(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
    end
    tiers = Plain(Try(EJ_GetNumTiers))
    return type(tiers) == "number" and tiers > 0
end

-- The current raids and their bosses, from the Adventure Guide's newest
-- tier (raids that list difficulties - the world-boss page doesn't). The
-- guide's selected tier is put back afterwards.
local function CurrentRaids()
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetEncounterInfoByIndex) then
        return {}
    end
    EnsureGuide()
    local tiers = Plain(Try(EJ_GetNumTiers))
    if type(tiers) ~= "number" or tiers < 1 then return {} end
    local saved = Plain(Try(EJ_GetCurrentTier))
    Try(EJ_SelectTier, tiers)
    local raids = {}
    for i = 1, 20 do
        local instID, name = Try(EJ_GetInstanceByIndex, i, true)
        if not instID then break end
        local showsDifficulty = select(9, Try(EJ_GetInstanceInfo, instID))
        if showsDifficulty ~= false then
            local bosses = {}
            for e = 1, 40 do
                local boss = Plain(Try(EJ_GetEncounterInfoByIndex, e, instID))
                if not boss then break end
                tinsert(bosses, boss)
            end
            if #bosses > 0 then tinsert(raids, { name = Plain(name), bosses = bosses }) end
        end
    end
    if type(saved) == "number" then Try(EJ_SelectTier, saved) end
    return raids
end

-- Every raid in the Adventure Guide, oldest tier first: { tier, tierName,
-- name }. For the farm-list picker and for sorting old raids by expansion.
-- It walks every tier, so it's read once per session (and only when
-- needed); the guide's selected tier is put back afterwards.
local catalog
local function RaidCatalog()
    if catalog then return catalog end
    local out = {}
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then return out end
    EnsureGuide()
    local tiers = Plain(Try(EJ_GetNumTiers))
    if type(tiers) ~= "number" or tiers < 1 then return out end
    local saved = Plain(Try(EJ_GetCurrentTier))
    for t = 1, tiers do
        Try(EJ_SelectTier, t)
        local tierName = Plain(Try(EJ_GetTierInfo, t)) or ("Tier " .. t)
        for i = 1, 40 do
            local instID, name = Try(EJ_GetInstanceByIndex, i, true)
            if not instID then break end
            name = Plain(name)
            -- raids that list difficulties (the world-boss page doesn't)
            local showsDifficulty = select(9, Try(EJ_GetInstanceInfo, instID))
            if name and showsDifficulty ~= false then
                tinsert(out, { tier = t, tierName = tierName, name = name })
            end
        end
    end
    if type(saved) == "number" then Try(EJ_SelectTier, saved) end
    if #out > 0 then catalog = out end
    return out
end

-- Difficulties only old raids have (10/25/40-player sizes, and Timewalking
-- replays): a raid locked on one of these is old for certain, guide or no
-- guide. Current raids use the flexible Normal/Heroic/Mythic difficulties.
-- IDs come from the game's own DifficultyUtil names.
local function OldRaidDifficulties()
    local ID, out = DifficultyUtil and DifficultyUtil.ID, {}
    if type(ID) ~= "table" then return out end
    for _, key in ipairs({ "Raid10Normal", "Raid25Normal", "Raid10Heroic", "Raid25Heroic", "Raid40", "RaidTimewalker" }) do
        if ID[key] then out[ID[key]] = true end
    end
    return out
end

-- The farm list: raids starred in the Legacy tab, for every character on
-- this account. Mirrored into each character's data so the app can read it.
local function Farm()
    local db = ForgesLedgerDungeonsDB
    db.farmRaids = type(db.farmRaids) == "table" and db.farmRaids or {}
    return db.farmRaids
end

-- The four raid difficulties, from the game's own constants and names.
local function RaidDifficulties()
    local ID = DifficultyUtil and DifficultyUtil.ID
    local out = {}
    if not (ID and GetDifficultyInfo) then return out end
    for _, key in ipairs({ "PrimaryRaidLFR", "PrimaryRaidNormal", "PrimaryRaidHeroic", "PrimaryRaidMythic" }) do
        local id = ID[key]
        local name = id and Plain(Try(GetDifficultyInfo, id))
        if name then tinsert(out, { id = id, name = name }) end
    end
    return out
end

-- This week's raid kills: lockouts (Normal/Heroic/Mythic) boss by boss,
-- plus Raid Finder wings, which the lockout list doesn't include.
local function ReadRaids(d)
    local kills, now = {}, time()
    local db = ForgesLedgerDungeonsDB
    -- The current expansion's raids, from the guide's newest tier, are kept
    -- in the save file: "legacy" means any raid NOT in this list, so when a
    -- new tier ships, last expansion's raids become legacy on their own.
    local cur = CurrentRaids()
    if #cur > 0 then
        local names = {}
        for _, r in ipairs(cur) do tinsert(names, r.name) end
        db.currentRaids = names
    end
    local current = {}
    for _, n in ipairs(type(db.currentRaids) == "table" and db.currentRaids or {}) do current[n] = true end
    local known, legacy = next(current) ~= nil, {}
    local oldDiff = OldRaidDifficulties()
    if GetNumSavedInstances and GetSavedInstanceInfo and GetSavedInstanceEncounterInfo then
        local n = Plain(Try(GetNumSavedInstances)) or 0
        for i = 1, n do
            local name, _, reset, diffID, _, _, _, isRaid, _, diffName, numEnc, progress, _, instanceID =
                Try(GetSavedInstanceInfo, i)
            name, reset, diffName = Plain(name), Plain(reset), Plain(diffName)
            if name and isRaid and type(reset) == "number" and reset > 0 then
                local bosses, list, down = {}, {}, 0
                for e = 1, (tonumber(Plain(numEnc)) or 0) do
                    local boss, _, killed = Try(GetSavedInstanceEncounterInfo, i, e)
                    boss = Plain(boss)
                    if boss and killed then bosses[boss] = true; down = down + 1 end
                    if boss then tinsert(list, { name = boss, killed = killed and true or false }) end
                end
                kills[name] = kills[name] or {}
                kills[name][diffName or tostring(diffID)] = { id = Plain(diffID), resetAt = now + reset, bosses = bosses }
                if (known and not current[name]) or oldDiff[Plain(diffID)] then
                    tinsert(legacy, { name = name, instanceID = Plain(instanceID), difficultyID = Plain(diffID),
                                      difficultyName = diffName, isRaid = true, expiresAt = now + reset,
                                      numEncounters = tonumber(Plain(numEnc)) or #list,
                                      encounterProgress = tonumber(Plain(progress)) or down, bosses = list })
                end
            end
        end
    end
    -- old raids run this week. Without the guide only the certain ones (old
    -- difficulties) are known, and the list says it's partial; with neither,
    -- nothing is guessed.
    if known or #legacy > 0 then
        d.legacyLockouts = legacy
        d.legacyPartial = not known or nil
        if #legacy > 0 then d.lastLegacyAt = now end
    end
    local copy = {}
    for k, v in pairs(Farm()) do if v then copy[k] = true end end
    d.farmRaids = copy
    -- Raid Finder: each wing reports its bosses as killed or not; a boss is
    -- filed under the current raid that lists it
    local lfr
    for _, diff in ipairs(RaidDifficulties()) do
        if DifficultyUtil.ID.PrimaryRaidLFR == diff.id then lfr = diff end
    end
    if lfr and GetNumRFDungeons and GetRFDungeonInfo and GetLFGDungeonNumEncounters and GetLFGDungeonEncounterInfo then
        local raidOf = {}
        for _, raid in ipairs(cur) do
            for _, boss in ipairs(raid.bosses) do raidOf[boss] = raid.name end
        end
        local resetAt = WeekStart() + 7 * 86400
        for i = 1, (tonumber(Plain(Try(GetNumRFDungeons))) or 0) do
            local wing = Try(GetRFDungeonInfo, i)
            local count = wing and tonumber(Plain(Try(GetLFGDungeonNumEncounters, wing))) or 0
            for e = 1, count do
                local boss, _, killed = Try(GetLFGDungeonEncounterInfo, wing, e)
                boss = Plain(boss)
                local raid = boss and raidOf[boss]
                if raid and killed then
                    kills[raid] = kills[raid] or {}
                    local entry = kills[raid][lfr.name] or { id = lfr.id, resetAt = resetAt, bosses = {} }
                    entry.bosses[boss] = true
                    kills[raid][lfr.name] = entry
                end
            end
        end
    end
    d.raidKills = kills
    d.raidsAt = now
end

local function ReadAll()
    local c = CharData()
    local d = c.data
    d.name = UnitName("player")
    d.class = select(2, UnitClass("player"))
    pcall(ReadMythicPlus, d)
    pcall(ReadRaids, d)
    c.exportedAt = time()
end

-- Has this character got a keystone this week? (A key from before the
-- weekly reset isn't the key they hold now.)
local function KeyOf(d)
    if type(d) ~= "table" or type(d.keystone) ~= "table" then return nil end
    if (tonumber(d.keystoneAt) or 0) < WeekStart() then return nil end
    return d.keystone
end

---------------------------------------------------------------- the panel ---
-- Two tabs: Mythic+ (rating, keystone, this week's runs, and the season's
-- dungeon grid with your best key in each) and Raids (the current raids'
-- bosses, killed this week on each difficulty). Plain frames - it opens and
-- works in combat. Draggable; its position is saved.

local W, PADDING, CELL_H, BOSS_H = 480, 12, 50, 22
local MEDIA = "Interface\\AddOns\\ForgesLedger_Dungeons\\Media\\"
local IRON, GOLD, BONE, DIM, GREEN = { 0.05, 0.05, 0.07, 0.96 }, { 0.90, 0.75, 0.25 },
    { 0.92, 0.90, 0.85 }, { 0.55, 0.55, 0.55 }, { 0.30, 0.85, 0.45 }
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- A small tribute in the panel's corner (DUNGEONS_SPEC 4.1): "for Luna"
-- and a heart, in gold. The heart is typed as "<3": WoW's fonts draw
-- neither emoji nor the text heart character (both tried in game).
local TRIBUTE_TEXT = "for Luna <3"
local panel, tab = nil, "mplus"
local tabs, cells, rows, heads, cols = {}, {}, {}, {}, {}

local function Tex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BORDER")
    t:SetColorTexture(r, g, b, a)
    return t
end

local function Border(f, alpha)
    local e = {}
    for i = 1, 4 do e[i] = Tex(f, "BORDER", GOLD[1], GOLD[2], GOLD[3], alpha) end
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(1)
    return e
end

local function Text(parent, font, col)
    local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    if col then f:SetTextColor(col[1], col[2], col[3]) end
    return f
end

local Render

local function GetTab(i)
    if tabs[i] then return tabs[i] end
    local t = CreateFrame("Button", nil, panel)
    t:SetHeight(32)
    t.bg = Tex(t, "BACKGROUND", 1, 1, 1, 0.03)
    t.bg:SetAllPoints()
    t.glow = Tex(t, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.14)
    t.glow:SetAllPoints()
    t.under = Tex(t, "OVERLAY", GOLD[1], GOLD[2], GOLD[3], 1)
    t.under:SetPoint("BOTTOMLEFT"); t.under:SetPoint("BOTTOMRIGHT"); t.under:SetHeight(2)
    Border(t, 0.35)
    t.text = Text(t, "GameFontNormalLarge")
    t.text:SetPoint("CENTER")
    t:SetScript("OnClick", function(self)
        tab = self.id
        ForgesLedgerDungeonsDB.panelTab = tab
        Render()
    end)
    tabs[i] = t
    return t
end

local function GetCell(i)
    if cells[i] then return cells[i] end
    local c = CreateFrame("Frame", nil, panel.body)
    c:SetHeight(CELL_H)
    c.bg = Tex(c, "BACKGROUND", 0, 0, 0, 0.35)
    c.bg:SetAllPoints()
    c.border = Border(c, 0.3)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(34, 34)
    c.icon:SetPoint("LEFT", 8, 0)
    c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.name = Text(c, "GameFontNormal", BONE)
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, -1)
    c.name:SetPoint("RIGHT", -6, 0)
    c.name:SetJustifyH("LEFT")
    c.name:SetWordWrap(false)
    c.best = Text(c, "GameFontHighlight")
    c.best:SetPoint("BOTTOMLEFT", c.icon, "BOTTOMRIGHT", 8, 1)
    c.check = c:CreateTexture(nil, "OVERLAY")
    c.check:SetSize(14, 14)
    c.check:SetTexture(CHECK)
    c.check:SetPoint("LEFT", c.best, "RIGHT", 4, 0)
    c.key = Text(c, "GameFontHighlightSmall", GOLD)
    c.key:SetPoint("BOTTOMRIGHT", -8, 4)
    cells[i] = c
    return c
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Frame", nil, panel.body)
    r:SetHeight(BOSS_H)
    r.sep = Tex(r, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.08)
    r.sep:SetPoint("TOPLEFT"); r.sep:SetPoint("TOPRIGHT"); r.sep:SetHeight(1)
    r.name = Text(r, "GameFontHighlight", BONE)
    r.name:SetPoint("LEFT", 10, 0)
    r.marks = {}
    rows[i] = r
    return r
end

local function GetHead(i)  -- raid name / column labels
    if heads[i] then return heads[i] end
    local h = CreateFrame("Frame", nil, panel.body)
    h:SetHeight(26)
    h.name = Text(h, "GameFontNormal", GOLD)
    h.name:SetPoint("BOTTOMLEFT", 6, 4)
    h.cols = {}
    heads[i] = h
    return h
end

-- Legacy tab: one row per old raid (a star, the raid, difficulty, bosses,
-- reset), and the farm-list picker (every older raid in the guide, one
-- expansion at a time).
local legacyRows, pickMode, pickTier = {}, false, nil

local function TextBtn(parent, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(140, 20)
    b.text = Text(b, "GameFontHighlightSmall", GOLD)
    b.text:SetPoint("LEFT")
    b.text:SetText(label)
    b:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function(self) self.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end)
    return b
end

local function GetLegacyRow(i)
    if legacyRows[i] then return legacyRows[i] end
    local r = CreateFrame("Frame", nil, panel.body)
    r:SetHeight(BOSS_H)
    r.sep = Tex(r, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.08)
    r.sep:SetPoint("TOPLEFT"); r.sep:SetPoint("TOPRIGHT"); r.sep:SetHeight(1)
    r.star = CreateFrame("Button", nil, r)
    r.star:SetSize(16, 16)
    r.star:SetPoint("LEFT", 6, 0)
    r.star.tex = r.star:CreateTexture(nil, "ARTWORK")
    r.star.tex:SetAllPoints()
    r.star:SetScript("OnClick", function(self)
        local farm = Farm()
        farm[self.raid] = not farm[self.raid] or nil
        local d = CharData().data
        local copy = {}
        for k in pairs(farm) do copy[k] = true end
        d.farmRaids = copy
        Render()
    end)
    r.star:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(Farm()[self.raid] and "On your farm list - click to remove" or "Add to your farm list")
        GameTooltip:Show()
    end)
    r.star:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.name = Text(r, "GameFontHighlight", BONE)
    r.name:SetPoint("LEFT", 30, 0)
    r.name:SetWidth(200)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.diff = Text(r, "GameFontHighlightSmall", DIM)
    r.diff:SetPoint("LEFT", 234, 0)
    r.diff:SetWidth(96)
    r.diff:SetJustifyH("LEFT")
    r.diff:SetWordWrap(false)
    r.prog = Text(r, "GameFontHighlight", BONE)
    r.prog:SetPoint("LEFT", 334, 0)
    r.reset = Text(r, "GameFontHighlightSmall", DIM)
    r.reset:SetPoint("RIGHT", -6, 0)
    legacyRows[i] = r
    return r
end

local function SetStar(r, raid)
    r.star.raid = raid
    local on = Farm()[raid] == true
    r.star.tex:SetTexture(MEDIA .. (on and "star_on" or "star_off"))
    r.star.tex:SetVertexColor((on and GOLD or DIM)[1], (on and GOLD or DIM)[2], (on and GOLD or DIM)[3], 1)
end

local function CreatePanel()
    panel = CreateFrame("Frame", "ForgesLedgerDungeonsPanel", UIParent)
    panel:SetWidth(W)
    panel:SetFrameStrata("HIGH")
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        ForgesLedgerDungeonsDB.panelPos = { point, rel, x, y }
    end)
    Tex(panel, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4]):SetAllPoints()
    Border(panel, 0.85)
    for i, a in ipairs({ 0.25, 0.12, 0.05 }) do  -- faint glow under the top edge
        local g = Tex(panel, "BORDER", GOLD[1], GOLD[2], GOLD[3], a)
        g:SetPoint("TOPLEFT", 1, -i); g:SetPoint("TOPRIGHT", -1, -i); g:SetHeight(1)
    end
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    -- the tribute: just text, so it can't take a click
    panel.tribute = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.tribute:SetText(TRIBUTE_TEXT)
    panel.tribute:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    panel.tribute:SetPoint("RIGHT", panel, "TOPRIGHT", -34, -28)
    panel.head1 = Text(panel, "GameFontNormal")
    panel.head2 = Text(panel, "GameFontHighlightSmall", BONE)
    panel.head3 = Text(panel, "GameFontHighlightSmall", DIM)
    panel.body = CreateFrame("Frame", nil, panel)
    panel.body:SetPoint("RIGHT", panel, "RIGHT", -PADDING, 0)
    panel.note = Text(panel.body, "GameFontHighlightSmall", DIM)
    panel.foot = Text(panel, "GameFontHighlightSmall", DIM)
    local pos = ForgesLedgerDungeonsDB.panelPos
    if type(pos) == "table" and type(pos[1]) == "string" then
        panel:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    local saved = ForgesLedgerDungeonsDB.panelTab
    tab = (saved == "raids" or saved == "legacy") and saved or "mplus"
    -- the Raids tab's way in to old raids (the Legacy tab only shows up
    -- once there's something on it)
    panel.legacyLink = TextBtn(panel.body, "Old raids and farm list")
    panel.legacyLink:SetScript("OnClick", function()
        tab, pickMode = "legacy", false
        ForgesLedgerDungeonsDB.panelTab = tab
        Render()
    end)
    panel.legacyLink:Hide()
    panel.pickBtn = TextBtn(panel.body, "Edit farm list")
    panel.pickBtn:SetScript("OnClick", function()
        pickMode = not pickMode
        Render()
    end)
    panel.pickBtn:Hide()
    panel.nav = CreateFrame("Frame", nil, panel.body)
    panel.nav:SetHeight(24)
    panel.nav.prev = TextBtn(panel.nav, "<  older")
    panel.nav.prev:SetSize(70, 20)
    panel.nav.prev:SetPoint("LEFT", 4, 0)
    panel.nav.prev:SetScript("OnClick", function() pickTier = (pickTier or 2) - 1; Render() end)
    panel.nav.next = TextBtn(panel.nav, "newer  >")
    panel.nav.next:SetSize(70, 20)
    panel.nav.next:SetPoint("RIGHT", -4, 0)
    panel.nav.next.text:ClearAllPoints()
    panel.nav.next.text:SetPoint("RIGHT")
    panel.nav.next:SetScript("OnClick", function() pickTier = (pickTier or 0) + 1; Render() end)
    panel.nav.label = Text(panel.nav, "GameFontNormal", GOLD)
    panel.nav.label:SetPoint("CENTER")
    panel.nav:Hide()
    tinsert(UISpecialFrames, "ForgesLedgerDungeonsPanel")
    panel:Hide()
end

local function HideAll(list)
    for _, f in ipairs(list) do f:Hide() end
end

local function RenderMythicPlus(d, top)
    local rating = tonumber(d.mythicPlusRating)
    local color = rating and Plain(Try(C_ChallengeMode.GetDungeonScoreRarityColor, rating))
    panel.head1:SetText(rating and ("Mythic+ rating " .. math.floor(rating + 0.5)) or "Mythic+ rating not read yet")
    if color and color.GetRGB then
        panel.head1:SetTextColor(color:GetRGB())
    else
        panel.head1:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    end
    local key = KeyOf(d)
    panel.head2:SetText(key and ("Your key: " .. tostring(key.name or "?") .. " +" .. key.level) or "No keystone this week")
    local runs = type(d.weeklyRuns) == "table" and d.weeklyRuns or {}
    local list = {}
    for i, lvl in ipairs(runs) do
        if i > 8 then break end
        tinsert(list, "+" .. lvl)
    end
    panel.head3:SetText(#runs > 0 and ("This week: " .. #runs .. (#runs == 1 and " run  " or " runs  ") .. table.concat(list, "  "))
        or "No runs this week yet")
    -- the season's dungeons, two per row
    local dungeons = type(d.seasonDungeons) == "table" and d.seasonDungeons or {}
    local bests = type(d.seasonBests) == "table" and d.seasonBests or {}
    local cellW = (W - PADDING * 2 - 10) / 2
    for i, dg in ipairs(dungeons) do
        local c = GetCell(i)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", panel.body, "TOPLEFT", col * (cellW + 10), -row * (CELL_H + 8))
        c:SetWidth(cellW)
        c.icon:SetTexture(dg.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        c.name:SetText(tostring(dg.name or "?"))
        local b = bests[dg.id]
        if b then
            c.best:SetText("+" .. b.level .. (b.timed and "" or "  over time"))
            c.best:SetTextColor((b.timed and BONE or DIM)[1], (b.timed and BONE or DIM)[2], (b.timed and BONE or DIM)[3])
        else
            c.best:SetText("no run this season")
            c.best:SetTextColor(DIM[1], DIM[2], DIM[3])
        end
        c.check:SetShown(b ~= nil and b.timed == true)
        local mine = key and key.dungeonID == dg.id
        c.key:SetText(mine and ("your key +" .. key.level) or "")
        for _, e in ipairs(c.border) do
            e:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], mine and 0.95 or 0.3)
        end
        c:Show()
    end
    for i = #dungeons + 1, #cells do cells[i]:Hide() end
    local h = math.ceil(#dungeons / 2) * (CELL_H + 8)
    panel.note:SetShown(#dungeons == 0)
    if #dungeons == 0 then
        panel.note:SetText("This season's dungeons appear once the game has sent them - try again in a moment.")
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", 4, -4)
        h = 24
    end
    return h
end

local function RenderRaids(d)
    local now = time()
    local raids = CurrentRaids()
    local diffs = RaidDifficulties()
    local kills = type(d.raidKills) == "table" and d.raidKills or {}
    panel.head1:SetText("Raids this week")
    panel.head1:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    panel.head2:SetText("")
    panel.head3:SetText("")
    local colW, nameW = 62, W - PADDING * 2 - 4 * 62
    local y, hi, ri = 0, 0, 0
    for _, raid in ipairs(raids) do
        hi = hi + 1
        local h = GetHead(hi)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, y)
        h:SetPoint("RIGHT", panel.body, "RIGHT")
        h.name:SetText(tostring(raid.name))
        for j, diff in ipairs(diffs) do  -- column labels
            local l = h.cols[j] or Text(h, "GameFontHighlightSmall", DIM)
            h.cols[j] = l
            l:SetText(diff.name)
            l:ClearAllPoints()
            l:SetPoint("BOTTOM", h, "BOTTOMLEFT", nameW + (j - 0.5) * colW, 4)
            l:Show()
        end
        for j = #diffs + 1, #h.cols do h.cols[j]:Hide() end
        h:Show()
        y = y - 26
        -- which bosses died this week on each difficulty (lockouts not yet reset)
        local byDiff = {}
        for _, entry in pairs(type(kills[raid.name]) == "table" and kills[raid.name] or {}) do
            if type(entry) == "table" and (tonumber(entry.resetAt) or 0) > now and entry.id then
                byDiff[entry.id] = entry.bosses
            end
        end
        for _, boss in ipairs(raid.bosses) do
            ri = ri + 1
            local r = GetRow(ri)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, y)
            r:SetPoint("RIGHT", panel.body, "RIGHT")
            r.name:SetText(boss)
            local any = false
            for j, diff in ipairs(diffs) do
                local m = r.marks[j]
                if not m then
                    m = r:CreateTexture(nil, "OVERLAY")
                    r.marks[j] = m
                end
                m:ClearAllPoints()
                m:SetPoint("CENTER", r, "LEFT", nameW + (j - 0.5) * colW, 0)
                local killed = type(byDiff[diff.id]) == "table" and byDiff[diff.id][boss] == true
                if killed then
                    any = true
                    m:SetTexture(CHECK)
                    m:SetSize(16, 16)
                    m:SetVertexColor(1, 1, 1, 1)
                else
                    m:SetColorTexture(0.3, 0.3, 0.3, 0.8)  -- a small grey mark: not killed
                    m:SetSize(5, 5)
                end
                m:Show()
            end
            for j = #diffs + 1, #r.marks do r.marks[j]:Hide() end
            r.name:SetTextColor((any and BONE or DIM)[1], (any and BONE or DIM)[2], (any and BONE or DIM)[3])
            r:Show()
            y = y - BOSS_H
        end
        y = y - 8
    end
    for i = hi + 1, #heads do heads[i]:Hide() end
    for i = ri + 1, #rows do rows[i]:Hide() end
    panel.note:SetShown(#raids == 0)
    if #raids == 0 then
        panel.note:SetText("The current raids appear once the Adventure Guide has loaded them.")
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", 4, -4)
        y = -24
    end
    return -y
end

-- old raids this week, and starred raids not run yet
local function RenderLegacy(d)
    local now = time()
    local farm = Farm()
    local order = {}
    for _, r in ipairs(RaidCatalog()) do order[r.name] = r.tier end
    if pickMode then
        -- the farm-list picker: one expansion of older raids at a time
        local current = {}
        for _, n in ipairs(type(ForgesLedgerDungeonsDB.currentRaids) == "table" and ForgesLedgerDungeonsDB.currentRaids or {}) do current[n] = true end
        local byTier, tiers = {}, {}
        for _, r in ipairs(RaidCatalog()) do
            if not current[r.name] then
                if not byTier[r.tier] then byTier[r.tier] = { name = r.tierName, raids = {} }; tinsert(tiers, r.tier) end
                tinsert(byTier[r.tier].raids, r.name)
            end
        end
        panel.head1:SetText("Farm list")
        panel.head1:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        panel.head2:SetText("Star the old raids you farm. Starred raids show on the Legacy tab every week.")
        panel.head3:SetText("")
        if #tiers == 0 then
            panel.note:SetText("The raid list appears once the Adventure Guide has loaded.")
            panel.note:ClearAllPoints()
            panel.note:SetPoint("TOPLEFT", 4, -4)
            panel.note:Show()
            panel.pickBtn:ClearAllPoints()
            panel.pickBtn:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 4, -26)
            panel.pickBtn.text:SetText("Done")
            panel.pickBtn:Show()
            return 50
        end
        local idx = 1
        for i, t in ipairs(tiers) do if t == pickTier then idx = i end end
        if not byTier[pickTier or -1] then idx = #tiers end
        pickTier = tiers[idx]
        panel.nav:ClearAllPoints()
        panel.nav:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, 0)
        panel.nav:SetPoint("RIGHT", panel.body, "RIGHT")
        panel.nav.label:SetText(byTier[pickTier].name)
        panel.nav.prev:SetShown(idx > 1)
        panel.nav.prev:SetScript("OnClick", function() pickTier = tiers[idx - 1]; Render() end)
        panel.nav.next:SetShown(idx < #tiers)
        panel.nav.next:SetScript("OnClick", function() pickTier = tiers[idx + 1]; Render() end)
        panel.nav:Show()
        local y = -28
        for i, name in ipairs(byTier[pickTier].raids) do
            local r = GetLegacyRow(i)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, y)
            r:SetPoint("RIGHT", panel.body, "RIGHT")
            SetStar(r, name)
            r.name:SetText(name)
            r.name:SetTextColor(BONE[1], BONE[2], BONE[3])
            r.diff:SetText(""); r.prog:SetText(""); r.reset:SetText("")
            r:Show()
            y = y - BOSS_H
        end
        for i = #byTier[pickTier].raids + 1, #legacyRows do legacyRows[i]:Hide() end
        panel.pickBtn:ClearAllPoints()
        panel.pickBtn:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 4, y - 6)
        panel.pickBtn.text:SetText("Done")
        panel.pickBtn:Show()
        return -y + 30
    end
    panel.head1:SetText("Old raids this week")
    panel.head1:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    panel.head2:SetText("Resets " .. date("%a %H:%M", WeekStart() + 7 * 86400))
    panel.head3:SetText(d.legacyPartial and "Newer old raids appear once the Adventure Guide has loaded."
        or "Star a raid to keep it on your farm list.")
    if type(d.legacyLockouts) ~= "table" then
        panel.note:SetText("Old raids appear once the Adventure Guide has loaded.")
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", 4, -4)
        panel.note:Show()
        return 24
    end
    -- this week's old-raid lockouts (still running), then starred raids not run yet
    local list, seen = {}, {}
    for _, l in ipairs(d.legacyLockouts) do
        if type(l) == "table" and (tonumber(l.expiresAt) or 0) > now then
            tinsert(list, l)
            seen[l.name] = true
        end
    end
    table.sort(list, function(a, b)
        local ta, tb = order[a.name] or 0, order[b.name] or 0
        if ta ~= tb then return ta > tb end  -- newest expansion first
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.difficultyName) < tostring(b.difficultyName)
    end)
    local waiting = {}
    for name in pairs(farm) do if not seen[name] then tinsert(waiting, name) end end
    table.sort(waiting, function(a, b)
        local ta, tb = order[a] or 0, order[b] or 0
        if ta ~= tb then return ta > tb end
        return a < b
    end)
    local y, i = 0, 0
    for _, l in ipairs(list) do
        i = i + 1
        local r = GetLegacyRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", panel.body, "RIGHT")
        SetStar(r, l.name)
        r.name:SetText(l.name)
        r.name:SetTextColor(BONE[1], BONE[2], BONE[3])
        r.diff:SetText(tostring(l.difficultyName or ""))
        local done = (tonumber(l.encounterProgress) or 0) >= (tonumber(l.numEncounters) or 1)
        r.prog:SetText((l.encounterProgress or 0) .. " / " .. (l.numEncounters or "?"))
        r.prog:SetTextColor((done and GOLD or BONE)[1], (done and GOLD or BONE)[2], (done and GOLD or BONE)[3])
        r.reset:SetText("")
        r:Show()
        y = y - BOSS_H
    end
    for _, name in ipairs(waiting) do
        i = i + 1
        local r = GetLegacyRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", panel.body, "RIGHT")
        SetStar(r, name)
        r.name:SetText(name)
        r.name:SetTextColor(DIM[1], DIM[2], DIM[3])
        r.diff:SetText("- not run yet")
        r.prog:SetText("")
        r.reset:SetText("")
        r:Show()
        y = y - BOSS_H
    end
    for j = i + 1, #legacyRows do legacyRows[j]:Hide() end
    if i == 0 then
        panel.note:SetText("No old raids run this week - star some in your farm list to track them.")
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", 4, -4)
        panel.note:Show()
        y = -24
    end
    panel.pickBtn:ClearAllPoints()
    panel.pickBtn:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 4, y - 6)
    panel.pickBtn.text:SetText("Edit farm list")
    panel.pickBtn:Show()
    return -y + 30
end

function Render()
    if not panel then return end
    local d = CharData().data
    -- tabs (Legacy only once there's something on it: an old raid this week
    -- or a starred raid)
    local hasLegacy = next(Farm()) ~= nil
    for _, l in ipairs(type(d.legacyLockouts) == "table" and d.legacyLockouts or {}) do
        if type(l) == "table" and (tonumber(l.expiresAt) or 0) > time() then hasLegacy = true end
    end
    if tab == "legacy" and not hasLegacy and not pickMode then hasLegacy = true end  -- opened from the link
    local defs = { { id = "mplus", label = "Mythic+" }, { id = "raids", label = "Raids" } }
    if hasLegacy then tinsert(defs, { id = "legacy", label = "Legacy" }) end
    local x = PADDING
    for i = #defs + 1, #tabs do tabs[i]:Hide() end
    for i, def in ipairs(defs) do
        local t = GetTab(i)
        t.id = def.id
        t.text:SetText(def.label)
        local active = def.id == tab
        local col = active and GOLD or BONE
        t.text:SetTextColor(col[1], col[2], col[3])
        t.text:SetAlpha(active and 1 or 0.75)
        t.under:SetShown(active)
        t.glow:SetShown(active)
        local w = math.ceil(t.text:GetStringWidth()) + 40
        t:SetWidth(w)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -12)
        t:Show()
        x = x + w + 6
    end
    -- header lines
    local y = -12 - 32 - 12
    panel.head1:ClearAllPoints(); panel.head1:SetPoint("TOPLEFT", PADDING + 2, y)
    panel.head2:ClearAllPoints(); panel.head2:SetPoint("TOPLEFT", PADDING + 2, y - 18)
    panel.head3:ClearAllPoints(); panel.head3:SetPoint("TOPLEFT", PADDING + 2, y - 34)
    -- body
    HideAll(cells); HideAll(rows); HideAll(heads); HideAll(legacyRows)
    panel.legacyLink:Hide(); panel.pickBtn:Hide(); panel.nav:Hide(); panel.note:Hide()
    if tab ~= "legacy" then pickMode = false end
    local bodyTop = tab == "raids" and (y - 22) or (y - 56)
    panel.body:ClearAllPoints()
    panel.body:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, bodyTop)
    panel.body:SetPoint("RIGHT", panel, "RIGHT", -PADDING, 0)
    local h
    if tab == "mplus" then
        h = RenderMythicPlus(d)
    elseif tab == "legacy" then
        h = RenderLegacy(d)
    else
        h = RenderRaids(d)
        panel.legacyLink:ClearAllPoints()
        panel.legacyLink:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 4, -h - 2)
        panel.legacyLink:Show()
        h = h + 24
    end
    panel.body:SetHeight(math.max(1, h))
    -- honest about when this was read
    local at = tab == "mplus" and d.mythicPlusAt or d.raidsAt
    panel.foot:SetText(at and ("Read from the game " .. (time() - at < 90 and "just now" or date("%H:%M", at)) .. ".") or "Not read yet.")
    panel.foot:ClearAllPoints()
    panel.foot:SetPoint("TOP", panel, "TOP", 0, bodyTop - h - 8)
    panel:SetHeight(-bodyTop + h + 30)
end

-- fade in while easing up 6px, ~150ms - the bar's motion language
local function ShowPanel()
    if not panel then CreatePanel() end
    ReadAll()
    Render()
    if panel:IsShown() then return end
    local point, rel, relPoint, x, y = panel:GetPoint()
    local t = 0
    panel:SetAlpha(0)
    panel:Show()
    panel:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        local f = math.min(1, t / 0.15)
        self:SetAlpha(f)
        self:ClearAllPoints()
        self:SetPoint(point, rel, relPoint, x, y - 6 * (1 - f))
        if f >= 1 then self:SetScript("OnUpdate", nil) end
    end)
end

local function TogglePanel()
    if panel and panel:IsShown() then
        panel:Hide()
        return false
    end
    ShowPanel()
    return true
end

------------------------------------------------------------------ events ---

local queued = false
local function Queue()
    if queued then return end
    queued = true
    C_Timer.After(1, function()
        queued = false
        ReadAll()
        if panel and panel:IsShown() then Render() end
        -- the bar's vault segment shows our keystone: let it redraw (core v2.10+)
        if ForgesLedger and type(ForgesLedger.RefreshBar) == "function" then
            pcall(ForgesLedger.RefreshBar)
        end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({
    "CHALLENGE_MODE_MAPS_UPDATE",      -- season dungeons/bests arrived
    "CHALLENGE_MODE_COMPLETED",        -- a key finished
    "MYTHIC_PLUS_NEW_WEEKLY_RECORD",
    "WEEKLY_REWARDS_UPDATE",
    "BAG_UPDATE_DELAYED",              -- keystone gained, lost, or changed
    "UPDATE_INSTANCE_INFO",            -- lockouts refreshed
    "LFG_LOCK_INFO_RECEIVED",          -- Raid Finder progress
    "ENCOUNTER_END",                   -- a boss fight ended
}) do
    pcall(frame.RegisterEvent, frame, e)  -- in case a client lacks one
end
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- ask the game for this week's data; the events above follow
        C_Timer.After(3, function()
            Try(C_MythicPlus.RequestMapInfo)
            Try(C_MythicPlus.RequestCurrentAffixes)
            Try(RequestRaidInfo)
            Try(RequestLFDPlayerLockInfo)
            Queue()
        end)
    elseif event == "ENCOUNTER_END" then
        Try(RequestRaidInfo)  -- the lockout list updates after a kill
        Queue()
    else
        Queue()
    end
end)

------------------------------------------------------------------ the bar ---
-- With the core addon v2.10+, this takes over the bar's Great Vault
-- segment: the core's own vault text (its slot count) plus your keystone,
-- "Vault: M+ 3/8 - Key +12", and the core's hover card plus a Keys section
-- - every character's keystone this week. Clicking it opens the panel.
-- Older cores keep their own segment; /fld still opens the panel.

local function KeysSection()
    local rows, stale, total = {}, 0, 0
    for key, c in pairs(type(ForgesLedgerDungeonsDB.characters) == "table" and ForgesLedgerDungeonsDB.characters or {}) do
        local d = type(c) == "table" and c.data
        if type(d) == "table" then
            total = total + 1
            local k = KeyOf(d)
            if k then
                tinsert(rows, { name = d.name or key, class = d.class, level = k.level,
                                value = tostring(k.name or "?") .. "  +" .. k.level })
            elseif (tonumber(d.keystoneAt) or 0) < WeekStart() then
                stale = stale + 1
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return a.name < b.name
    end)
    return rows, stale
end

local core = ForgesLedger and ForgesLedger.GetBarPlugin and ForgesLedger.GetBarPlugin("vault")
if core and type(core.text) == "function" and ForgesLedger.RegisterBarPlugin then
    ForgesLedger.RegisterBarPlugin({
        id = "vault", label = core.label or "Great Vault",
        updateEvents = { "WEEKLY_REWARDS_UPDATE", "CHALLENGE_MODE_COMPLETED", "BAG_UPDATE_DELAYED" },
        text = function()
            local text, dot = core.text()  -- the core's count, unchanged
            local key = KeyOf(CharData().data)
            if key then
                text = text and (text .. "  \194\183  Key +" .. key.level) or ("Key +" .. key.level)
            end
            return text, dot
        end,
        roster = function()
            local card = type(core.roster) == "function" and core.roster() or nil
            if type(card) ~= "table" then card = { title = core.label or "Great Vault", rows = {} } end
            card.rows = type(card.rows) == "table" and card.rows or {}
            card.footer = type(card.footer) == "table" and card.footer or {}
            -- "who has which key?" - up to 6, highest first, as of each login
            local keys, stale = KeysSection()
            tinsert(card.rows, { section = "Keys" })
            for i, k in ipairs(keys) do
                if i > 6 then break end
                tinsert(card.rows, { name = k.name, class = k.class, value = k.value })
            end
            if #keys == 0 then
                tinsert(card.rows, { name = "No keystones recorded this week", valueColor = DIM })
            end
            if #keys > 6 then tinsert(card.footer, "+" .. (#keys - 6) .. " more keys") end
            if stale > 0 then
                tinsert(card.footer, stale .. (stale == 1 and " character" or " characters") .. " not seen since the weekly reset")
            end
            card.empty = nil
            return card
        end,
        onClick = function() TogglePanel() end,
        open = function(toggle)
            if toggle then return TogglePanel() end
            ShowPanel()
            return true
        end,
    })
end

-------------------------------------------------------------------- /fld ---

SLASH_FORGESLEDGERDUNGEONS1 = "/fld"
SlashCmdList["FORGESLEDGERDUNGEONS"] = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "" or cmd == "open" then
        TogglePanel()
    elseif cmd == "raids" or cmd == "mplus" then
        tab = cmd
        ForgesLedgerDungeonsDB.panelTab = tab
        ShowPanel()
    elseif cmd == "legacy" then
        local n = Plain(Try(GetNumSavedInstances)) or 0
        print(PREFIX .. n .. " saved instances. Current raids: " .. table.concat(ForgesLedgerDungeonsDB.currentRaids or {}, ", "))
        for i = 1, n do
            local name, _, reset, diffID, _, _, _, isRaid, _, diffName, numEnc, progress, _, instanceID = Try(GetSavedInstanceInfo, i)
            print("  " .. tostring(name) .. " | " .. tostring(diffName) .. " (" .. tostring(diffID) .. ") | raid "
                .. tostring(isRaid) .. " | " .. tostring(progress) .. "/" .. tostring(numEnc) .. " | resets in "
                .. tostring(reset) .. "s | instance " .. tostring(instanceID))
        end
    elseif cmd == "farm" then
        tab, pickMode = "legacy", true
        ForgesLedgerDungeonsDB.panelTab = tab
        ShowPanel()
    elseif cmd == "scan" then
        ReadAll()
        local d = CharData().data
        local key = KeyOf(d)
        print(PREFIX .. "Keystone: " .. (key and (tostring(key.name) .. " +" .. key.level) or "none")
            .. "  |  rating: " .. tostring(d.mythicPlusRating and math.floor(d.mythicPlusRating + 0.5) or "?")
            .. "  |  season dungeons: " .. #(d.seasonDungeons or {})
            .. "  |  runs this week: " .. #(d.weeklyRuns or {}))
        local n = 0
        for _ in pairs(d.raidKills or {}) do n = n + 1 end
        print(PREFIX .. "Raids with kills this week: " .. n .. "  |  current raids in the guide: " .. #CurrentRaids())
        if panel and panel:IsShown() then Render() end
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /fld - open or close the panel")
        print("  /fld mplus, /fld raids - open on that tab")
        print("  /fld farm - choose the old raids you farm")
        print("  /fld legacy - list this week's lockouts as the game reports them")
        print("  /fld scan - re-read from the game and print what was found")
    end
end
