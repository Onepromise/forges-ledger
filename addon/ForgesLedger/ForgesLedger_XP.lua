-- Forge's Ledger: the XP bar (v0.1 WIP).
-- A slim, movable bar alongside the game's own: progress through the level, rested XP,
-- and an honest pace line (XP per hour, time to level, kills to level).
-- Plain frames and events only. Nothing is sent anywhere; pace numbers are runtime-only,
-- only the bar's settings (shown, locked, position) are saved, per character.
local ADDON_NAME, ns = ...
local XP = {}
ns.XP = XP

local WARM_SECONDS = 60     -- pace says "calculating" until a minute has passed...
local WARM_GAINS = 3        -- ...and at least 3 XP gains were seen
local KILL_MIN = 3          -- kills to level needs this many kill-XP samples
local KILL_SAMPLE = 20      -- rolling average over the last 20 kills
local PAIR_WINDOW = 1.0     -- a kill message and its XP update arrive within this many seconds

local CHECK = "|TInterface\\Buttons\\UI-CheckBox-Check:16:16|t"
local BOX = "|TInterface\\Buttons\\UI-CheckBox-Up:16:16|t"

local bar
local s       -- session pace state (runtime only)

local function Now() return GetTime and GetTime() or 0 end

local function Plain(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- ------------------------------------------------------------ settings
local function Settings()
    ForgeGoldDB = ForgeGoldDB or {}
    ForgeGoldDB.xpbar = type(ForgeGoldDB.xpbar) == "table" and ForgeGoldDB.xpbar or {}
    local key = ns.CharKey and ns.CharKey() or "Unknown"
    local c = ForgeGoldDB.xpbar[key]
    if type(c) ~= "table" then c = {}; ForgeGoldDB.xpbar[key] = c end
    if c.enabled == nil then c.enabled = true end
    if c.locked == nil then c.locked = false end
    return c
end
XP.Settings = Settings

-- ------------------------------------------------------------ the numbers
local function Pcall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return Plain(a) end
    return nil
end

-- level, xp, xpMax, rested, atMax -- or nil if the game won't say
function XP.Read()
    local level = Pcall(UnitLevel, "player")
    local xp = Pcall(UnitXP, "player")
    local xpMax = Pcall(UnitXPMax, "player")
    if type(level) ~= "number" then return nil end
    local rested = Pcall(GetXPExhaustion)
    if type(rested) ~= "number" or rested < 0 then rested = 0 end
    local atMax = false
    if IsPlayerAtEffectiveMaxLevel then
        atMax = Pcall(IsPlayerAtEffectiveMaxLevel) and true or false
    else
        local maxLevel = Pcall(GetMaxLevelForPlayerExpansion) or Pcall(GetMaxPlayerLevel) or MAX_PLAYER_LEVEL
        atMax = type(maxLevel) == "number" and level >= maxLevel
    end
    if type(xpMax) ~= "number" or xpMax <= 0 then atMax = true end   -- no bar to fill
    if type(xp) ~= "number" then xp = 0 end
    return level, xp, xpMax or 0, rested, atMax
end

function XP.ResetSession(now)
    s = { start = now or Now(), gained = 0, gains = 0, kills = {}, killXP = 0,
          pendingKill = nil, unattributed = nil }
end

local function RecordKill(amount)
    if type(amount) ~= "number" or amount <= 0 then return end
    local k = s.kills
    k[#k + 1] = amount
    if #k > KILL_SAMPLE then table.remove(k, 1) end
end

-- An XP update arrived: delta is what was gained. Pair it with a kill message if one is near.
function XP.OnGain(delta, now)
    if not s or type(delta) ~= "number" or delta <= 0 then return end
    now = now or Now()
    s.gained = s.gained + delta
    s.gains = s.gains + 1
    if s.pendingKill and now - s.pendingKill <= PAIR_WINDOW then
        RecordKill(delta)
        s.pendingKill = nil
    else
        s.unattributed = { t = now, delta = delta }
    end
end

-- The game's "X dies, you gain N experience." line arrived (we only use its timing).
function XP.OnKillMessage(now)
    if not s then return end
    now = now or Now()
    local u = s.unattributed
    if u and now - u.t <= PAIR_WINDOW then
        RecordKill(u.delta)
        s.unattributed = nil
    else
        s.pendingKill = now
    end
end

-- Pure: everything the bar shows, from numbers.
-- level, xp, xpMax, rested, atMax  ->  model
function XP.Model(level, xp, xpMax, rested, atMax, now)
    local m = { level = level, atMax = atMax }
    if atMax then
        m.pct, m.remaining, m.restedPct = 100, 0, 0
        return m
    end
    xp = math.max(0, math.min(xp, xpMax))
    m.pct = 100 * xp / xpMax
    m.remaining = xpMax - xp
    m.rested = rested
    m.restedPct = math.min(100 - m.pct, 100 * (rested or 0) / xpMax)   -- runway, capped at the bar's end
    now = now or Now()
    local elapsed = s and (now - s.start) or 0
    m.elapsed = elapsed
    m.ready = s ~= nil and elapsed >= WARM_SECONDS and s.gains >= WARM_GAINS and s.gained > 0
    if m.ready then
        m.perHour = s.gained / elapsed * 3600
        m.secondsToLevel = m.remaining / (m.perHour / 3600)
        if #s.kills >= KILL_MIN then
            local sum = 0
            for _, v in ipairs(s.kills) do sum = sum + v end
            m.avgKillXP = sum / #s.kills
            m.killsToLevel = math.ceil(m.remaining / m.avgKillXP)
        end
    end
    return m
end

-- ------------------------------------------------------------ formatting
local function Commas(n)
    local s_ = tostring(math.floor((n or 0) + 0.5))
    local out = s_:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
XP.Commas = Commas

local function Short(n)
    n = n or 0
    if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if n >= 10000 then return string.format("%dk", math.floor(n / 1000 + 0.5)) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n + 0.5))
