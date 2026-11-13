-- Forge's Challenge: the System windows. Tempered Steel (dark iron, bone text, gold trim) pushed
-- hard: a near-solid iron panel (readable over any scenery), a luminous double-rule gold border
-- with angular corner brackets and a faint outer glow, a glowing header band with an emblem, a
-- framed rank badge, a tall glowing XP bar. One frame language for every window.
-- Plain frames and OnUpdate fades only. Popups never take keyboard input; a click dismisses one.
-- "Hide in combat" (default on) holds popups until combat ends.
local ADDON, ns = ...
ns = ns or {}
local UI = {}
ns.UI = UI

local GOLD = { 1, 0.82, 0 }
local GOLD_HI = { 1, 0.92, 0.45 }
local BONE = { 0.95, 0.93, 0.88 }
local BONE_DIM = { 0.76, 0.74, 0.70 }     -- the quiet text: still readable over bright scenery
local RED = { 0.9, 0.28, 0.22 }
local GREEN = { 0.45, 0.85, 0.35 }
local IRON = { 0.03, 0.03, 0.05, 0.97 }   -- near-solid
ns.STYLE = { bgAlpha = IRON[4] }

local function Settings() return ForgeChallengeDB and ForgeChallengeDB.settings or {} end

local function Tex(f, layer, r, g, b, a)
    local t = f:CreateTexture(nil, layer)
    t:SetColorTexture(r, g, b, a)
    t._a, t._c = a, { r, g, b }     -- (kept so the tests can read what was drawn)
    return t
end

-- one thin line along a frame edge, `inset` px inside it (negative = outside)
local function Line(f, side, inset, thick, c, a, layer)
    local t = Tex(f, layer or "BORDER", c[1], c[2], c[3], a)
    if side == "T" then
        t:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset); t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -inset, -inset); t:SetHeight(thick)
    elseif side == "B" then
        t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", inset, inset); t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset); t:SetHeight(thick)
    elseif side == "L" then
        t:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset); t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", inset, inset); t:SetWidth(thick)
    else
        t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -inset, -inset); t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset); t:SetWidth(thick)
    end
    return t
end

-- The System frame: backdrop, double rule, corner brackets, outer glow. Returns the parts so a
-- window can be recoloured (the penalty window is red) -- sys.recolor(color).
local function System(f, accent)
    accent = accent or GOLD
    local sys = { parts = {} }
    local function add(t, base) t._base = base; sys.parts[#sys.parts + 1] = t; return t end
    sys.bg = Tex(f, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4])
    sys.bg:SetAllPoints()
    for _, side in ipairs({ "T", "B", "L", "R" }) do
        add(Line(f, side, 0, 1, accent, 0.95), 0.95)           -- outer rule, bright
        add(Line(f, side, 4, 1, accent, 0.40), 0.40)           -- inner rule, quieter: the "double rule"
        add(Line(f, side, -2, 1, accent, 0.16, "BACKGROUND"), 0.16)   -- glow, two faint rings outside
        add(Line(f, side, -4, 2, accent, 0.07, "BACKGROUND"), 0.07)
    end
    -- angular corner brackets, just outside the corners
    local function corner(pt, dx, dy)
        local h = Tex(f, "OVERLAY", accent[1], accent[2], accent[3], 1)
        h:SetSize(18, 2); h:SetPoint(pt, f, pt, dx, dy)
        local v = Tex(f, "OVERLAY", accent[1], accent[2], accent[3], 1)
        v:SetSize(2, 18); v:SetPoint(pt, f, pt, dx, dy)
        add(h, 1); add(v, 1)
    end
    corner("TOPLEFT", -3, 3); corner("TOPRIGHT", 3, 3); corner("BOTTOMLEFT", -3, -3); corner("BOTTOMRIGHT", 3, -3)
    function sys.recolor(c)
        for _, t in ipairs(sys.parts) do t:SetColorTexture(c[1], c[2], c[3], t._base); t._c = { c[1], c[2], c[3] } end
    end
    return sys
end

