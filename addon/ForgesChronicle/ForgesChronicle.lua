-- Forge's Chronicle v1.2 (retail and WoW Forever)
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

local VERSION = "1.2"
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
    if s.chapterCeremony == nil then s.chapterCeremony = true end
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

------------------------------------------------------------------ words ---
-- What the journal says. Chapter names and entry lines are by Luna (the
-- v1.1 voice pass): warm, a little wry, one sentence where possible.
-- <name> <zone> <item> <boss> <instance> <guild> <level> are filled in.

-- chapters of ten levels: 1-10, 11-20, ... (Forever stops at 60, retail 90)
local CHAPTERS = { "First Steps", "Finding Your Feet", "The Road Widens", "Trial by Fire",
                   "The Long Climb", "Tempered", "Uncharted", "The Crucible", "Apex" }

-- shown on the chapter ceremony (Luna)
local EPIGRAPHS = {
    "Every legend starts with a blank page.",
    "The road stops feeling foreign somewhere around here. The boots fit. The wilds nod back.",
    "The horizon keeps moving. Good. So do you.",
    "What doesn't kill you gets written down.",
    "The air thins. The view improves.",
    "Fire, hammer, patience. You are the work.",
    "The map ends. The story doesn't.",
    "Pressure makes diamonds. And legends.",
    "The top of the mountain is just a better view of the next one.",
}

local LINES = {
    beginNew = "Every legend starts with a blank page. This one is yours, <name>.",
    beginLater = "Earlier deeds went unrecorded. From here, <name>'s story is written down.",
    level = "Level <level>. The road is starting to feel familiar.",
    maxLevel = "Level <level> - the top of this mountain. The view is good from here, <name>.",
    death = "Here fell <name>, in <zone>. Not the last time, probably.",
    zone = "<zone> - new ground under your boots.",
    firstDungeon = "First dungeon: <instance>. Went in green, came out proven.",
    dungeon = "First run through <instance>.",
    firstRaidBoss = "<boss> fell. The first of many, if you've got the stomach for it.",
    raidBoss = "<boss> defeated in <instance>.",
    bgWin = "Victory in <instance>. <name> stood when it counted.",
    firstEpic = "First epic: <item>. Purple at last.",
    firstLegendary = "<item>. Legends aren't found - except this one. You found it.",
    firstGuild = "Joined <guild>. No hero walks alone forever.",
    guild = "Now running with <guild>.",
}

-- A line with its placeholders filled. A place the game didn't name is
-- left out gracefully ("Here fell Bob.") rather than printed as a blank.
local function Say(key, vars)
    local text = (LINES[key] or ""):gsub("<(%a+)>", function(k)
        local v = vars and vars[k]
        return v ~= nil and tostring(v) or ""
    end)
    text = text:gsub(", in %.", ".")
    return text
end

-- chapter number and its header, e.g. "Tempered  -  levels 51 - 60"
local function ChapterOf(level)
    local i = math.max(1, math.ceil((tonumber(level) or 1) / 10))
    local name = CHAPTERS[math.min(i, #CHAPTERS)]
    return i, name .. "  -  levels " .. ((i - 1) * 10 + 1) .. " - " .. (i * 10)
end

---------------------------------------------------------------- entries ---

local RefreshJournal = function() end  -- set by the journal window below
local ChapterReached, BackfillChapters = function() end, function() end  -- the chapter ceremony

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
    note = "Interface\\Icons\\INV_Misc_Note_01",
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
    -- anything inside the first chapter (levels 1-10) counts as the start
    d.fromStart = lvl <= 10
    -- a fresh character gets every chapter ceremony, starting with this one
    if d.fromStart then d.chaptersSeen = {} end
    local zone = Zone()
    -- the level and zone show on the entry's date line
    local text = Say(d.fromStart and "beginNew" or "beginLater", { name = PlayerName() })
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
        Write("level", "first", "Level " .. lvl .. " - the top", Say("maxLevel", { level = lvl, name = PlayerName() }))
    elseif lvl % 10 == 0 then
        Write("level", "milestone", "Level " .. lvl, Say("level", { level = lvl }))
    end
    ChapterReached(lvl)
end

local function OnDeath()
    local d = c.data
    d.counts.deaths = (tonumber(d.counts.deaths) or 0) + 1
    Touch()
    if d.firsts.death then return end
    d.firsts.death = time()
    if not Settings().firstDeath then return end
    local zone = Zone()
    Write("death", "first", First("death"), Say("death", { name = PlayerName(), zone = zone }), { noShot = true })
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
        Write("zone", "milestone", "Discovered " .. zone, Say("zone", { zone = zone }))
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
            Write("raid", "first", First("raid boss: ") .. boss, Say("firstRaidBoss", { boss = boss, instance = name }))
        elseif newBoss then
            Write("raid", "milestone", boss .. " defeated", Say("raidBoss", { boss = boss, instance = name }))
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
            run.base = Say(first and "firstDungeon" or "dungeon", { instance = name })
            run.entry = Write("dungeon", first and "first" or "milestone",
                (first and First("dungeon: ") or "First run: ") .. name, "", { instance = name })
        end
    end
    tinsert(run.bosses, boss)
    if run.entry then
        run.entry.text = run.base .. " Defeated: " .. table.concat(run.bosses, ", ") .. "."
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
    Write("pvp", "first", First("battleground win"), Say("bgWin", { instance = name, name = PlayerName() }))
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
        Write("guild", "first", "Joined " .. g, Say("firstGuild", { guild = g }))
    else
        Write("guild", "milestone", "Joined " .. g, Say("guild", { guild = g }))
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
            Write("loot", "first", "First legendary: " .. name, Say("firstLegendary", { item = name }), { icon = icon or ICONS.loot })
        elseif q == EPIC and not d.firsts.epic then
            d.firsts.epic = time()
            Write("loot", "first", "First epic: " .. name, Say("firstEpic", { item = name }), { icon = icon or ICONS.loot })
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
-- "The Thread" (design by Luna, v1.2): the journal as an artifact. On the
-- left, a dark page with a golden thread; every moment hangs on it as a gem
-- (gold diamonds for firsts, iron circles for milestones, red for deaths),
-- chapters cut across it as banners, and the unwritten future waits at the
-- top. On the right, an open book page for the chosen moment. Settings and
-- the recap take over that page.
--
-- Fonts: Cinzel (headings) and Alegreya (body), both under the SIL Open
-- Font License (see Fonts/). Text in a script a font can't draw (Cyrillic
-- in Cinzel, Chinese/Korean in either) falls back to the game's own font.

local MEDIA = "Interface\\AddOns\\ForgesChronicle\\"
local W, H, LIST_W, TOP = 720, 500, 300, 62
local ROW_H, BANNER_H, FUTURE_H = 38, 48, 40
local THREAD_X = 28

local function Hex(h, a)
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, a or 1 }
end
local IRON, FRAME_GOLD, GOLD = Hex("161619", 0.98), Hex("8A6F2E"), Hex("D9B64A")
local SUB, PARCH, CARD = Hex("9A8C66"), Hex("EFE3C2"), Hex("FBF5E3")
local INK, INK2, ACCENT = Hex("2A2419"), Hex("7A6C4E"), Hex("B08D2E")
local RUST, GREEN, OFF = Hex("A0522D"), Hex("6B8F3D"), Hex("C9BC98")
local NIGHT, BANNER = Hex("1B1A17"), Hex("100F0D")
local BLOOD = Hex("962420")

