"""Forge's Challenge v1 (solo) in the mock WoW UI: XP and levels, ranks, the Retail event map,
dailies, streaks, gentle penalties, titles, gates, popups and windows, settings, Forever."""
import os, sys
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = sys.argv[1]
fails, passes = [], 0


def check(name, cond, detail=""):
    global passes
    if cond:
        passes += 1
        print("  ok  ", name)
    else:
        fails.append(name)
        print("  FAIL", name, "->", detail)


MOCK = open(os.path.join(HERE, "wowmock.lua"), encoding="utf-8").read()
WORLD = r'''
Minimap = CreateFrame("Frame", "Minimap"); Minimap:SetSize(198, 198)
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function issecretvalue(v) return false end
function UnitFullName() return "Testchar", "Area52" end
LVL, MAXLVL = 30, 90
function UnitLevel() return LVL end
function GetMaxLevelForPlayerExpansion() return MAXLVL end
function GetAverageItemLevel() return 215 end
-- the daily reset: 10:00 UTC every day
function C_DateAndTime_secs() return (36000 - (time() % 86400)) % 86400 end
C_DateAndTime = { GetSecondsUntilDailyReset = function() return C_DateAndTime_secs() end }
-- target
TGT = nil
function UnitExists(u) return u == "target" and TGT ~= nil end
function UnitIsDead(u) return TGT ~= nil and TGT.dead == true end
function UnitIsPlayer(u) return TGT ~= nil and TGT.player == true end
function UnitIsTapDenied(u) return TGT ~= nil and TGT.tap == true end
function UnitGUID(u) return TGT and TGT.guid end
function UnitClassification(u) return TGT and TGT.class or "normal" end
NKILL = 0
function KILL(class, extra)
  NKILL = NKILL + 1
  TGT = { guid = "Creature-0-1-1-1-100-" .. NKILL, class = class or "normal", dead = true }
  for k, v in pairs(extra or {}) do TGT[k] = v end
  FireEvent("UNIT_HEALTH", "target")
end
-- instances
INST, ITYPE, INAME, DIFF = false, "none", "", 1
function IsInInstance() return INST, ITYPE end
function GetInstanceInfo() return INAME, ITYPE, DIFF end
function ENTER(name, itype, diff) INST, ITYPE, INAME, DIFF = true, itype, name, diff; FireEvent("ZONE_CHANGED_NEW_AREA") end
function LEAVE() INST, ITYPE, INAME, DIFF = false, "none", "", 1; FireEvent("ZONE_CHANGED_NEW_AREA") end
C_QuestLog = { IsRepeatableQuest = function(id) return id >= 5000 and id < 6000 end,
               IsWorldQuest = function(id) return id >= 6000 end }
KEY = nil
C_ChallengeMode = { GetChallengeCompletionInfo = function() return KEY end, GetActiveKeystoneInfo = function() return 0 end }
GetBattlefieldArenaFaction = function() return 1 end
C_PvP = { IsArena = function() return false end }
SOUNDS = {}
function PlaySound(id) table.insert(SOUNDS, id) end
function Fire(e, ...) FireEvent(e, ...); RunTimers() end
'''


def make(extra="", saved="", forever=False):
    R = lua51.LuaRuntime(unpack_returned_tuples=True)
    R.execute(MOCK)
    R.execute(WORLD)
    if forever:
        R.execute("WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 2, 1; GetMaxLevelForPlayerExpansion = nil; MAX_PLAYER_LEVEL = 60")
    R.execute(extra)
    ns = R.eval("{}")
    R.globals().NS = ns
    for f in ["ForgeChallenge_Data.lua", "ForgeChallenge.lua", "ForgeChallenge_UI.lua"]:
        code = open(os.path.join(ADDON, "ForgeChallenge", f), encoding="utf-8").read()
        chunk = R.eval("function(code, n) local f, err = loadstring(code, '@'..n); if not f then error(err) end; return f end")(code, f)
        chunk("ForgeChallenge", ns)
    R.execute(saved)
    R.execute('FireEvent("ADDON_LOADED", "ForgeChallenge"); FireEvent("PLAYER_LOGIN"); FireEvent("PLAYER_ENTERING_WORLD"); RunTimers()')
    return R


def ev(R, s): R.execute(s + "; RunTimers()")
def D(R, path): return R.eval("ForgeChallengeDB.characters['Testchar-Area52'].data." + path)
def printed(R): return " | ".join(R.eval("PRINTED").values())
def errors(R): return [p for p in R.eval("PRINTED").values() if "error" in p.lower()]
def tick(R, secs): ev(R, "AdvanceTime(%d)" % secs); R.execute("NS.Rollover()")
def popup(R): return R.eval("ForgeChallengePopup and ForgeChallengePopup:IsShown()")
def run_popups(R, secs=20):
    for _ in range(int(secs * 10)):
        R.execute("if ForgeChallengePopup then ForgeChallengePopup._scripts.OnUpdate(ForgeChallengePopup, 0.1) end")


