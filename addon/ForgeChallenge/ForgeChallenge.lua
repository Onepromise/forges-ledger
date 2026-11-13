-- Forge's Challenge v0.1 (WIP) - core: tracking, XP, levels, ranks, dailies, penalties.
-- A game within the game: cosmetic and informational only. Plain frames and events; the
-- combat log is never registered (kills are seen the way Kill Ledger's default counter sees
-- them: your target dying). Nothing is sent anywhere.
local ADDON, ns = ...
ns = ns or {}

local VERSION = "0.1-WIP"
local SCHEMA = 1
local PREFIX = "|cffFFD700[Challenge]|r "
ns.VERSION, ns.PREFIX = VERSION, PREFIX

ForgeChallengeDB = ForgeChallengeDB or {}

-- ------------------------------------------------------------ helpers
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

local function Plain(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end
ns.Plain, ns.Try = Plain, Try

local function IsForever()
    return WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE and true or false
end
ns.IsForever = IsForever

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "Unknown"
    realm = realm:gsub("[%s%'%-]", "")
    return (name or "Unknown") .. "-" .. realm
end

-- ------------------------------------------------------------ saved data
-- ForgeChallengeDB = { schemaVersion, version, settings = {...},
--   characters = { ["Name-Realm"] = { exportedAt, data = {...} } } }
local function DB()
    if type(ForgeChallengeDB) ~= "table" then ForgeChallengeDB = {} end
    local db = ForgeChallengeDB
    db.schemaVersion = SCHEMA
    db.version = IsForever() and "Forever" or "Retail"
    db.settings = type(db.settings) == "table" and db.settings or {}
    local s = db.settings
    if s.hideInCombat == nil then s.hideInCombat = true end
    if s.popups == nil then s.popups = true end
    if s.penalties == nil then s.penalties = true end     -- gentle penalties: on by default (ruling 2)
    if s.minimap == nil then s.minimap = true end
    if s.sound == nil then s.sound = true end
    db.characters = type(db.characters) == "table" and db.characters or {}
    return db
end
ns.DB = DB

local COUNTERS = { "kills", "bosses", "dungeonBosses", "raidBosses", "heroicRaidBosses", "dungeons", "mplus",
                   "mplusTimed", "maxTimedKey", "quests", "worldQuests", "bgWins", "arenaWins", "deaths",
                   "penaltiesDone", "dailiesDone", "daysCompleted" }

local function Data()
    local db = DB()
    local key = CharKey()
    local c = db.characters[key]
    if type(c) ~= "table" then c = { data = {} }; db.characters[key] = c end
    local d = type(c.data) == "table" and c.data or {}
    c.data = d
    d.level = tonumber(d.level) or 1
    d.xp = tonumber(d.xp) or 0          -- XP into the current level
    d.totalXP = tonumber(d.totalXP) or 0
    d.streak = tonumber(d.streak) or 0
    d.bestStreak = tonumber(d.bestStreak) or 0
    d.titles = type(d.titles) == "table" and d.titles or {}
    d.counters = type(d.counters) == "table" and d.counters or {}
    for _, k in ipairs(COUNTERS) do d.counters[k] = tonumber(d.counters[k]) or 0 end
    return d, c
end
ns.Data = Data

local function Stamp()
    local d, c = Data()
    c.exportedAt = time()
    c.character = CharKey()
    -- the readable state other tools (the Ledger's "tonight" view, the dashboard) can use
    local rank = ns.RankName(d.level)
    local done, total = 0, 0
    for _, q in ipairs(d.day and d.day.quests or {}) do total = total + 1; if q.done then done = done + 1 end end
    d.summary = { level = d.level, rank = rank, xp = d.xp, xpToNext = ns.XpForLevel(d.level),
                  streak = d.streak, dailiesDone = done, dailiesTotal = total,
                  penalty = d.penalty and d.penalty.state or nil }
end
ns.Stamp = Stamp

-- ------------------------------------------------------------ XP and levels
local function UI(name, ...)
    if ns.UI and ns.UI[name] then pcall(ns.UI[name], ...) end
end

function ns.TitleCheck()
    local d = Data()
    for _, t in ipairs(ns.TITLES) do
        local v = (t.stat == "bestStreak") and d.bestStreak or d.counters[t.stat] or 0
        if not d.titles[t.id] and v >= t.min then
            d.titles[t.id] = time()
            UI("Alert", "TITLE EARNED", t.name, t.desc)
        end
    end
end

-- Adds XP, rolling over levels. Returns the number of levels gained.
function ns.AddXP(amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return 0 end
    local d = Data()
    d.totalXP = d.totalXP + amount
    d.xp = d.xp + amount
    local gained, rankBefore = 0, ns.RankIndex(d.level)
    while d.xp >= ns.XpForLevel(d.level) do
        d.xp = d.xp - ns.XpForLevel(d.level)
        d.level = d.level + 1
        gained = gained + 1
    end
    if gained > 0 then
        local rankUp = ns.RankIndex(d.level) > rankBefore
        UI("LevelUp", d.level, rankUp and ns.RankName(d.level) or nil, gained)
    end
    Stamp()
    UI("Refresh")
    return gained
end

-- ------------------------------------------------------------ days, dailies, streaks, penalties
-- A day = the stretch between two daily resets. dayIdx counts those days. It comes from
-- C_DateAndTime.GetSecondsUntilDailyReset (the moment of the next reset, in whole days since
-- 1970 UTC); without it the character's local calendar day is used.
function ns.DayIdx()
    local secs = Try(C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset)
    secs = Plain(secs)
    if type(secs) == "number" and secs >= 0 then
        return math.floor((time() + secs) / 86400)
    end
    return math.floor((time() + (ns.TZ or 0)) / 86400)
end

local function IsMaxLevel()
    local lvl = Plain(Try(UnitLevel, "player"))
    local cap = Plain(Try(GetMaxLevelForPlayerExpansion)) or Plain(Try(GetMaxPlayerLevel)) or MAX_PLAYER_LEVEL
    return type(lvl) == "number" and type(cap) == "number" and lvl >= cap
end

local function RealLevel() return Plain(Try(UnitLevel, "player")) or 1 end

local function PickDailies(idx)
    local level, atMax = RealLevel(), IsMaxLevel()
    local pool = {}
    for _, t in ipairs(ns.DAILIES) do
        if level >= t.minLevel and (not t.maxOnly or atMax) then pool[#pool + 1] = t end
    end
    local out = {}
    local n = math.min(ns.DAILIES_PER_DAY, #pool)
    local start = (#pool > n) and (idx % #pool) or 0     -- rotate so a max-level day is not always the same
    for i = 0, n - 1 do
        local t = pool[((start + i) % #pool) + 1]
        out[#out + 1] = { id = t.id, counter = t.counter, text = string.format(t.text, t.target(level)),
                          target = t.target(level), progress = 0, done = false }
    end
    return out
end

local function PickPenalty()
    local level = RealLevel()
    for _, p in ipairs(ns.PENALTIES) do
        if level >= p.minLevel then
            return { id = p.id, counter = p.counter, text = string.format(p.text, p.target(level)),
                     target = p.target(level), progress = 0 }
        end
    end
end

local function BreakStreak(d)
    d.streak = 0
end

-- Called at login, entering the world, and once a minute: starts a new day when the reset passed.
function ns.Rollover()
    local d = Data()
    local idx = ns.DayIdx()
    local s = DB().settings
    local pen = d.penalty
    if d.day and d.day.idx == idx then return false end

    -- settle an old penalty first
    if pen then
        if pen.state == "active" and idx > (pen.untilIdx or -1) then BreakStreak(d); d.penalty = nil
        elseif pen.state == "offered" and idx > (pen.untilIdx or -1) then BreakStreak(d); d.penalty = nil
        elseif pen.state == "done" or pen.state == "declined" then d.penalty = nil end
    end

    local prev = d.day
    if prev then
        local gap = idx - prev.idx
        if gap == 1 then
            if not prev.allDone then
                -- a penalty only exists to save a streak, so there must be one to save
                if s.penalties and d.streak > 0 and not d.penalty then
                    local p = PickPenalty()
                    if p then
                        p.state, p.forIdx, p.untilIdx = "offered", prev.idx, idx
                        d.penalty = p
                    else
                        BreakStreak(d)
                    end
                else
                    BreakStreak(d)
                end
            end
        elseif gap > 1 then
            BreakStreak(d)
            d.penalty = nil
        end
    end
    d.day = { idx = idx, quests = PickDailies(idx), allDone = false }
    Stamp()
    UI("Refresh")
    if d.penalty and d.penalty.state == "offered" then UI("Penalty", d.penalty) end
    return true
end

function ns.AcceptPenalty()
    local d = Data()
    local p = d.penalty
    if not p or p.state ~= "offered" then return false end
    p.state, p.progress, p.untilIdx = "active", 0, ns.DayIdx()   -- "before the next reset"
    Stamp(); UI("Refresh")
    return true
end

function ns.DeclinePenalty()
    local d = Data()
    local p = d.penalty
    if not p or p.state ~= "offered" then return false end
    BreakStreak(d)             -- declining breaks the streak and costs nothing else
    d.penalty = nil
    Stamp(); UI("Refresh")
    return true
end

-- An event counter advanced: kill / quest / dungeon / mplus / worldquest.
function ns.Counter(kind, n)
    n = n or 1
    local d = Data()
    ns.Rollover()
    local day = d.day
    if day then
        for _, q in ipairs(day.quests) do
            if q.counter == kind and not q.done then
                q.progress = math.min(q.target, q.progress + n)
                if q.progress >= q.target then
                    q.done = true
                    d.counters.dailiesDone = d.counters.dailiesDone + 1
                    ns.AddXP(ns.XP_VALUES.daily, "daily")
                    UI("QuestAlert", q.text, ns.XP_VALUES.daily)
                end
            end
        end
        local all = #day.quests > 0
        for _, q in ipairs(day.quests) do if not q.done then all = false end end
        if all and not day.allDone then
            day.allDone = true
            d.streak = d.streak + 1
            if d.streak > d.bestStreak then d.bestStreak = d.streak end
            d.counters.daysCompleted = d.counters.daysCompleted + 1
            ns.AddXP(ns.XP_VALUES.dailyAll, "dailies")
            UI("QuestAlert", "All dailies complete - streak " .. d.streak, ns.XP_VALUES.dailyAll)
        end
    end
    local p = d.penalty
    if p and p.state == "active" and p.counter == kind then
        p.progress = math.min(p.target, p.progress + n)
        if p.progress >= p.target then
            p.state = "done"
            d.counters.penaltiesDone = d.counters.penaltiesDone + 1
            ns.AddXP(ns.XP_VALUES.penalty, "penalty")
            UI("QuestAlert", "Penalty complete - streak saved", ns.XP_VALUES.penalty)
        end
    end
    ns.TitleCheck()
    Stamp()
    UI("Refresh")
end

-- ------------------------------------------------------------ the event map (spec 5.1)
local function Bump(name, n)
    local d = Data()
    d.counters[name] = (d.counters[name] or 0) + (n or 1)
end

local function DifficultyClass(id)
    -- Retail difficulty ids: 1/23 normal-ish dungeon, 2 heroic dungeon; raids 14 normal, 15 heroic, 16 mythic, 7/17 LFR.
    if id == 16 or id == 23 or id == 6 then return "mythic" end
    if id == 15 or id == 2 or id == 5 then return "heroic" end
    if id == 7 or id == 17 then return "lfr" end
    return "normal"
end

local function InstanceInfo()
    local inInst, itype = Try(IsInInstance)
    if not inInst then return nil end
    local name, _, diffID = Try(GetInstanceInfo)
    return itype, Plain(name), Plain(diffID)
end

function ns.OnKill(classification)
    local v = ns.XP_VALUES.kill[classification or "normal"] or ns.XP_VALUES.kill.normal
    Bump("kills")
    ns.AddXP(v, "kill")
    ns.Counter("kill")
end

function ns.OnEncounterEnd(encounterName, success)
    if success ~= 1 and success ~= true then return end
    local itype, name, diffID = InstanceInfo()
    local d = Data()
    if itype == "party" then
        Bump("bosses"); Bump("dungeonBosses")
        ns.AddXP(ns.XP_VALUES.dungeonBoss, "boss")
    elseif itype == "raid" then
        local cls = DifficultyClass(diffID)
        Bump("bosses"); Bump("raidBosses")
        if cls == "heroic" or cls == "mythic" then Bump("heroicRaidBosses") end
        ns.AddXP(ns.XP_VALUES.raidBoss[cls] or ns.XP_VALUES.raidBoss.normal, "boss")
    else
        return
    end
    ns.GateBoss(encounterName)
    ns.TitleCheck()
end

local clearedRun = {}
function ns.OnDungeonClear(token)
    local itype = InstanceInfo()
    if itype ~= "party" then return end
    token = token or "run"
    if clearedRun[token] and (time() - clearedRun[token]) < 600 then return end   -- one credit per run
    clearedRun[token] = time()
    Bump("dungeons")
    ns.AddXP(ns.XP_VALUES.dungeonClear, "clear")
    ns.Counter("dungeon")
    UI("Alert", "GATE CLEARED", ns.gate and ns.gate.name or "Dungeon", "+" .. ns.XP_VALUES.dungeonClear .. " XP")
end

function ns.OnMythicPlus(level, onTime)
    level = tonumber(level)
    if not level or level <= 0 then return end
    local xp = ns.XP_VALUES.mplusPerLevel * level
    if onTime then
        xp = math.floor(xp * (1 + ns.XP_VALUES.mplusTimedBonus))
        Bump("mplusTimed")
        local d = Data()
        if level > d.counters.maxTimedKey then d.counters.maxTimedKey = level end
    end
    Bump("mplus"); Bump("dungeons")
    ns.AddXP(xp, "mplus")
    ns.Counter("mplus"); ns.Counter("dungeon")
end

function ns.OnQuest(questID)
    local repeatable = Plain(Try(C_QuestLog and C_QuestLog.IsRepeatableQuest, questID))
    local wq = Plain(Try(C_QuestLog and C_QuestLog.IsWorldQuest, questID))
    Bump("quests")
    if wq then Bump("worldQuests") end
    ns.AddXP(repeatable and ns.XP_VALUES.questRepeatable or ns.XP_VALUES.quest, "quest")
    ns.Counter("quest")
    if wq then ns.Counter("worldquest") end
end

function ns.OnPvPWin(isArena)
    if isArena then Bump("arenaWins"); ns.AddXP(ns.XP_VALUES.arenaWin, "arena")
    else Bump("bgWins"); ns.AddXP(ns.XP_VALUES.bgWin, "bg") end
    ns.TitleCheck()
end

function ns.OnRealLevelUp()
    ns.AddXP(ns.XP_VALUES.levelUp, "levelup")
end

function ns.OnDeath()
    Bump("deaths")
    print(PREFIX .. "The Challenge acknowledges your struggle. Your streak is untouched.")
end

-- ------------------------------------------------------------ gates (spec 9, solo part)
ns.gate = nil
function ns.GateEnter()
    local itype, name, diffID = InstanceInfo()
    if itype ~= "party" and itype ~= "raid" then ns.gate = nil; return end
    local key = tostring(name) .. ":" .. tostring(diffID)
    if ns.gate and ns.gate.key == key then return end
    local cls = DifficultyClass(diffID)
    local rank
    if itype == "raid" then rank = ns.GATE.raid[cls]
    else rank = ns.GATE.dungeon[cls] end
    local mkey = Plain(Try(C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo))
    if itype == "party" and type(mkey) == "number" and mkey > 0 then rank = ns.GATE.mplus(mkey) end
    -- difficulty ids are Retail's; on Forever they are not verified, so no rank is guessed
    if IsForever() then rank = "?" end
    ns.gate = { key = key, name = name or "Unknown", rank = rank or "?", bosses = {}, kind = itype }
    UI("Gate", ns.gate)
end

function ns.GateBoss(name)
    if not ns.gate then return end
    ns.gate.bosses[#ns.gate.bosses + 1] = tostring(name or "Boss")
    UI("Gate", ns.gate, true)
end

-- ------------------------------------------------------------ stats (flavor, derived from counters)
function ns.Stats()
    local d = Data()
    local c = d.counters
    local ilvl = Plain(Try(GetAverageItemLevel))
    ilvl = type(ilvl) == "number" and ilvl or 0
    return {
        STR = 10 + math.floor(ilvl / 10),
        AGI = 10 + math.floor(c.quests / 25),
        VIT = 10 + math.floor(c.bosses / 10),
        INT = 10 + math.floor(c.dailiesDone / 10),
        SEN = 10 + math.floor(c.kills / 200),
    }
end

-- ------------------------------------------------------------ the kill observer (no combat log)
local seen = {}          -- guid -> time credited

local function TargetDied()
    if not Plain(Try(UnitExists, "target")) then return end
    if not Plain(Try(UnitIsDead, "target")) then return end
    if Plain(Try(UnitIsPlayer, "target")) then return end
    if Plain(Try(UnitIsTapDenied, "target")) then return end
    local guid = Plain(Try(UnitGUID, "target"))
    if type(guid) ~= "string" then return end
    local t = time()
    if seen[guid] and t - seen[guid] < 600 then return end
    seen[guid] = t
    local n = 0
    for g, ts in pairs(seen) do n = n + 1; if t - ts > 600 then seen[g] = nil end end
    ns.OnKill(Plain(Try(UnitClassification, "target")))
end

-- ------------------------------------------------------------ events
local frame = CreateFrame("Frame", "ForgeChallengeDriver")
local E = {
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_TARGET_CHANGED",
    "UNIT_HEALTH", "ENCOUNTER_END", "CHALLENGE_MODE_COMPLETED", "QUEST_TURNED_IN", "PVP_MATCH_COMPLETE",
    "PLAYER_LEVEL_UP", "PLAYER_DEAD", "LFG_COMPLETION_REWARD", "SCENARIO_COMPLETED", "PLAYER_REGEN_ENABLED",
}
for _, e in ipairs(E) do pcall(frame.RegisterEvent, frame, e) end   -- in case a client lacks one

local acc = 0
frame:SetScript("OnEvent", function(_, event, a, b, c, d4, e5)
    if event == "ADDON_LOADED" then
        if a ~= ADDON then return end
        DB(); Data()
        return
    end
    if not (ForgeChallengeDB and ForgeChallengeDB.settings) then return end
    if event == "PLAYER_LOGIN" then
        ns.Rollover(); Stamp(); UI("Init")
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        ns.Rollover()
        ns.GateEnter()
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- (nothing to remember: the target's own state is read when it dies)
    elseif event == "UNIT_HEALTH" then
        if a == "target" then pcall(TargetDied) end
    elseif event == "ENCOUNTER_END" then
        pcall(ns.OnEncounterEnd, Plain(b), Plain(e5))
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        local info
        if C_ChallengeMode and C_ChallengeMode.GetChallengeCompletionInfo then
            info = Plain(Try(C_ChallengeMode.GetChallengeCompletionInfo))
        end
        if type(info) == "table" then
            pcall(ns.OnMythicPlus, Plain(info.level), Plain(info.onTime))
        else
            local _, level, _, onTime = Try(C_ChallengeMode and C_ChallengeMode.GetCompletionInfo)
            pcall(ns.OnMythicPlus, Plain(level), Plain(onTime))
        end
    elseif event == "QUEST_TURNED_IN" then
        pcall(ns.OnQuest, Plain(a))
    elseif event == "PVP_MATCH_COMPLETE" then
        -- credited only when the winner and the player's side can both be read and agree
        local winner = Plain(a)
        local mine = Plain(Try(GetBattlefieldArenaFaction))
        if type(winner) == "number" and type(mine) == "number" and winner == mine then
            pcall(ns.OnPvPWin, Plain(Try(C_PvP and C_PvP.IsArena)) and true or false)
        end
    elseif event == "PLAYER_LEVEL_UP" then
        pcall(ns.OnRealLevelUp)
    elseif event == "PLAYER_DEAD" then
        pcall(ns.OnDeath)
    elseif event == "LFG_COMPLETION_REWARD" or event == "SCENARIO_COMPLETED" then
        pcall(ns.OnDungeonClear, ns.gate and ns.gate.key or "run")
    elseif event == "PLAYER_REGEN_ENABLED" then
        UI("Flush")
    end
end)
frame:SetScript("OnUpdate", function(_, dt)
    acc = acc + (dt or 0)
    if acc >= 60 then acc = 0; if ForgeChallengeDB and ForgeChallengeDB.settings then pcall(ns.Rollover) end end
end)

-- ------------------------------------------------------------ slash
SLASH_FORGECHALLENGE1 = "/fc"
SLASH_FORGECHALLENGE2 = "/challenge"
SlashCmdList["FORGECHALLENGE"] = function(msg)
    msg = strtrim((msg or ""):lower())
    local s = DB().settings
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    local function flag(name, label, arg)
        if arg == "on" then s[name] = true elseif arg == "off" then s[name] = false else s[name] = not s[name] end
        print(PREFIX .. label .. " " .. (s[name] and "on" or "off") .. ".")
        UI("Refresh")
    end
    if cmd == "" or cmd == "status" then UI("ToggleStatus")
    elseif cmd == "daily" or cmd == "dailies" then UI("ToggleDaily")
    elseif cmd == "penalty" then
        local d = Data()
        if d.penalty and d.penalty.state == "offered" then UI("Penalty", d.penalty)
        elseif d.penalty and d.penalty.state == "active" then
            print(PREFIX .. "Penalty: " .. d.penalty.text .. " (" .. d.penalty.progress .. "/" .. d.penalty.target .. ")")
        else print(PREFIX .. "No penalty right now.") end
    elseif cmd == "penalties" then flag("penalties", "Penalty quests", rest)
    elseif cmd == "combat" then flag("hideInCombat", "Hide popups in combat", rest)
    elseif cmd == "popups" then flag("popups", "Popups", rest)
    elseif cmd == "sound" then flag("sound", "Sounds", rest)
    elseif cmd == "minimap" then flag("minimap", "Minimap button", rest)
    elseif cmd == "xp" then
        local d = Data()
        print(PREFIX .. "Level " .. d.level .. " (" .. ns.RankName(d.level) .. "): " .. d.xp .. " / " .. ns.XpForLevel(d.level)
            .. " XP. Streak " .. d.streak .. ".")
    elseif cmd == "values" then
        local v = ns.XP_VALUES
        print(PREFIX .. "XP values (all in ForgeChallenge_Data.lua): kill " .. v.kill.normal .. "/" .. v.kill.elite .. "/" .. v.kill.rare
            .. ", dungeon boss " .. v.dungeonBoss .. ", clear " .. v.dungeonClear .. ", M+ " .. v.mplusPerLevel .. "xlevel, quest "
            .. v.quest .. ", level-up " .. v.levelUp .. ", daily " .. v.daily .. ", all dailies " .. v.dailyAll)
    elseif cmd == "reset" then
        if rest == "confirm" then
            local db = DB(); db.characters[CharKey()] = nil; Data(); ns.Rollover(); Stamp(); UI("Refresh")
            print(PREFIX .. "This character's Challenge progress was reset.")
        else
            print(PREFIX .. "This erases this character's Challenge level, streak and titles. Type /fc reset confirm to do it.")
        end
    else
        print(PREFIX .. "v" .. VERSION .. (IsForever() and " (WoW Forever: preview, numbers not verified on this client)" or "") .. " commands:")
        print("  /fc - Status window; /fc daily - Daily Quests; /fc penalty - the current penalty; /fc xp")
        print("  /fc penalties|combat|popups|sound|minimap on|off - settings (combat = hide popups in combat)")
        print("  /fc values - the XP values; /fc reset - start this character over")
    end
end

ForgeChallenge = { version = VERSION, schema = SCHEMA, ns = ns }
