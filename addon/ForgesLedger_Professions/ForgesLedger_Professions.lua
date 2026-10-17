-- Forge's Ledger: Professions v1.10 (retail)
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
local VERSION = "1.10"
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
-- set further down (next craft and shopping list, celebration, panel)
local ScanRecipes, Celebrate = function() end, function() end
local RenderNext, RenderShop, ToggleShop, RenderPlan
local BuildShopping, PlanCrafted = function() end, function() end
local pendingCelebrations = {}
-- profession -> the expansion tier the panel shows (picked by clicking it in
-- the panel, or by switching the profession window to it)
local selectedTier = {}

local function RecordTier(c, info, keepUnlearned)
    if type(info) ~= "table" or not info.professionName or info.professionName == "" then return end
    if not info.parentProfessionName then return end  -- a base profession, not a tier
    local max = info.maxSkillLevel or 0
    if not keepUnlearned and (info.skillLevel or 0) <= 0 and max <= 0 then return end
    local prev, skill = c.data.tiers[info.professionName], info.skillLevel or 0
    c.data.celebrated = c.data.celebrated or {}
    if max > 0 and skill >= max and (tonumber(c.data.celebrated[info.professionName]) or 0) < max then
        -- only a change we saw happen is cheered; a tier first seen already
        -- maxed is just noted, so logging in never celebrates
        if prev and (tonumber(prev.skill) or 0) < max then
            tinsert(pendingCelebrations, info.professionName .. " " .. skill .. " / " .. max)
        end
        c.data.celebrated[info.professionName] = max
    end
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
    ScanRecipes(c)  -- next craft and shopping list, with a profession window open
    c.data.lastScan = time()
    c.exportedAt = time()
    if #pendingCelebrations > 0 then
        Celebrate(table.concat(pendingCelebrations, "  \194\183  "))
        wipe(pendingCelebrations)
    end
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

-- The panel follows the profession window: whichever expansion the window
-- is switched to becomes the one the panel shows for that profession.
local function FollowWindowTier()
    local T = C_TradeSkillUI
    if not (T and T.GetChildProfessionInfo) then return end
    local ok, info = pcall(T.GetChildProfessionInfo)
    if ok and type(info) == "table" and info.parentProfessionName and info.professionName then
        selectedTier[info.parentProfessionName] = info.professionName
    end
end

local function ProfessionWindowShown()
    return ProfessionsFrame and ProfessionsFrame:IsShown() and true or false
end

------------------------------------------------------------ craft counts ---
-- For the panel's "This session / Last session" line: how many crafts this
-- character made in a play session, and what. Counted when the open
-- profession finishes casting one of this character's learned recipes, so
-- only real crafts count. A session starts at a real login - a /reload
-- doesn't start a new one. Kept per character in this addon's save file.

local function NewSession()
    local d = CharData().data
    if type(d.session) == "table" and (tonumber(d.session.crafts) or 0) > 0 then
        d.lastSession = d.session  -- the session that just ended becomes "last"
    end
    d.session = { startedAt = time(), crafts = 0, made = {} }
end

local function RecordCraft(spellID)
    if spellID == nil or (issecretvalue and issecretvalue(spellID)) then return end
    if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return end
    local T = C_TradeSkillUI
    if not (T and T.GetRecipeInfo) then return end
    local ok, info = pcall(T.GetRecipeInfo, spellID)
    if not ok or type(info) ~= "table" or not info.learned or not info.name then return end
    local c = CharData()
    local s = c.data.session
    if type(s) ~= "table" then
        s = { startedAt = time(), crafts = 0, made = {} }
        c.data.session = s
    end
    s.made = type(s.made) == "table" and s.made or {}
    s.crafts = (tonumber(s.crafts) or 0) + 1
    local m = type(s.made[info.name]) == "table" and s.made[info.name] or { count = 0 }
    m.count = (tonumber(m.count) or 0) + 1
    m.icon = info.icon or m.icon
    s.made[info.name] = m
    PlanCrafted(c, spellID)
    c.exportedAt = time()
    return true
end

-- "This session: 14 crafts - most made: Arcanoweave Bolt x9" while there
-- are crafts this session, else the last session's; nil if neither.
local function SessionLine()
    local d = CharData().data
    local s, label = d.session, "This session"
    if type(s) ~= "table" or (tonumber(s.crafts) or 0) == 0 then
        s, label = d.lastSession, "Last session"
    end
    local n = type(s) == "table" and tonumber(s.crafts) or 0
    if n == 0 then return nil end
    local best, bestN, icon
    for name, m in pairs(type(s.made) == "table" and s.made or {}) do
        if type(m) == "table" and (tonumber(m.count) or 0) > (bestN or 0) then
            best, bestN, icon = name, tonumber(m.count), m.icon
        end
    end
    return label .. ": " .. n .. (n == 1 and " craft" or " crafts")
        .. (best and ("  \194\183  most made: " .. best .. " \195\151" .. bestN) or ""), icon
end

------------------------------------------- next craft and shopping list ---
-- With a profession window open, read that expansion tier's recipes from
-- the game (C_TradeSkillUI) and work out:
--   * the best next craft: a recipe this character KNOWS that still gives
--     skill - its first-craft bonus first, then orange, then yellow -
--     preferring one whose reagents are already in the bags, then the one
--     needing the fewest reagents. (No prices: the auction house is out of
--     scope.) A recipe whose reagents the game won't list is never picked.
--   * the plan: every known recipe that still gives skill (orange, yellow,
--     green - the colours the game reports at your current skill), each
--     with a craft count YOU set in the panel. The game doesn't say at which
--     skill a recipe changes colour, so the addon never guesses counts.
--   * the shopping list: the reagents for one of each known recipe that
--     still has its first-craft bonus, plus the planned crafts (or, with
--     nothing planned, one of the next craft).
-- Stored per tier (skill and max come from the game too). Informational
-- only - nothing here crafts, queues or clicks anything.