print("== loads, saved data, no combat log")
R = make()
check("it loads without errors", not errors(R))
check("the save file has the shared envelope", R.eval("ForgeChallengeDB.schemaVersion") == 1 and R.eval("ForgeChallengeDB.version") == "Retail"
      and R.eval("ForgeChallengeDB.characters['Testchar-Area52'].exportedAt") is not None)
check("the combat log is never registered", R.eval("(function() for f in pairs(EVENT_FRAMES) do if f._events.COMBAT_LOG_EVENT_UNFILTERED then return true end end return false end)()") is False)
check("a new character starts at level 1 with 0 XP", D(R, "level") == 1 and D(R, "xp") == 0)
check("the state is readable: a summary sits in the save", D(R, "summary.rank") == "Cinder" and D(R, "summary.xpToNext") == 1000 and D(R, "summary.dailiesTotal") >= 1)

print("\n== XP, levels, ranks")
check("level curve: xpForLevel(1) = 1000", R.eval("NS.XpForLevel(1)") == 1000)
check("level curve: xpForLevel(4) = 8000 (1000 * 4^1.5)", R.eval("NS.XpForLevel(4)") == 8000)
check("level curve: xpForLevel(5) = 11180", R.eval("NS.XpForLevel(5)") == 11180)
ev(R, "NS.AddXP(999)")
check("999 XP is still level 1", D(R, "level") == 1 and D(R, "xp") == 999)
ev(R, "NS.AddXP(1)")
check("1000 XP makes level 2, with the overflow carried", D(R, "level") == 2 and D(R, "xp") == 0)
ev(R, "NS.AddXP(1000 + 2828 + 50)")
check("a big gain rolls several levels and carries the rest (2 -> 3 costs 2828; 1050 left)", D(R, "level") == 3 and D(R, "xp") == 1050, (D(R, "level"), D(R, "xp")))
names = [R.eval("NS.RankName(%d)" % n) for n in (1, 9, 10, 19, 20, 30, 40, 49, 50, 120)]
check("ranks: one per 10 levels, Cinder to Eternal", names == ["Cinder", "Cinder", "Spark", "Spark", "Ember", "Blaze", "Inferno", "Inferno", "Eternal", "Eternal"], names)
t0 = D(R, "totalXP")
ev(R, "NS.AddXP(0); NS.AddXP(-5)")
check("zero or negative XP does nothing", D(R, "totalXP") == t0)

print("\n== the Retail event map")
R = make()
x0 = D(R, "totalXP")
ev(R, "KILL('normal')")
check("a normal kill is worth 1", D(R, "totalXP") - x0 == 1 and D(R, "counters.kills") == 1)
ev(R, "KILL('elite')"); check("an elite kill is worth 3", D(R, "totalXP") - x0 == 4)
ev(R, "KILL('rare')"); check("a rare kill is worth 10", D(R, "totalXP") - x0 == 14)
ev(R, "KILL('rareelite')"); check("a rare elite uses the rare value", D(R, "totalXP") - x0 == 24)
n = D(R, "counters.kills")
ev(R, "FireEvent('UNIT_HEALTH', 'target')")
check("the same corpse is credited once", D(R, "counters.kills") == n)
ev(R, "KILL('normal', { player = true })")
check("a player is not a kill", D(R, "counters.kills") == n)
ev(R, "KILL('normal', { tap = true })")
check("a tap-denied corpse is not credited", D(R, "counters.kills") == n)
ev(R, "TGT = { guid = 'Creature-0-1-1-1-100-9999', dead = false }; FireEvent('UNIT_HEALTH', 'target')")
check("a living target is not a kill", D(R, "counters.kills") == n)
ev(R, "FireEvent('UNIT_HEALTH', 'party1')")
check("other units' health is ignored", D(R, "counters.kills") == n)

