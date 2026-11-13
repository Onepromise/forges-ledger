-- Forge's Challenge: the System windows (Tempered Steel: dark iron, bone text, gold trim).
-- Plain frames and OnUpdate fades only. Popups never take keyboard input; a click dismisses one.
-- "Hide in combat" (default on) holds popups until combat ends.
local ADDON, ns = ...
ns = ns or {}
local UI = {}
ns.UI = UI

local GOLD = { 1, 0.82, 0 }
local BONE = { 0.92, 0.90, 0.85 }
local DIM = { 0.62, 0.60, 0.56 }
local RED = { 0.85, 0.25, 0.20 }
local GREEN = { 0.45, 0.85, 0.35 }
local IRON = { 0.05, 0.05, 0.07, 0.92 }

local function Settings() return ForgeChallengeDB and ForgeChallengeDB.settings or {} end

local function Tex(f, layer, r, g, b, a)
    local t = f:CreateTexture(nil, layer)
    t:SetColorTexture(r, g, b, a)
    return t
end

local function Trim(f, c, a)
    local p = {}
    for i = 1, 4 do p[i] = Tex(f, "BORDER", c[1], c[2], c[3], a or 0.8) end
    p[1]:SetPoint("TOPLEFT"); p[1]:SetPoint("TOPRIGHT"); p[1]:SetHeight(1)
    p[2]:SetPoint("BOTTOMLEFT"); p[2]:SetPoint("BOTTOMRIGHT"); p[2]:SetHeight(1)
    p[3]:SetPoint("TOPLEFT"); p[3]:SetPoint("BOTTOMLEFT"); p[3]:SetWidth(1)
    p[4]:SetPoint("TOPRIGHT"); p[4]:SetPoint("BOTTOMRIGHT"); p[4]:SetWidth(1)
    return p
end

local function Text(parent, font, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    local c = color or BONE
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

local function Btn(parent, label, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 90, 22)
    Tex(b, "BACKGROUND", 1, 1, 1, 0.07):SetAllPoints()
    Trim(b, GOLD, 0.4)
    b.text = Text(b, "GameFontNormal", GOLD)
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    return b
end

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function Held() return Settings().hideInCombat and InCombat() end

local function Sound(kind)
    if not Settings().sound or type(PlaySound) ~= "function" then return end
    local id
    if kind == "level" then id = (SOUNDKIT and SOUNDKIT.UI_70_ARTIFACT_FORGE_APPEARANCE_UNLOCKED) or 888
    else id = (SOUNDKIT and (SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.IG_QUEST_LIST_COMPLETE)) or 888 end
    pcall(PlaySound, id)
end

local function SavePos(f, name)
    local db = ForgeChallengeDB
    if not db then return end
    db.positions = type(db.positions) == "table" and db.positions or {}
    local p, _, rp, x, y = f:GetPoint()
    db.positions[name] = { p or "CENTER", rp or p or "CENTER", x or 0, y or 0 }
end

local function PlaceFrom(f, name, default)
    local pos = ForgeChallengeDB and ForgeChallengeDB.positions and ForgeChallengeDB.positions[name]
    f:ClearAllPoints()
    if type(pos) == "table" and type(pos[1]) == "string" then
        f:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    else
        f:SetPoint(default[1], UIParent, default[2], default[3], default[4])
    end
end

local function Movable(f, name)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos(self, name) end)
end

-- ------------------------------------------------------------ popups
local pop, queue, cur = nil, {}, nil
local IN, HOLD, OUT = 0.25, 4.5, 0.7