local DIFF = Enum and Enum.TradeskillRelativeDifficulty or {}
local ORANGE, YELLOW, EASY = DIFF.Optimal, DIFF.Medium, DIFF.Easy
local BASIC = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic

-- The reagents one craft must have: {itemID, alts (other qualities of the
-- same reagent), qty}. nil if the game won't list them.
local function ReagentsFor(recipeID)
    local T = C_TradeSkillUI
    if not (T and T.GetRecipeSchematic) then return nil end
    local ok, sch = pcall(T.GetRecipeSchematic, recipeID, false)
    if not ok or type(sch) ~= "table" or type(sch.reagentSlotSchematics) ~= "table" then return nil end
    local list = {}
    for _, slot in ipairs(sch.reagentSlotSchematics) do
        local basic = BASIC == nil or slot.reagentType == BASIC
        if slot.required and basic then
            local ids = {}
            for _, r in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do
                if r.itemID then tinsert(ids, r.itemID) end
            end
            if #ids == 0 then return nil end  -- a required reagent we can't name: unknown
            tinsert(list, { itemID = ids[1], alts = ids, qty = tonumber(slot.quantityRequired) or 1 })
        end
    end
    return list
end

-- Looked up once a session: a recipe's expansion and its reagents don't
-- change, and asking the game for them is the slow part of a scan.
local recipeTier, recipeReagents = {}, {}

local function RecipeInTier(id, professionID)
    local T = C_TradeSkillUI
    if not (professionID and T.GetProfessionInfoByRecipeID) then return true end
    if recipeTier[id] == nil then
        local ok, pinfo = pcall(T.GetProfessionInfoByRecipeID, id)
        recipeTier[id] = ok and type(pinfo) == "table" and pinfo.professionID or false
    end
    return recipeTier[id] == false or recipeTier[id] == professionID
end

local function CachedReagents(id)
    if recipeReagents[id] == nil then recipeReagents[id] = ReagentsFor(id) or false end
    return recipeReagents[id] or nil
end

local function ItemName(id)
    local name
    if C_Item and C_Item.GetItemNameByID then
        local ok, n = pcall(C_Item.GetItemNameByID, id)
        name = ok and n or nil
    end
    if not name and GetItemInfo then
        local ok, n = pcall(GetItemInfo, id)
        name = ok and n or nil
    end
    if not name and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)  -- arrives later; the list fills in then
    end
    return name
end

local function ItemIcon(id)
    if C_Item and C_Item.GetItemIconByID then
        local ok, t = pcall(C_Item.GetItemIconByID, id)
        if ok and t then return t end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local bankSeen = false  -- the bank was opened this session, so bank counts are real

-- How many of a reagent (any quality) the character has: bags, and the
-- bank too once it has been opened this session (nil = unknown).
local function Have(alts)
    local bags, total = 0, 0
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    for _, id in ipairs(alts) do
        local ok, n = pcall(count, id)
        bags = bags + (ok and tonumber(n) or 0)
        if bankSeen then
            local ok2, all = pcall(count, id, true, false, true, true)
            total = total + (ok2 and tonumber(all) or 0)
        end
    end
    return bags, bankSeen and total or nil
end

local function EnoughFor(reagents)
    for _, r in ipairs(reagents) do
        if Have(r.alts) < r.qty then return false end
    end
    return true
end

ScanRecipes = function(c)
    local T = C_TradeSkillUI
    if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return end
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetChildProfessionInfo) then return end
    local ok, child = pcall(T.GetChildProfessionInfo)
    if not ok or type(child) ~= "table" or not child.professionName or not child.parentProfessionName then return end
    local tier, skill, max = child.professionName, child.skillLevel or 0, child.maxSkillLevel or 0
    local okIds, ids = pcall(T.GetAllRecipeIDs)
    if not okIds or type(ids) ~= "table" then return end
    local candidates, firsts, planned = {}, {}, {}
    for _, id in ipairs(ids) do
        local okI, info = pcall(T.GetRecipeInfo, id)
        -- only known, real crafts (not recrafts/salvage) - checked first,
        -- since it's cheap and rules out most of the list - then only this
        -- tier's recipes
        if okI and type(info) == "table" and info.learned and not info.isRecraft
                and not info.isSalvageRecipe and not info.isDummyRecipe and info.name
                and RecipeInTier(id, child.professionID) then
            local first = info.firstCraft == true
            local diff = info.relativeDifficulty
            local color = (ORANGE ~= nil and diff == ORANGE and "orange") or (YELLOW ~= nil and diff == YELLOW and "yellow")
                          or (EASY ~= nil and diff == EASY and "green") or nil
            local gives = first or color == "orange" or color == "yellow"
            if gives or color then
                local reagents = CachedReagents(id)
                if reagents then
                    local qty = 0
                    for _, r in ipairs(reagents) do qty = qty + r.qty end
                    local entry = { id = id, name = info.name, icon = info.icon, first = first,
                                    rank = first and 0 or (diff == ORANGE and 1 or 2), color = color or "grey",
                                    ups = tonumber(info.numSkillUps),
                                    have = EnoughFor(reagents), qty = qty, reagents = reagents }
                    if gives then tinsert(candidates, entry) end
                    if first then tinsert(firsts, entry) end
                    tinsert(planned, entry)
                end
            end
        end
    end
    c.data.nextCraft = c.data.nextCraft or {}
    c.data.shoppingList = c.data.shoppingList or {}
    c.data.plan = c.data.plan or {}
    if max > 0 and skill >= max then
        c.data.nextCraft[tier] = { profession = child.parentProfessionName, at = time(), none = "maxed" }
        c.data.plan[tier] = nil
        c.data.shoppingList[tier] = nil
        return
    end
    -- the plan: orange, then yellow, then green; within a colour first
    -- crafts, then what you have reagents for, then the fewest reagents
    local colorRank = { orange = 1, yellow = 2, green = 3, grey = 4 }
    table.sort(planned, function(a, b)
        if a.color ~= b.color then return colorRank[a.color] < colorRank[b.color] end
        if a.first ~= b.first then return a.first end
        if a.have ~= b.have then return a.have end
        if a.qty ~= b.qty then return a.qty < b.qty end
        return a.name < b.name
    end)
    local recipes = {}
    for i = 1, math.min(#planned, 40) do  -- a cap keeps the saved file small
        local e = planned[i]
        local reagents = {}
        for _, r in ipairs(e.reagents) do
            tinsert(reagents, { itemID = r.itemID, alts = r.alts, qty = r.qty, name = ItemName(r.itemID) })
        end
        tinsert(recipes, { recipeID = e.id, name = e.name, icon = e.icon, color = e.color, first = e.first,
                           ups = e.ups, reagents = reagents })
    end
    c.data.plan[tier] = { profession = child.parentProfessionName, expansion = child.expansionName,
                          skill = skill, max = max, at = time(), recipes = recipes }
    if #candidates == 0 then
        c.data.nextCraft[tier] = { profession = child.parentProfessionName, at = time(),
                                   none = "no known recipe gives skill right now" }
        BuildShopping(c, tier)
        return
    end
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.have ~= b.have then return a.have end
        if a.qty ~= b.qty then return a.qty < b.qty end
        return a.name < b.name
    end)
    local best = candidates[1]
    local why = best.first and "first craft bonus" or (best.rank == 1 and "orange" or "yellow")
    why = why .. (best.have and " · you have the reagents" or " · reagents needed")
    c.data.nextCraft[tier] = { profession = child.parentProfessionName, recipeID = best.id,
                               name = best.name, icon = best.icon, reason = why, at = time() }
    BuildShopping(c, tier)
