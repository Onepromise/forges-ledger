-- Forge's Challenge: the tunable tables. Everything numeric lives here so it can be changed
-- (and listed) in one place. `src` says where each number comes from: "spec" = the Challenge
-- spec (2026-10-16), "chosen" = not in the spec, picked for v1 and flagged for Forge.
local _, ns = ...

ns.XP_VALUES = {
    kill = { normal = 1, elite = 3, rare = 10, rareelite = 10, worldboss = 10 },
    dungeonBoss = 50,
    dungeonClear = 150,
    mplusPerLevel = 100,
    mplusTimedBonus = 0.5,
    raidBoss = { normal = 100, heroic = 200, mythic = 400, lfr = 100 },
    quest = 10,
    questRepeatable = 2,
    bgWin = 75,
    arenaWin = 100,
    levelUp = 250,
    daily = 50,
    dailyAll = 100,
    penalty = 75,
    src = {
        kill = "spec 5.1 (normal 1 / elite 3 / rare 10); rareelite and worldboss use the rare value: chosen",
        dungeonBoss = "spec 5.1", dungeonClear = "spec 5.1",
        mplusPerLevel = "spec 5.1", mplusTimedBonus = "spec 5.1 (+50%)",
        raidBoss = "spec 5.1 (Normal 100 / Heroic 200 / Mythic 400); LFR uses the Normal value: chosen",
        quest = "spec 5.1 (10, repeatables 2)", questRepeatable = "spec 5.1",
        bgWin = "spec 5.1", arenaWin = "spec 5.1", levelUp = "spec 5.1",
        daily = "chosen (spec gives no daily reward)", dailyAll = "chosen (spec gives no daily reward)",
        penalty = "chosen (spec gives no penalty reward)",
    },
}

-- xpForLevel(n) = XP to go from Challenge level n to n+1. Spec 5.2: 1000 * n^1.5 (tunable constant).
ns.LEVEL_BASE, ns.LEVEL_POWER = 1000, 1.5
function ns.XpForLevel(n)
    return math.floor(ns.LEVEL_BASE * (math.max(1, n) ^ ns.LEVEL_POWER))
end

