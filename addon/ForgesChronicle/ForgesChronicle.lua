-- Forge's Chronicle v1.0 (retail and WoW Forever)
-- An automatic adventure journal. It watches your character's journey and
-- writes the memorable parts into a timeline - you never have to write an
-- entry, though you can add your own words to any of them, or delete one.
--
-- What gets written (every entry comes from a game event it saw happen):
--   * firsts - journaled, with a screenshot: first dungeon, first raid boss,
--     first battleground win, first epic and first legendary item, reaching
--     max level, joining a guild for the first time. First death is
--     journaled without one (it can be switched off).
--   * milestones - journaled, no screenshot unless you turn it on: every
--     10 levels, each new dungeon and raid boss, a new guild, and (on a
--     character that started its chronicle at the beginning) each zone
--     discovered.
--   * repeats - only counted, for the recap: more deaths, more dungeon runs.
-- Never tracked: chat, other players, anything outside your own journey.
--
-- A character that already existed when the addon was installed starts its
-- chronicle "today" with an opening entry that says earlier deeds went
-- unrecorded - so a "first" in its journal means the first one since then,
-- never a guess about the past.
--
-- Screenshots use the game's own screenshot (the same as the Print Screen
-- key): the game names and saves the file in its Screenshots folder; the
-- journal notes the time it was taken.
--
-- Rules it follows: works on its own (no other addon needed); every game
-- call is checked to exist and pcall-guarded, since retail and Forever have
-- different functions; one save file per account with a "characters" list;
-- no work every frame.

local VERSION = "1.0"
local SCHEMA = 1
local PREFIX = "|cffFFD700[Forge's Chronicle]|r "
local DEFAULT_TITLE = "Forge's Chronicle"

local IS_RETAIL = not (WOW_PROJECT_ID and WOW_PROJECT_MAINLINE) or WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
local GAME = IS_RETAIL and "Retail" or "Forever"

ForgesChronicleDB = ForgesChronicleDB or {}

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
    realm = realm:gsub("[%s%'%-]", "")  -- same key style as Forge's Ledger
    return (name or "Unknown") .. "-" .. realm
end

local function Settings()
    local db = ForgesChronicleDB
    local s = type(db.settings) == "table" and db.settings or {}
    db.settings = s
    if s.hideInCombat == nil then s.hideInCombat = true end
    if s.firstDeath == nil then s.firstDeath = true end
    if s.shotFirsts == nil then s.shotFirsts = true end
    if s.shotMilestones == nil then s.shotMilestones = false end
    if s.minimap == nil then s.minimap = true end
    s.scale = tonumber(s.scale) or 1
    s.alpha = tonumber(s.alpha) or 1
    s.angle = tonumber(s.angle) or 200
    return s
end

-- "Forge's Chronicle", or "Bob's Chronicles" once a name is set: the
-- journey is the player's, so the journal can carry their name.
local function JournalTitle()
    local n = Settings().ownerName
    if type(n) == "string" then n = strtrim(n) end
    if not n or n == "" then return DEFAULT_TITLE end
    return n .. "'s Chronicles"
end

local function Level() return Plain(Try(UnitLevel, "player")) or 0 end
local function Zone() return Plain(Try(GetRealZoneText)) or Plain(Try(GetZoneText)) or "" end
local function MaxLevel()
    return Plain(Try(GetMaxLevelForPlayerExpansion)) or Plain(Try(GetMaxPlayerLevel)) or (IS_RETAIL and 90 or 60)
end
local function InInstance()
    local inside, kind = Try(IsInInstance)
    return inside and true or false, kind
end

------------------------------------------------------------- save data ---

local c  -- this character's record, set on login

local function CharData()
    local db = ForgesChronicleDB
    db.schemaVersion = SCHEMA
    db.version = GAME
    db.characters = type(db.characters) == "table" and db.characters or {}
    local key = CharKey()
    local rec = type(db.characters[key]) == "table" and db.characters[key] or { data = {} }
    rec.character = key
    local d = type(rec.data) == "table" and rec.data or {}
    rec.data = d
    d.entries = type(d.entries) == "table" and d.entries or {}
    d.firsts = type(d.firsts) == "table" and d.firsts or {}
    d.counts = type(d.counts) == "table" and d.counts or {}
    d.counts.runs = type(d.counts.runs) == "table" and d.counts.runs or {}
    d.zones = type(d.zones) == "table" and d.zones or {}          -- zone -> true (seen)
    d.zoneTime = type(d.zoneTime) == "table" and d.zoneTime or {}  -- zone -> seconds
    d.items = type(d.items) == "table" and d.items or {}          -- epic+ itemIDs already seen
    d.bosses = type(d.bosses) == "table" and d.bosses or {}       -- "instance|boss" -> true
    d.instances = type(d.instances) == "table" and d.instances or {}
    d.levelUps = type(d.levelUps) == "table" and d.levelUps or {} -- [level] = time
    d.nextId = tonumber(d.nextId) or 1
    db.characters[key] = rec
    return rec
end

local function Touch() if c then c.exportedAt = time() end end

------------------------------------------------------------ screenshots ---

local loading, pendingShot = false, nil

local function CinematicPlaying()
    if Try(InCinematic) then return true end
    if CinematicFrame and CinematicFrame:IsShown() then return true end
    if MovieFrame and MovieFrame:IsShown() then return true end
    return false
end