local journal, items, offset, selectedId, view = nil, {}, 0, nil, "entry"
local WritePage  -- set below: start a page of your own
local UpdateMinimap  -- set with the minimap button below
local fonts = {}

-- one font object per style, with the game's own font as the fallback
local function Font(key, file, size, fallbackFile)
    if fonts[key] then return fonts[key] end
    local f = CreateFont("ForgesChronicleFont_" .. key)
    local ok = f:SetFont(MEDIA .. "Fonts\\" .. file, size, "")
    if ok == false then f:SetFont(fallbackFile or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "") end
    local fb = CreateFont("ForgesChronicleFont_" .. key .. "_fb")
    fb:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", math.max(10, size - 1), "")
    fonts[key] = { obj = f, fallback = fb, cinzel = file:find("Cinzel") ~= nil }
    return fonts[key]
end

local STYLES = {
    title = { "Cinzel-Bold.ttf", 20, "Fonts\\MORPHEUS.TTF" },
    heading = { "Cinzel-Bold.ttf", 17, "Fonts\\MORPHEUS.TTF" },
    banner = { "Cinzel-Bold.ttf", 11 },
    ceremony = { "Cinzel-Bold.ttf", 40, "Fonts\\MORPHEUS.TTF" },
    body = { "Alegreya-Regular.ttf", 14 },
    small = { "Alegreya-Regular.ttf", 12 },
    italic = { "Alegreya-Italic.ttf", 15 },
    italicSmall = { "Alegreya-Italic.ttf", 12 },
    epigraph = { "Alegreya-Italic.ttf", 19 },
}

-- Cinzel has Latin only; Alegreya adds Cyrillic and Greek. Anything else
-- (and Cyrillic in a Cinzel heading) uses the game's font for that line.
local function Covered(text, cinzel)
    if text:find("[\227-\239]") then  -- three-byte scripts: CJK, Korean...
        -- ...except punctuation like the en dash and ellipsis (E2 80 xx)
        return false
    end
    if cinzel and text:find("[\206-\211]") then return false end
    return true
end

local function Say2(fs, style, text, col)
    text = tostring(text or "")
    local st = STYLES[style]
    local f = Font(style, st[1], st[2], st[3])
    fs:SetFontObject(Covered(text, f.cinzel) and f.obj or f.fallback)
    fs:SetText(text)
    if col then fs:SetTextColor(col[1], col[2], col[3], col[4] or 1) end
end

-- "FIRST STEPS" -> "F I R S T   S T E P S": letter-spacing for small caps
local function Spaced(s)
    s = tostring(s):upper()
    return (s:gsub("(.)", "%1 "):gsub("   ", "     "):gsub(" $", ""))
end

local function Tex(parent, layer, col, file)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    if file then
        t:SetTexture(MEDIA .. "Media\\" .. file)
        if col then t:SetVertexColor(col[1], col[2], col[3], col[4] or 1) end
    else
        t:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end
    return t
end

