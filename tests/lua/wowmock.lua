tinsert, tremove = table.insert, table.remove
SlashCmdList = {}
-- Minimal stand-in for the WoW UI API, enough to load and drive the addon.
-- Widget methods not on the KNOWN list raise an error, so a misspelled
-- method name fails here instead of silently passing.
local KNOWN = {}
for m in ([[SetPoint SetScript GetScript Hide Show IsShown SetShown CreateTexture CreateFontString
  SetColorTexture SetSize SetText GetText SetHeight GetHeight SetWidth GetWidth SetAllPoints
  RegisterEvent UnregisterEvent SetTextColor ClearAllPoints SetStatusBarColor SetFrameStrata
  EnableMouse SetMovable SetClampedToScreen SetAlpha RegisterForDrag IsMouseOver StopMovingOrSizing
  StartMoving SetWordWrap SetVerticalScroll SetValue SetToplevel SetTexture SetTexCoord
  SetStatusBarTexture SetScrollChild SetMinMaxValues SetJustifyH SetFontObject SetBackdropColor
  SetBackdrop RegisterForClicks Raise GetStringWidth GetPoint GetName SetOwner AddLine AddDoubleLine
  SetParent GetParent SetFrameLevel SetLooping SetFromAlpha SetToAlpha SetDuration SetOrder GetStringHeight SetHorizTile SetVertTile SetAutoFocus SetMaxLetters SetFocus ClearFocus HighlightText HasFocus
  SetScale EnableMouseWheel SetMultiLine SetJustifyV SetOrientation SetValueStep SetObeyStepOnDrag SetThumbTexture
  SetPropagateKeyboardInput EnableKeyboard SetVertexColor SetObeyStepOnDrag]]):gmatch("%S+") do KNOWN[m] = true end

ALL_FRAMES = {}
EVENT_FRAMES = {}
local Widget = {}
local function new(kind, name, parent)
    local o = { _kind = kind, _name = name, _parent = parent, _shown = true, _scripts = {}, _events = {},
                _w = 0, _h = 0, _text = "", _points = {} }
    setmetatable(o, { __index = function(t, k)
        if Widget[k] then return Widget[k] end
        if KNOWN[k] then return function() end end
        if type(k) ~= "string" or not k:match("^%u") then return nil end  -- addon's own fields
        error("unknown widget method: " .. tostring(k), 2)
    end })
    tinsert(ALL_FRAMES, o)
    if name then _G[name] = o end
    return o
end
function Widget:SetScript(n, f) self._scripts[n] = f end
function Widget:GetScript(n) return self._scripts[n] end
function Widget:Show() self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end
function Widget:Hide() local was = self._shown; self._shown = false; if was and self._scripts.OnHide then self._scripts.OnHide(self) end end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown()
    local f = self
    while f do if not f._shown then return false end; f = f._parent end
    return true
end
function Widget:CreateTexture() return new("Texture", nil, self) end
function Widget:CreateFontString() return new("FontString", nil, self) end
function Widget:SetText(t) self._text = t == nil and "" or tostring(t) end
function Widget:GetText() return self._text end
function Widget:GetStringWidth() return #(self._text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "XX")) * 7 end
function Widget:GetStringHeight() local _, n = self._text:gsub("\n", ""); return (n + 1) * 12 end
function Widget:SetFontObject(o) self._font = o end
function Widget:HasFocus() return false end
function Widget:SetFocus() FOCUSED = self end
function Widget:GetThumbTexture() self._thumb = self._thumb or CreateFrame('Texture'); return self._thumb end
function Widget:SetWidth(w) self._w = w end
function Widget:GetWidth() return self._w end
function Widget:SetHeight(h) self._h = h end
function Widget:GetHeight() return self._h end
function Widget:SetSize(w, h) self._w, self._h = w, h end
function Widget:SetPoint(...) tinsert(self._points, { ... }) end
function Widget:ClearAllPoints() self._points = {} end
function Widget:GetPoint() local p = self._points[1] or {}; return p[1], p[2], p[3], p[4], p[5] end
function Widget:RegisterEvent(e)
    if e == "NONEXISTENT_EVENT" then error("unknown event") end
    self._events[e] = true; EVENT_FRAMES[self] = true
end
function Widget:UnregisterEvent(e) self._events[e] = nil end
function Widget:GetName() return self._name end
function Widget:IsMouseOver() return false end
function Widget:GetParent() return self._parent end
function Widget:CreateAnimationGroup() local g = new("AnimationGroup", nil, self); g._playing = false; return g end
function Widget:CreateAnimation() return new("Animation", nil, self) end
function Widget:Play() self._playing = true end
function Widget:Stop() self._playing = false end
function Widget:SetTexture(t) self._tex = t end
function Widget:IsPlaying() return self._playing == true end
function Widget:SetAttribute(k, v) self._attr = self._attr or {}; self._attr[k] = v end
function Widget:HookScript(n, f)
    local old = self._scripts[n]
    self._scripts[n] = function(...) if old then old(...) end f(...) end