-- A moment later (so the level-up glow or loot window is on screen), and
-- never during a cutscene or loading screen: tries again a few times, then
-- lets it go - the entry is written either way.
local function Capture(entry, tries)
    tries = tries or 0
    C_Timer.After(tries == 0 and 1 or 2, function()
        if loading or CinematicPlaying() then
            if tries < 5 then Capture(entry, tries + 1) end
            return
        end
        if type(Screenshot) ~= "function" then return end
        pendingShot = entry
        if not pcall(Screenshot) then pendingShot = nil end
    end)
end

---------------------------------------------------------------- entries ---

local RefreshJournal = function() end  -- set by the journal window below

local ICONS = {
    begin = "Interface\\Icons\\INV_Misc_Book_09",
    level = "Interface\\Icons\\Spell_Holy_SurgeOfLight",
    death = "Interface\\Icons\\Ability_Rogue_FeignDeath",
    loot = "Interface\\Icons\\INV_Misc_Bag_10",
    zone = "Interface\\Icons\\INV_Misc_Map_01",
    dungeon = "Interface\\Icons\\INV_Misc_Key_03",
    raid = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    pvp = "Interface\\Icons\\INV_BannerPVP_02",
    guild = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
}

-- tier: "first" (the big moments) or "milestone"
local function Write(kind, tier, title, text, extra)
    if not c then return end
    local d = c.data
    local e = { id = d.nextId, at = time(), kind = kind, tier = tier, title = title, text = text,
                level = Level(), zone = Zone(), icon = ICONS[kind] }
    for k, v in pairs(extra or {}) do e[k] = v end
    d.nextId = d.nextId + 1
    tinsert(d.entries, e)
    Touch()
    local s = Settings()
    if (tier == "first" and s.shotFirsts) or (tier == "milestone" and s.shotMilestones) then
        if not e.noShot then Capture(e) end
    end
    if tier == "first" then print(PREFIX .. "A new page: " .. title) end
    RefreshJournal()
    return e
end

local function FindEntry(id)
    for i, e in ipairs(c and c.data.entries or {}) do
        if e.id == id then return e, i end
    end
end

-------------------------------------------------------------- detectors ---

local function PlayerName() return Plain(Try(UnitName, "player")) or "our hero" end

-- A character followed from the start gets real firsts; one picked up
-- mid-journey gets the chronicle's firsts (its true firsts are unknown).
local function First(what)
    return (c.data.fromStart and "First " or "Chronicle's first ") .. what
end

-- First sight of this character: the opening page.
local function Begin()
    local d = c.data
    if d.started then return end
    local lvl = Level()
    d.started = time()
    d.fromStart = lvl <= 5  -- anything before level 5 is barely a journey yet
    local race = Plain(Try(UnitRace, "player")) or ""
    local class = Plain(Try(UnitClass, "player")) or ""
    local who = PlayerName() .. ", " .. strtrim(race .. " " .. class)
    local zone = Zone()
    local text
    if d.fromStart then
        text = who .. ", takes the first step" .. (zone ~= "" and (" in " .. zone) or "") .. "."
    else
        text = who .. ", level " .. lvl .. (zone ~= "" and (", in " .. zone) or "")
            .. ". The chronicle begins here - earlier deeds went unrecorded."
    end
    if zone ~= "" then d.zones[zone] = true end
    Write("begin", "milestone", "The chronicle begins", text, { noShot = true })
end

-- level-ups: every 10 levels, and the top
local function OnLevel(lvl)
    lvl = tonumber(Plain(lvl)) or Level()
    local d = c.data
    d.levelUps[lvl] = d.levelUps[lvl] or time()
    if lvl >= MaxLevel() and not d.firsts.maxLevel then
        d.firsts.maxLevel = time()
        Write("level", "first", "Level " .. lvl .. " - the top",
            PlayerName() .. " reached level " .. lvl .. ", as high as this world allows.")
    elseif lvl % 10 == 0 then
        Write("level", "milestone", "Level " .. lvl, PlayerName() .. " reached level " .. lvl .. ".")
    end
end

local function OnDeath()
    local d = c.data
    d.counts.deaths = (tonumber(d.counts.deaths) or 0) + 1
    Touch()
    if d.firsts.death then return end
    d.firsts.death = time()
    if not Settings().firstDeath then return end
    local zone = Zone()
    Write("death", "first", First("death"),
        "Here fell " .. PlayerName() .. (zone ~= "" and (", in " .. zone) or "") .. ". Not the last time, probably.",
        { noShot = true })
end