R = make()
x0 = D(R, "totalXP")
ev(R, "ENTER('Test Dungeon', 'party', 1); FireEvent('ENCOUNTER_END', 1, 'Boss One', 1, 5, 1)")
check("a dungeon boss kill is worth 50", D(R, "totalXP") - x0 == 50 and D(R, "counters.dungeonBosses") == 1)
ev(R, "FireEvent('ENCOUNTER_END', 2, 'Boss Two', 1, 5, 0)")
check("a wipe (success 0) is worth nothing", D(R, "totalXP") - x0 == 50)
ev(R, "LEAVE(); ENTER('Test Raid', 'raid', 14); FireEvent('ENCOUNTER_END', 3, 'R1', 14, 20, 1)")
check("a Normal raid boss is worth 100", D(R, "totalXP") - x0 == 150)
ev(R, "DIFF = 15; FireEvent('ENCOUNTER_END', 4, 'R2', 15, 20, 1)")
check("a Heroic raid boss is worth 200", D(R, "totalXP") - x0 == 350 and D(R, "counters.heroicRaidBosses") == 1)
ev(R, "DIFF = 16; FireEvent('ENCOUNTER_END', 5, 'R3', 16, 20, 1)")
check("a Mythic raid boss is worth 400", D(R, "totalXP") - x0 == 750)
ev(R, "DIFF = 17; FireEvent('ENCOUNTER_END', 6, 'R4', 17, 20, 1)")
check("an LFR boss uses the Normal value (100)", D(R, "totalXP") - x0 == 850)
ev(R, "LEAVE(); FireEvent('ENCOUNTER_END', 7, 'World', 0, 1, 1)")
check("a boss outside any instance is not counted", D(R, "totalXP") - x0 == 850)

R = make()
x0 = D(R, "totalXP")
ev(R, "ENTER('Test Dungeon', 'party', 1); FireEvent('LFG_COMPLETION_REWARD')")
check("a dungeon clear is worth 150 and counts as a dungeon", D(R, "totalXP") - x0 >= 150 and D(R, "counters.dungeons") == 1)
ev(R, "FireEvent('SCENARIO_COMPLETED')")
check("the same run is credited once", D(R, "counters.dungeons") == 1)
x0 = D(R, "totalXP")
ev(R, "LEAVE(); KEY = { level = 8, onTime = false }; FireEvent('CHALLENGE_MODE_COMPLETED')")
check("a +8 Mythic+ is worth 100 x level", D(R, "totalXP") - x0 >= 800 and D(R, "counters.mplus") == 1, D(R, "totalXP") - x0)
x0 = D(R, "totalXP")
ev(R, "KEY = { level = 10, onTime = true }; FireEvent('CHALLENGE_MODE_COMPLETED')")
check("a timed +10 is worth 1000 + 50%", D(R, "totalXP") - x0 >= 1500 and D(R, "counters.maxTimedKey") == 10, D(R, "totalXP") - x0)

R = make()
x0 = D(R, "totalXP")
ev(R, "FireEvent('QUEST_TURNED_IN', 1234)")
check("a quest is worth 10", D(R, "totalXP") - x0 == 10 and D(R, "counters.quests") == 1)
ev(R, "FireEvent('QUEST_TURNED_IN', 5100)")
check("a repeatable quest is worth 2", D(R, "totalXP") - x0 == 12)
ev(R, "FireEvent('QUEST_TURNED_IN', 6100)")
check("a world quest counts as a world quest too", D(R, "counters.worldQuests") == 1)
x0 = D(R, "totalXP")
ev(R, "FireEvent('PVP_MATCH_COMPLETE', 1)")
check("a battleground win (winner = my side) is worth 75", D(R, "totalXP") - x0 == 75 and D(R, "counters.bgWins") == 1)
ev(R, "FireEvent('PVP_MATCH_COMPLETE', 0)")
check("a loss is worth nothing", D(R, "counters.bgWins") == 1)
ev(R, "GetBattlefieldArenaFaction = function() return nil end; FireEvent('PVP_MATCH_COMPLETE', 1)")
check("an unreadable side is never credited", D(R, "counters.bgWins") == 1)
ev(R, "GetBattlefieldArenaFaction = function() return 1 end; C_PvP.IsArena = function() return true end; FireEvent('PVP_MATCH_COMPLETE', 1)")
check("an arena win is worth 100", D(R, "counters.arenaWins") == 1)
x0 = D(R, "totalXP")
ev(R, "FireEvent('PLAYER_LEVEL_UP', 31)")
check("a real level-up is worth 250", D(R, "totalXP") - x0 == 250)
x0 = D(R, "totalXP")
ev(R, "FireEvent('PLAYER_DEAD')")
check("death is worth 0, acknowledged, and the streak is untouched", D(R, "totalXP") == x0 and "acknowledges your struggle" in printed(R) and D(R, "counters.deaths") == 1)

