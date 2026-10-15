-- Forge's Ledger: Professions v1.8 (retail)
-- A companion to Forge's Ledger, and useful on its own: a panel with your
-- skill in every expansion's tier of each profession, plus your profession
-- cooldowns, that opens with the profession window. It also records those
-- numbers for the Forge's Ledger app.
--
-- Step 1 of the satellite plan: record skills + the panel. "Best next
-- craft" and the shopping list come next.
--
-- Rules it follows (see the app's satellite spec):
--   * works without the desktop app and without the core addon
--   * no work every frame - it reads on login and when a profession window
--     opens or changes; the only timer is the panel's 1-second countdown,
--     and that runs only while the panel is open
--   * every game call is checked to exist and pcall-guarded, so an API
--     change can't break the game UI
--   * one save file per account, with a "characters" list, so characters
--     never overwrite each other

local ADDON_NAME = "ForgesLedger_Professions"
local VERSION = "1.8"
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

--------------------------------------------------- the open profession ---
-- (Until v1.8 a small panel sat beside the profession window. The Ledger
-- panel below replaced it: it opens with the profession window instead.)

local function OpenProfession()
    local T = C_TradeSkillUI
    if not (T and T.GetBaseProfessionInfo) then return nil end
    local ok, info = pcall(T.GetBaseProfessionInfo)
    return ok and type(info) == "table" and info.professionName or nil
end

-- the expansion tier the open window is on, e.g. "Midnight Tailoring"
local function CurrentTierName()
    local T = C_TradeSkillUI
    if not (T and T.GetChildProfessionInfo) then return nil end
    local ok, info = pcall(T.GetChildProfessionInfo)
    return ok and type(info) == "table" and info.professionName or nil
end

local function ProfessionWindowShown()
    return ProfessionsFrame and ProfessionsFrame:IsShown() and true or false
end

---------------------------------------------------------------- events ---

-- the Ledger panel (below) replaces these
local RefreshHub, AutoOpenHub, AutoCloseHub = function() end, function() end, function() end

local queued, autoOpen = false, false
local function QueueScan()
    if queued then return end
    queued = true
    C_Timer.After(1, function()
        queued = false
        Scan()
        if autoOpen then  -- a profession window just opened: bring the panel up with it
            autoOpen = false
            AutoOpenHub()
        end
        RefreshHub()
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
        AutoCloseHub()
    else
        if event == "TRADE_SKILL_SHOW" then autoOpen = true end
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


--------------------------------------------------------- the Ledger panel ---
-- The addon's own window (opened from the bar's Professions segment, or
-- /fl professions / /flp open): a tab per primary profession this
-- character knows, that profession's expansion tiers, and every one of
-- this character's profession cooldowns with live countdowns.
--
-- Tabs double as quick-open buttons: clicking one opens that profession's
-- crafting window, like clicking it in the spellbook. That needs a secure
-- button (the game only lets its own secure buttons cast a spell), and a
-- window containing secure buttons can't be shown or hidden in combat. So
-- the panel itself is a plain frame that opens anytime, and invisible
-- secure buttons are laid over the tabs only while out of combat. In
-- combat a tab click just switches the panel.
--
-- Which spell opens a profession isn't hard-coded: the game reports each
-- profession's spellbook slot, and the spell in that slot is the one the
-- spellbook itself casts. /flp tabs prints what was found.
--
-- Everything shown comes from this addon's tier scans and the core addon's
-- recorded cooldowns. The panel only ticks (once a second, for the
-- countdowns) while it's open.

local HUB_W, TAB_H, TIER_H, CARD_H = 470, 38, 22, 52
local IRON, GOLD, BONE, DIM, GREEN = { 0.05, 0.05, 0.07, 0.96 }, { 0.90, 0.75, 0.25 },
    { 0.92, 0.90, 0.85 }, { 0.55, 0.55, 0.55 }, { 0.30, 0.85, 0.45 }
local DOT = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"  -- round mask, tinted gold
local hub, ticker
local hubTabs, hubTiers, hubDots, hubCards, secureTabs = {}, {}, {}, {}, {}
local selected  -- profession name of the open tab

local function Line(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BORDER")
    t:SetColorTexture(r, g, b, a)
    return t
end

local function Frame(f, alpha)  -- 1px gold border
    local e = {
        Line(f, "BORDER", GOLD[1], GOLD[2], GOLD[3], alpha), Line(f, "BORDER", GOLD[1], GOLD[2], GOLD[3], alpha),
        Line(f, "BORDER", GOLD[1], GOLD[2], GOLD[3], alpha), Line(f, "BORDER", GOLD[1], GOLD[2], GOLD[3], alpha) }
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(1)
    return e
end

local function Pulse(region, low)  -- gentle looping alpha pulse, ~1.2s
    local g = region:CreateAnimationGroup()
    g:SetLooping("BOUNCE")
    local a = g:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(low or 0.85)
    a:SetDuration(0.6)
    return g
end

local function SetPulse(g, on)
    if on then
        if not g:IsPlaying() then g:Play() end
    elseif g:IsPlaying() then
        g:Stop()
    end
end

-- "2h 14m 33s"
local function Countdown(s)
    s = math.max(0, math.floor(s))
    local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
    if h > 0 then return string.format("%dh %dm %ds", h, m, s % 60) end
    if m > 0 then return string.format("%dm %ds", m, s % 60) end
    return s .. "s"
end

-- The spell in a profession's spellbook slot (the one the spellbook casts).
local function ProfessionSpell(offset)
    if type(offset) ~= "number" then return nil end
    local SB = C_SpellBook
    if SB and SB.GetSpellBookItemInfo and Enum and Enum.SpellBookSpellBank then
        local ok, info = pcall(SB.GetSpellBookItemInfo, offset + 1, Enum.SpellBookSpellBank.Player)
        if ok and type(info) == "table" and info.spellID then return info.spellID end
    end
    if GetSpellBookItemInfo then  -- older clients
        local ok, _, id = pcall(GetSpellBookItemInfo, offset + 1, "spell")
        if ok and id then return id end
    end
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and n then return n end
    end
    if GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        if ok and n then return n end
    end
end

local function SpellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, t = pcall(C_Spell.GetSpellTexture, id)
        if ok and t then return t end
    end
    if GetSpellTexture then
        local ok, t = pcall(GetSpellTexture, id)
        if ok and t then return t end
    end
end

-- This character's primary professions, from the game: name, icon, and the
-- spell that opens it (nil if the game didn't give one). While a secondary
-- profession's window is open (Fishing, Cooking), it gets a tab too - no
-- quick-open needed, its window is already up.
local function PrimaryProfessions()
    local list = {}
    if not (GetProfessions and GetProfessionInfo) then return list end
    local ok, p1, p2, arch, fish, cook = pcall(GetProfessions)
    if not ok then return list end
    for i = 1, 2 do
        local idx = select(i, p1, p2)
        if idx then
            local ok2, name, icon, _, _, _, offset = pcall(GetProfessionInfo, idx)
            if ok2 and name then
                local spell = ProfessionSpell(offset)
                tinsert(list, { name = name, icon = icon, spell = spell and SpellName(spell) and spell or nil })
            end
        end
    end
    local open = ProfessionWindowShown() and OpenProfession()
    if open then
        local known = false
        for _, p in ipairs(list) do if p.name == open then known = true end end
        for _, idx in ipairs({ fish or false, cook or false, arch or false }) do
            if not known and idx then
                local ok2, name, icon = pcall(GetProfessionInfo, idx)
                if ok2 and name == open then
                    tinsert(list, { name = name, icon = icon })
                    known = true
                end
            end
        end
    end
    return list
end

-- This character's cooldowns (recorded by the core addon), ready first,
-- then soonest.
local function MyCooldowns()
    local out, now = {}, time()
    local chars = type(ForgeGoldDB) == "table" and ForgeGoldDB.chars
    local me = type(chars) == "table" and chars[CharKey()]
    if type(me) ~= "table" or type(me.cooldowns) ~= "table" then return out end
    for id, cd in pairs(me.cooldowns) do
        if type(cd) == "table" and type(cd.readyAt) == "number" then
            tinsert(out, { id = tonumber(id), name = cd.name or "?", profession = cd.profession,
                           readyAt = cd.readyAt, ready = cd.readyAt <= now })
        end
    end
    table.sort(out, function(a, b)
        if a.ready ~= b.ready then return a.ready end
        if a.ready then return a.name < b.name end
        return a.readyAt < b.readyAt
    end)
    return out
end

local function SavePosition()
    local point, _, rel, x, y = hub:GetPoint()
    ForgesLedgerProfessionsDB.hubPos = { point, rel, x, y }
end

local Render  -- defined below

local function SelectTab(name)
    selected = name
    ForgesLedgerProfessionsDB.hubTab = name
    Render()
end

-- Secure overlays: placed over the tabs out of combat, removed when combat
-- starts (the game forbids touching them during combat).
local function DetachSecure()
    if InCombatLockdown() then return end
    for _, b in ipairs(secureTabs) do
        b:Hide()
        b:ClearAllPoints()
    end
end

local function AttachSecure()
    if InCombatLockdown() or not (hub and hub:IsShown()) then return end
    for i, tab in ipairs(hubTabs) do
        local b = secureTabs[i]
        if tab:IsShown() and tab.spell then
            if not b then
                b = CreateFrame("Button", "ForgesLedgerProfessionsTab" .. i, UIParent, "SecureActionButtonTemplate")
                -- both, so it works whichever "cast on key down" setting is on
                b:RegisterForClicks("AnyUp", "AnyDown")
                b:SetAttribute("type", "spell")
                b:HookScript("OnClick", function(self) if self.profession then SelectTab(self.profession) end end)
                b:SetFrameStrata("DIALOG")
                secureTabs[i] = b
            end
            b:SetAttribute("spell", tab.spell)
            b.profession = tab.profession
            b:ClearAllPoints()
            b:SetAllPoints(tab)
            b:Show()
        elseif b then
            b:Hide()
            b:ClearAllPoints()
        end
    end
end

local function GetTab(i)
    if hubTabs[i] then return hubTabs[i] end
    local t = CreateFrame("Button", nil, hub)
    t:SetHeight(TAB_H)
    t.bg = Line(t, "BACKGROUND", 1, 1, 1, 0.03)
    t.bg:SetAllPoints()
    t.glow = Line(t, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.14)  -- active tab wash
    t.glow:SetAllPoints()
    t.under = Line(t, "OVERLAY", GOLD[1], GOLD[2], GOLD[3], 1)   -- active underline
    t.under:SetPoint("BOTTOMLEFT")
    t.under:SetPoint("BOTTOMRIGHT")
    t.under:SetHeight(2)
    t.border = Frame(t, 0.35)
    t.icon = t:CreateTexture(nil, "OVERLAY")
    t.icon:SetSize(24, 24)
    t.icon:SetPoint("LEFT", 10, 0)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.text = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t.text:SetPoint("LEFT", t.icon, "RIGHT", 8, 0)
    t.pulse = Pulse(t.glow, 0.35)  -- a ready cooldown makes the tab breathe
    -- in combat (no secure overlay) a click just switches the panel
    t:SetScript("OnClick", function(self) SelectTab(self.profession) end)
    hubTabs[i] = t
    return t
end

local function GetTier(i)
    if hubTiers[i] then return hubTiers[i] end
    local r = CreateFrame("Frame", nil, hub.zone)
    r:SetHeight(TIER_H)
    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.label:SetPoint("LEFT", 12, 0)
    r.track = Line(r, "ARTWORK", 0, 0, 0, 0.6)
    r.track:SetSize(200, 8)
    r.track:SetPoint("LEFT", 140, 0)
    r.fill = Line(r, "OVERLAY", GOLD[1], GOLD[2], GOLD[3], 0.95)
    r.fill:SetHeight(8)
    r.fill:SetPoint("LEFT", r.track, "LEFT")
    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.value:SetPoint("RIGHT", -12, 0)
    hubTiers[i] = r
    return r
end

local function GetDot(i)
    if hubDots[i] then return hubDots[i] end
    local d = hub.zone:CreateTexture(nil, "OVERLAY")
    d:SetSize(9, 9)
    d:SetTexture(DOT)
    hubDots[i] = d
    return d
end

local function GetCard(i)
    if hubCards[i] then return hubCards[i] end
    local c = CreateFrame("Frame", nil, hub.cds)
    c:SetHeight(CARD_H)
    c.bg = Line(c, "BACKGROUND", 0, 0, 0, 0.35)
    c.bg:SetAllPoints()
    c.border = Frame(c, 0.3)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(32, 32)
    c.icon:SetPoint("LEFT", 10, 0)
    c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 10, -1)
    c.name:SetPoint("RIGHT", -8, 0)
    c.name:SetJustifyH("LEFT")
    c.name:SetWordWrap(false)
    c.state = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.state:SetPoint("BOTTOMLEFT", c.icon, "BOTTOMRIGHT", 10, 1)
    c.pulse = Pulse(c)
    hubCards[i] = c
    return c
end

local function CreateHub()
    hub = CreateFrame("Frame", "ForgesLedgerProfessionsHub", UIParent)
    hub:SetWidth(HUB_W)
    hub:SetFrameStrata("HIGH")
    hub:SetToplevel(true)
    hub:SetClampedToScreen(true)
    hub:EnableMouse(true)
    hub:SetMovable(true)
    hub:RegisterForDrag("LeftButton")
    hub:SetScript("OnDragStart", hub.StartMoving)
    hub:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    local bg = Line(hub, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4])
    bg:SetAllPoints()
    Frame(hub, 0.85)
    for i, a in ipairs({ 0.25, 0.12, 0.05 }) do  -- faint glow under the top edge
        local g = Line(hub, "BORDER", GOLD[1], GOLD[2], GOLD[3], a)
        g:SetPoint("TOPLEFT", 1, -i)
        g:SetPoint("TOPRIGHT", -1, -i)
        g:SetHeight(1)
    end
    local close = CreateFrame("Button", nil, hub, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    hub.zone = CreateFrame("Frame", nil, hub)  -- tiers of the selected profession
    hub.zone:SetPoint("TOPLEFT", 12, -(12 + TAB_H + 10))
    hub.zone:SetPoint("RIGHT", hub, "RIGHT", -12, 0)
    local zbg = Line(hub.zone, "BACKGROUND", 0, 0, 0, 0.3)
    zbg:SetAllPoints()
    Frame(hub.zone, 0.25)
    hub.maxed = hub.zone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hub.maxed:SetPoint("TOPLEFT", 12, -8)
    hub.maxed:SetTextColor(DIM[1], DIM[2], DIM[3])
    hub.note = hub.zone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hub.note:SetTextColor(DIM[1], DIM[2], DIM[3])

    hub.cds = CreateFrame("Frame", nil, hub)  -- every cooldown, as cards
    hub.cds:SetPoint("RIGHT", hub, "RIGHT", -12, 0)
    Frame(hub.cds, 0.5)
    local cbg = Line(hub.cds, "BACKGROUND", 0, 0, 0, 0.3)
    cbg:SetAllPoints()
    local clock = hub.cds:CreateTexture(nil, "OVERLAY")
    clock:SetSize(16, 16)
    clock:SetPoint("TOPLEFT", 10, -8)
    clock:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    clock:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local ch = hub.cds:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ch:SetPoint("LEFT", clock, "RIGHT", 6, 0)
    ch:SetText("Cooldowns")
    ch:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    hub.cdEmpty = hub.cds:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hub.cdEmpty:SetPoint("TOPLEFT", 12, -32)
    hub.cdEmpty:SetTextColor(DIM[1], DIM[2], DIM[3])

    hub.none = hub:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hub.none:SetTextColor(DIM[1], DIM[2], DIM[3])
    hub.none:SetText("No professions learned.")

    local pos = ForgesLedgerProfessionsDB.hubPos
    if type(pos) == "table" and type(pos[1]) == "string" then
        hub:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    else
        hub:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    hub:SetScript("OnShow", function()
        -- countdowns tick only while the panel is open
        if ticker then ticker:Cancel() end
        ticker = C_Timer.NewTicker(1, function() if hub:IsShown() then Render() end end)
        AttachSecure()
    end)
    hub:SetScript("OnHide", function()
        if ticker then ticker:Cancel(); ticker = nil end
        DetachSecure()
    end)
    tinsert(UISpecialFrames, "ForgesLedgerProfessionsHub")
    hub:Hide()
end

function Render()
    if not hub then return end
    local profs = PrimaryProfessions()
    local cds = MyCooldowns()
    local readyBy = {}
    for _, cd in ipairs(cds) do
        if cd.ready and cd.profession then readyBy[cd.profession] = true end
    end
    -- tabs
    local valid = false
    for _, p in ipairs(profs) do if p.name == selected then valid = true end end
    if not valid then
        local saved = ForgesLedgerProfessionsDB.hubTab
        selected = profs[1] and profs[1].name
        for _, p in ipairs(profs) do if p.name == saved then selected = saved end end
    end
    local x = 12
    for i, p in ipairs(profs) do
        local t = GetTab(i)
        t.profession, t.spell = p.name, p.spell
        t.icon:SetTexture(p.icon)
        t.text:SetText(p.name)
        local active = p.name == selected
        t.text:SetTextColor((active and GOLD or BONE)[1], (active and GOLD or BONE)[2], (active and GOLD or BONE)[3])
        t.text:SetAlpha(active and 1 or 0.75)
        t.under:SetShown(active)
        t.glow:SetShown(active or readyBy[p.name] == true)
        SetPulse(t.pulse, readyBy[p.name] == true)
        local w = math.ceil(t.text:GetStringWidth()) + 58
        t:SetWidth(w)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", hub, "TOPLEFT", x, -12)
        t:Show()
        x = x + w + 6
    end
    for i = #profs + 1, #hubTabs do
        hubTabs[i]:Hide()
        SetPulse(hubTabs[i].pulse, false)
    end
    hub.none:SetShown(#profs == 0)
    hub.zone:SetShown(#profs > 0)
    hub.cds:SetShown(#profs > 0 or #cds > 0)

    -- tiers of the selected profession, newest expansion first
    local zoneH = 0
    if #profs > 0 then
        local tiers = {}
        for tierName, t in pairs(CharData().data.tiers) do
            if t.profession == selected then
                tinsert(tiers, { name = t.expansion or tierName, tier = tierName, skill = t.skill or 0,
                                 max = t.maxSkill or 0, rank = ExpansionRank(t.expansion) })
            end
        end
        table.sort(tiers, function(a, b)
            if a.rank ~= b.rank then return a.rank > b.rank end
            return a.name < b.name
        end)
        local maxed = 0
        for _, t in ipairs(tiers) do if t.max > 0 and t.skill >= t.max then maxed = maxed + 1 end end
        hub.maxed:SetText(#tiers > 0 and (maxed .. " of " .. #tiers .. " expansions maxed") or "")
        -- the dot strip: one per expansion, oldest to newest, gold when maxed
        for i = 1, #tiers do
            local t = tiers[#tiers - i + 1]
            local d = GetDot(i)
            local full = t.max > 0 and t.skill >= t.max
            d:SetVertexColor(full and GOLD[1] or 0.25, full and GOLD[2] or 0.25, full and GOLD[3] or 0.25, 1)
            d:ClearAllPoints()
            d:SetPoint("TOPRIGHT", hub.zone, "TOPRIGHT", -12 - (#tiers - i) * 13, -10)
            d:Show()
        end
        for i = #tiers + 1, #hubDots do hubDots[i]:Hide() end
        -- the tier the open profession window is on gets a ">" marker
        local current = ProfessionWindowShown() and CurrentTierName()
        local y = -28
        for i, t in ipairs(tiers) do
            local r = GetTier(i)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, y)
            r:SetPoint("RIGHT", hub.zone, "RIGHT")
            local unlearned = t.skill <= 0
            local p = t.max > 0 and math.min(1, t.skill / t.max) or 0
            r.label:SetText((t.tier == current and "> " or "") .. t.name)
            r.label:SetTextColor(unlearned and DIM[1] or GOLD[1], unlearned and DIM[2] or GOLD[2], unlearned and DIM[3] or GOLD[3])
            r.value:SetText(t.max > 0 and (t.skill .. "/" .. t.max) or tostring(t.skill))
            r.value:SetTextColor(unlearned and DIM[1] or BONE[1], unlearned and DIM[2] or BONE[2], unlearned and DIM[3] or BONE[3])
            local col = (t.max > 0 and t.skill >= t.max) and GREEN or GOLD
            r.fill:SetColorTexture(col[1], col[2], col[3], 0.95)
            r.fill:SetWidth(math.max(1, 200 * p))
            r.fill:SetShown(p > 0)
            r:Show()
            y = y - TIER_H
        end
        for i = #tiers + 1, #hubTiers do hubTiers[i]:Hide() end
        hub.note:SetShown(#tiers == 0)
        if #tiers == 0 then
            hub.note:SetText("Open " .. tostring(selected) .. " once to record its expansion levels.")
            hub.note:ClearAllPoints()
            hub.note:SetPoint("TOPLEFT", 12, y - 2)
            y = y - 22
        end
        zoneH = -y + 8
        hub.zone:SetHeight(zoneH)
    end

    -- cooldown cards, two per row, ready first
    local top = 12 + TAB_H + 10 + zoneH + 12
    if #profs == 0 then
        hub.none:ClearAllPoints()
        hub.none:SetPoint("TOP", hub, "TOP", 0, -24)
        top = 56
    end
    hub.cds:ClearAllPoints()
    hub.cds:SetPoint("TOPLEFT", hub, "TOPLEFT", 12, -top)
    hub.cds:SetPoint("RIGHT", hub, "RIGHT", -12, 0)
    local now = time()
    local cardW = (HUB_W - 24 - 30) / 2
    for i, cd in ipairs(cds) do
        local c = GetCard(i)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", hub.cds, "TOPLEFT", 10 + col * (cardW + 10), -32 - row * (CARD_H + 8))
        c:SetWidth(cardW)
        c.icon:SetTexture((cd.id and SpellIcon(cd.id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
        c.name:SetText(cd.name)
        c.name:SetTextColor(BONE[1], BONE[2], BONE[3])
        if cd.ready then
            c.state:SetText("READY NOW")
            c.state:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        else
            c.state:SetText(Countdown(cd.readyAt - now))
            c.state:SetTextColor(BONE[1], BONE[2], BONE[3])
        end
        for _, e in ipairs(c.border) do  -- a ready card gets a bright gold edge
            e:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], cd.ready and 0.9 or 0.3)
        end
        SetPulse(c.pulse, cd.ready)
        if not cd.ready then c:SetAlpha(1) end
        c:Show()
    end
    for i = #cds + 1, #hubCards do
        hubCards[i]:Hide()
        SetPulse(hubCards[i].pulse, false)
    end
    hub.cdEmpty:SetShown(#cds == 0)
    hub.cdEmpty:SetText("No cooldowns tracked yet - one shows up after you use it.")
    local rows = math.ceil(#cds / 2)
    local cdsH = #cds > 0 and (32 + rows * (CARD_H + 8) + 2) or 54
    hub.cds:SetHeight(cdsH)
    hub:SetHeight(top + (hub.cds:IsShown() and cdsH or 0) + 14)
end

-- Open with the same motion as the bar's hover cards: fade in while
-- easing up 6px, ~150ms, then the OnUpdate removes itself.
local function ShowHub()
    if not hub then CreateHub() end
    Render()
    if hub:IsShown() then return end
    local point, rel, relPoint, x, y = hub:GetPoint()
    local t = 0
    hub:SetAlpha(0)
    hub:Show()
    hub:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        local f = math.min(1, t / 0.15)
        self:SetAlpha(f)
        self:ClearAllPoints()
        self:SetPoint(point, rel, relPoint, x, y - 6 * (1 - f))
        if f >= 1 then self:SetScript("OnUpdate", nil) end
    end)
end

local function ToggleHub()
    if hub and hub:IsShown() then
        hub:Hide()
        return false
    end
    ShowHub()
    hub.auto = false  -- opened by hand: stays open when a profession window closes
    return true
end

-- With a profession window: open on its tab, close with it - unless the
-- panel was already open by hand. /flp panel turns this off.
AutoOpenHub = function()
    if ForgesLedgerProfessionsDB.hidePanel then return end
    local open = OpenProfession()
    local wasShown = hub and hub:IsShown()
    if open then
        selected = open
        ForgesLedgerProfessionsDB.hubTab = open
    end
    ShowHub()
    if not wasShown then hub.auto = true end
end

AutoCloseHub = function()
    if hub and hub:IsShown() and hub.auto then hub:Hide() end
    RefreshHub()  -- drops a Fishing/Cooking tab once its window closes
end

-- combat: overlays off when it starts, back on when it ends
local hubEvents = CreateFrame("Frame")
hubEvents:RegisterEvent("PLAYER_REGEN_DISABLED")
hubEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
hubEvents:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- fires just before combat lockdown starts, so this is still allowed
        for _, b in ipairs(secureTabs) do
            b:Hide()
            b:ClearAllPoints()
        end
    else
        AttachSecure()
    end
end)

RefreshHub = function()
    if hub and hub:IsShown() then
        Render()
        AttachSecure()
    end
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
        -- a click opens the Ledger panel (core v2.7+); /fl professions too (v2.8+)
        onClick = function() ToggleHub() end,
        open = function(toggle)
            if toggle then return ToggleHub() end
            ShowHub()
            return true
        end,
        -- older cores (v2.5-2.6) open this simple list instead
        window = { title = "Professions", lines = BarWindowLines },
    })
end

---------------------------------------------------------------- /flp ---

SLASH_FORGESLEDGERPROF1 = "/flp"
SlashCmdList["FORGESLEDGERPROF"] = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "panel" then
        -- (this used to toggle the old side panel; same setting, new panel)
        ForgesLedgerProfessionsDB.hidePanel = not ForgesLedgerProfessionsDB.hidePanel
        print(PREFIX .. "The panel " .. (ForgesLedgerProfessionsDB.hidePanel
            and "won't open with profession windows. /flp open still opens it."
            or "opens with profession windows."))
    elseif cmd == "open" then
        ToggleHub()
    elseif cmd == "tabs" then
        -- what the quick-open tabs will cast, straight from the game
        local profs = PrimaryProfessions()
        if #profs == 0 then print(PREFIX .. "No primary professions learned.") end
        for _, p in ipairs(profs) do
            print(PREFIX .. p.name .. ": " .. (p.spell and ("opens with spell " .. p.spell .. " (" .. tostring(SpellName(p.spell)) .. ")")
                or "no spell found - the tab switches the panel but can't open the window"))
        end
    elseif cmd == "scan" then
        Scan()
        local n = 0
        for _ in pairs(CharData().data.tiers) do n = n + 1 end
        print(PREFIX .. n .. " profession tiers recorded for this character.")
        -- what the game itself reported, so a missing tier can be told apart
        -- from one the addon dropped
        print(PREFIX .. "The game listed " .. lastSeen.lines .. " profession lines, "
              .. lastSeen.tiers .. " of them expansion tiers.")
        RefreshHub()
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /flp open - open the Ledger panel (tiers and cooldowns)")
        print("  /flp panel - open the panel with profession windows, or not")
        print("  /flp tabs - list the spell each profession tab opens")
        print("  /flp scan - re-read your profession skills now")
    end
end