end
function Widget:SetAllPoints(rel) self._points = { { "ALL", rel } } end
function Widget:SetVertexColor(r, g, b) self._dotcolor = (r > 0.5) and "gold" or "grey" end
function Widget:SetAlpha(a) self._alpha = a end
-- tooltip
function Widget:AddLine(t) tinsert(self._lines, tostring(t)) end
function Widget:AddDoubleLine(a, b) tinsert(self._lines, tostring(a) .. " || " .. tostring(b)) end
function Widget:SetOwner() self._lines = {} end

function CreateFrame(kind, name, parent, template)
    local f = new(kind, name, parent)
    f._template = template
    if template and template:find("Secure") then
        f._attr = {}
        for _, m in ipairs({ "SetPoint", "ClearAllPoints", "Show", "Hide", "SetAttribute", "SetAllPoints" }) do
            local orig = Widget[m]
            f[m] = function(self, ...)
                if InCombatLockdown() then error("ADDON_ACTION_BLOCKED: " .. m .. " on a secure frame in combat") end
                return orig(self, ...)
            end
        end
    end
    if template == "UIPanelScrollFrameTemplate" then
        f.ScrollBar = new("Slider", name and (name .. "ScrollBar"), f)
    end
    return f
end

function FireEvent(e, ...)
    local list = {}
    for f in pairs(EVENT_FRAMES) do if f._events[e] and f._scripts.OnEvent then tinsert(list, f) end end
    for _, f in ipairs(list) do f._scripts.OnEvent(f, e, ...) end
end

-- timers: run manually with RunTimers()
local timers, NOW = {}, 1760000000
function time() return NOW end
function AdvanceTime(s) NOW = NOW + s end
C_Timer = {
    After = function(d, fn) tinsert(timers, fn) end,
    NewTicker = function(d, fn)
        TICKERS = TICKERS or {}
        local t = { fn = fn }
        tinsert(TICKERS, fn)
        function t:Cancel()
            TICKERS_CANCELLED = (TICKERS_CANCELLED or 0) + 1
            for i, f in ipairs(TICKERS) do if f == fn then table.remove(TICKERS, i) break end end
        end
        return t
    end,
}
function RunTimers()
    for _ = 1, 10 do
        if #timers == 0 then return end
        local run = timers; timers = {}
        for _, fn in ipairs(run) do fn() end
    end
end

UIParent = new("Frame", "UIParent"); UIParent._h = 768; UIParent._w = 1366
GameTooltip = new("GameTooltip", "GameTooltip"); GameTooltip._lines = {}
GameTooltip_Hide = function() end
UISpecialFrames = {}
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
tinsert, tremove = table.insert, table.remove
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
PRINTED = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end tinsert(PRINTED, table.concat(t, " ")) end
function date(fmt, t) return os.date(fmt, t or NOW) end
function GetMoneyString(m, sep) return string.format("%dg%ds%dc", math.floor(m / 10000), math.floor(m / 100) % 100, m % 100) end
function GetCoinTextureString(m) return GetMoneyString(m) end
function SecondsToTime(s) return math.floor(s / 60) .. " Min" end
function UnitFullName() return "Testchar", "Area52" end
function GetRealmName() return "Area 52" end
function UnitName() return "Testchar" end
function UnitClass() return "Warrior", "WARRIOR" end
function UnitLevel() return 90 end
function UnitFactionGroup() return "Horde" end
function GetXPExhaustion() return 0 end
function UnitXPMax() return 100 end
MONEY = 123456789
function GetMoney() return MONEY end
function InCombatLockdown() return false end
function ReloadUI() RELOADED = true end
function IsShiftKeyDown() return false end
function GetNumSavedInstances() return 1 end
function GetSavedInstanceInfo(i) return "March on Quel'Danas", 0, 3600, 0, true, false, 0, true, 20, "Heroic", 8, 3 end
function GetNumSavedWorldBosses() return 0 end
function GetSavedWorldBossInfo() end

CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.5, 0, 0.25 } }
function GetMaxLevelForPlayerExpansion() return 90 end
-- drive OnUpdate scripts (the card's 150ms open animation)
function RunOnUpdates(seconds)
    for _, f in ipairs(ALL_FRAMES) do
        for _ = 1, 10 do
            if f._scripts.OnUpdate then f._scripts.OnUpdate(f, seconds / 10) end
        end
    end
end