end

-- The craft counts set in the plan: {recipeID -> count}, per character and tier.
local function PlanCounts(c, tier)
    c.data.planCounts = type(c.data.planCounts) == "table" and c.data.planCounts or {}
    local t = c.data.planCounts[tier]
    if type(t) ~= "table" then
        t = {}
        c.data.planCounts[tier] = t
    end
    return t
end

-- The tier's shopping list, from the saved plan (so changing a count needs
-- no rescan): one of each first craft, the planned counts, and - with
-- nothing planned - one of the next craft.
BuildShopping = function(c, tier)
    c.data.shoppingList = c.data.shoppingList or {}
    local plan = type(c.data.plan) == "table" and c.data.plan[tier]
    if type(plan) ~= "table" or type(plan.recipes) ~= "table" then
        c.data.shoppingList[tier] = nil
        return
    end
    local counts = PlanCounts(c, tier)
    local nc = type(c.data.nextCraft) == "table" and c.data.nextCraft[tier]
    local planned = 0
    for _, r in ipairs(plan.recipes) do planned = planned + (tonumber(counts[r.recipeID]) or 0) end
    local items, recipes = {}, {}
    for _, r in ipairs(plan.recipes) do
        local n = tonumber(counts[r.recipeID]) or 0
        if r.first then n = math.max(n, 1) end
        if planned == 0 and type(nc) == "table" and nc.recipeID == r.recipeID then n = math.max(n, 1) end
        if n > 0 then
            tinsert(recipes, { recipeID = r.recipeID, name = r.name, first = r.first, count = n })
            for _, g in ipairs(r.reagents or {}) do
                local it = items[g.itemID] or { itemID = g.itemID, need = 0, alts = g.alts }
                it.need = it.need + g.qty * n
                it.name = it.name or g.name or ItemName(g.itemID)
                items[g.itemID] = it
            end
        end
    end
    if #recipes == 0 then
        c.data.shoppingList[tier] = nil
        return
    end
    local list = {}
    for _, it in pairs(items) do tinsert(list, it) end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    c.data.shoppingList[tier] = { profession = plan.profession, expansion = plan.expansion,
                                  skill = plan.skill, max = plan.max, at = time(), recipes = recipes, items = list }
end

-- A finished craft takes one off its planned count.
PlanCrafted = function(c, recipeID)
    if type(c.data.planCounts) ~= "table" then return end
    for tier, counts in pairs(c.data.planCounts) do
        local n = type(counts) == "table" and tonumber(counts[recipeID])
        if n and n > 0 then
            counts[recipeID] = n > 1 and n - 1 or nil
            BuildShopping(c, tier)
        end
    end
end

-- Set from the panel's - / + buttons.
local function SetPlanCount(tier, recipeID, n)
    local c = CharData()
    PlanCounts(c, tier)[recipeID] = n > 0 and math.min(n, 999) or nil
    BuildShopping(c, tier)
    c.exportedAt = time()
end

local function ClearPlan(tier)
    local c = CharData()
    if type(c.data.planCounts) == "table" then c.data.planCounts[tier] = nil end
    BuildShopping(c, tier)
    c.exportedAt = time()
end

------------------------------------------------------------ celebration ---
-- Celebrate(reason): a gold flash and a sound, once, when something worth
-- cheering happens - for now, a profession tier reaching its max. Kept as
-- one function so later satellites can share it without changing callers.
-- Dismiss with a click; /flp celebrate turns it off.

local celebrateFrame