local function Text(parent, font, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    local c = color or BONE
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- glowing title text: the text drawn again, faintly, a pixel either side behind it
local function GlowText(parent, font, color, x, y, point)
    local main = Text(parent, font, color)
    main:SetPoint(point or "TOPLEFT", x, y)
    local glows = {}
    for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local g = parent:CreateFontString(nil, "ARTWORK", font)
        g:SetPoint(point or "TOPLEFT", x + d[1], y + d[2])
        g:SetTextColor(1, 0.55, 0.1)
        g:SetAlpha(0.35)
        glows[#glows + 1] = g
    end
    local obj = { main = main, glows = glows }
    function obj:SetText(t) self.main:SetText(t); for _, g in ipairs(self.glows) do g:SetText(t) end end
    function obj:GetText() return self.main:GetText() end
    return obj
end

-- a section header with a thin gold rule under it
local function Section(parent, text, y)
    local fs = Text(parent, "GameFontNormal", GOLD)
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    local r = Tex(parent, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.55)
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y - 18)
    r:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, y - 18)
    r:SetHeight(1)
    return fs, r
end

local function Btn(parent, label, w, accent)
    accent = accent or GOLD
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 90, 24)
    Tex(b, "BACKGROUND", accent[1] * 0.25, accent[2] * 0.25, accent[3] * 0.25, 0.9):SetAllPoints()
    Line(b, "T", 0, 1, accent, 0.9); Line(b, "B", 0, 1, accent, 0.9); Line(b, "L", 0, 1, accent, 0.9); Line(b, "R", 0, 1, accent, 0.9)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(accent[1], accent[2], accent[3], 0.2)
    b.text = Text(b, "GameFontNormal", accent)
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    return b
end