local function BuildPopup()
    if pop then return end
    pop = CreateFrame("Frame", "ForgeChallengePopup", UIParent)
    pop:SetSize(360, 84)
    pop:SetFrameStrata("HIGH")
    pop:SetPoint("TOP", UIParent, "TOP", 0, -140)
    pop.bg = Tex(pop, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4])
    pop.bg:SetAllPoints()
    pop.trim = Trim(pop, GOLD, 0.85)
    pop.kicker = Text(pop, "GameFontNormalSmall", GOLD)
    pop.kicker:SetPoint("TOP", 0, -10)
    pop.main = Text(pop, "GameFontNormalLarge", BONE)
    pop.main:SetPoint("TOP", pop.kicker, "BOTTOM", 0, -6)
    pop.main:SetWidth(330)
    pop.sub = Text(pop, "GameFontHighlightSmall", DIM)
    pop.sub:SetPoint("TOP", pop.main, "BOTTOM", 0, -6)
    pop.sub:SetWidth(330)
    pop:EnableMouse(true)
    pop:SetScript("OnMouseUp", function() if cur then cur.age = IN + HOLD end end)   -- click: fade it out
    pop:SetScript("OnUpdate", function(self, dt)
        if not cur then return end
        cur.age = cur.age + (dt or 0)
        local a
        if cur.age < IN then a = cur.age / IN
        elseif cur.age < IN + HOLD then a = 1
        elseif cur.age < IN + HOLD + OUT then a = 1 - (cur.age - IN - HOLD) / OUT
        else
            cur = nil
            self:Hide()
            UI.Next()
            return
        end
        self:SetAlpha(a)
    end)
    pop:Hide()
end

function UI.Next()
    if cur or not pop then return end
    if Held() then return end
    local item = table.remove(queue, 1)
    if not item then return end
    cur = { age = 0, data = item }
    pop.kicker:SetText(item.kicker)
    pop.main:SetText(item.main)
    pop.sub:SetText(item.sub or "")
    for _, t in ipairs(pop.trim) do t:SetColorTexture(item.color[1], item.color[2], item.color[3], 0.85) end
    pop:SetAlpha(0)
    pop:Show()
    Sound(item.sound)
end

local function Enqueue(item)
    if not Settings().popups then return end
    BuildPopup()
    item.color = item.color or GOLD
    queue[#queue + 1] = item
    UI.Next()
end

function UI.Alert(kicker, main, sub) Enqueue({ kicker = kicker, main = main, sub = sub }) end
function UI.QuestAlert(text, xp) Enqueue({ kicker = "QUEST COMPLETE", main = text, sub = "+" .. xp .. " XP", sound = "quest" }) end

-- the level-up flash: a full-screen wash of gold that fades, then the banner
local flash
function UI.LevelUp(level, rankName, gained)
    if Settings().popups then
        if not flash then
            flash = CreateFrame("Frame", "ForgeChallengeFlash", UIParent)
            flash:SetAllPoints(UIParent)
            flash:SetFrameStrata("FULLSCREEN_DIALOG")
            flash.tex = Tex(flash, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.18)
            flash.tex:SetAllPoints()
            flash:EnableMouse(false)
            flash:SetScript("OnUpdate", function(self, dt)
                self.age = (self.age or 0) + (dt or 0)
                if self.age >= 0.9 then self:Hide() else self:SetAlpha(1 - self.age / 0.9) end
            end)
            flash:Hide()
        end
        if not Held() then flash.age = 0; flash:SetAlpha(1); flash:Show() end
    end
    local main = "Level " .. level
    local sub = rankName and ("RANK UP: " .. rankName) or ((gained or 1) > 1 and (gained .. " levels") or "The Challenge grows stronger")
    Enqueue({ kicker = rankName and "LEVEL UP  -  RANK UP" or "LEVEL UP", main = main, sub = sub, sound = "level",
              color = rankName and { 1, 0.9, 0.4 } or GOLD })
end

function UI.Flush()
    UI.Next()
    if UI.penaltyWanted and UI.penaltyFrame and not UI.penaltyFrame:IsShown() and not Held() then UI.penaltyFrame:Show() end
    if UI.gateWanted and UI.gateFrame and not Held() then UI.gateFrame:Show() end
    if UI.dailyWanted and UI.dailyFrame and not Held() then UI.dailyFrame:Show() end
end

-- ------------------------------------------------------------ gate window
local gate
local function BuildGate()
    if gate then return end
    gate = CreateFrame("Frame", "ForgeChallengeGate", UIParent)
    gate:SetSize(330, 90)
    gate:SetFrameStrata("HIGH")
    PlaceFrom(gate, "gate", { "TOP", "TOP", 0, -240 })
    Tex(gate, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4]):SetAllPoints()
    Trim(gate, GOLD, 0.85)
    gate.kicker = Text(gate, "GameFontNormal", GOLD)
    gate.kicker:SetPoint("TOP", 0, -10)
    gate.body = Text(gate, "GameFontHighlightSmall", BONE)
    gate.body:SetPoint("TOP", gate.kicker, "BOTTOM", 0, -8)
    gate.body:SetWidth(300)
    gate:EnableMouse(true)
    gate:SetScript("OnMouseUp", function(self) self:Hide(); UI.gateWanted = false end)
    gate:SetScript("OnUpdate", function(self, dt)
        self.age = (self.age or 0) + (dt or 0)
        if self.age > 12 then self:Hide(); UI.gateWanted = false end
    end)
    gate:Hide()
    UI.gateFrame = gate