-- zones: discoveries for a character followed from the start; time spent
-- everywhere (for the recap's favourite zone)
local zoneNow, zoneSince
local function ZoneClock()
    if zoneNow and zoneSince then
        c.data.zoneTime[zoneNow] = (tonumber(c.data.zoneTime[zoneNow]) or 0) + math.max(0, time() - zoneSince)
    end
    local z = Zone()
    zoneNow, zoneSince = (z ~= "" and z or nil), time()
end

-- the current dungeon/raid run: bosses beaten since entering
local run

local function OnZone()
    ZoneClock()
    local inside, kind = InInstance()
    local name = Plain(Try(GetInstanceInfo))
    if not inside or (run and run.instance ~= name) then run = nil end
    if inside then return end
    local zone = Zone()
    local d = c.data
    if zone == "" or d.zones[zone] then return end
    d.zones[zone] = true
    Touch()
    if d.fromStart then
        Write("zone", "milestone", "Discovered " .. zone, PlayerName() .. " set foot in " .. zone .. " for the first time.")
    end
end

local function OnBossKill(encounterName, success)
    if Plain(success) ~= 1 and Plain(success) ~= true then return end
    local name, kind = Try(GetInstanceInfo)
    name, kind = Plain(name), Plain(kind)
    local boss = Plain(encounterName)
    if not name or not boss or (kind ~= "party" and kind ~= "raid") then return end
    local d = c.data
    local key = name .. "|" .. boss
    local newBoss = not d.bosses[key]
    d.bosses[key] = true
    d.counts.bossKills = (tonumber(d.counts.bossKills) or 0) + 1
    Touch()
    if kind == "raid" then
        if not d.firsts.raidBoss then
            d.firsts.raidBoss = time()
            Write("raid", "first", First("raid boss: ") .. boss, PlayerName() .. " helped bring down " .. boss .. " in " .. name .. ".")
        elseif newBoss then
            Write("raid", "milestone", boss .. " defeated", "First victory over " .. boss .. " in " .. name .. ".")
        end
        return
    end
    -- dungeons: one entry for the first run of each, updated as bosses fall
    if not run or run.instance ~= name then
        run = { instance = name, bosses = {} }
        d.counts.runs[name] = (tonumber(d.counts.runs[name]) or 0) + 1
        if not d.instances[name] then
            d.instances[name] = time()
            local first = not d.firsts.dungeon
            if first then d.firsts.dungeon = time() end
            run.entry = Write("dungeon", first and "first" or "milestone",
                (first and First("dungeon: ") or "First run: ") .. name, "", { instance = name })
        end
    end
    tinsert(run.bosses, boss)
    if run.entry then
        run.entry.text = PlayerName() .. " fought through " .. name .. ". Defeated: " .. table.concat(run.bosses, ", ") .. "."
        RefreshJournal()
    end
end

-- dungeon finder completion (retail): the run counts as cleared
local function OnDungeonDone()
    if run and run.entry and not run.entry.cleared then
        run.entry.cleared = true
        run.entry.text = run.entry.text .. " Cleared."
        RefreshJournal()
    end
end

-- battlegrounds: the first win
local bgDone = false
local function OnBattlefield()
    local _, kind = Try(GetInstanceInfo)
    if Plain(kind) ~= "pvp" then bgDone = false return end
    local winner = Plain(Try(GetBattlefieldWinner))
    if winner == nil or bgDone then return end
    bgDone = true
    local mine = (Plain(Try(UnitFactionGroup, "player")) == "Horde") and 0 or 1
    if winner ~= mine then return end
    local d = c.data
    d.counts.bgWins = (tonumber(d.counts.bgWins) or 0) + 1
    Touch()
    if d.firsts.bgWin then return end
    d.firsts.bgWin = time()
    local name = Plain(Try(GetInstanceInfo)) or "the battleground"
    Write("pvp", "first", First("battleground win"), PlayerName() .. " fought on the winning side in " .. name .. ".")
end

-- guilds: joining one (the very first is a big moment)
local loginAt = 0
local function OnGuild(silent)
    -- the guild's name arrives a few seconds after login: that's the game
    -- catching up, not a join
    silent = silent or (time() - loginAt) < 15
    if not Try(IsInGuild) then
        if not silent then c.data.guild = nil end  -- left; only trust a real update, not a loading blip
        return
    end
    local g = Plain(Try(GetGuildInfo, "player"))
    if not g or g == c.data.guild then return end
    c.data.guild = g
    Touch()
    if silent then
        -- already in a guild when the chronicle began: not news
        if not c.data.fromStart then
            c.data.firsts.guild = c.data.firsts.guild or time()
            return
        end
    end
    if not c.data.firsts.guild then
        c.data.firsts.guild = time()
        Write("guild", "first", "Joined " .. g, PlayerName() .. " joined the guild " .. g .. ". The first of many friends.")
    else
        Write("guild", "milestone", "Joined " .. g, PlayerName() .. " joined the guild " .. g .. ".")
    end
end

-- items: the first epic, the first legendary (bags and what's worn)
local EPIC, LEGENDARY, HEIRLOOM = 4, 5, 7

local function EachItem(fn)
    local C = C_Container
    local numSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
    local bags = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, bags do
        for slot = 1, tonumber(Try(numSlots, bag)) or 0 do
            local id, q, link, icon
            if C and C.GetContainerItemInfo then
                local info = Try(C.GetContainerItemInfo, bag, slot)
                if type(info) == "table" then id, q, link, icon = info.itemID, info.quality, info.hyperlink, info.iconFileID end
            elseif GetContainerItemInfo then
                local tex, _, _, quality, _, _, l, _, _, itemID = Try(GetContainerItemInfo, bag, slot)
                id, q, link, icon = itemID, quality, l, tex
            end
            if id then fn(id, q, link, icon) end
        end
    end
    for slot = 1, 19 do
        local id = Try(GetInventoryItemID, "player", slot)
        if id then
            fn(id, Try(GetInventoryItemQuality, "player", slot), Try(GetInventoryItemLink, "player", slot),
               Try(GetInventoryItemTexture, "player", slot))
        end
    end
end

local function ItemNameFromLink(link)
    return type(link) == "string" and link:match("%[(.-)%]") or nil
end

local function ScanItems()
    local d = c.data
    local baseline = not d.itemsBaselined  -- first look: what you already own isn't news
    EachItem(function(id, q, link, icon)
        q = tonumber(Plain(q))
        if not q or q < EPIC or q == HEIRLOOM or d.items[id] then return end
        d.items[id] = true
        -- only for a character followed from the start: on one picked up
        -- mid-journey, an old epic fetched from the bank would look new
        if baseline or not d.fromStart then return end
        local name = ItemNameFromLink(Plain(link)) or ("item " .. id)
        if q >= LEGENDARY and not d.firsts.legendary then
            d.firsts.legendary = time()
            Write("loot", "first", "First legendary: " .. name, PlayerName() .. " now carries " .. name .. ".", { icon = icon or ICONS.loot })
        elseif q == EPIC and not d.firsts.epic then
            d.firsts.epic = time()
            Write("loot", "first", "First epic: " .. name, PlayerName() .. " found " .. name .. ".", { icon = icon or ICONS.loot })
        else
            d.counts.epics = (tonumber(d.counts.epics) or 0) + 1
        end
    end)
    d.itemsBaselined = true
    Touch()
end

local itemScanQueued = false
local function QueueItemScan()
    if itemScanQueued then return end
    itemScanQueued = true
    C_Timer.After(0.5, function() itemScanQueued = false; if c then ScanItems() end end)
end

----------------------------------------------------------------- export ---

local function Day(t) return date("%b %d", t) end

local function Duration(s)
    s = math.floor(s or 0)
    local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

local function Header()
    local class = Plain(Try(UnitClass, "player")) or ""
    return JournalTitle() .. " - " .. PlayerName() .. ", level " .. Level() .. " " .. class .. " (" .. GAME .. ")"
end

-- The recap: the top moments and the numbers, ready to paste anywhere.
local function Recap()
    if not c then return "" end
    ZoneClock()
    local d = c.data
    local out = { Header() }
    if d.started then
        local days = math.max(1, math.floor((time() - d.started) / 86400) + 1)
        tinsert(out, "Since " .. date("%b %d, %Y", d.started) .. " - " .. days .. (days == 1 and " day" or " days"))
    end
    tinsert(out, "")
    -- top 10: the firsts, then the latest milestones, in order
    local firsts, rest = {}, {}
    for _, e in ipairs(d.entries) do tinsert(e.tier == "first" and firsts or rest, e) end
    local pick = {}
    for _, e in ipairs(firsts) do if #pick < 10 then tinsert(pick, e) end end
    for i = #rest, 1, -1 do if #pick < 10 then tinsert(pick, rest[i]) end end
    table.sort(pick, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
    if #pick > 0 then
        tinsert(out, "Top moments")
        for i, e in ipairs(pick) do
            tinsert(out, "  " .. i .. ". " .. Day(e.at) .. " - " .. e.title .. (e.note and (" - \"" .. e.note .. "\"") or ""))
        end
        tinsert(out, "")
    end
    local curve = {}
    local lv = {}
    for l in pairs(d.levelUps) do tinsert(lv, l) end
    table.sort(lv)
    for _, l in ipairs(lv) do
        if l % 10 == 0 or l >= MaxLevel() then tinsert(curve, l .. " on " .. Day(d.levelUps[l])) end
    end
    if #curve > 0 then tinsert(out, "Level curve: " .. table.concat(curve, ", ")) end
    tinsert(out, "Deaths: " .. (tonumber(d.counts.deaths) or 0))
    local fav, favT
    for z, t in pairs(d.zoneTime) do if not favT or t > favT then fav, favT = z, t end end
    if fav then tinsert(out, "Favourite zone: " .. fav .. " (" .. Duration(favT) .. ")") end
    local runs = {}
    for name, n in pairs(d.counts.runs) do tinsert(runs, { name = name, n = n }) end
    table.sort(runs, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    if #runs > 0 then
        local parts = {}
        for i = 1, math.min(5, #runs) do parts[i] = runs[i].name .. (runs[i].n > 1 and (" x" .. runs[i].n) or "") end
        tinsert(out, "Dungeons: " .. table.concat(parts, ", "))
    end
    if (tonumber(d.counts.bgWins) or 0) > 0 then tinsert(out, "Battleground wins: " .. d.counts.bgWins) end
    tinsert(out, "")
    tinsert(out, "Written by Forge's Chronicle")
    return table.concat(out, "\n")
end

-- The full timeline, oldest first, for blogs and video descriptions.
local function Timeline()
    if not c then return "" end
    local out = { Header(), "" }
    for _, e in ipairs(c.data.entries) do
        tinsert(out, date("%b %d, %Y", e.at) .. " - level " .. (e.level or "?") .. (e.zone and e.zone ~= "" and (" - " .. e.zone) or ""))
        tinsert(out, e.title)
        if e.text and e.text ~= "" then tinsert(out, e.text) end
        if e.note then tinsert(out, "\"" .. e.note .. "\"") end
        tinsert(out, "")
    end
    tinsert(out, "Written by Forge's Chronicle")
    return table.concat(out, "\n")
end

---------------------------------------------------------------- journal ---
-- A journal-style window: dark iron frame, parchment pages. Timeline on
-- the left (newest first, grouped by level band), the chosen entry on the
-- right with its note. Settings and the recap take over the right page.

local W, H, ROW_H, ROWS = 680, 470, 22, 16
local IRON = { 0.06, 0.06, 0.08, 0.97 }
local GOLD = { 0.90, 0.75, 0.25 }
local PAPER = { 0.80, 0.72, 0.55, 1 }
local INK = { 0.22, 0.15, 0.08 }
local FADED = { 0.42, 0.33, 0.22 }

local journal, rows, offset, selectedId, view = nil, {}, 0, nil, "entry"
local UpdateMinimap  -- set with the minimap button below

local function Tex(parent, layer, col)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    return t
end

local function Border(f, a)
    for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 1 },
                         { "TOPLEFT", "BOTTOMLEFT", nil }, { "TOPRIGHT", "BOTTOMRIGHT", nil } }) do
        local t = Tex(f, "BORDER", { GOLD[1], GOLD[2], GOLD[3], a or 0.8 })
        t:SetPoint(p[1])
        t:SetPoint(p[2])
        if p[3] then t:SetHeight(1) else t:SetWidth(1) end
    end
end

local function Btn(parent, label, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 70, 20)
    b.bg = Tex(b, "BACKGROUND", { GOLD[1], GOLD[2], GOLD[3], 0.14 })
    b.bg:SetAllPoints()
    local hl = Tex(b, "HIGHLIGHT", { 1, 1, 1, 0.10 })
    hl:SetAllPoints()
    Border(b, 0.5)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    return b
end

local function Ink(fs, col) col = col or INK; fs:SetTextColor(col[1], col[2], col[3]) end

-- the timeline as rows: band headers and entries, newest first
local function RowModel()
    local list, lastBand = {}, nil
    local entries = c and c.data.entries or {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        local band = math.floor((tonumber(e.level) or 0) / 10)
        if band ~= lastBand then
            lastBand = band
            tinsert(list, { header = band == 0 and "Levels 1 - 9" or ("Levels " .. band * 10 .. " - " .. band * 10 + 9) })
        end
        tinsert(list, { entry = e })
    end
    return list
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, journal.list)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", journal.list, "TOPLEFT", 4, -6 - (i - 1) * ROW_H)
    r:SetPoint("RIGHT", journal.list, "RIGHT", -4, 0)
    r.sel = Tex(r, "BACKGROUND", { INK[1], INK[2], INK[3], 0.15 })
    r.sel:SetAllPoints()
    local hl = Tex(r, "HIGHLIGHT", { INK[1], INK[2], INK[3], 0.08 })
    hl:SetAllPoints()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 6, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.date = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.date:SetPoint("LEFT", 28, 0)
    r.date:SetWidth(46)
    r.date:SetJustifyH("LEFT")
    r.title = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.title:SetPoint("LEFT", 76, 0)
    r.title:SetPoint("RIGHT", -4, 0)
    r.title:SetJustifyH("LEFT")
    r.title:SetWordWrap(false)
    r:SetScript("OnClick", function(self)
        if self.entryId then selectedId, view = self.entryId, "entry"; RefreshJournal() end
    end)
    rows[i] = r
    return r
end

local function RenderList()
    local model = RowModel()
    offset = math.max(0, math.min(offset, #model - ROWS))
    for i = 1, ROWS do
        local m, r = model[offset + i], GetRow(i)
        if not m then
            r:Hide()
        elseif m.header then
            r.entryId = nil
            r.icon:Hide()
            r.date:SetText("")
            r.title:SetText(m.header)
            r.title:SetFontObject("GameFontNormal")
            Ink(r.title, { 0.55, 0.38, 0.10 })
            r.sel:Hide()
            r:Show()
        else
            local e = m.entry
            r.entryId = e.id
            r.icon:SetTexture(e.icon or ICONS[e.kind] or ICONS.begin)
            r.icon:Show()
            r.date:SetText(Day(e.at))
            Ink(r.date, FADED)
            r.title:SetText(e.title)
            r.title:SetFontObject(e.tier == "first" and "GameFontNormal" or "GameFontHighlightSmall")
            Ink(r.title, e.tier == "first" and { 0.45, 0.20, 0.05 } or INK)
            r.sel:SetShown(e.id == selectedId)
            r:Show()
        end
    end
    journal.empty:SetShown(#model == 0)
end

local function RenderEntry()
    local p = journal.page
    local e = selectedId and FindEntry(selectedId)
    if not e then
        local entries = c and c.data.entries or {}
        e = entries[#entries]
        selectedId = e and e.id
    end
    p.entry:SetShown(e ~= nil)
    if not e then return end
    p.title:SetText(e.title)
    p.meta:SetText(date("%B %d, %Y  %H:%M", e.at) .. "  -  level " .. tostring(e.level or "?")
        .. (e.zone and e.zone ~= "" and ("  -  " .. e.zone) or ""))
    p.body:SetText(e.text or "")
    p.shot:SetText(e.shot and ("Screenshot taken " .. date("%H:%M:%S", e.shot) .. " - in your WoW Screenshots folder.") or "")
    p.note.entryId = e.id
    p.note:SetText(e.note or "")
    p.delete.armed = false
    p.delete.text:SetText("Delete")
end

local function ShowView()
    local p = journal.page
    p.entry:SetShown(view == "entry")
    journal.settings:SetShown(view == "settings")
    journal.recap:SetShown(view == "recap")
end

local function RenderSettings()
    local s, sp = Settings(), journal.settings
    sp.preview:SetText("Title: " .. JournalTitle())
    for _, t in ipairs(sp.toggles) do
        local on = s[t.key] and true or false
        t.btn.text:SetText(on and "On" or "Off")
        t.btn.bg:SetAlpha(on and 1 or 0.4)
    end
    sp.scale:SetText(math.floor(s.scale * 100 + 0.5) .. "%")
    sp.alpha:SetText(math.floor(s.alpha * 100 + 0.5) .. "%")
end

local RenderRecap

RefreshJournal = function()
    if not (journal and journal:IsShown()) then return end
    journal.title:SetText(JournalTitle())
    journal.sub:SetText(PlayerName() .. "  -  level " .. Level() .. "  -  " .. GAME)
    RenderList()
    ShowView()
    if view == "entry" then RenderEntry() end
    if view == "settings" then RenderSettings() end
    if view == "recap" then RenderRecap() end
end

local function ApplyLook()
    if not journal then return end
    local s = Settings()
    journal:SetScale(s.scale)
    journal:SetAlpha(s.alpha)
end

local function EditBox(parent, multi)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetAutoFocus(false)
    e:SetFontObject("GameFontHighlight")
    e:SetMultiLine(multi and true or false)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

local function CreateJournal()
    local s = Settings()
    journal = CreateFrame("Frame", "ForgesChronicleJournal", UIParent)
    journal:SetSize(W, H)
    if s.pos then
        journal:SetPoint(s.pos[1], UIParent, s.pos[1], s.pos[2], s.pos[3])
    else
        journal:SetPoint("CENTER")
    end
    journal:SetFrameStrata("HIGH")
    journal:SetToplevel(true)
    journal:SetClampedToScreen(true)
    journal:EnableMouse(true)
    journal:SetMovable(true)
    journal:RegisterForDrag("LeftButton")
    journal:SetScript("OnDragStart", journal.StartMoving)
    journal:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        Settings().pos = { point, x, y }
    end)
    tinsert(UISpecialFrames, "ForgesChronicleJournal")  -- Escape closes it
    local bg = Tex(journal, "BACKGROUND", IRON)
    bg:SetAllPoints()
    Border(journal, 0.85)

    journal.title = journal:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    journal.title:SetPoint("TOPLEFT", 16, -12)
    journal.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    journal.sub = journal:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    journal.sub:SetPoint("TOPLEFT", 16, -32)
    journal.sub:SetTextColor(0.7, 0.7, 0.7)
    local close = CreateFrame("Button", nil, journal, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    local gear = Btn(journal, "Settings", 70)
    gear:SetPoint("TOPRIGHT", -34, -14)
    gear:SetScript("OnClick", function() view = view == "settings" and "entry" or "settings"; RefreshJournal() end)
    local recapB = Btn(journal, "Recap", 60)
    recapB:SetPoint("RIGHT", gear, "LEFT", -6, 0)
    recapB:SetScript("OnClick", function()
        view = view == "recap" and "entry" or "recap"
        RefreshJournal()
        if view == "recap" then RenderRecap(true) end
    end)

    -- left page: the timeline
    journal.list = CreateFrame("Frame", nil, journal)
    journal.list:SetPoint("TOPLEFT", 12, -54)
    journal.list:SetPoint("BOTTOMLEFT", 12, 12)
    journal.list:SetWidth(300)
    Tex(journal.list, "BACKGROUND", PAPER):SetAllPoints()
    Border(journal.list, 0.35)
    journal.list:EnableMouseWheel(true)
    journal.list:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 3)
        RenderList()
    end)
    journal.empty = journal.list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    journal.empty:SetPoint("TOPLEFT", 14, -14)
    journal.empty:SetPoint("RIGHT", -14, 0)
    journal.empty:SetJustifyH("LEFT")
    journal.empty:SetText("The first page is still blank. Go and do something worth writing down.")
    Ink(journal.empty, FADED)

    -- right page: the entry (settings and recap share it)
    local page = CreateFrame("Frame", nil, journal)
    page:SetPoint("TOPLEFT", journal.list, "TOPRIGHT", 10, 0)
    page:SetPoint("BOTTOMRIGHT", -12, 12)
    Tex(page, "BACKGROUND", PAPER):SetAllPoints()
    Border(page, 0.35)
    journal.page = page

    local ent = CreateFrame("Frame", nil, page)
    ent:SetAllPoints()
    page.entry = ent
    page.title = ent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    page.title:SetPoint("TOPLEFT", 16, -16)
    page.title:SetPoint("RIGHT", -16, 0)
    page.title:SetJustifyH("LEFT")
    Ink(page.title, { 0.45, 0.20, 0.05 })
    page.meta = ent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.meta:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -6)
    Ink(page.meta, FADED)
    page.body = ent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    page.body:SetPoint("TOPLEFT", page.meta, "BOTTOMLEFT", 0, -12)
    page.body:SetPoint("RIGHT", -16, 0)
    page.body:SetJustifyH("LEFT")
    Ink(page.body)
    page.shot = ent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.shot:SetPoint("TOPLEFT", page.body, "BOTTOMLEFT", 0, -10)
    page.shot:SetPoint("RIGHT", -16, 0)
    page.shot:SetJustifyH("LEFT")
    Ink(page.shot, FADED)
    local label = ent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", 16, 150)
    label:SetText("Your own words (optional)")
    Ink(label, FADED)
    local box = CreateFrame("Frame", nil, ent)
    box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    box:SetPoint("RIGHT", -16, 0)
    box:SetHeight(96)
    Tex(box, "BACKGROUND", { 1, 1, 1, 0.25 }):SetAllPoints()
    Border(box, 0.3)
    page.note = EditBox(box, true)
    page.note:SetPoint("TOPLEFT", 6, -6)
    page.note:SetPoint("BOTTOMRIGHT", -6, 6)
    page.note:SetMaxLetters(500)
    page.note:SetTextColor(INK[1], INK[2], INK[3])
    page.note:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local e = self.entryId and FindEntry(self.entryId)
        if not e then return end
        local t = strtrim(self:GetText() or "")
        e.note = t ~= "" and t or nil
        Touch()
    end)
    box:SetScript("OnMouseDown", function() page.note:SetFocus() end)
    page.delete = Btn(ent, "Delete", 120)
    page.delete:SetPoint("BOTTOMRIGHT", -16, 16)
    page.delete:SetScript("OnClick", function(self)
        -- two clicks: a stray click never loses a page
        if not self.armed then
            self.armed = true
            self.text:SetText("Click again to delete")
            return
        end
        local _, i = FindEntry(selectedId)
        if i then tremove(c.data.entries, i); Touch() end
        selectedId = nil
        RefreshJournal()
    end)

    -- settings
    local sp = CreateFrame("Frame", nil, page)
    sp:SetAllPoints()
    journal.settings = sp
    local st = sp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    st:SetPoint("TOPLEFT", 16, -16)
    st:SetText("Settings")
    Ink(st, { 0.45, 0.20, 0.05 })
    local nl = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nl:SetPoint("TOPLEFT", 16, -48)
    nl:SetText("Your name for the journal (leave empty for \"" .. DEFAULT_TITLE .. "\")")
    Ink(nl, FADED)
    local nbox = CreateFrame("Frame", nil, sp)
    nbox:SetPoint("TOPLEFT", 16, -64)
    nbox:SetSize(200, 22)
    Tex(nbox, "BACKGROUND", { 1, 1, 1, 0.25 }):SetAllPoints()
    Border(nbox, 0.3)
    sp.name = EditBox(nbox, false)
    sp.name:SetPoint("TOPLEFT", 6, -3)
    sp.name:SetPoint("BOTTOMRIGHT", -6, 3)
    sp.name:SetMaxLetters(24)
    sp.name:SetTextColor(INK[1], INK[2], INK[3])
    sp.name:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local t = strtrim(self:GetText() or "")
        Settings().ownerName = t ~= "" and t or nil
        RefreshJournal()
    end)
    sp.name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    sp.preview = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sp.preview:SetPoint("LEFT", nbox, "RIGHT", 10, 0)
    Ink(sp.preview)
    sp.toggles = {}
    local y = -104
    for _, t in ipairs({
        { key = "shotFirsts", label = "Screenshot the big firsts" },
        { key = "shotMilestones", label = "Screenshot milestones too" },
        { key = "firstDeath", label = "Write down the first death" },
        { key = "hideInCombat", label = "Hide the journal in combat" },
        { key = "minimap", label = "Minimap button" },
    }) do
        local l = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l:SetPoint("TOPLEFT", 16, y)
        l:SetText(t.label)
        Ink(l)
        t.btn = Btn(sp, "On", 46)
        t.btn:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -16, y + 3)
        t.btn:SetScript("OnClick", function()
            local s2 = Settings()
            s2[t.key] = not s2[t.key]
            if t.key == "minimap" and UpdateMinimap then UpdateMinimap() end
            RenderSettings()
        end)
        tinsert(sp.toggles, t)
        y = y - 28
    end
    local function Stepper(label, key, lo, hi)
        local l = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l:SetPoint("TOPLEFT", 16, y)
        l:SetText(label)
        Ink(l)
        local plus = Btn(sp, "+", 22)
        plus:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -16, y + 3)
        local val = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("RIGHT", plus, "LEFT", -6, 0)
        val:SetWidth(44)
        Ink(val)
        local minus = Btn(sp, "-", 22)
        minus:SetPoint("RIGHT", val, "LEFT", -6, 0)
        local function step(d)
            local s2 = Settings()
            s2[key] = math.max(lo, math.min(hi, math.floor((s2[key] + d) * 100 + 0.5) / 100))
            ApplyLook()
            RenderSettings()
        end
        plus:SetScript("OnClick", function() step(0.05) end)
        minus:SetScript("OnClick", function() step(-0.05) end)
        y = y - 28
        return val
    end
    sp.scale = Stepper("Size", "scale", 0.6, 1.5)
    sp.alpha = Stepper("Opacity", "alpha", 0.3, 1)
    local foot = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    foot:SetPoint("BOTTOMLEFT", 16, 16)
    foot:SetPoint("RIGHT", -16, 0)
    foot:SetJustifyH("LEFT")
    foot:SetText("Everything stays on your PC. Screenshots go to your WoW Screenshots folder.\nForge's Chronicle v" .. VERSION .. " - by Forge at Crescent Cove")
    Ink(foot, FADED)

    -- recap
    local rp = CreateFrame("Frame", nil, page)
    rp:SetAllPoints()
    journal.recap = rp
    local rt = rp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    rt:SetPoint("TOPLEFT", 16, -16)
    rt:SetText("Share your story")
    Ink(rt, { 0.45, 0.20, 0.05 })
    rp.mode = "recap"
    local b1 = Btn(rp, "Recap", 70)
    b1:SetPoint("TOPRIGHT", -96, -16)
    b1:SetScript("OnClick", function() rp.mode = "recap"; RenderRecap(true) end)
    local b2 = Btn(rp, "Full timeline", 90)
    b2:SetPoint("TOPRIGHT", -16, -16)
    b2:SetScript("OnClick", function() rp.mode = "timeline"; RenderRecap(true) end)
    rp.b1, rp.b2 = b1, b2
    local hint = rp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 16, -44)
    hint:SetText("It's selected: press Ctrl+C to copy, then paste it anywhere.")
    Ink(hint, FADED)
    local scroll = CreateFrame("ScrollFrame", "ForgesChronicleRecapScroll", rp, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -64)
    scroll:SetPoint("BOTTOMRIGHT", -34, 16)
    rp.text = EditBox(scroll, true)
    rp.text:SetWidth(W - 300 - 12 - 12 - 10 - 50)
    rp.text:SetTextColor(INK[1], INK[2], INK[3])
    rp.text:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(rp.text)

    journal:SetScript("OnShow", function()
        sp.name:SetText(Settings().ownerName or "")
        RefreshJournal()
    end)
    journal:Hide()
    ApplyLook()