print("\n== dailies, streaks, penalties")
R = make(extra="LVL = 5")
check("a level-5 character gets only what it can do (no dungeon dailies)", all(q["id"] != "dungeon" for q in [R.eval("ForgeChallengeDB.characters['Testchar-Area52'].data.day.quests[%d]" % i) for i in (1, 2)]) and R.eval("#ForgeChallengeDB.characters['Testchar-Area52'].data.day.quests") == 2)
R = make(extra="LVL = 30")
ids = [R.eval("ForgeChallengeDB.characters['Testchar-Area52'].data.day.quests[%d].id" % i) for i in (1, 2, 3)]
check("a level-30 character gets kills, quests and a dungeon", sorted(ids) == ["dungeon", "kills", "quests"], ids)
R = make(extra="LVL = 90")
ids = [R.eval("ForgeChallengeDB.characters['Testchar-Area52'].data.day.quests[%d].id" % i) for i in (1, 2, 3)]
check("a max-level character is offered M+ and world quests in the pool", len(set(ids)) == 3 and set(ids) <= {"kills", "quests", "dungeon", "mplus", "worldquest"}, ids)

R = make(extra="LVL = 5")
q1 = R.eval("ForgeChallengeDB.characters['Testchar-Area52'].data.day.quests[1]")
target = q1["target"]
x0 = D(R, "totalXP")
for _ in range(int(target) - 1): ev(R, "KILL('normal')")
check("a daily advances with progress", D(R, "day.quests[1].progress") == target - 1 and not D(R, "day.quests[1].done"))
ev(R, "KILL('normal')")
check("completing one gives the daily XP (50) and an alert", D(R, "day.quests[1].done") and D(R, "totalXP") - x0 >= 50 + target)
check("a Quest Alert popup is up", popup(R))
check("...it reads QUEST COMPLETE with the XP", "QUEST COMPLETE" in R.eval("ForgeChallengePopup.kicker:GetText()") and "+50" in R.eval("ForgeChallengePopup.sub:GetText()"))
check("no streak until the whole day is done", D(R, "streak") == 0)
ev(R, "FireEvent('QUEST_TURNED_IN', 1); FireEvent('QUEST_TURNED_IN', 2); FireEvent('QUEST_TURNED_IN', 3); FireEvent('QUEST_TURNED_IN', 4)")
check("all dailies complete: streak 1 and the all-done bonus", D(R, "day.allDone") and D(R, "streak") == 1 and D(R, "counters.daysCompleted") == 1)
check("the best streak is kept", D(R, "bestStreak") == 1)

print("\n-- next day, finished yesterday")
tick(R, 86400)
check("a new day brings new dailies and keeps the streak", not D(R, "day.allDone") and D(R, "streak") == 1 and D(R, "day.quests[1].progress") == 0)
check("no penalty when yesterday was completed", D(R, "penalty") is None)
tick(R, 86400)
check("a day that was missed: a penalty is offered", D(R, "penalty.state") == "offered", D(R, "penalty"))
check("...the Penalty Quest window is up, red-trimmed", R.eval("ForgeChallengePenalty:IsShown()"))
check("...and the streak is not broken yet", D(R, "streak") == 1)
ev(R, "ForgeChallengePenalty.accept._scripts.OnClick()")
check("accepting makes it active and hides the window", D(R, "penalty.state") == "active" and not R.eval("ForgeChallengePenalty:IsShown()"))
target = D(R, "penalty.target")
for _ in range(int(target)): ev(R, "KILL('normal')")
check("completing it saves the streak and counts a penalty quest", D(R, "penalty.state") == "done" and D(R, "streak") == 1 and D(R, "counters.penaltiesDone") == 1)
ev(R, "for i = 1, 10 do FireEvent('QUEST_TURNED_IN', i) end; for i = 1, 70 do KILL('normal') end")
check("finishing that day's dailies too takes the streak to 2", D(R, "streak") == 2)
tick(R, 86400)
check("the penalty is cleared at the next reset, the streak kept", D(R, "penalty") is None and D(R, "streak") == 2)

print("\n-- penalty declined / failed / off / long gap")
R = make(extra="LVL = 5")
for q in range(5): ev(R, "KILL('normal')")
ev(R, "for i = 1, 10 do FireEvent('QUEST_TURNED_IN', i) end; for i = 1, 70 do KILL('normal') end")
check("setup: a streak of 1", D(R, "streak") == 1)
tick(R, 86400)   # new day, no progress
tick(R, 86400)   # missed -> offered
ev(R, "ForgeChallengePenalty.decline._scripts.OnClick()")
check("declining breaks the streak and costs nothing else", D(R, "streak") == 0 and D(R, "penalty") is None and D(R, "bestStreak") == 1)