end

function UI.Gate(g, bossUpdate)
    if not Settings().popups then return end
    BuildGate()
    gate.kicker:SetText("GATE DETECTED: " .. tostring(g.name) .. "  -  Rank " .. tostring(g.rank))
    if #g.bosses == 0 then
        gate.body:SetText(g.kind == "raid" and "Fell the bosses within." or "Clear the gate.")
    else
        gate.body:SetText("Felled: " .. table.concat(g.bosses, ", "))
    end
    gate.age = 0
    UI.gateWanted = true
    if not Held() then gate:Show(); if not bossUpdate then Sound("quest") end end
end

-- ------------------------------------------------------------ penalty quest
local pen
local function BuildPenalty()
    if pen then return end
    pen = CreateFrame("Frame", "ForgeChallengePenalty", UIParent)
    pen:SetSize(400, 150)
    pen:SetFrameStrata("DIALOG")
    PlaceFrom(pen, "penalty", { "CENTER", "CENTER", 0, 120 })
    Tex(pen, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4]):SetAllPoints()
    pen.trim = Trim(pen, RED, 0.9)
    Movable(pen, "penalty")
    pen.kicker = Text(pen, "GameFontNormal", RED)
    pen.kicker:SetPoint("TOP", 0, -12)
    pen.kicker:SetText("PENALTY QUEST")
    pen.text = Text(pen, "GameFontNormalLarge", BONE)
    pen.text:SetPoint("TOP", pen.kicker, "BOTTOM", 0, -10)
    pen.text:SetWidth(360)
    pen.note = Text(pen, "GameFontHighlightSmall", DIM)
    pen.note:SetPoint("TOP", pen.text, "BOTTOM", 0, -8)
    pen.note:SetWidth(360)
    pen.note:SetText("A missed day. Finish this before the next reset to save your streak. Decline and the streak resets: nothing else is lost.")
    pen.accept = Btn(pen, "Accept", 110)
    pen.accept:SetPoint("BOTTOMRIGHT", pen, "BOTTOM", -6, 12)
    pen.decline = Btn(pen, "Decline", 110)
    pen.decline:SetPoint("BOTTOMLEFT", pen, "BOTTOM", 6, 12)
    pen.accept:SetScript("OnClick", function() ns.AcceptPenalty(); pen:Hide(); UI.penaltyWanted = false end)
    pen.decline:SetScript("OnClick", function() ns.DeclinePenalty(); pen:Hide(); UI.penaltyWanted = false end)
    pen:Hide()
    UI.penaltyFrame = pen
end

function UI.Penalty(p)
    BuildPenalty()
    pen.text:SetText(p.text)
    UI.penaltyWanted = true
    if not Held() then pen:Show() end
end