end

RenderRecap = function(focus)
    local rp = journal.recap
    rp.b1.bg:SetAlpha(rp.mode == "recap" and 1 or 0.4)
    rp.b2.bg:SetAlpha(rp.mode == "timeline" and 1 or 0.4)
    rp.text:SetText(rp.mode == "timeline" and Timeline() or Recap())
    if focus then
        rp.text:SetFocus()
        rp.text:HighlightText()
    end
end

local function ToggleJournal(show)
    if not journal then CreateJournal() end
    if show == nil then show = not journal:IsShown() end
    if show then
        view = view == "settings" and "entry" or view
        journal:Show()
    else
        journal:Hide()
    end
end

--------------------------------------------------------- minimap button ---

local mini
UpdateMinimap = function()
    if not Minimap then return end
    local s = Settings()
    if not mini then
        mini = CreateFrame("Button", "ForgesChronicleMinimapButton", Minimap)
        mini:SetSize(31, 31)
        mini:SetFrameStrata("MEDIUM")
        mini:SetFrameLevel(8)
        local icon = mini:CreateTexture(nil, "BACKGROUND")
        icon:SetTexture(ICONS.begin)
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local border = mini:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        mini:RegisterForClicks("AnyUp")
        mini:RegisterForDrag("LeftButton")
        mini:SetScript("OnClick", function() ToggleJournal() end)
        mini:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local cx, cy = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                Settings().angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
                UpdateMinimap()
            end)
        end)
        mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        mini:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(JournalTitle())
            GameTooltip:AddLine("Click to open your journal. Drag to move.", 1, 1, 1)
            GameTooltip:Show()
        end)
        mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local a = math.rad(s.angle)
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
    mini:SetShown(s.minimap)