R = make(extra="LVL = 5")
ev(R, "for i = 1, 10 do FireEvent('QUEST_TURNED_IN', i) end; for i = 1, 70 do KILL('normal') end")
tick(R, 86400); tick(R, 86400)
ev(R, "ForgeChallengePenalty.accept._scripts.OnClick()")
tick(R, 86400)
check("an accepted penalty not finished by the next reset breaks the streak", D(R, "streak") == 0 and D(R, "penalty") is None)

R = make(extra="LVL = 5")
ev(R, "for i = 1, 10 do FireEvent('QUEST_TURNED_IN', i) end; for i = 1, 70 do KILL('normal') end")
tick(R, 86400); tick(R, 86400)
tick(R, 86400)
check("an unanswered penalty is a decline at the next reset", D(R, "streak") == 0 and D(R, "penalty") is None)

R = make(extra="LVL = 5")
ev(R, "for i = 1, 10 do FireEvent('QUEST_TURNED_IN', i) end; for i = 1, 70 do KILL('normal') end")
tick(R, 3 * 86400)
check("more than one day away: the streak resets and no penalty is offered", D(R, "streak") == 0 and D(R, "penalty") is None)

R = make(extra="LVL = 5")
ev(R, "SlashCmdList.FORGECHALLENGE('penalties off')")
ev(R, "for i = 1, 10 do FireEvent('QUEST_TURNED_IN', i) end; for i = 1, 70 do KILL('normal') end")
tick(R, 86400); tick(R, 86400)
check("with penalties off, a missed day just ends the streak", D(R, "streak") == 0 and D(R, "penalty") is None and not R.eval("ForgeChallengePenalty and ForgeChallengePenalty:IsShown()"))

print("\n== titles")
R = make()
ev(R, "ForgeChallengeDB.characters['Testchar-Area52'].data.counters.kills = 9999; KILL('normal')")
check("The Relentless at 10,000 kills", D(R, "titles.relentless") is not None)
check("a title popup is queued", popup(R) and "TITLE" in R.eval("ForgeChallengePopup.kicker:GetText()"))
check("a title is earned once", (lambda: (ev(R, "KILL('normal')"), D(R, "titles.relentless") is not None)[1])())
ev(R, "KEY = { level = 10, onTime = true }; FireEvent('CHALLENGE_MODE_COMPLETED')")
check("Keystone Tempered for a timed +10", D(R, "titles.keystone") is not None)
ev(R, "for i = 1, 10 do ENTER('D' .. i, 'party', 1); FireEvent('LFG_COMPLETION_REWARD') end")
check("Gatecrasher at 10 dungeons", D(R, "titles.gatecrasher") is not None)

print("\n== popups, combat, level-up")
R = make()
ev(R, "NS.AddXP(1000)")
check("a level-up shows the banner", popup(R) and "LEVEL UP" in R.eval("ForgeChallengePopup.kicker:GetText()") and "Level 2" in R.eval("ForgeChallengePopup.main:GetText()"))
check("...and the gold flash", R.eval("ForgeChallengeFlash:IsShown()"))
check("...with a sound", R.eval("#SOUNDS") >= 1)
run_popups(R, 10)
check("the banner fades away by itself", not popup(R))
run_popups(R, 30)
R.execute("ForgeChallengeDB.characters['Testchar-Area52'].data.level = 9; ForgeChallengeDB.characters['Testchar-Area52'].data.xp = 0")
ev(R, "NS.AddXP(NS.XpForLevel(9))")
check("crossing from level 9 to 10 announces a rank up to Spark", "RANK UP" in R.eval("ForgeChallengePopup.kicker:GetText()") and "Spark" in R.eval("ForgeChallengePopup.sub:GetText()"), R.eval("ForgeChallengePopup.sub:GetText()"))
run_popups(R, 30)
ev(R, "function InCombatLockdown() return true end")
ev(R, "NS.UI.Alert('TEST', 'held in combat', 'x')")
check("hide in combat (default on): the popup waits", not popup(R))
ev(R, "function InCombatLockdown() return false end; FireEvent('PLAYER_REGEN_ENABLED')")
check("...and shows when combat ends", popup(R) and "held in combat" in R.eval("ForgeChallengePopup.main:GetText()"))
run_popups(R, 30)
ev(R, "SlashCmdList.FORGECHALLENGE('combat off'); function InCombatLockdown() return true end; NS.UI.Alert('TEST', 'in combat ok', 'x')")
check("with hide-in-combat off it shows in combat", popup(R))
ev(R, "function InCombatLockdown() return false end")
run_popups(R, 30)
ev(R, "SlashCmdList.FORGECHALLENGE('popups off'); NS.UI.Alert('TEST', 'nothing', 'x')")
check("popups off: nothing is shown", not popup(R))
check("...XP still counts", (lambda: (ev(R, "KILL('normal')"), D(R, "counters.kills") >= 1)[1])())