local function Border(f, col, size, inset)
    size, inset = size or 1, inset or 0
    local out = {}
    for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                         { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = Tex(f, "BORDER", col)
        local dx = (p[1]:find("LEFT") and inset or -inset)
        local dy = (p[1]:find("TOP") and -inset or inset)
        t:SetPoint(p[1], dx, dy)
        t:SetPoint(p[2], (p[2]:find("LEFT") and inset or -inset), (p[2]:find("TOP") and -inset or inset))
        if i <= 2 then t:SetHeight(size) else t:SetWidth(size) end
        out[i] = t
    end
    return out
end

-- a dashed outline, from tiled dashes
local function Dashed(f, col)
    for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                         { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetTexture(MEDIA .. "Media\\dash_" .. p[3], "REPEAT", "REPEAT")
        t:SetVertexColor(col[1], col[2], col[3], col[4] or 1)
        t:SetPoint(p[1])
        t:SetPoint(p[2])
        if p[3] == "h" then t:SetHeight(1); t:SetHorizTile(true) else t:SetWidth(1); t:SetVertTile(true) end
    end
end

-- outline button: quiet, coloured edge and text
local function OutlineBtn(parent, label, col, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 120, 24)
    b.bg = Tex(b, "BACKGROUND", { col[1], col[2], col[3], 0 })
    b.bg:SetAllPoints()
    local hl = Tex(b, "HIGHLIGHT", { col[1], col[2], col[3], 0.12 })
    hl:SetAllPoints()
    Border(b, { col[1], col[2], col[3], 0.9 })
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetPoint("CENTER")
    b.col = col
    Say2(b.text, "small", label, col)
    return b
end

-- round icon button for the title bar
local function IconBtn(parent, icon, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(26, 26)
    b.fill = Tex(b, "BACKGROUND", { GOLD[1], GOLD[2], GOLD[3], 0.18 }, "circle.tga")
    b.fill:SetAllPoints()
    b.fill:Hide()
    b.ring = Tex(b, "BORDER", { FRAME_GOLD[1], FRAME_GOLD[2], FRAME_GOLD[3], 1 }, "ring.tga")
    b.ring:SetAllPoints()
    b.icon = Tex(b, "ARTWORK", GOLD, icon)
    b.icon:SetPoint("CENTER")
    b.icon:SetSize(16, 16)
    local hl = Tex(b, "HIGHLIGHT", { 1, 1, 1, 0.12 }, "circle.tga")
    hl:SetAllPoints()
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(tip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function Gem(parent, size)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetSize(size or 22, size or 22)
    return t
end

local function GemFile(e)
    if e.kind == "death" then return "gem_death.tga" end
    if e.tier == "first" then return "gem_first.tga" end
    return "gem_milestone.tga"
end

-- the kicker over an entry's title
local function Kicker(e)
    if e.kind == "begin" then return "First page" end
    if e.kind == "note" then return "Your own page" end
    if e.kind == "death" then return "A fall" end
    if e.tier == "first" then return "A first" end
    return "A milestone"
end

local function ClassName() return Plain(Try(UnitClass, "player")) or "" end

-- the thread as items, top to bottom: the unwritten future, then the
-- moments newest first, with a banner where each chapter starts
local function ThreadModel()
    local list = { { future = true } }
    local lastChapter
    local entries = c and c.data.entries or {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        local chapter = ChapterOf(e.level)
        if chapter ~= lastChapter then
            lastChapter = chapter
            tinsert(list, { chapter = chapter })
        end
        tinsert(list, { entry = e })
    end
    return list
end

local function ItemHeight(m)
    return m.chapter and BANNER_H or (m.future and FUTURE_H or ROW_H)
end

local function GetItem(i)
    if items[i] then return items[i] end
    local r = CreateFrame("Button", nil, journal.list)
    r:SetPoint("LEFT", journal.list, "LEFT", 0, 0)
    r:SetPoint("RIGHT", journal.list, "RIGHT", 0, 0)
    -- entry parts
    r.sel = Tex(r, "BACKGROUND", { GOLD[1], GOLD[2], GOLD[3], 0.10 })
    r.sel:SetAllPoints()
    r.selEdge = Tex(r, "BORDER", GOLD)
    r.selEdge:SetPoint("TOPLEFT")
    r.selEdge:SetPoint("BOTTOMLEFT")
    r.selEdge:SetWidth(2)
    r.hover = Tex(r, "HIGHLIGHT", { 1, 1, 1, 0.04 })
    r.hover:SetAllPoints()
    r.gem = Gem(r, 22)
    r.title = r:CreateFontString(nil, "OVERLAY")
    r.title:SetPoint("TOPLEFT", THREAD_X + 22, -5)
    r.title:SetPoint("RIGHT", -10, 0)
    r.title:SetJustifyH("LEFT")
    r.title:SetWordWrap(false)
    r.meta = r:CreateFontString(nil, "OVERLAY")
    r.meta:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -1)
    r.meta:SetJustifyH("LEFT")
    -- banner parts
    r.band = Tex(r, "BACKGROUND", BANNER)
    r.band:SetAllPoints()
    r.bandName = r:CreateFontString(nil, "OVERLAY")
    r.bandName:SetPoint("TOP", 0, -10)
    r.bandLevels = r:CreateFontString(nil, "OVERLAY")
    r.bandLevels:SetPoint("TOP", r.bandName, "BOTTOM", 0, -3)
    r.ruleL = Tex(r, "ARTWORK", { ACCENT[1], ACCENT[2], ACCENT[3], 0.8 })
    r.ruleL:SetHeight(1)
    r.ruleR = Tex(r, "ARTWORK", { ACCENT[1], ACCENT[2], ACCENT[3], 0.8 })
    r.ruleR:SetHeight(1)
    r.dL = Tex(r, "OVERLAY", ACCENT, "diamond.tga")
    r.dL:SetSize(8, 8)
    r.dR = Tex(r, "OVERLAY", ACCENT, "diamond.tga")
    r.dR:SetSize(8, 8)
    r:SetScript("OnClick", function(self)
        if self.entryId then selectedId, view = self.entryId, "entry"; RefreshJournal()
        elseif self.future and WritePage then WritePage() end
    end)
    r:SetScript("OnEnter", function(self)
        if not self.future then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Write a page of your own")
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    items[i] = r
    return r
end

local function ShowParts(r, kind)
    local entry, banner = kind == "entry", kind == "banner"
    r.sel:SetShown(false); r.selEdge:SetShown(false)
    r.title:SetShown(entry or kind == "future"); r.meta:SetShown(entry)
    r.gem:SetShown(entry or kind == "future")
    for _, p in ipairs({ r.band, r.bandName, r.bandLevels, r.ruleL, r.ruleR, r.dL, r.dR }) do p:SetShown(banner) end
end

local function RenderList()
    local model = ThreadModel()
    offset = math.max(0, math.min(offset, #model - 1))
    local avail = H - TOP - 12 - 4
    local y, n = -2, 0
    for k = offset + 1, #model do
        local m = model[k]
        local h = ItemHeight(m)
        if -y + h > avail then break end
        n = n + 1
        local r = GetItem(n)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", journal.list, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", journal.list, "RIGHT", 0, 0)
        r:SetHeight(h)
        r.entryId, r.future = nil, nil
        if m.future then
            ShowParts(r, "future")
            r.gem:SetTexture(MEDIA .. "Media\\gem_future.tga")
            r.gem:ClearAllPoints()
            r.gem:SetPoint("CENTER", r, "LEFT", THREAD_X, 0)
            r.title:ClearAllPoints()
            r.title:SetPoint("LEFT", THREAD_X + 22, 0)
            r.title:SetPoint("RIGHT", -10, 0)
            Say2(r.title, "italicSmall", "The rest is unwritten\226\128\166", SUB)
            r.future = true
        elseif m.chapter then
            ShowParts(r, "banner")
            local name = CHAPTERS[math.min(m.chapter, #CHAPTERS)]
            Say2(r.bandName, "banner", Spaced(name), GOLD)
            Say2(r.bandLevels, "italicSmall", "Levels " .. ((m.chapter - 1) * 10 + 1) .. " \226\128\147 " .. (m.chapter * 10), SUB)
            local half = math.ceil((r.bandName:GetStringWidth() or 80) / 2) + 12
            r.ruleL:ClearAllPoints()
            r.ruleL:SetPoint("LEFT", r, "LEFT", 22, 0)
            r.ruleL:SetPoint("RIGHT", r, "CENTER", -half, 0)
            r.ruleL:SetPoint("TOP", r.bandName, "CENTER", 0, 0)
            r.ruleR:ClearAllPoints()
            r.ruleR:SetPoint("LEFT", r, "CENTER", half, 0)
            r.ruleR:SetPoint("RIGHT", r, "RIGHT", -22, 0)
            r.ruleR:SetPoint("TOP", r.bandName, "CENTER", 0, 0)
            r.dL:ClearAllPoints()
            r.dL:SetPoint("CENTER", r.ruleL, "LEFT", 0, 0)
            r.dR:ClearAllPoints()
            r.dR:SetPoint("CENTER", r.ruleR, "RIGHT", 0, 0)
        else
            local e = m.entry
            ShowParts(r, "entry")
            r.entryId = e.id
            local selected = e.id == selectedId
            r.sel:SetShown(selected)
            r.selEdge:SetShown(selected)
            r.gem:SetTexture(MEDIA .. "Media\\" .. GemFile(e))
            local gs = selected and 26 or 20
            r.gem:SetSize(gs, gs)
            r.gem:ClearAllPoints()
            r.gem:SetPoint("CENTER", r, "LEFT", THREAD_X, 0)
            r.title:ClearAllPoints()
            r.title:SetPoint("TOPLEFT", THREAD_X + 22, -5)
            r.title:SetPoint("RIGHT", -10, 0)
            Say2(r.title, "body", e.title, e.tier == "first" and GOLD or PARCH)
            Say2(r.meta, "italicSmall", Day(e.at) .. "  \194\183  Level " .. tostring(e.level or "?"), SUB)
        end
        r:Show()
        y = y - h
    end
    for k = n + 1, #items do items[k]:Hide() end
    -- the thread runs behind the gems, down to the last one shown
    journal.thread:ClearAllPoints()
    journal.thread:SetPoint("TOP", journal.list, "TOPLEFT", THREAD_X, -2 - FUTURE_H / 2)
    journal.thread:SetPoint("BOTTOM", journal.list, "TOPLEFT", THREAD_X, y + (n > 1 and ROW_H / 2 or FUTURE_H / 2))
    journal.thread:SetShown(n > 1)
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
    p.blank:SetShown(e == nil)
    if not e then return end
    Say2(p.kicker, "banner", Spaced(Kicker(e)), ACCENT)
    Say2(p.title, "heading", e.title, INK)
    Say2(p.meta, "italicSmall", date("%B %d, %Y", e.at) .. "  \194\183  Level " .. tostring(e.level or "?")
        .. (e.zone and e.zone ~= "" and ("  \194\183  " .. e.zone) or ""), INK2)
    p.plateIcon:SetTexture(e.icon or ICONS[e.kind] or ICONS.begin)
    p.plateGem:SetTexture(MEDIA .. "Media\\" .. GemFile(e))
    Say2(p.body, "italic", e.text or "", INK)
    p.rule:SetShown((e.text or "") ~= "")
    Say2(p.shot, "italicSmall", e.shot and ("A screenshot was taken at " .. date("%H:%M", e.shot)
        .. " \226\128\147 it's in your WoW Screenshots folder.") or "", INK2)
    p.note.entryId = e.id
    p.note:SetText(e.note or "")
    p.placeholder:SetShown((e.note or "") == "")
    p.delete.armed = false
    Say2(p.delete.text, "small", "Delete entry", RUST)
end

WritePage = function()
    local e = Write("note", "milestone", "A page of your own", "", { noShot = true })
    if not e then return end
    selectedId, view, offset = e.id, "entry", 0
    RefreshJournal()
    journal.page.note:SetFocus()
end

local function ShowView()
    journal.page.entry:SetShown(view == "entry")
    journal.page.blank:SetShown(false)
    journal.settings:SetShown(view == "settings")
    journal.recap:SetShown(view == "recap")
    for id, b in pairs(journal.tabs) do b.fill:SetShown(id == view) end
end

local function SetToggle(t, on)
    t.track:SetVertexColor((on and GREEN or OFF)[1], (on and GREEN or OFF)[2], (on and GREEN or OFF)[3], 1)
    t.knob:ClearAllPoints()
    t.knob:SetPoint("CENTER", t, on and "RIGHT" or "LEFT", on and -9 or 9, 0)
    t.on = on
end

local function RenderSettings()
    local s, sp = Settings(), journal.settings
    Say2(sp.preview, "italicSmall", "Your journal is called \"" .. JournalTitle() .. "\"", INK2)
    for _, t in ipairs(sp.toggles) do SetToggle(t, s[t.key] and true or false) end
    Say2(sp.scale, "small", math.floor(s.scale * 100 + 0.5) .. "%", INK)
    Say2(sp.alphaText, "small", math.floor(s.alpha * 100 + 0.5) .. "%", INK)
    sp.slider.quiet = true
    sp.slider:SetValue(s.alpha)
    sp.slider.quiet = false
end

local RenderRecap

RefreshJournal = function()
    if not (journal and journal:IsShown()) then return end
    Say2(journal.title, "title", JournalTitle(), GOLD)
    Say2(journal.sub, "italicSmall", PlayerName() .. "  \194\183  Level " .. Level() .. " " .. ClassName() .. "  \194\183  " .. GAME, SUB)
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

local function EditBox(parent, multi, style)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetAutoFocus(false)
    local st = STYLES[style or "body"]
    e:SetFontObject(Font(style or "body", st[1], st[2], st[3]).obj)
    e:SetMultiLine(multi and true or false)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

local function SectionLabel(parent, text, y)
    local l = parent:CreateFontString(nil, "OVERLAY")
    l:SetPoint("TOPLEFT", 28, y)
    Say2(l, "banner", Spaced(text), ACCENT)
    local rule = Tex(parent, "ARTWORK", { ACCENT[1], ACCENT[2], ACCENT[3], 0.35 })
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 28, y - 16)
    rule:SetPoint("RIGHT", parent, "RIGHT", -28, 0)
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
    Tex(journal, "BACKGROUND", IRON):SetAllPoints()
    Border(journal, FRAME_GOLD, 1, 0)
    Border(journal, { FRAME_GOLD[1], FRAME_GOLD[2], FRAME_GOLD[3], 0.5 }, 1, 3)  -- the inset line

    -- title bar
    journal.title = journal:CreateFontString(nil, "OVERLAY")
    journal.title:SetPoint("TOPLEFT", 20, -14)
    journal.sub = journal:CreateFontString(nil, "OVERLAY")
    journal.sub:SetPoint("TOPLEFT", journal.title, "BOTTOMLEFT", 0, -3)
    local close = IconBtn(journal, "icon_close.tga", "Close")
    close:SetPoint("TOPRIGHT", -16, -18)
    close:SetScript("OnClick", function() journal:Hide() end)
    journal.close = close
    journal.tabs = {}
    local prev = close
    for _, t in ipairs({ { "settings", "icon_gear.tga", "Settings" }, { "recap", "icon_share.tga", "Share your story" },
                         { "entry", "icon_book.tga", "Journal" } }) do
        local b = IconBtn(journal, t[2], t[3])
        b:SetPoint("RIGHT", prev, "LEFT", -8, 0)
        b:SetScript("OnClick", function()
            view = t[1]
            RefreshJournal()
            if view == "recap" then RenderRecap(true) end
        end)
        journal.tabs[t[1]] = b
        prev = b
    end

    -- left: the thread
    journal.list = CreateFrame("Frame", nil, journal)
    journal.list:SetPoint("TOPLEFT", 12, -TOP)
    journal.list:SetPoint("BOTTOMLEFT", 12, 12)
    journal.list:SetWidth(LIST_W)
    Tex(journal.list, "BACKGROUND", NIGHT):SetAllPoints()
    local lg = Tex(journal.list, "BORDER", { GOLD[1], GOLD[2], GOLD[3], 0.10 }, "glow.tga")
    lg:SetPoint("TOPLEFT")
    lg:SetPoint("TOPRIGHT")
    lg:SetHeight(140)
    Border(journal.list, { FRAME_GOLD[1], FRAME_GOLD[2], FRAME_GOLD[3], 0.45 })
    journal.thread = Tex(journal.list, "BORDER", { 1, 1, 1, 0.9 }, "thread.tga")
    journal.thread:SetWidth(8)
    journal.list:EnableMouseWheel(true)
    journal.list:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta)
        RenderList()
    end)

    -- right: the open page
    local page = CreateFrame("Frame", nil, journal)
    page:SetPoint("TOPLEFT", journal.list, "TOPRIGHT", 10, 0)
    page:SetPoint("BOTTOMRIGHT", -12, 12)
    Tex(page, "BACKGROUND", PARCH):SetAllPoints()
    local pg = Tex(page, "BORDER", { CARD[1], CARD[2], CARD[3], 0.95 }, "glow.tga")
    pg:SetPoint("TOPLEFT")
    pg:SetPoint("TOPRIGHT")
    pg:SetHeight(180)
    Border(page, { FRAME_GOLD[1], FRAME_GOLD[2], FRAME_GOLD[3], 0.45 })
    journal.page = page
    local PW = W - 12 - LIST_W - 10 - 12

    local ent = CreateFrame("Frame", nil, page)
    ent:SetAllPoints()
    page.entry = ent
    page.kicker = ent:CreateFontString(nil, "OVERLAY")
    page.kicker:SetPoint("TOP", 0, -22)
    local kl = Tex(ent, "ARTWORK", ACCENT, "diamond.tga")
    kl:SetSize(7, 7)
    kl:SetPoint("RIGHT", page.kicker, "LEFT", -8, 0)
    local kr = Tex(ent, "ARTWORK", ACCENT, "diamond.tga")
    kr:SetSize(7, 7)
    kr:SetPoint("LEFT", page.kicker, "RIGHT", 8, 0)
    page.title = ent:CreateFontString(nil, "OVERLAY")
    page.title:SetPoint("TOPLEFT", 28, -44)
    page.title:SetWidth(PW - 56)
    page.title:SetJustifyH("LEFT")
    page.meta = ent:CreateFontString(nil, "OVERLAY")
    page.meta:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -5)
    page.meta:SetWidth(PW - 56)
    page.meta:SetJustifyH("LEFT")
    -- the plate: an illuminated miniature of the moment (the game can't
    -- show the screenshot file itself, so this stands in, by design)
    local plate = CreateFrame("Frame", nil, ent)
    plate:SetSize(64, 64)
    plate:SetPoint("TOPLEFT", page.meta, "BOTTOMLEFT", 0, -16)
    Tex(plate, "BACKGROUND", NIGHT):SetAllPoints()
    local pglow = Tex(plate, "BORDER", { GOLD[1], GOLD[2], GOLD[3], 0.25 }, "glow.tga")
    pglow:SetAllPoints()
    Border(plate, GOLD, 1, 0)
    Border(plate, { GOLD[1], GOLD[2], GOLD[3], 0.4 }, 1, 3)
    page.plateIcon = plate:CreateTexture(nil, "ARTWORK")
    page.plateIcon:SetSize(38, 38)
    page.plateIcon:SetPoint("CENTER")
    page.plateIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    page.plateGem = plate:CreateTexture(nil, "OVERLAY")
    page.plateGem:SetSize(18, 18)
    page.plateGem:SetPoint("CENTER", plate, "BOTTOM", 0, 0)
    page.plate = plate
    -- the moment's line, as a quote with a gold rule
    local rule = Tex(ent, "ARTWORK", ACCENT)
    page.rule = rule
    rule:SetWidth(2)
    rule:SetPoint("TOPLEFT", plate, "TOPRIGHT", 16, 0)
    rule:SetPoint("BOTTOMLEFT", plate, "BOTTOMRIGHT", 16, 0)
    page.body = ent:CreateFontString(nil, "OVERLAY")
    page.body:SetPoint("TOPLEFT", rule, "TOPRIGHT", 12, 0)
    page.body:SetWidth(PW - 56 - 64 - 30)
    page.body:SetJustifyH("LEFT")
    page.body:SetJustifyV("TOP")
    page.shot = ent:CreateFontString(nil, "OVERLAY")
    page.shot:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", 0, -16)
    page.shot:SetWidth(PW - 56)
    page.shot:SetJustifyH("LEFT")
    -- your own words
    local label = ent:CreateFontString(nil, "OVERLAY")
    label:SetPoint("BOTTOMLEFT", 28, 160)
    Say2(label, "banner", Spaced("Your own words"), ACCENT)
    local box = CreateFrame("Frame", nil, ent)
    box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    box:SetPoint("RIGHT", -28, 0)
    box:SetHeight(92)
    Tex(box, "BACKGROUND", { CARD[1], CARD[2], CARD[3], 0.6 }):SetAllPoints()
    Dashed(box, { ACCENT[1], ACCENT[2], ACCENT[3], 0.8 })
    page.note = EditBox(box, true, "body")
    page.note:SetPoint("TOPLEFT", 10, -8)
    page.note:SetPoint("BOTTOMRIGHT", -10, 8)
    page.note:SetMaxLetters(500)
    page.note:SetTextColor(INK[1], INK[2], INK[3])
    page.placeholder = box:CreateFontString(nil, "OVERLAY")
    page.placeholder:SetPoint("TOPLEFT", 12, -10)
    Say2(page.placeholder, "italic", "Write what the journal missed\226\128\166", INK2)
    page.note:SetScript("OnTextChanged", function(self, userInput)
        page.placeholder:SetShown((self:GetText() or "") == "" and not (self.HasFocus and self:HasFocus()))
        if not userInput then return end
        local e = self.entryId and FindEntry(self.entryId)
        if not e then return end
        local t = strtrim(self:GetText() or "")
        e.note = t ~= "" and t or nil
        Touch()
    end)
    page.note:SetScript("OnEditFocusGained", function() page.placeholder:Hide() end)
    page.note:SetScript("OnEditFocusLost", function(self) page.placeholder:SetShown((self:GetText() or "") == "") end)
    box:SetScript("OnMouseDown", function() page.note:SetFocus() end)
    page.delete = OutlineBtn(ent, "Delete entry", RUST, 110)
    page.delete:SetPoint("BOTTOMLEFT", 28, 20)
    page.delete:SetScript("OnClick", function(self)
        -- two clicks: a stray click never loses a page
        if not self.armed then
            self.armed = true
            Say2(self.text, "small", "Click again to delete", RUST)
            return
        end
        local _, i = FindEntry(selectedId)
        if i then tremove(c.data.entries, i); Touch() end
        selectedId = nil
        RefreshJournal()
    end)
    -- the empty journal (everything deleted, or nothing yet)
    local blank = CreateFrame("Frame", nil, page)
    blank:SetAllPoints()
    page.blank = blank
    local bk = blank:CreateFontString(nil, "OVERLAY")
    bk:SetPoint("TOP", 0, -22)
    Say2(bk, "banner", Spaced("A blank page"), ACCENT)
    local bt = blank:CreateFontString(nil, "OVERLAY")
    bt:SetPoint("TOPLEFT", 28, -48)
    Say2(bt, "heading", "Nothing written yet", INK)
    local bb = blank:CreateFontString(nil, "OVERLAY")
    bb:SetPoint("TOPLEFT", bt, "BOTTOMLEFT", 0, -12)
    bb:SetWidth(PW - 56)
    bb:SetJustifyH("LEFT")
    Say2(bb, "italic", "Your chronicle writes itself as you play: your first dungeon, your first epic, "
        .. "every ten levels, each new chapter. The big moments get a screenshot too.", INK)
    local bb2 = blank:CreateFontString(nil, "OVERLAY")
    bb2:SetPoint("TOPLEFT", bb, "BOTTOMLEFT", 0, -14)
    bb2:SetWidth(PW - 56)
    bb2:SetJustifyH("LEFT")
    Say2(bb2, "italic", "Or start one yourself - a page for anything the journal can't see.", INK2)
    page.write = OutlineBtn(blank, "Write a page", ACCENT, 130)
    page.write:SetPoint("TOPLEFT", bb2, "BOTTOMLEFT", 0, -18)
    page.write:SetScript("OnClick", function() WritePage() end)
    blank:Hide()

    local share = OutlineBtn(ent, "Share your story", ACCENT, 130)
    share:SetPoint("BOTTOMRIGHT", -28, 20)
    share:SetScript("OnClick", function() view = "recap"; RefreshJournal(); RenderRecap(true) end)

    -- settings (Luna's v2 layout: sections, switches, a slider)
    local sp = CreateFrame("Frame", nil, page)
    sp:SetAllPoints()
    journal.settings = sp
    local st = sp:CreateFontString(nil, "OVERLAY")
    st:SetPoint("TOPLEFT", 28, -22)
    Say2(st, "heading", "Settings", INK)
    local sd = sp:CreateFontString(nil, "OVERLAY")
    sd:SetPoint("TOPLEFT", st, "BOTTOMLEFT", 0, -4)
    sd:SetWidth(PW - 56)
    sd:SetJustifyH("LEFT")
    Say2(sd, "italicSmall", "Everything stays on your PC. Screenshots go to your WoW Screenshots folder.", INK2)
    SectionLabel(sp, "Journal", -78)
    local nl = sp:CreateFontString(nil, "OVERLAY")
    nl:SetPoint("TOPLEFT", 28, -104)
    Say2(nl, "small", "Your name for the journal", INK)
    local nbox = CreateFrame("Frame", nil, sp)
    nbox:SetPoint("TOPLEFT", 28, -122)
    nbox:SetPoint("RIGHT", sp, "RIGHT", -28, 0)
    nbox:SetHeight(26)
    Tex(nbox, "BACKGROUND", CARD):SetAllPoints()
    Border(nbox, { ACCENT[1], ACCENT[2], ACCENT[3], 0.7 })
    sp.name = EditBox(nbox, false, "body")
    sp.name:SetPoint("TOPLEFT", 8, -4)
    sp.name:SetPoint("BOTTOMRIGHT", -8, 4)
    sp.name:SetMaxLetters(24)
    sp.name:SetTextColor(INK[1], INK[2], INK[3])
    sp.name:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local t = strtrim(self:GetText() or "")
        Settings().ownerName = t ~= "" and t or nil
        RefreshJournal()
    end)
    sp.name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nbox:SetScript("OnMouseDown", function() sp.name:SetFocus() end)
    sp.preview = sp:CreateFontString(nil, "OVERLAY")
    sp.preview:SetPoint("TOPLEFT", nbox, "BOTTOMLEFT", 0, -4)
    sp.toggles = {}
    local function Toggle(key, label, y)
        local l = sp:CreateFontString(nil, "OVERLAY")
        l:SetPoint("TOPLEFT", 28, y)
        Say2(l, "body", label, INK)
        local t = CreateFrame("Button", nil, sp)
        t:SetSize(36, 18)
        t:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -28, y + 1)
        t.track = Tex(t, "BACKGROUND", OFF, "pill.tga")
        t.track:SetAllPoints()
        t.knob = Tex(t, "ARTWORK", { 1, 1, 1, 1 }, "circle.tga")
        t.knob:SetSize(14, 14)
        t.key = key
        t:SetScript("OnClick", function(self)
            local s2 = Settings()
            s2[key] = not s2[key]
            if key == "minimap" and UpdateMinimap then UpdateMinimap() end
            RenderSettings()
        end)
        tinsert(sp.toggles, t)
    end
    SectionLabel(sp, "Moments", -178)
    Toggle("shotFirsts", "Screenshot the big firsts", -204)
    Toggle("shotMilestones", "Screenshot milestones too", -230)
    Toggle("firstDeath", "Write down the first death", -256)
    Toggle("chapterCeremony", "Show each new chapter", -282)
    SectionLabel(sp, "Display", -310)
    Toggle("hideInCombat", "Hide the journal in combat", -336)
    Toggle("minimap", "Minimap button", -362)
    -- size: a stepper
    local sl = sp:CreateFontString(nil, "OVERLAY")
    sl:SetPoint("TOPLEFT", 28, -388)
    Say2(sl, "body", "Size", INK)
    local function Round(label, x)
        local b = CreateFrame("Button", nil, sp)
        b:SetSize(20, 20)
        b:SetPoint("TOPRIGHT", sp, "TOPRIGHT", x, -386)
        Tex(b, "BORDER", ACCENT, "ring.tga"):SetAllPoints()
        Tex(b, "HIGHLIGHT", { ACCENT[1], ACCENT[2], ACCENT[3], 0.2 }, "circle.tga"):SetAllPoints()
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetPoint("CENTER", 0, 1)
        Say2(b.text, "body", label, INK)
        return b
    end
    local plus = Round("+", -28)
    sp.scale = sp:CreateFontString(nil, "OVERLAY")
    sp.scale:SetPoint("RIGHT", plus, "LEFT", -8, 0)
    sp.scale:SetWidth(40)
    local minus = Round("-", -28 - 20 - 56)
    local function step(d)
        local s2 = Settings()
        s2.scale = math.max(0.6, math.min(1.5, math.floor((s2.scale + d) * 100 + 0.5) / 100))
        ApplyLook()
        RenderSettings()
    end
    plus:SetScript("OnClick", function() step(0.05) end)
    minus:SetScript("OnClick", function() step(-0.05) end)
    sp.plus, sp.minus = plus, minus
    -- opacity: a slider
    local ol = sp:CreateFontString(nil, "OVERLAY")
    ol:SetPoint("TOPLEFT", 28, -416)
    Say2(ol, "body", "Opacity", INK)
    sp.alphaText = sp:CreateFontString(nil, "OVERLAY")
    sp.alphaText:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -28, -416)
    local slider = CreateFrame("Slider", nil, sp)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(120, 16)
    slider:SetPoint("RIGHT", sp.alphaText, "LEFT", -12, 0)
    slider:SetMinMaxValues(0.3, 1)
    slider:SetValueStep(0.05)
    slider:SetObeyStepOnDrag(true)
    local track = Tex(slider, "BACKGROUND", { ACCENT[1], ACCENT[2], ACCENT[3], 0.45 })
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    slider:SetThumbTexture(MEDIA .. "Media\\circle.tga")
    local thumb = slider:GetThumbTexture()
    if thumb then thumb:SetSize(14, 14); thumb:SetVertexColor(Hex("6B5838")[1], Hex("6B5838")[2], Hex("6B5838")[3], 1) end
    slider:SetScript("OnValueChanged", function(self, value)
        if self.quiet then return end
        Settings().alpha = math.floor(value * 20 + 0.5) / 20
        ApplyLook()
        Say2(sp.alphaText, "small", math.floor(Settings().alpha * 100 + 0.5) .. "%", INK)
    end)
    sp.slider = slider
    local fl = sp:CreateFontString(nil, "OVERLAY")
    fl:SetPoint("BOTTOMLEFT", 28, 16)
    Say2(fl, "italicSmall", "Forge's Chronicle v" .. VERSION, INK2)
    local fr = sp:CreateFontString(nil, "OVERLAY")
    fr:SetPoint("BOTTOMRIGHT", -28, 16)
    Say2(fr, "italicSmall", "by Forge at Crescent Cove", INK2)

    -- share your story
    local rp = CreateFrame("Frame", nil, page)
    rp:SetAllPoints()
    journal.recap = rp
    local rt = rp:CreateFontString(nil, "OVERLAY")
    rt:SetPoint("TOPLEFT", 28, -22)
    Say2(rt, "heading", "Share your story", INK)
    rp.mode = "recap"
    local function Seg(label, mode, x)
        local b = OutlineBtn(rp, label, ACCENT, mode == "recap" and 70 or 100)
        b:SetPoint("TOPRIGHT", x, -22)
        b:SetScript("OnClick", function() rp.mode = mode; RenderRecap(true) end)
        return b
    end
    rp.b2 = Seg("Full timeline", "timeline", -28)
    rp.b1 = Seg("Recap", "recap", -28 - 100 - 6)
    local hint = rp:CreateFontString(nil, "OVERLAY")
    hint:SetPoint("TOPLEFT", 28, -54)
    Say2(hint, "italicSmall", "It's selected: press Ctrl+C to copy, then paste it anywhere.", INK2)
    local scroll = CreateFrame("ScrollFrame", nil, rp)
    scroll:SetPoint("TOPLEFT", 28, -78)
    scroll:SetPoint("BOTTOMRIGHT", -28, 20)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = self.GetVerticalScrollRange and self:GetVerticalScrollRange() or 0
        local cur = self.GetVerticalScroll and self:GetVerticalScroll() or 0
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 40)))
    end)
    rp.text = EditBox(scroll, true, "body")
    rp.text:SetWidth(PW - 56)
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
    for _, b in ipairs({ { rp.b1, "recap" }, { rp.b2, "timeline" } }) do
        local on = rp.mode == b[2]
        b[1].bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], on and 1 or 0)
        b[1].text:SetTextColor((on and CARD or ACCENT)[1], (on and CARD or ACCENT)[2], (on and CARD or ACCENT)[3])
    end
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
        if view == "settings" then view = "entry" end
        journal:Show()
    else
        journal:Hide()
    end