end

----------------------------------------------------------------- events ---

local hiddenForCombat = false
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
-- pcall: some of these don't exist on every client
for _, e in ipairs({ "PLAYER_LEVEL_UP", "PLAYER_DEAD", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END",
                     "LFG_COMPLETION_REWARD", "UPDATE_BATTLEFIELD_SCORE", "PLAYER_GUILD_UPDATE",
                     "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "SCREENSHOT_SUCCEEDED",
                     "SCREENSHOT_FAILED", "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED",
                     "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }) do
    pcall(frame.RegisterEvent, frame, e)
end
frame:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if event == "PLAYER_LOGIN" then
        c = CharData()
        loginAt = time()
        Settings()
        Begin()
        zoneNow, zoneSince = nil, nil
        ZoneClock()
        OnGuild(true)
        C_Timer.After(3, function() ScanItems() end)  -- bags are ready a moment after login
        UpdateMinimap()
        return
    end
    if not c then return end
    if event == "PLAYER_LEVEL_UP" then
        OnLevel(a1)
    elseif event == "PLAYER_DEAD" then
        OnDeath()
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        OnZone()
    elseif event == "ENCOUNTER_END" then
        OnBossKill(a2, a5)  -- encounterID, name, difficulty, size, success
    elseif event == "LFG_COMPLETION_REWARD" then
        OnDungeonDone()
    elseif event == "UPDATE_BATTLEFIELD_SCORE" then
        OnBattlefield()
    elseif event == "PLAYER_GUILD_UPDATE" then
        OnGuild(false)
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        QueueItemScan()
    elseif event == "SCREENSHOT_SUCCEEDED" then
        if pendingShot then pendingShot.shot = time(); pendingShot = nil; Touch(); RefreshJournal() end
    elseif event == "SCREENSHOT_FAILED" then
        pendingShot = nil
    elseif event == "LOADING_SCREEN_ENABLED" then
        loading = true
    elseif event == "LOADING_SCREEN_DISABLED" then
        loading = false
    elseif event == "PLAYER_REGEN_DISABLED" then
        if Settings().hideInCombat and journal and journal:IsShown() then
            hiddenForCombat = true
            journal:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if hiddenForCombat then hiddenForCombat = false; ToggleJournal(true) end
    elseif event == "PLAYER_LOGOUT" then
        ZoneClock()
        Touch()
    end
end)

------------------------------------------------------------ /chronicle ---

SLASH_FORGESCHRONICLE1 = "/chronicle"
SLASH_FORGESCHRONICLE2 = "/ch"
SlashCmdList.FORGESCHRONICLE = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ToggleJournal()
    elseif cmd == "recap" or cmd == "export" then
        view = "recap"
        ToggleJournal(true)
        RefreshJournal()
        RenderRecap(true)
    elseif cmd == "name" then
        Settings().ownerName = rest ~= "" and rest or nil
        print(PREFIX .. "Your journal is now called \"" .. JournalTitle() .. "\".")
        RefreshJournal()
    elseif cmd == "minimap" then
        Settings().minimap = not Settings().minimap
        UpdateMinimap()
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /chronicle - open or close your journal")
        print("  /chronicle recap (or export) - a recap of your story, ready to copy")
        print("  /chronicle name Bob - call it \"Bob's Chronicles\" (/chronicle name on its own: back to \"" .. DEFAULT_TITLE .. "\")")
        print("  /chronicle minimap - show or hide the minimap button")
    end
end