print("\n== gates")
R = make()
ev(R, "ENTER('The Test Halls', 'party', 2)")
check("entering a Heroic dungeon shows a Gate Detected window, rank C", R.eval("ForgeChallengeGate:IsShown()") and "GATE DETECTED: The Test Halls" in R.eval("ForgeChallengeGate.kicker:GetText()") and "Rank C" in R.eval("ForgeChallengeGate.kicker:GetText()"), R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "FireEvent('ENCOUNTER_END', 1, 'First Boss', 2, 5, 1)")
check("boss kills fill in the gate", "First Boss" in R.eval("ForgeChallengeGate.body:GetText()"))
ev(R, "LEAVE(); ENTER('Old Fort', 'party', 1)")
check("a Normal dungeon is rank D", "Rank D" in R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "LEAVE(); ENTER('The Big Raid', 'raid', 16)")
check("a Mythic raid is rank S", "Rank S" in R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "LEAVE(); ENTER('The Big Raid', 'raid', 14)")
check("a Normal raid is rank B", "Rank B" in R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "LEAVE(); ENTER('The Big Raid', 'raid', 15)")
check("a Heroic raid is rank A", "Rank A" in R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "LEAVE(); ENTER('The Big Raid', 'raid', 17)")
check("an LFR raid is rank C", "Rank C" in R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "LEAVE(); C_ChallengeMode.GetActiveKeystoneInfo = function() return 12 end; ENTER('Key Dungeon', 'party', 8)")
check("a +12 Mythic+ is rank A", "Rank A" in R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "LEAVE(); ENTER('Old Fort', 'party', 1); NS.gate = NS.gate")
check("leaving clears the gate", (lambda: (ev(R, "LEAVE()"), R.eval("NS.gate") is None)[1])())

print("\n== the Status and Daily windows")
R = make(extra="LVL = 30")
ev(R, "SlashCmdList.FORGECHALLENGE('')")
check("/fc opens the Status window", R.eval("ForgeChallengeStatus:IsShown()"))
check("it shows level, rank and the XP bar", "Level 1" in R.eval("ForgeChallengeStatus.level:GetText()") and "Cinder" in R.eval("ForgeChallengeStatus.rank:GetText()") and "/ 1000" in R.eval("ForgeChallengeStatus.barText:GetText()"))
check("it shows the five flavor stats", "STR 31" in R.eval("ForgeChallengeStatus.stats:GetText()") and "SEN 10" in R.eval("ForgeChallengeStatus.stats:GetText()"), R.eval("ForgeChallengeStatus.stats:GetText()"))
ev(R, "NS.AddXP(500)")
check("it updates as XP comes in", abs(R.eval("ForgeChallengeStatus.barW") - 346 * 0.5) < 0.01)
check("no titles yet is said plainly", "None yet" in R.eval("ForgeChallengeStatus.titles:GetText()"))
ev(R, "SlashCmdList.FORGECHALLENGE('')")
check("/fc again closes it", not R.eval("ForgeChallengeStatus:IsShown()"))
check("the Daily window greets at login while dailies remain", R.eval("ForgeChallengeDaily:IsShown()"))
check("it lists the three dailies with progress", "0/" in R.eval("ForgeChallengeDaily.rows[1]:GetText()") and R.eval("ForgeChallengeDaily.rows[3]:GetText()") != "")
check("it shows time to reset", "Resets in" in R.eval("ForgeChallengeDaily.reset:GetText()"), R.eval("ForgeChallengeDaily.reset:GetText()"))
ev(R, "ForgeChallengeDaily._scripts.OnDragStop(ForgeChallengeDaily)")
check("moving a window saves its position", R.eval("ForgeChallengeDB.positions.daily ~= nil"))
check("a minimap button exists", R.eval("ForgeChallengeMinimapButton ~= nil and ForgeChallengeMinimapButton:IsShown()"))
ev(R, "SlashCmdList.FORGECHALLENGE('minimap off')")
check("/fc minimap off hides it", not R.eval("ForgeChallengeMinimapButton:IsShown()"))