end

local function Duration(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 100 * 3600 then return "99h+" end
    local h, m = math.floor(sec / 3600), math.floor(sec / 60) % 60
    if h > 0 then return string.format("%dh %02dm", h, m) end
    if m > 0 then return m .. "m" end
    return "<1m"
end
XP.Duration = Duration

function XP.Text(m)
    if m.atMax then return "Level " .. m.level .. "  -  Max level" end
    local t = string.format("Lvl %d  -  %d%%  -  %s to level", m.level, math.floor(m.pct), Commas(m.remaining))
    if not m.ready then
        return t .. "  -  pace: calculating"
    end
    t = t .. "  -  " .. Short(m.perHour) .. " XP/h  -  " .. Duration(m.secondsToLevel) .. " to level"
    if m.killsToLevel then t = t .. "  -  ~" .. Commas(m.killsToLevel) .. " kills" end
    return t
end

-- ------------------------------------------------------------ the bar
local FILL = { 0.78, 0.60, 0.10 }   -- Ledger gold
local RESTED = { 0.25, 0.45, 0.85 }
local BAR_W, BAR_H = 480, 18

local function Place()
    if not bar then return end
    local c = Settings()
    bar:ClearAllPoints()
    if type(c.pos) == "table" and type(c.pos[1]) == "string" then
        bar:SetPoint(c.pos[1], UIParent, c.pos[2] or c.pos[1], tonumber(c.pos[3]) or 0, tonumber(c.pos[4]) or 0)
    else
        bar:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 120)
    end
    bar:EnableMouse(not c.locked)
end

local function Build()
    if bar then return end
    bar = CreateFrame("Frame", "ForgesLedgerXPBar", UIParent)
    bar:SetSize(BAR_W, BAR_H)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints(bar)
    bar.bg:SetColorTexture(0.05, 0.05, 0.07, 0.85)
    bar.rested = bar:CreateTexture(nil, "BORDER")
    bar.rested:SetColorTexture(RESTED[1], RESTED[2], RESTED[3], 0.55)
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetColorTexture(FILL[1], FILL[2], FILL[3], 0.95)
    bar.edge = bar:CreateTexture(nil, "OVERLAY")
    bar.edge:SetPoint("TOPLEFT"); bar.edge:SetPoint("TOPRIGHT"); bar.edge:SetHeight(1)
    bar.edge:SetColorTexture(1, 0.82, 0, 0.6)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    bar:SetScript("OnDragStart", function(self) if not Settings().locked then self:StartMoving() end end)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        Settings().pos = { p or "BOTTOM", rp or p or "BOTTOM", x or 0, y or 0 }
    end)
    bar:SetScript("OnEnter", function(self) XP.Tooltip(self) end)
    bar:SetScript("OnLeave", function() if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end end)
    Place()
end

local lastModel
function XP.Refresh()
    if not bar then Build() end
    local c = Settings()
    if not c.enabled then bar:Hide(); return end
    local level, xp, xpMax, rested, atMax = XP.Read()
    if not level then bar:Hide(); return end
    local m = XP.Model(level, xp, xpMax, rested, atMax)
    lastModel = m
    bar.fill:ClearAllPoints()
    bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -1)
    bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    bar.fill:SetWidth(math.max(0.001, BAR_W * m.pct / 100))
    bar.rested:ClearAllPoints()
    bar.rested:SetPoint("TOPLEFT", bar, "TOPLEFT", BAR_W * m.pct / 100, -1)
    bar.rested:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", BAR_W * m.pct / 100, 0)
    bar.rested:SetWidth(math.max(0.001, BAR_W * m.restedPct / 100))
    bar.rested:SetShown(m.restedPct > 0)
    bar.text:SetText(XP.Text(m))
    bar.model = m
    bar:Show()