local function CelebrationSound()
    -- whichever of these the game has (checked, not assumed)
    for _, key in ipairs({ "UI_PROFESSIONS_NEW_RECIPE_LEARNED_TOAST", "UI_EPICLOOT_TOAST", "ACHIEVEMENT_MENU_OPEN" }) do
        if SOUNDKIT and SOUNDKIT[key] then return SOUNDKIT[key] end
    end
end

Celebrate = function(reason)
    if ForgesLedgerProfessionsDB.celebrate == false then return end
    if not celebrateFrame then
        local f = CreateFrame("Frame", "ForgesLedgerCelebration", UIParent)
        f:SetSize(440, 96)
        f:SetPoint("TOP", UIParent, "TOP", 0, -150)
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true)
        f:SetScript("OnMouseDown", function(self) self:Hide() end)  -- click to dismiss
        f.flash = f:CreateTexture(nil, "BACKGROUND")
        f.flash:SetPoint("TOPLEFT", -40, 30)
        f.flash:SetPoint("BOTTOMRIGHT", 40, -30)
        f.flash:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        f.flash:SetVertexColor(0.95, 0.78, 0.3, 1)
        local bg = f:CreateTexture(nil, "BORDER")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.07, 0.94)
        for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 1 } }) do
            local e = f:CreateTexture(nil, "ARTWORK")
            e:SetPoint(side[1]); e:SetPoint(side[2]); e:SetHeight(1)
            e:SetColorTexture(0.9, 0.75, 0.25, 0.9)
        end
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        f.title:SetPoint("TOP", 0, -16)
        f.title:SetTextColor(0.95, 0.8, 0.3)
        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
        f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.hint:SetPoint("BOTTOM", 0, 8)
        f.hint:SetTextColor(0.55, 0.55, 0.55)
        f.hint:SetText("Click to dismiss")
        f.anim = f.flash:CreateAnimationGroup()
        local a1 = f.anim:CreateAnimation("Alpha")
        a1:SetFromAlpha(0); a1:SetToAlpha(0.9); a1:SetDuration(0.25); a1:SetOrder(1)
        local a2 = f.anim:CreateAnimation("Alpha")
        a2:SetFromAlpha(0.9); a2:SetToAlpha(0); a2:SetDuration(1.4); a2:SetOrder(2)
        f.anim:SetScript("OnFinished", function() f.flash:SetAlpha(0) end)
        celebrateFrame = f
    end
    local f = celebrateFrame
    f.title:SetText("Maxed!")
    f.text:SetText(tostring(reason or ""))
    f.flash:SetAlpha(0)
    f:Show()
    f.anim:Stop()
    f.anim:Play()
    local kit = CelebrationSound()
    if kit then pcall(PlaySound, kit) end
    C_Timer.After(8, function() if f:IsShown() then f:Hide() end end)
end

---------------------------------------------------------------- events ---

-- the Ledger panel (below) replaces these
local RefreshHub, AutoOpenHub, AutoCloseHub = function() end, function() end, function() end