print("\n== persistence, settings, reset")
saved = "ForgeChallengeDB = { settings = { penalties = false }, characters = { ['Testchar-Area52'] = { data = { level = 7, xp = 123, totalXP = 9999, streak = 4, bestStreak = 6, titles = { relentless = 1 } } } } }"
R = make(saved=saved)
check("progress carries over from the save file", D(R, "level") == 7 and D(R, "xp") == 123 and D(R, "streak") == 4)
check("settings carry over", R.eval("ForgeChallengeDB.settings.penalties") is False and R.eval("ForgeChallengeDB.settings.hideInCombat") is True)
ev(R, "SlashCmdList.FORGECHALLENGE('reset')")
check("reset asks to be confirmed", D(R, "level") == 7 and "confirm" in printed(R))
ev(R, "SlashCmdList.FORGECHALLENGE('reset confirm')")
check("reset confirm starts the character over", D(R, "level") == 1 and D(R, "streak") == 0)
ev(R, "SlashCmdList.FORGECHALLENGE('values')")
check("/fc values lists the XP numbers", "kill 1/3/10" in printed(R) and "level-up 250" in printed(R), printed(R))
ev(R, "SlashCmdList.FORGECHALLENGE('help')")
check("/fc help works", "commands" in printed(R))
check("no errors", not errors(R))
R = make(saved="ForgeChallengeDB = { characters = { ['Other-Realm'] = { data = { level = 20 } } } }")
check("another character's progress is separate", D(R, "level") == 1 and R.eval("ForgeChallengeDB.characters['Other-Realm'].data.level") == 20)
R = make(saved="ForgeChallengeDB = 'garbage'")
check("a corrupt save does not error and starts clean", D(R, "level") == 1 and not errors(R))

print("\n== WoW Forever")
R = make(forever=True)
check("it loads on Forever and says so in the save", R.eval("ForgeChallengeDB.version") == "Forever" and not errors(R))
ev(R, "KILL('elite')")
check("kills work on Forever", D(R, "counters.kills") == 1)
ev(R, "ENTER('Some Dungeon', 'party', 1)")
check("gate ranks are not guessed on Forever", "Rank ?" in R.eval("ForgeChallengeGate.kicker:GetText()"), R.eval("ForgeChallengeGate.kicker:GetText()"))
ev(R, "SlashCmdList.FORGECHALLENGE('')")
check("the Status window carries the Forever preview note", "Forever" in R.eval("ForgeChallengeStatus.note:GetText()"))
R = make(extra="C_DateAndTime = nil; ns_tz = 0")
check("no daily-reset API: it falls back to the calendar day and still works", D(R, "day") is not None and not errors(R))
R = make(extra="UnitClassification = nil; UnitIsTapDenied = nil; GetAverageItemLevel = nil")
ev(R, "KILL('normal')")
check("missing optional APIs do not break it", D(R, "counters.kills") == 1 and not errors(R))

print("\n== the System-window look")
R = make(extra="LVL = 30")
ev(R, "SlashCmdList.FORGECHALLENGE('')")
ev(R, "SlashCmdList.FORGECHALLENGE('daily')"); ev(R, "SlashCmdList.FORGECHALLENGE('daily')")   # (opened at login; toggle shows it again)
ev(R, "ForgeChallengeDaily:Show()")
ev(R, "ENTER('Style Halls', 'party', 2)")
ev(R, "NS.UI.Alert('TEST', 'banner', 'sub')")
ev(R, "NS.UI.Penalty({ text = 'Complete 2 extra dungeons' })")
frames = ["ForgeChallengeStatus", "ForgeChallengeDaily", "ForgeChallengeGate", "ForgeChallengePopup", "ForgeChallengePenalty"]
for f in frames:
    a = R.eval("%s.sys.bg._a" % f)
    check(f + ": near-solid backdrop (readable over any scenery)", a >= 0.95, a)
for f in frames:
    n = R.eval("#%s.sys.parts" % f)
    check(f + ": double rule + glow + corner brackets (24 parts)", n == 24, n)