-- the header band across the top of a window: a glowing title and the emblem
local function Header(f, title, accent)
    accent = accent or GOLD
    local band = Tex(f, "ARTWORK", accent[1], accent[2], accent[3], 0.12)
    band:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -5)
    band:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    band:SetHeight(34)
    local rule = Tex(f, "ARTWORK", accent[1], accent[2], accent[3], 0.9)
    rule:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -39)
    rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -39)
    rule:SetHeight(1)
    local emblem = f:CreateTexture(nil, "OVERLAY")
    emblem:SetTexture("Interface\\Icons\\Spell_Fire_Fire")
    emblem:SetSize(22, 22)
    emblem:SetPoint("TOPLEFT", 14, -10)
    emblem:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local t = GlowText(f, "GameFontNormalLarge", GOLD_HI, 42, -12)
    t:SetText(title)
    return t, band
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
    pop:SetSize(380, 92)
    pop:SetFrameStrata("HIGH")
    pop:SetPoint("TOP", UIParent, "TOP", 0, -140)
    pop.sys = System(pop, GOLD)
    pop.kicker = GlowText(pop, "GameFontNormal", GOLD_HI, 0, -12, "TOP")
    pop.main = Text(pop, "GameFontNormalLarge", BONE)
    pop.main:SetPoint("TOP", pop, "TOP", 0, -34)
    pop.main:SetWidth(340)
    pop.sub = Text(pop, "GameFontNormal", GOLD)
    pop.sub:SetPoint("TOP", pop.main, "BOTTOM", 0, -6)
    pop.sub:SetWidth(340)
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
    pop.sys.recolor(item.color)
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
            flash.tex = Tex(flash, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.2)
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
              color = rankName and GOLD_HI or GOLD })
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
    gate:SetSize(360, 96)
    gate:SetFrameStrata("HIGH")
    PlaceFrom(gate, "gate", { "TOP", "TOP", 0, -250 })
    gate.sys = System(gate, GOLD)
    gate.kicker = GlowText(gate, "GameFontNormal", GOLD_HI, 0, -14, "TOP")
    gate.body = Text(gate, "GameFontHighlightSmall", BONE)
    gate.body:SetPoint("TOP", gate, "TOP", 0, -42)
    gate.body:SetWidth(320)
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
    pen:SetSize(430, 176)
    pen:SetFrameStrata("DIALOG")
    PlaceFrom(pen, "penalty", { "CENTER", "CENTER", 0, 120 })
    pen.sys = System(pen, RED)
    Movable(pen, "penalty")
    pen.kicker = GlowText(pen, "GameFontNormalLarge", { 1, 0.5, 0.4 }, 0, -14, "TOP")
    pen.kicker:SetText("PENALTY QUEST")
    pen.text = Text(pen, "GameFontNormalLarge", BONE)
    pen.text:SetPoint("TOP", pen, "TOP", 0, -48)
    pen.text:SetWidth(380)
    pen.note = Text(pen, "GameFontHighlightSmall", BONE_DIM)
    pen.note:SetPoint("TOP", pen.text, "BOTTOM", 0, -10)
    pen.note:SetWidth(380)
    pen.note:SetText("A missed day. Finish this before the next reset to save your streak. Decline and the streak resets: nothing else is lost.")
    pen.accept = Btn(pen, "Accept", 120, GOLD)
    pen.accept:SetPoint("BOTTOMRIGHT", pen, "BOTTOM", -8, 16)
    pen.decline = Btn(pen, "Decline", 120, RED)
    pen.decline:SetPoint("BOTTOMLEFT", pen, "BOTTOM", 8, 16)
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
local STATUS_W, PAD = 380, 16
local BAR_W = STATUS_W - 2 * PAD
local status
local function BuildStatus()
    if status then return end
    status = CreateFrame("Frame", "ForgeChallengeStatus", UIParent)
    status:SetSize(STATUS_W, 330)
    status:SetFrameStrata("MEDIUM")
    PlaceFrom(status, "status", { "CENTER", "CENTER", -300, 0 })
    status.sys = System(status, GOLD)
    Movable(status, "status")
    status.title = Header(status, "Forge's Challenge", GOLD)
    status.name = Text(status, "GameFontHighlight", BONE)
    status.name:SetPoint("TOPLEFT", PAD, -52)
    -- the rank as a framed chip
    status.chip = CreateFrame("Frame", nil, status)
    status.chip:SetSize(116, 24)
    status.chip:SetPoint("TOPRIGHT", -PAD, -49)
    status.chipBg = Tex(status.chip, "BACKGROUND", 0.95, 0.5, 0.2, 0.22)
    status.chipBg:SetAllPoints()
    status.chipLines = { Line(status.chip, "T", 0, 1, GOLD, 0.95), Line(status.chip, "B", 0, 1, GOLD, 0.95),
                         Line(status.chip, "L", 0, 1, GOLD, 0.95), Line(status.chip, "R", 0, 1, GOLD, 0.95) }
    status.rank = Text(status.chip, "GameFontNormal", GOLD)
    status.rank:SetPoint("CENTER")
    status.level = Text(status, "GameFontNormalLarge", BONE)
    status.level:SetPoint("TOPLEFT", PAD, -80)
    -- the XP bar: tall, glowing gold, bright leading edge
    status.barBg = Tex(status, "BACKGROUND", 0, 0, 0, 0.85)
    status.barBg:SetSize(BAR_W, 20)
    status.barBg:SetPoint("TOPLEFT", PAD, -110)
    status.barFrame = CreateFrame("Frame", nil, status)
    status.barFrame:SetSize(BAR_W, 20)
    status.barFrame:SetPoint("TOPLEFT", PAD, -110)
    Line(status.barFrame, "T", 0, 1, GOLD, 0.7); Line(status.barFrame, "B", 0, 1, GOLD, 0.7)
    Line(status.barFrame, "L", 0, 1, GOLD, 0.7); Line(status.barFrame, "R", 0, 1, GOLD, 0.7)
    status.barGlow = Tex(status, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.16)
    status.barGlow:SetPoint("TOPLEFT", status.barFrame, "TOPLEFT", 0, 3)
    status.barGlow:SetSize(1, 26)
    status.bar = Tex(status, "OVERLAY", 0.95, 0.72, 0.1, 1)
    status.bar:SetPoint("TOPLEFT", PAD + 1, -111)
    status.bar:SetSize(1, 18)
    status.lead = Tex(status, "OVERLAY", 1, 0.97, 0.7, 1)       -- the bright leading edge
    status.lead:SetSize(3, 18)
    status.lead:SetPoint("TOPLEFT", PAD + 1, -111)
    status.barText = Text(status, "GameFontNormal", BONE)
    status.barText:SetPoint("TOPLEFT", PAD, -136)
    status.streak = Text(status, "GameFontHighlight", BONE)
    status.streak:SetPoint("TOPLEFT", PAD, -160)
    status.statsHead, status.statsRule = Section(status, "Stats", -186)
    status.stats = Text(status, "GameFontHighlight", BONE)
    status.stats:SetPoint("TOPLEFT", PAD, -212)
    status.stats:SetJustifyH("LEFT")
    status.flavor = Text(status, "GameFontHighlightSmall", BONE_DIM)
    status.flavor:SetPoint("TOPLEFT", PAD, -238)         -- its own line, a clear gap under the stats
    status.flavor:SetText("Flavor only: worked out from your item level and counts.")
    status.titlesHead, status.titlesRule = Section(status, "Titles", -262)
    status.titles = Text(status, "GameFontHighlight", BONE)
    status.titles:SetPoint("TOPLEFT", PAD, -288)
    status.titles:SetWidth(BAR_W)
    status.titles:SetJustifyH("LEFT")
    status.titles:SetWordWrap(true)
    status.note = Text(status, "GameFontHighlightSmall", BONE_DIM)   -- one short line; the long version is a tooltip
    status.note:SetJustifyH("LEFT")
    status.foot = CreateFrame("Frame", nil, status)
    status.foot:SetPoint("TOPLEFT", status.note, "TOPLEFT", -2, 2)
    status.foot:SetSize(BAR_W, 16)
    status.foot:EnableMouse(true)
    status.foot:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Forge's Challenge", 1, 0.82, 0)
        GameTooltip:AddLine("Cosmetic only. Everything here is earned from what you do in the game, and nothing changes your character's power.", 1, 1, 1, true)
        GameTooltip:AddLine("The stats are flavor, worked out from your item level and lifetime counts.", 0.8, 0.8, 0.8, true)
        if ns.IsForever() then
            GameTooltip:AddLine("WoW Forever: preview. Gate ranks and some event numbers are not verified on this client yet.", 0.9, 0.7, 0.4, true)
        end
        GameTooltip:Show()
    end)
    status.foot:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    status.close = CreateFrame("Button", nil, status, "UIPanelCloseButton")
    status.close:SetPoint("TOPRIGHT", 2, 2)
    status.close:SetScript("OnClick", function() status:Hide() end)
    status:Hide()