end

function XP.Tooltip(owner)
    if not (GameTooltip and lastModel) then return end
    local m = lastModel
    pcall(function()
        GameTooltip:SetOwner(owner, "ANCHOR_TOP")
        GameTooltip:AddLine("Forge's Ledger - XP", 1, 0.82, 0)
        if m.atMax then
            GameTooltip:AddLine("Level " .. m.level .. " - max level", 1, 1, 1)
        else
            GameTooltip:AddLine(string.format("Level %d: %.1f%% - %s XP to go", m.level, m.pct, Commas(m.remaining)), 1, 1, 1)
            if (m.rested or 0) > 0 then GameTooltip:AddLine("Rested: " .. Commas(m.rested) .. " XP", 0.45, 0.65, 1) end
            if m.ready then
                GameTooltip:AddLine(Commas(m.perHour) .. " XP per hour this session", 1, 1, 1)
                GameTooltip:AddLine("About " .. Duration(m.secondsToLevel) .. " to level at that pace", 1, 1, 1)
                if m.killsToLevel then
                    GameTooltip:AddLine(string.format("About %s kills (average %s XP per kill, last %d kills)",
                        Commas(m.killsToLevel), Commas(m.avgKillXP), #s.kills), 1, 1, 1)
                else
                    GameTooltip:AddLine("Kills to level: not enough kill XP seen yet", 0.62, 0.6, 0.56)
                end
            else
                GameTooltip:AddLine("Pace: calculating (needs a minute and a few gains)", 0.62, 0.6, 0.56)
            end
        end
        GameTooltip:Show()
    end)
end

-- ------------------------------------------------------------ settings + commands
function XP.SetEnabled(on)
    Settings().enabled = on and true or false
    XP.Refresh()
end

function XP.SetLocked(on)
    Settings().locked = on and true or false
    Place()
end

function XP.SettingsLines()
    local c = Settings()
    return {
        { text = "XP bar", header = true },
        { text = (c.enabled and CHECK or BOX) .. " Show the XP bar", onClick = function() XP.SetEnabled(not Settings().enabled) end },
        { text = (c.locked and CHECK or BOX) .. " Lock the XP bar's position", onClick = function() XP.SetLocked(not Settings().locked) end },
    }
end

-- /fl xp [lock]; returns the line to print
function XP.Command(arg)
    if arg == "lock" or arg == "unlock" then
        local on = (arg == "lock")
        XP.SetLocked(on)
        return on and "XP bar locked." or "XP bar unlocked - drag it to move it."
    end
    local on = not Settings().enabled
    XP.SetEnabled(on)
    return "XP bar " .. (on and "shown." or "hidden. Type /fl xp to show it again.")
end

-- ------------------------------------------------------------ events
local last = {}   -- level / xp / xpMax at the previous update

local function Snapshot()
    local level, xp, xpMax = XP.Read()
    last.level, last.xp, last.xpMax = level, xp, xpMax
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_XP_UPDATE", "UPDATE_EXHAUSTION",
                     "PLAYER_LEVEL_UP", "CHAT_MSG_COMBAT_XP_GAIN" }) do
    pcall(ev.RegisterEvent, ev, e)   -- in case a client lacks one
end
local acc = 0
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        XP.ResetSession()
        Snapshot()
        XP.Refresh()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not s then XP.ResetSession() end
        Snapshot()
        XP.Refresh()
    elseif event == "PLAYER_XP_UPDATE" then
        if arg1 and arg1 ~= "player" then return end
        local level, xp, xpMax = XP.Read()
        if level and last.level and type(xp) == "number" then
            local delta
            if level > last.level then
                delta = (last.xpMax or 0) - (last.xp or 0) + xp     -- crossed a level
            else
                delta = xp - (last.xp or xp)
            end
            if delta and delta > 0 then XP.OnGain(delta) end
        end
        last.level, last.xp, last.xpMax = level, xp, xpMax
        XP.Refresh()
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        XP.OnKillMessage()
    else     -- UPDATE_EXHAUSTION, PLAYER_LEVEL_UP
        if event == "PLAYER_LEVEL_UP" then
            -- the level in UnitLevel can lag; the next XP update re-reads it
        end
        XP.Refresh()
    end
end)
ev:SetScript("OnUpdate", function(_, dt)
    acc = acc + (dt or 0)
    if acc >= 1 then acc = 0; if bar and bar:IsShown() then pcall(XP.Refresh) end end
end)