local queued, autoOpen, follow = false, false, false
local function QueueScan()
    if queued then return end
    queued = true
    -- a short wait folds a burst of events (opening a window fires several)
    -- into one scan; a quarter second is enough and doesn't feel slow
    C_Timer.After(0.25, function()
        queued = false
        if follow then  -- the window opened or switched expansion: follow it
            follow = false
            FollowWindowTier()
        end
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
pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")    -- login vs. /reload
pcall(frame.RegisterEvent, frame, "UNIT_SPELLCAST_SUCCEEDED") -- a craft finished
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_DATA_SOURCE_CHANGED")  -- switched tier or profession
pcall(frame.RegisterEvent, frame, "BANKFRAME_OPENED")         -- bank counts are real from now
pcall(frame.RegisterEvent, frame, "BAG_UPDATE_DELAYED")       -- reagents gained or used
pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")   -- a reagent's name arrived
frame:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(5, Scan)  -- give the game a moment to load profession data
    elseif event == "PLAYER_ENTERING_WORLD" then
        if a1 then NewSession() end  -- a real login, not a /reload or zoning
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" and RecordCraft(a3) then RefreshHub() end
    elseif event == "TRADE_SKILL_CLOSE" then
        AutoCloseHub()
    elseif event == "BANKFRAME_OPENED" then
        bankSeen = true
        if RenderShop then RenderShop() end
    elseif event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED" then
        if RenderShop then RenderShop() end  -- only draws when the list is open
    else
        if event == "TRADE_SKILL_SHOW" then autoOpen = true end
        if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then follow = true end
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

-- This character's professions, from the game: the two primaries, then
-- Cooking and Fishing (smaller tabs), each with the spell that opens it
-- (nil if the game didn't give one). Fishing gets no quick-open: its
-- spellbook spell casts your fishing line rather than opening a window.
-- (The game reports which slot is fishing, so no names are matched.)
-- Any other profession whose window is open gets a tab while it's open.
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
    for _, idx in ipairs({ cook or false, fish or false }) do
        if idx then
            local ok2, name, icon, _, _, _, offset = pcall(GetProfessionInfo, idx)
            if ok2 and name then
                local spell = idx ~= fish and ProfessionSpell(offset) or nil
                tinsert(list, { name = name, icon = icon, secondary = true, fishing = idx == fish,
                                spell = spell and SpellName(spell) and spell or nil })
            end
        end
    end
    local open = ProfessionWindowShown() and OpenProfession()
    if open then
        local known = false
        for _, p in ipairs(list) do if p.name == open then known = true end end
        for _, idx in ipairs({ arch or false }) do
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

-- Clicking an expansion row shows it in the panel. With the profession
-- window open it also switches the window to that expansion, so its recipes
-- can be read for the Next craft line and the shopping list. This only
-- changes what the window shows; it never crafts or spends anything.
local function SelectTier(tier, skillLineID)
    if not selected then return end
    selectedTier[selected] = tier
    local T = C_TradeSkillUI
    if skillLineID and ProfessionWindowShown() and CurrentTierName() ~= tier
       and T and T.SetProfessionChildSkillLineID then
        pcall(T.SetProfessionChildSkillLineID, skillLineID)
        -- the same two steps the profession window's own code uses: the
        -- call above changes which expansion the game reads, and this makes
        -- the window redraw for it (without it the window keeps showing
        -- the old expansion)
        if ProfessionsFrame and ProfessionsFrame.SetProfessionInfo
           and Professions and Professions.GetProfessionInfo then
            local ok, info = pcall(Professions.GetProfessionInfo)
            if ok and type(info) == "table" then
                pcall(ProfessionsFrame.SetProfessionInfo, ProfessionsFrame, info, false)
            end
        end
    end
    Render()
end

local function GetTier(i)
    if hubTiers[i] then return hubTiers[i] end
    local r = CreateFrame("Button", nil, hub.zone)
    r:SetHeight(TIER_H)
    r.sel = Line(r, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.10)  -- the expansion being shown
    r.sel:SetAllPoints()
    r.hover = Line(r, "HIGHLIGHT", 1, 1, 1, 0.05)
    r.hover:SetAllPoints()
    r:SetScript("OnClick", function(self) SelectTier(self.tier, self.skillLineID) end)
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
    local sb = CreateFrame("Button", nil, hub)  -- placed by Render, after the tabs
    sb:SetSize(108, 22)
    hub.shopBtn = sb
    sb.bg = Line(sb, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.12)
    sb.bg:SetAllPoints()
    Frame(sb, 0.5)
    local st = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    st:SetPoint("CENTER")
    st:SetText("Shopping list")
    sb:SetScript("OnClick", function() ToggleShop() end)

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

    hub.session = hub:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hub.session:SetTextColor(BONE[1] * 0.8, BONE[2] * 0.8, BONE[3] * 0.8)
    hub.sessionIcon = hub:CreateTexture(nil, "OVERLAY")
    hub.sessionIcon:SetSize(16, 16)
    hub.sessionIcon:SetPoint("RIGHT", hub.session, "LEFT", -6, 0)
    hub.sessionIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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
        t.icon:SetSize(p.secondary and 20 or 24, p.secondary and 20 or 24)
        t.text:SetFontObject(p.secondary and "GameFontNormal" or "GameFontNormalLarge")
        t.text:SetText(p.name)
        local active = p.name == selected
        t.text:SetTextColor((active and GOLD or BONE)[1], (active and GOLD or BONE)[2], (active and GOLD or BONE)[3])
        t.text:SetAlpha(active and 1 or 0.75)
        t.under:SetShown(active)
        t.glow:SetShown(active or readyBy[p.name] == true)
        SetPulse(t.pulse, readyBy[p.name] == true)
        local w = math.ceil(t.text:GetStringWidth()) + (p.secondary and 50 or 58)
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
    -- the Shopping list button sits at the right end of the tab row, left of
    -- the close button; the panel grows sideways when the tabs plus the
    -- button need more room than the default width, so nothing overlaps
    local sbW = hub.shopBtn:GetWidth()
    local width = math.max(HUB_W, x + 6 + sbW + 34)
    hub:SetWidth(width)
    hub.shopBtn:ClearAllPoints()
    hub.shopBtn:SetPoint("TOPRIGHT", hub, "TOPRIGHT", -34, -12 - (TAB_H - 22) / 2)
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
                                 max = t.maxSkill or 0, rank = ExpansionRank(t.expansion), id = t.id })
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
        local y, shownTier = RenderNext(selected, -28)
        y = RenderPlan(selected, shownTier, y)
        for i, t in ipairs(tiers) do
            local r = GetTier(i)
            r.tier, r.skillLineID = t.tier, t.id
            r.sel:SetShown(t.tier == shownTier)
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
    local cardW = (width - 24 - 30) / 2
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
    local height = top + (hub.cds:IsShown() and cdsH or 0) + 14
    -- this or the last play session's crafts; hidden until there are any
    local line, icon = SessionLine()
    hub.session:SetShown(line ~= nil)
    hub.sessionIcon:SetShown(line ~= nil)
    if line then
        hub.session:SetText(line)
        hub.sessionIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        hub.session:ClearAllPoints()
        hub.session:SetPoint("TOP", hub, "TOP", 10, -(height - 4))
        height = height + 22
    end
    hub:SetHeight(height)
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

------------------------------------------------- next craft line, shop ---
-- The "Next craft" line at the top of a profession's tiers, and the
-- Shopping list panel docked beside the Ledger panel.

-- The recommendation to show for a profession: the tier its window is on,
-- or else the newest tier that has one.
local function NextFor(profession)
    local nc = CharData().data.nextCraft
    if type(nc) ~= "table" then nc = {} end
    local pick = selectedTier[profession]
    if pick then
        if type(nc[pick]) == "table" and nc[pick].profession == profession then return nc[pick], pick end
        -- picked, but its recipes haven't been read yet
        return { none = ProfessionWindowShown() and "reading its recipes..."
                 or ("open " .. tostring(profession) .. " on this expansion to read its recipes") }, pick
    end
    local current = ProfessionWindowShown() and CurrentTierName()
    if current and nc[current] and nc[current].profession == profession then return nc[current], current end
    local best, bestTier, bestRank
    for tier, n in pairs(nc) do
        if type(n) == "table" and n.profession == profession and n.recipeID then
            local t = CharData().data.tiers[tier]
            local rank = ExpansionRank(t and t.expansion)
            if not bestRank or rank > bestRank then best, bestTier, bestRank = n, tier, rank end
        end
    end
    return best, bestTier
end