end

local RANK_COLORS = {
    { 0.95, 0.5, 0.2 }, { 1, 0.85, 0.35 }, { 1, 0.45, 0.15 }, { 1, 0.3, 0.12 }, { 0.95, 0.25, 0.3 }, { 1, 0.95, 0.7 },
}

local function RefreshStatus()
    if not status or not status:IsShown() then return end
    local d = ns.Data()
    local need = ns.XpForLevel(d.level)
    status.name:SetText(UnitName and UnitName("player") or "")
    status.level:SetText("Level " .. d.level)
    local rc = RANK_COLORS[ns.RankIndex(d.level)] or GOLD
    status.rankColor = rc
    status.rank:SetText(ns.RankName(d.level))
    status.rank:SetTextColor(rc[1], rc[2], rc[3])
    status.chipBg:SetColorTexture(rc[1], rc[2], rc[3], 0.22)
    for _, l in ipairs(status.chipLines) do l:SetColorTexture(rc[1], rc[2], rc[3], 0.95) end
    local w = math.max(1, (BAR_W - 2) * d.xp / need)
    status.bar:SetWidth(w)
    status.barW = w
    status.barGlow:SetWidth(math.max(1, w + 2))
    status.lead:ClearAllPoints()
    status.lead:SetPoint("TOPLEFT", PAD + 1 + math.max(0, w - 3), -111)
    status.barText:SetText(string.format("%d / %d XP   (%d%%)   -   %d to level", d.xp, need, math.floor(100 * d.xp / need), need - d.xp))
    status.streak:SetText("Daily streak: " .. d.streak .. (d.bestStreak > d.streak and ("   (best " .. d.bestStreak .. ")") or ""))
    local s = ns.Stats()
    status.stats:SetText(string.format("STR %d    AGI %d    VIT %d    INT %d    SEN %d", s.STR, s.AGI, s.VIT, s.INT, s.SEN))
    local names = {}
    for _, t in ipairs(ns.TITLES) do if d.titles[t.id] then names[#names + 1] = t.name end end
    status.titles:SetText(#names > 0 and table.concat(names, ", ") or "None yet. Titles come from milestones.")
    -- tighten the frame to its content: no empty middle
    local th = math.max(16, status.titles:GetStringHeight() or 16)
    local footY = 288 + th + 12
    status.note:ClearAllPoints()
    status.note:SetPoint("TOPLEFT", PAD, -footY)
    status.note:SetText(ns.IsForever() and "Cosmetic only  -  Forever: preview" or "Cosmetic only")
    status.foot:ClearAllPoints()
    status.foot:SetPoint("TOPLEFT", status, "TOPLEFT", PAD - 2, -footY + 2)
    status.contentBottom = footY + 16
    status:SetHeight(footY + 16 + 14)
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
    daily:SetSize(STATUS_W, 260)
    daily:SetFrameStrata("MEDIUM")
    PlaceFrom(daily, "daily", { "CENTER", "CENTER", 300, 0 })
    daily.sys = System(daily, GOLD)
    Movable(daily, "daily")
    daily.title = Header(daily, "Daily Quests", GOLD)
    daily.streak = Text(daily, "GameFontNormal", GOLD_HI)
    daily.streak:SetPoint("TOPLEFT", PAD, -52)
    daily.rows, daily.tracks, daily.fills = {}, {}, {}
    for i = 1, ns.DAILIES_PER_DAY do
        local y = -82 - (i - 1) * 38
        local fs = Text(daily, "GameFontHighlight", BONE)
        fs:SetPoint("TOPLEFT", PAD, y)
        fs:SetWidth(BAR_W)
        fs:SetJustifyH("LEFT")
        daily.rows[i] = fs
        local tr = Tex(daily, "ARTWORK", 0, 0, 0, 0.8)
        tr:SetPoint("TOPLEFT", PAD, y - 20)
        tr:SetSize(BAR_W, 5)
        local fi = Tex(daily, "OVERLAY", 0.95, 0.72, 0.1, 1)
        fi:SetPoint("TOPLEFT", PAD, y - 20)
        fi:SetSize(1, 5)
        daily.tracks[i], daily.fills[i] = tr, fi
    end
    daily.pen = Text(daily, "GameFontHighlightSmall", { 1, 0.5, 0.4 })
    daily.pen:SetWidth(BAR_W)
    daily.pen:SetJustifyH("LEFT")
    daily.reset = Text(daily, "GameFontHighlightSmall", BONE_DIM)
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
    local n = 0
    for i, fs in ipairs(daily.rows) do
        local q = day and day.quests[i]
        if q then
            n = n + 1
            fs:SetText((q.done and "|cff73b84d[x]|r " or "[ ] ") .. q.text .. "   " .. q.progress .. "/" .. q.target)
            fs:Show()
            daily.tracks[i]:Show()
            daily.fills[i]:SetWidth(math.max(1, BAR_W * (q.progress / math.max(1, q.target))))
            daily.fills[i]:SetShown(q.progress > 0)
        else
            fs:SetText(""); fs:Hide(); daily.tracks[i]:Hide(); daily.fills[i]:Hide()
        end
    end
    local p = d.penalty
    if p and p.state == "offered" then daily.pen:SetText("A penalty quest is waiting: /fc penalty")
    elseif p and p.state == "active" then daily.pen:SetText("Penalty: " .. p.text .. "  " .. p.progress .. "/" .. p.target)
    else daily.pen:SetText("") end
    local y = 82 + n * 38 + 4
    daily.pen:ClearAllPoints(); daily.pen:SetPoint("TOPLEFT", PAD, -y)
    if daily.pen:GetText() ~= "" then y = y + 22 end
    local secs = ns.Plain(ns.Try(C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset))
    daily.reset:SetText(type(secs) == "number" and ("Resets in " .. Clock(secs)) or "")
    daily.reset:ClearAllPoints(); daily.reset:SetPoint("TOPLEFT", PAD, -y)
    daily:SetHeight(y + 18 + 14)
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