-- ------------------------------------------------------------ the Status window
local status
local function BuildStatus()
    if status then return end
    status = CreateFrame("Frame", "ForgeChallengeStatus", UIParent)
    status:SetSize(360, 400)
    status:SetFrameStrata("MEDIUM")
    PlaceFrom(status, "status", { "CENTER", "CENTER", -300, 0 })
    Tex(status, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4]):SetAllPoints()
    Trim(status, GOLD, 0.8)
    Movable(status, "status")
    status.title = Text(status, "GameFontNormalLarge", GOLD)
    status.title:SetPoint("TOPLEFT", 14, -12)
    status.title:SetText("Forge's Challenge")
    status.name = Text(status, "GameFontHighlight", BONE)
    status.name:SetPoint("TOPLEFT", 14, -40)
    status.level = Text(status, "GameFontNormalLarge", BONE)
    status.level:SetPoint("TOPLEFT", 14, -62)
    status.rank = Text(status, "GameFontNormal", GOLD)
    status.rank:SetPoint("TOPRIGHT", -14, -66)
    status.barBg = Tex(status, "BACKGROUND", 0, 0, 0, 0.6)
    status.barBg:SetSize(332, 14)
    status.barBg:SetPoint("TOPLEFT", 14, -96)
    status.bar = Tex(status, "ARTWORK", GOLD[1] * 0.85, GOLD[2] * 0.7, 0.1, 0.95)
    status.bar:SetPoint("TOPLEFT", 14, -96)
    status.bar:SetSize(1, 14)
    status.barText = Text(status, "GameFontHighlightSmall", BONE)
    status.barText:SetPoint("TOPLEFT", 14, -114)
    status.streak = Text(status, "GameFontHighlight", BONE)
    status.streak:SetPoint("TOPLEFT", 14, -138)
    status.stats = Text(status, "GameFontHighlight", BONE)
    status.stats:SetPoint("TOPLEFT", 14, -166)
    status.stats:SetJustifyH("LEFT")
    status.titlesHead = Text(status, "GameFontNormal", GOLD)
    status.titlesHead:SetPoint("TOPLEFT", 14, -236)
    status.titlesHead:SetText("Titles")
    status.titles = Text(status, "GameFontHighlight", BONE)
    status.titles:SetPoint("TOPLEFT", 14, -256)
    status.titles:SetWidth(332)
    status.titles:SetJustifyH("LEFT")
    status.note = Text(status, "GameFontHighlightSmall", DIM)
    status.note:SetPoint("BOTTOMLEFT", 14, 12)
    status.note:SetWidth(332)
    status.note:SetJustifyH("LEFT")
    status.close = CreateFrame("Button", nil, status, "UIPanelCloseButton")
    status.close:SetPoint("TOPRIGHT", 2, 2)
    status.close:SetScript("OnClick", function() status:Hide() end)
    status:Hide()
end