end

------------------------------------------------------- chapter ceremony ---
-- Crossing into a new chapter: a full-screen spread with the chapter's
-- name and its epigraph, once per chapter. Any click or key dismisses it.
-- Never during combat, a cutscene or a loading screen: it waits for calm.

local ceremony, pendingChapter

local function Roman(n)
    local out = ""
    for _, p in ipairs({ { 10, "X" }, { 9, "IX" }, { 5, "V" }, { 4, "IV" }, { 1, "I" } }) do
        while n >= p[1] do out, n = out .. p[2], n - p[1] end
    end
    return out
end

local function HideCeremony()
    if ceremony and ceremony:IsShown() then
        pcall(ceremony.EnableKeyboard, ceremony, false)
        ceremony:Hide()
    end
end

local function CreateCeremony()
    ceremony = CreateFrame("Frame", "ForgesChronicleCeremony", UIParent)
    ceremony:SetAllPoints(UIParent)
    ceremony:SetFrameStrata("FULLSCREEN_DIALOG")
    ceremony:EnableMouse(true)
    Tex(ceremony, "BACKGROUND", { 0.04, 0.035, 0.03, 0.88 }):SetAllPoints()
    local g = Tex(ceremony, "BORDER", { GOLD[1], GOLD[2], GOLD[3], 0.18 }, "glow.tga")
    g:SetSize(900, 420)
    g:SetPoint("CENTER", 0, 60)
    ceremony.kicker = ceremony:CreateFontString(nil, "OVERLAY")
    ceremony.kicker:SetPoint("CENTER", 0, 92)
    ceremony.name = ceremony:CreateFontString(nil, "OVERLAY")
    ceremony.name:SetPoint("CENTER", 0, 44)
    local d = Tex(ceremony, "OVERLAY", GOLD, "diamond.tga")
    d:SetSize(12, 12)
    d:SetPoint("CENTER", 0, 4)
    for _, side in ipairs({ -1, 1 }) do
        local r = Tex(ceremony, "ARTWORK", { GOLD[1], GOLD[2], GOLD[3], 0.8 })
        r:SetSize(170, 1)
        r:SetPoint("CENTER", d, "CENTER", side * 96, 0)
        local e = Tex(ceremony, "OVERLAY", GOLD, "diamond.tga")
        e:SetSize(7, 7)
        e:SetPoint("CENTER", d, "CENTER", side * 184, 0)
    end
    ceremony.epigraph = ceremony:CreateFontString(nil, "OVERLAY")
    ceremony.epigraph:SetPoint("TOP", d, "BOTTOM", 0, -22)
    ceremony.epigraph:SetWidth(560)
    ceremony.foot = ceremony:CreateFontString(nil, "OVERLAY")
    ceremony.foot:SetPoint("TOP", ceremony.epigraph, "BOTTOM", 0, -40)
    Say2(ceremony.foot, "italicSmall", "Click anywhere to continue", SUB)
    ceremony.fade = ceremony:CreateAnimationGroup()
    local a = ceremony.fade:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(0.8)
    ceremony:SetScript("OnMouseDown", HideCeremony)
    ceremony:SetScript("OnKeyDown", HideCeremony)
    ceremony:Hide()