RenderNext = function(profession, y)
    if not hub.next then
        local b = CreateFrame("Button", nil, hub.zone)
        b:SetHeight(24)
        b.bg = Line(b, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.08)
        b.bg:SetAllPoints()
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT", 8, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.why = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.why:SetPoint("LEFT", b.text, "RIGHT", 8, 0)
        b.why:SetTextColor(DIM[1], DIM[2], DIM[3])
        b.flash = Pulse(b.bg, 0.3)
        -- show the recipe in the profession window (the game's own "open
        -- recipe" - it only navigates; the player still crafts)
        b:SetScript("OnClick", function(self)
            local T = C_TradeSkillUI
            if self.recipeID and ProfessionWindowShown() and T and T.OpenRecipe then
                pcall(T.OpenRecipe, self.recipeID)
            end
            self.flash:Play()
            C_Timer.After(1.2, function() self.flash:Stop(); self.bg:SetAlpha(1) end)
        end)
        hub.next = b
    end
    local b = hub.next
    local n, tier = NextFor(profession)
    if not n then
        b:Hide()
        return y, nil
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", hub.zone, "TOPLEFT", 4, y)
    b:SetPoint("RIGHT", hub.zone, "RIGHT", -4, 0)
    if n.recipeID then
        b.recipeID = n.recipeID
        b.icon:SetTexture(n.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        b.icon:Show()
        b.text:SetText("Next craft: " .. tostring(n.name))
        b.why:SetText(tostring(n.reason or ""))
    else
        b.recipeID = nil
        b.icon:Hide()
        b.text:SetText("Next craft: " .. tostring(tier or ""))
        b.why:SetText(tostring(n.none or ""))
    end
    b:Show()
    return y - 28, tier
end

-- Plan block -------------------------------------------------------------
-- Under the Next craft line: the shown expansion's recipes that still give
-- skill, each with a craft count you set (- / +, shift-click for 10). The
-- colours are the game's, as of the last time the window showed that
-- expansion. Counts feed the shopping list; a finished craft counts down.

local DIFF_COLOR = { orange = { 1, 0.50, 0.25 }, yellow = { 1, 0.82, 0 }, green = { 0.25, 0.75, 0.25 },
                     grey = { 0.55, 0.55, 0.55 } }
local PLAN_ROWS, PLAN_ROW_H = 6, 20
local planRows, planAll = {}, {}  -- planAll[tier]: show every row, not just the first few

local function SmallButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 18, 18)
    b.bg = Line(b, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.12)
    b.bg:SetAllPoints()
    b.hl = Line(b, "HIGHLIGHT", 1, 1, 1, 0.10)
    b.hl:SetAllPoints()
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    return b
end

local function Step()  -- shift-click moves by 10
    return (IsShiftKeyDown and IsShiftKeyDown()) and 10 or 1
end

local function PlanRow(i)
    if planRows[i] then return planRows[i] end
    local r = CreateFrame("Frame", nil, hub.zone)
    r:SetHeight(PLAN_ROW_H)
    r.strip = Line(r, "ARTWORK", 1, 1, 1, 0.9)  -- the recipe's colour
    r.strip:SetPoint("TOPLEFT", 4, -2)
    r.strip:SetPoint("BOTTOMLEFT", 4, 2)
    r.strip:SetWidth(3)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 12, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.plus = SmallButton(r, "+")
    r.plus:SetPoint("RIGHT", -6, 0)
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.count:SetWidth(30)
    r.count:SetPoint("RIGHT", r.plus, "LEFT", -2, 0)
    r.minus = SmallButton(r, "-")
    r.minus:SetPoint("RIGHT", r.count, "LEFT", -2, 0)
    r.tag = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.tag:SetPoint("RIGHT", r.minus, "LEFT", -8, 0)
    r.tag:SetTextColor(DIM[1], DIM[2], DIM[3])
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r.tag, "LEFT", -6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.plus:SetScript("OnClick", function()
        SetPlanCount(r.tier, r.recipeID, r.n + Step())
        Render(); if RenderShop then RenderShop() end
    end)
    r.minus:SetScript("OnClick", function()
        SetPlanCount(r.tier, r.recipeID, math.max(0, r.n - Step()))
        Render(); if RenderShop then RenderShop() end
    end)
    planRows[i] = r
    return r
end

local function PlanWidgets()
    if hub.plan then return hub.plan end
    local p = {}
    p.head = hub.zone:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.clear = SmallButton(hub.zone, "Clear", 46)
    p.clear:SetScript("OnClick", function(self)
        ClearPlan(self.tier)
        Render(); if RenderShop then RenderShop() end
    end)
    p.hint = hub.zone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.hint:SetJustifyH("LEFT")
    p.hint:SetTextColor(DIM[1], DIM[2], DIM[3])
    p.more = CreateFrame("Button", nil, hub.zone)
    p.more:SetHeight(18)
    p.more.text = p.more:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.more.text:SetPoint("LEFT", 12, 0)
    p.more.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    p.more:SetScript("OnClick", function(self)
        planAll[self.tier] = not planAll[self.tier] or nil
        Render()
    end)
    hub.plan = p
    return p
end

RenderPlan = function(profession, tier, y)
    local p = PlanWidgets()
    local c = CharData()
    local plan = tier and type(c.data.plan) == "table" and c.data.plan[tier]
    if type(plan) ~= "table" or plan.profession ~= profession or type(plan.recipes) ~= "table"
       or #plan.recipes == 0 then
        p.head:Hide(); p.clear:Hide(); p.hint:Hide(); p.more:Hide()
        for _, r in ipairs(planRows) do r:Hide() end
        return y
    end
    local counts = type(c.data.planCounts) == "table" and type(c.data.planCounts[tier]) == "table"
                   and c.data.planCounts[tier] or {}
    local t = c.data.tiers[tier]
    local skill = t and tonumber(t.skill) or plan.skill or 0
    local max = t and tonumber(t.maxSkill) or plan.max or 0
    local planned = 0
    for _, r in ipairs(plan.recipes) do planned = planned + (tonumber(counts[r.recipeID]) or 0) end
    p.head:ClearAllPoints()
    p.head:SetPoint("TOPLEFT", hub.zone, "TOPLEFT", 12, y - 4)
    p.head:SetText("Plan: " .. math.max(0, max - skill) .. " points to go  \194\183  "
        .. planned .. (planned == 1 and " craft" or " crafts") .. " planned")
    p.head:Show()
    p.clear.tier = tier
    p.clear:ClearAllPoints()
    p.clear:SetPoint("TOPRIGHT", hub.zone, "TOPRIGHT", -6, y - 2)
    p.clear:SetShown(planned > 0)
    y = y - 24
    local shown = planAll[tier] and #plan.recipes or math.min(#plan.recipes, PLAN_ROWS)
    for i = 1, shown do
        local rec, r = plan.recipes[i], PlanRow(i)
        r.tier, r.recipeID = tier, rec.recipeID
        r.n = tonumber(counts[rec.recipeID]) or 0
        local col = DIFF_COLOR[rec.color] or DIFF_COLOR.grey
        r.strip:SetColorTexture(col[1], col[2], col[3], 0.9)
        r.icon:SetTexture(rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        r.name:SetText(tostring(rec.name))
        r.name:SetTextColor(col[1], col[2], col[3])
        r.tag:SetText(rec.first and "first craft" or ((rec.ups or 0) > 1 and ("+" .. rec.ups .. " each") or ""))
        r.count:SetText(tostring(r.n))
        r.count:SetTextColor((r.n > 0 and BONE or DIM)[1], (r.n > 0 and BONE or DIM)[2], (r.n > 0 and BONE or DIM)[3])
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", hub.zone, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", hub.zone, "RIGHT")
        r:Show()
        y = y - PLAN_ROW_H
    end
    for i = shown + 1, #planRows do planRows[i]:Hide() end
    if #plan.recipes > PLAN_ROWS then
        p.more.tier = tier
        p.more.text:SetText(planAll[tier] and "Show fewer" or ("Show all " .. #plan.recipes .. " recipes"))
        p.more:ClearAllPoints()
        p.more:SetPoint("TOPLEFT", hub.zone, "TOPLEFT", 0, y)
        p.more:SetPoint("RIGHT", hub.zone, "RIGHT")
        p.more:Show()
        y = y - 18
    else
        p.more:Hide()
    end
    -- colours are only as fresh as the last look at this expansion
    local stale = (tonumber(plan.skill) or 0) < skill
    local hint = planned == 0 and "Set how many of each to craft (shift-click: 10); the shopping list adds up the reagents. Orange always gives a point, yellow and green only sometimes." or nil
    if stale then
        hint = "Colours as of skill " .. tostring(plan.skill) .. " - open this expansion in the profession window to refresh."
            .. (hint and ("\n" .. hint) or "")
    end
    if hint then
        p.hint:ClearAllPoints()
        p.hint:SetPoint("TOPLEFT", hub.zone, "TOPLEFT", 12, y - 2)
        p.hint:SetPoint("RIGHT", hub.zone, "RIGHT", -12, 0)
        p.hint:SetText(hint)
        p.hint:Show()
        y = y - 6 - math.max(14, math.ceil(p.hint.GetStringHeight and p.hint:GetStringHeight() or 14))
    else
        p.hint:Hide()
    end
    return y - 6
end

-- Shopping list panel ---------------------------------------------------

local shop, shopRows, shopScope = nil, {}, "me"

local function ShopRow(i)
    if shopRows[i] then return shopRows[i] end
    local r = CreateFrame("Frame", nil, shop)
    r:SetHeight(20)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 10, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.value:SetPoint("RIGHT", -10, 0)
    r.name:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
    shopRows[i] = r
    return r
end

-- {tier -> list} for this character, or every character's lists added up
local function ShopLists()
    local out = {}
    local chars = shopScope == "warband" and ForgesLedgerProfessionsDB.characters or { [CharKey()] = CharData() }
    for _, c in pairs(chars or {}) do
        local sl = type(c) == "table" and type(c.data) == "table" and c.data.shoppingList
        for tier, l in pairs(type(sl) == "table" and sl or {}) do
            if type(l) == "table" and type(l.items) == "table" then
                local o = out[tier] or { profession = l.profession, expansion = l.expansion, items = {}, recipes = 0 }
                for _, r in ipairs(type(l.recipes) == "table" and l.recipes or {}) do
                    o.recipes = o.recipes + (tonumber(r.count) or 1)
                end
                for _, it in ipairs(l.items) do
                    local cur = o.items[it.itemID] or { itemID = it.itemID, name = it.name, need = 0,
                                                       alts = it.alts or { it.itemID } }
                    cur.need = cur.need + (tonumber(it.need) or 0)
                    cur.name = cur.name or it.name
                    o.items[it.itemID] = cur
                end
                out[tier] = o
            end
        end
    end
    return out
end

RenderShop = function()
    if not (shop and shop:IsShown()) then return end
    for _, b in ipairs(shop.scope) do b:SetAlpha(b.id == shopScope and 1 or 0.55) end
    local lists, tiers = ShopLists(), {}
    for tier, l in pairs(lists) do tinsert(tiers, { tier = tier, l = l, rank = ExpansionRank(l.expansion) }) end
    table.sort(tiers, function(a, b)
        if a.l.profession ~= b.l.profession then return tostring(a.l.profession) < tostring(b.l.profession) end
        return a.rank > b.rank
    end)
    local y, i = -64, 0
    local function row(icon, name, value, col, header)
        i = i + 1
        local r = ShopRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", shop, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", shop, "RIGHT")
        r.icon:SetShown(icon ~= nil)
        if icon then r.icon:SetTexture(icon) end
        r.name:SetFontObject(header and "GameFontNormal" or "GameFontHighlightSmall")
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", icon and 32 or 10, 0)
        r.name:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
        r.name:SetText(name)
        r.name:SetTextColor((header and GOLD or BONE)[1], (header and GOLD or BONE)[2], (header and GOLD or BONE)[3])
        r.value:SetText(value or "")
        local c = col or DIM
        r.value:SetTextColor(c[1], c[2], c[3])
        r:Show()
        y = y - 20
    end
    for _, t in ipairs(tiers) do
        row(nil, t.tier, t.l.recipes .. (t.l.recipes == 1 and " craft" or " crafts"), DIM, true)
        local items = {}
        for _, it in pairs(t.l.items) do tinsert(items, it) end
        table.sort(items, function(a, b) return tostring(a.name or a.itemID) < tostring(b.name or b.itemID) end)
        for _, it in ipairs(items) do
            local bags, all = Have(it.alts)
            local got = all or bags
            local name = it.name or ItemName(it.itemID) or ("item " .. it.itemID)
            row(ItemIcon(it.itemID), name, got .. " / " .. it.need, got >= it.need and GREEN or BONE)
        end
        y = y - 6
    end
    for j = i + 1, #shopRows do shopRows[j]:Hide() end
    shop.empty:SetShown(#tiers == 0)
    shop.note:ClearAllPoints()
    shop.note:SetPoint("TOPLEFT", 10, y - 4)
    shop.note:SetPoint("RIGHT", -10, 0)
    shop.note:SetText((bankSeen and "Have = bags and bank." or "Have = bags only - bank unknown until you open it.")
        .. (shopScope == "warband" and " Needs are every character's lists added up; have counts are this character's." or "")
        .. "\nReagents for one of each recipe that still gives its first-craft bonus, plus your planned crafts (or the next craft when nothing is planned). Open a profession to update it.")
    local noteH = shop.note.GetStringHeight and shop.note:GetStringHeight() or 28
    shop:SetHeight(-y + 4 + math.max(28, math.ceil(noteH or 28)) + 12)
end

local function CreateShop()
    shop = CreateFrame("Frame", "ForgesLedgerProfessionsShop", hub)
    shop:SetWidth(330)
    shop:SetPoint("TOPLEFT", hub, "TOPRIGHT", 6, 0)
    local bg = Line(shop, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4])
    bg:SetAllPoints()
    Frame(shop, 0.85)
    local title = shop:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Shopping list")
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    shop.scope = {}
    local x = 12
    for _, s in ipairs({ { id = "me", label = "This character" }, { id = "warband", label = "Warband" } }) do
        local b = CreateFrame("Button", nil, shop)
        b.id = s.id
        b:SetHeight(20)
        b.bg = Line(b, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.12)
        b.bg:SetAllPoints()
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER")
        b.text:SetText(s.label)
        b:SetWidth(math.ceil(b.text:GetStringWidth()) + 20)
        b:SetPoint("TOPLEFT", shop, "TOPLEFT", x, -38)
        x = x + b:GetWidth() + 6
        b:SetScript("OnClick", function(self) shopScope = self.id; RenderShop() end)
        tinsert(shop.scope, b)
    end
    shop.empty = shop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shop.empty:SetPoint("TOPLEFT", 12, -66)
    shop.empty:SetTextColor(DIM[1], DIM[2], DIM[3])
    shop.empty:SetText("Nothing yet - open a profession window to build the list.")
    shop.note = shop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shop.note:SetJustifyH("LEFT")
    shop.note:SetTextColor(DIM[1], DIM[2], DIM[3])
    shop:SetScript("OnShow", RenderShop)
    shop:Hide()
end

ToggleShop = function()
    if not hub then return end
    if not shop then CreateShop() end
    shop:SetShown(not shop:IsShown())
    if shop:IsShown() then RenderShop() end
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
        if RenderShop then RenderShop() end
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
            -- dot and pulse while anything's ready (core v2.11+ pulses;
            -- older cores ignore the third value)
            return "Professions: " .. #ready .. " ready", #ready > 0, #ready > 0
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
                or p.fishing and "switches the panel only (its spellbook spell casts your line)"
                or "no spell found - the tab switches the panel but can't open the window"))
        end
    elseif cmd == "celebrate" then
        ForgesLedgerProfessionsDB.celebrate = ForgesLedgerProfessionsDB.celebrate == false
        print(PREFIX .. "Celebration when a profession tier is maxed: " .. (ForgesLedgerProfessionsDB.celebrate == false and "off." or "on."))
    elseif cmd == "celebrate test" then
        local was = ForgesLedgerProfessionsDB.celebrate
        ForgesLedgerProfessionsDB.celebrate = true
        Celebrate("This is what maxing a profession tier looks like")
        ForgesLedgerProfessionsDB.celebrate = was
    elseif cmd == "next" then
        local nc = CharData().data.nextCraft or {}
        local any = false
        for tier, n in pairs(nc) do
            any = true
            print(PREFIX .. tier .. ": " .. (n.recipeID and (tostring(n.name) .. " (" .. tostring(n.reason) .. ")") or tostring(n.none)))
        end
        if not any then print(PREFIX .. "No recommendation yet - open a profession window.") end
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
        print("  /flp next - list the best next craft for each tier")
        print("  /flp celebrate - turn the 'tier maxed' celebration on or off (/flp celebrate test to see it)")
    end
end