check("the double rule: outer bright, inner quieter", R.eval("(function() local o, i = 0, 0 for _, p in ipairs(ForgeChallengeStatus.sys.parts) do if p._base == 0.95 then o = o + 1 elseif p._base == 0.4 then i = i + 1 end end return o == 4 and i == 4 end)()"))
check("four corner brackets (two strokes each)", R.eval("(function() local n = 0 for _, p in ipairs(ForgeChallengeStatus.sys.parts) do if p._base == 1 then n = n + 1 end end return n end)()") == 8)
check("an outer glow (two faint rings)", R.eval("(function() local a, b = 0, 0 for _, p in ipairs(ForgeChallengeStatus.sys.parts) do if p._base == 0.16 then a = a + 1 elseif p._base == 0.07 then b = b + 1 end end return a == 4 and b == 4 end)()"))
check("the penalty window is the same frame in red", R.eval("ForgeChallengePenalty.sys.parts[1]._c[1]") > 0.8 and R.eval("ForgeChallengePenalty.sys.parts[1]._c[2]") < 0.4)
check("the header: a glowing title (the text drawn behind it) and the emblem", R.eval("ForgeChallengeStatus.title:GetText()") == "Forge's Challenge" and R.eval("#ForgeChallengeStatus.title.glows") == 4)
check("the rank is a framed chip in the rank's colour (Cinder: ember orange)", R.eval("ForgeChallengeStatus.rank:GetText()") == "Cinder" and R.eval("ForgeChallengeStatus.rankColor[1]") > 0.9 and R.eval("ForgeChallengeStatus.rankColor[3]") < 0.3 and R.eval("#ForgeChallengeStatus.chipLines") == 4)
ev(R, "ForgeChallengeDB.characters['Testchar-Area52'].data.level = 12; NS.UI.Refresh()")
check("a higher rank changes the chip colour (Spark)", R.eval("ForgeChallengeStatus.rank:GetText()") == "Spark" and R.eval("ForgeChallengeStatus.rankColor[2]") > 0.8)
ev(R, "ForgeChallengeDB.characters['Testchar-Area52'].data.level = 1; ForgeChallengeDB.characters['Testchar-Area52'].data.xp = 0; NS.AddXP(500)")
check("the XP bar is tall (20 px) and framed", R.eval("ForgeChallengeStatus.barFrame:GetHeight()") == 20)
check("the bar's bright leading edge sits at the end of the fill", abs(R.eval("ForgeChallengeStatus.lead._points[1][2]") - (16 + 1 + 346 * 0.5 - 3)) < 0.01, R.eval("ForgeChallengeStatus.lead._points[1][2]"))
check("a glow under the bar follows the fill", R.eval("ForgeChallengeStatus.barGlow:GetWidth()") > 170)
check("section headers have a rule under them", R.eval("ForgeChallengeStatus.statsRule._a") > 0 and R.eval("ForgeChallengeStatus.titlesRule._a") > 0)
gap = R.eval("ForgeChallengeStatus.stats._points[1][3] - ForgeChallengeStatus.flavor._points[1][3]")
check("the stats line and its explainer have a clear gap (>= 20 px)", gap >= 20, gap)
check("the bottom is one short line", len(R.eval("ForgeChallengeStatus.note:GetText()")) < 40 and "\n" not in R.eval("ForgeChallengeStatus.note:GetText()"), R.eval("ForgeChallengeStatus.note:GetText()"))
ev(R, "ForgeChallengeStatus.foot._scripts.OnEnter(ForgeChallengeStatus.foot)")
tip = " | ".join(R.eval("GameTooltip._lines").values())
check("...and the long version lives in its tooltip", "Cosmetic only" in tip and "flavor" in tip.lower(), tip)
h = R.eval("ForgeChallengeStatus:GetHeight()")
check("the frame is tight to its content (no big empty middle)", h == R.eval("ForgeChallengeStatus.contentBottom") + 14 and h < 360, h)
check("the Status window is no longer the old 400 px", h < 400)
ev(R, "NS.Data().titles.relentless = 1; NS.UI.Refresh()")
check("a title shows in the Titles section", "The Relentless" in R.eval("ForgeChallengeStatus.titles:GetText()"))
check("the Daily window sizes to its rows (tight)", R.eval("ForgeChallengeDaily:GetHeight()") < 260 and R.eval("ForgeChallengeDaily:GetHeight()") > 150, R.eval("ForgeChallengeDaily:GetHeight()"))
ev(R, "KILL('normal')")
check("a daily shows a progress bar that fills with progress", R.eval("ForgeChallengeDaily.fills[1]:GetWidth()") > 1 or R.eval("ForgeChallengeDaily.fills[2]:GetWidth()") > 1 or R.eval("ForgeChallengeDaily.fills[3]:GetWidth()") > 1)
for f in ["ForgeChallengeStatus", "ForgeChallengeDaily", "ForgeChallengePenalty"]:
    check(f + " is still movable", R.eval("%s._scripts.OnDragStart ~= nil and %s._scripts.OnDragStop ~= nil" % (f, f)))
check("the popup and gate are still click-dismissable", R.eval("ForgeChallengePopup._scripts.OnMouseUp ~= nil and ForgeChallengeGate._scripts.OnMouseUp ~= nil"))
run_popups(R, 120)
ev(R, "NS.UI.LevelUp(10, 'Spark', 1)")
check("a rank-up banner recolours to the bright gold", R.eval("ForgeChallengePopup.sys.parts[1]._c[2]") > 0.88, R.eval("ForgeChallengePopup.sys.parts[1]._c[2]"))
check("no errors", not errors(R))

print("\n%d passed" % passes)
print("FAILURES: " + (", ".join(fails) if fails else "none"))
sys.exit(1 if fails else 0)