-- Rank = one per 10 Challenge levels (Forge's ruling 2026-11-13): levels 1-9 Cinder ... 50+ Eternal.
ns.RANKS = { "Cinder", "Spark", "Ember", "Blaze", "Inferno", "Eternal" }
function ns.RankIndex(level)
    return math.min(#ns.RANKS, math.floor(math.max(1, level) / 10) + 1)
end
function ns.RankName(level) return ns.RANKS[ns.RankIndex(level)] end

-- Titles, data-driven: earned when counter `stat` reaches `min` (spec 6).
ns.TITLES = {
    { id = "gatecrasher", name = "Gatecrasher", desc = "Clear 10 dungeons", stat = "dungeons", min = 10 },
    { id = "keystone", name = "Keystone Tempered", desc = "Time a +10 Mythic+", stat = "maxTimedKey", min = 10 },
    { id = "unbroken", name = "Unbroken", desc = "A 30-day daily streak", stat = "bestStreak", min = 30 },
    { id = "dragonshadow", name = "Dragonslayer's Shadow",
      desc = "Kill a raid boss on Heroic or higher (v1 counts any raid boss kill; end-boss detection is not reliable yet)",
      stat = "heroicRaidBosses", min = 1 },
    { id = "relentless", name = "The Relentless", desc = "10,000 lifetime kills", stat = "kills", min = 10000 },
    { id = "survivor", name = "Penalty Survivor", desc = "Complete 5 penalty quests", stat = "penaltiesDone", min = 5 },
}

-- Daily quest templates (spec 7). counter = which tracked event advances it.
-- target(level) gives the amount; minLevel / maxOnly decide who can be given it.
-- pool = which track it belongs to ("pve" or "pvp"); `needs` lists what the client must have for the
-- quest to be trackable at all -- events that must have registered and APIs that must exist -- so a
-- daily a client cannot track never enters its pool (decided by the client, never guessed by version).
local function tier(level, a, b, c, d) if level < 20 then return a elseif level < 40 then return b elseif level < 60 then return c end return d end
ns.TRACKS = { "pve", "pvp", "mixed" }
ns.TRACK_NAMES = { pve = "PvE", pvp = "PvP", mixed = "Mixed" }
ns.TRACK_BLURB = {
    pve = "Kills, dungeons, bosses, quests.",
    pvp = "Battlegrounds, arenas, player kills.",
    mixed = "A blend of both.",
}
ns.DAILIES = {
    -- PvE pool
    { id = "kills", pool = "pve", counter = "kill", minLevel = 1, text = "Slay %d enemies",
      target = function(l) return tier(l, 10, 25, 40, 60) end },
    { id = "quests", pool = "pve", counter = "quest", minLevel = 1, text = "Turn in %d quests",
      target = function(l) return tier(l, 2, 3, 4, 5) end },
    { id = "dungeon", pool = "pve", counter = "dungeon", minLevel = 10, text = "Complete %d dungeons",
      target = function(l) return 2 end },
    { id = "bosses", pool = "pve", counter = "boss", minLevel = 10, text = "Defeat %d dungeon or raid bosses",
      target = function(l) return 3 end, needs = { events = { "ENCOUNTER_END" } } },
    { id = "mplus", pool = "pve", counter = "mplus", minLevel = 1, maxOnly = true, text = "Complete %d Mythic+ dungeon",
      target = function(l) return 1 end, needs = { events = { "CHALLENGE_MODE_COMPLETED" } } },
    { id = "worldquest", pool = "pve", counter = "worldquest", minLevel = 1, maxOnly = true, text = "Complete %d world quests",
      target = function(l) return 4 end, needs = { apis = { "C_QuestLog.IsWorldQuest" } } },
    -- PvP pool (a battleground / arena result comes from PVP_MATCH_COMPLETE; an arena also needs C_PvP.IsArena
    -- to tell it from a battleground; player kills come from the target observer and need nothing)
    { id = "bgwin", pool = "pvp", counter = "bgwin", minLevel = 10, text = "Win %d battleground",
      target = function(l) return 1 end, needs = { events = { "PVP_MATCH_COMPLETE" } } },
    { id = "bggame", pool = "pvp", counter = "bggame", minLevel = 10, text = "Finish %d battlegrounds",
      target = function(l) return 2 end, needs = { events = { "PVP_MATCH_COMPLETE" } } },
    { id = "arenawin", pool = "pvp", counter = "arenawin", minLevel = 10, text = "Win %d arena match",
      target = function(l) return 1 end, needs = { events = { "PVP_MATCH_COMPLETE" }, apis = { "C_PvP.IsArena" } } },
    { id = "arenagame", pool = "pvp", counter = "arenagame", minLevel = 10, text = "Finish %d arena matches",
      target = function(l) return 2 end, needs = { events = { "PVP_MATCH_COMPLETE" }, apis = { "C_PvP.IsArena" } } },
    { id = "pvpkill", pool = "pvp", counter = "pvpkill", minLevel = 1, text = "Defeat %d enemy players",
      target = function(l) return tier(l, 5, 10, 15, 20) end },
    src = "chosen: spec 7 gives only two examples (level 20: 2 dungeons; max level: 1 M+ and 4 world quests); the rest, and every PvP quest, are picked for v1",
}
ns.DAILIES_PER_DAY = 3

-- Gentle penalty objectives (Forge's ruling: in-game extra objectives, auto-tracked). A penalty is drawn
-- from the SAME pool as the daily that was missed.
ns.PENALTIES = {
    { id = "dungeons", pool = "pve", counter = "dungeon", minLevel = 10, text = "Complete %d extra dungeons before the next reset",
      target = function(l) return 2 end },
    { id = "kills", pool = "pve", counter = "kill", minLevel = 1, text = "Slay %d extra enemies before the next reset",
      target = function(l) return 25 end },
    { id = "bggames", pool = "pvp", counter = "bggame", minLevel = 10, text = "Finish %d extra battlegrounds before the next reset",
      target = function(l) return 2 end, needs = { events = { "PVP_MATCH_COMPLETE" } } },
    { id = "pvpkills", pool = "pvp", counter = "pvpkill", minLevel = 1, text = "Defeat %d extra enemy players before the next reset",
      target = function(l) return 10 end },
    src = "spec 7 example: 2 extra dungeons; the rest are chosen",
}

-- Gate ranks (spec 9). Mythic+ key levels: <10 B, 10-14 A, 15+ S (spec says "B/A/S by key level": thresholds chosen).
ns.GATE = {
    dungeon = { normal = "D", heroic = "C", mythic = "C" },
    raid = { lfr = "C", normal = "B", heroic = "A", mythic = "S" },
    mplus = function(key) if key >= 15 then return "S" elseif key >= 10 then return "A" end return "B" end,
}