end

local function ShowCeremony(chapter)
    if InCombatLockdown() or loading or CinematicPlaying() then
        pendingChapter = chapter
        return
    end
    pendingChapter = nil
    if not ceremony then CreateCeremony() end
    local name = CHAPTERS[math.min(chapter, #CHAPTERS)]
    Say2(ceremony.kicker, "banner", Spaced("Chapter " .. Roman(chapter)), SUB)
    Say2(ceremony.name, "ceremony", name, GOLD)
    Say2(ceremony.epigraph, "epigraph", EPIGRAPHS[math.min(chapter, #EPIGRAPHS)] or "", PARCH)
    ceremony:Show()
    -- keys pass through to the game too, so nothing gets stuck
    pcall(ceremony.EnableKeyboard, ceremony, true)
    pcall(ceremony.SetPropagateKeyboardInput, ceremony, true)
    ceremony.fade:Play()
end

-- after a level-up, or the opening page of a fresh character
ChapterReached = function(level, quietly)
    local d = c.data
    d.chaptersSeen = type(d.chaptersSeen) == "table" and d.chaptersSeen or {}
    local chapter = ChapterOf(level)
    if d.chaptersSeen[chapter] then return end
    d.chaptersSeen[chapter] = time()
    Touch()
    if not quietly and Settings().chapterCeremony then ShowCeremony(chapter) end
end

-- characters journaled before v1.2: chapters already behind them were seen
BackfillChapters = function()
    local d = c.data
    if type(d.chaptersSeen) == "table" then return end
    d.chaptersSeen = {}
    for i = 1, ChapterOf(Level()) do d.chaptersSeen[i] = d.started or time() end
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
        BackfillChapters()
        C_Timer.After(3, function() ChapterReached(Level()) end)
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
        if pendingChapter then C_Timer.After(2, function() if pendingChapter then ShowCeremony(pendingChapter) end end) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        HideCeremony()
        if Settings().hideInCombat and journal and journal:IsShown() then
            hiddenForCombat = true
            journal:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if hiddenForCombat then hiddenForCombat = false; ToggleJournal(true) end
        if pendingChapter then C_Timer.After(1, function() if pendingChapter then ShowCeremony(pendingChapter) end end) end
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
    elseif cmd == "chapter" then
        ShowCeremony(ChapterOf(Level()))
    elseif cmd == "minimap" then
        Settings().minimap = not Settings().minimap
        UpdateMinimap()
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /chronicle - open or close your journal")
        print("  /chronicle recap (or export) - a recap of your story, ready to copy")
        print("  /chronicle name Bob - call it \"Bob's Chronicles\" (/chronicle name on its own: back to \"" .. DEFAULT_TITLE .. "\")")
        print("  /chronicle chapter - see your current chapter's page again")
        print("  /chronicle minimap - show or hide the minimap button")
    end
end