local function RefreshStatus()
    if not status or not status:IsShown() then return end
    local d = ns.Data()
    local need = ns.XpForLevel(d.level)
    status.name:SetText(UnitName and UnitName("player") or "")
    status.level:SetText("Level " .. d.level)
    status.rank:SetText("Rank: " .. ns.RankName(d.level))
    status.bar:SetWidth(math.max(1, 332 * d.xp / need))
    status.barText:SetText(string.format("%d / %d XP   (%d%%)   -   %d to level", d.xp, need, math.floor(100 * d.xp / need), need - d.xp))
    status.streak:SetText("Daily streak: " .. d.streak .. (d.bestStreak > d.streak and ("   (best " .. d.bestStreak .. ")") or ""))
    local s = ns.Stats()
    status.stats:SetText(string.format("STR %d    AGI %d    VIT %d    INT %d    SEN %d\n|cff9a9890Flavor only: worked out from your item level and lifetime counts. They change nothing in the game.|r",
        s.STR, s.AGI, s.VIT, s.INT, s.SEN))
    local names = {}
    for _, t in ipairs(ns.TITLES) do if d.titles[t.id] then names[#names + 1] = t.name end end
    status.titles:SetText(#names > 0 and table.concat(names, ", ") or "None yet. Titles come from milestones.")
    status.note:SetText("Cosmetic only. Everything here is earned from what you do in the game."
        .. (ns.IsForever() and "\nWoW Forever: preview. Ranks for gates and some events are not verified on this client yet." or ""))
end

function UI.ToggleStatus()
    BuildStatus()
    status:SetShown(not status:IsShown())
    RefreshStatus()
end

-- ------------------------------------------------------------ the Daily Quest window
local daily
local function BuildDaily()
    if daily then return end
    daily = CreateFrame("Frame", "ForgeChallengeDaily", UIParent)
    daily:SetSize(360, 230)
    daily:SetFrameStrata("MEDIUM")
    PlaceFrom(daily, "daily", { "CENTER", "CENTER", 300, 0 })
    Tex(daily, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4]):SetAllPoints()
    Trim(daily, GOLD, 0.8)
    Movable(daily, "daily")
    daily.title = Text(daily, "GameFontNormalLarge", GOLD)
    daily.title:SetPoint("TOPLEFT", 14, -12)
    daily.title:SetText("Daily Quests")
    daily.streak = Text(daily, "GameFontHighlightSmall", DIM)
    daily.streak:SetPoint("TOPLEFT", 14, -38)
    daily.rows = {}
    for i = 1, ns.DAILIES_PER_DAY do
        local fs = Text(daily, "GameFontHighlight", BONE)
        fs:SetPoint("TOPLEFT", 14, -62 - (i - 1) * 24)
        fs:SetWidth(332)
        fs:SetJustifyH("LEFT")
        daily.rows[i] = fs
    end
    daily.pen = Text(daily, "GameFontHighlightSmall", RED)
    daily.pen:SetPoint("TOPLEFT", 14, -62 - ns.DAILIES_PER_DAY * 24 - 6)
    daily.pen:SetWidth(332)
    daily.pen:SetJustifyH("LEFT")
    daily.reset = Text(daily, "GameFontHighlightSmall", DIM)
    daily.reset:SetPoint("BOTTOMLEFT", 14, 12)
    daily.close = CreateFrame("Button", nil, daily, "UIPanelCloseButton")
    daily.close:SetPoint("TOPRIGHT", 2, 2)
    daily.close:SetScript("OnClick", function() daily:Hide(); UI.dailyWanted = false end)
    daily:Hide()
    UI.dailyFrame = daily
end

local function Clock(secs)
    secs = math.max(0, math.floor(secs))
    return string.format("%dh %02dm", math.floor(secs / 3600), math.floor(secs / 60) % 60)
end

local function RefreshDaily()
    if not daily or not daily:IsShown() then return end
    local d = ns.Data()
    local day = d.day
    daily.streak:SetText("Streak: " .. d.streak .. (d.bestStreak > d.streak and ("   (best " .. d.bestStreak .. ")") or "")
        .. (day and day.allDone and "   -   today complete" or ""))
    for i, fs in ipairs(daily.rows) do
        local q = day and day.quests[i]
        if q then
            fs:SetText((q.done and "|cff73b84d[x]|r " or "[ ] ") .. q.text .. "   " .. q.progress .. "/" .. q.target)
            fs:Show()
        else fs:SetText(""); fs:Hide() end
    end
    local p = d.penalty
    if p and p.state == "offered" then daily.pen:SetText("A penalty quest is waiting: /fc penalty")
    elseif p and p.state == "active" then daily.pen:SetText("Penalty: " .. p.text .. "  " .. p.progress .. "/" .. p.target)
    else daily.pen:SetText("") end
    local secs = ns.Plain(ns.Try(C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset))
    daily.reset:SetText(type(secs) == "number" and ("Resets in " .. Clock(secs)) or "")
end

function UI.ToggleDaily()
    BuildDaily()
    daily:SetShown(not daily:IsShown())
    UI.dailyWanted = daily:IsShown()
    RefreshDaily()
end

-- ------------------------------------------------------------ minimap button
local mini
local function Minimap_()
    if not Minimap then return end
    local s = Settings()
    if not mini then
        mini = CreateFrame("Button", "ForgeChallengeMinimapButton", Minimap)
        mini:SetSize(31, 31)
        mini:SetFrameStrata("MEDIUM")
        mini:SetFrameLevel(8)
        local icon = mini:CreateTexture(nil, "BACKGROUND")
        icon:SetTexture("Interface\\Icons\\Spell_Fire_Fire")
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER")
        local border = mini:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        mini:RegisterForClicks("AnyUp")
        mini:RegisterForDrag("LeftButton")
        mini:SetScript("OnClick", function(_, btn) if btn == "RightButton" then UI.ToggleDaily() else UI.ToggleStatus() end end)
        mini:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local cx, cy = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                ForgeChallengeDB.settings.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
                Minimap_()
            end)
        end)
        mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        mini:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Forge's Challenge")
            GameTooltip:AddLine("Click: Status. Right-click: Daily Quests. Drag to move.", 1, 1, 1)
            GameTooltip:Show()
        end)
        mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local a = math.rad(tonumber(s.angle) or 200)
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
    mini:SetShown(s.minimap and true or false)
end

-- ------------------------------------------------------------ plumbing
function UI.Refresh()
    RefreshStatus()
    RefreshDaily()
    Minimap_()
end

function UI.Init()
    BuildPopup()
    Minimap_()
    -- the Daily Quest window greets you at login while there is something left to do
    local d = ns.Data()
    local open = false
    for _, q in ipairs(d.day and d.day.quests or {}) do if not q.done then open = true end end
    if open and Settings().popups then
        BuildDaily()
        UI.dailyWanted = true
        if not Held() then daily:Show() end
        RefreshDaily()
    end
end
