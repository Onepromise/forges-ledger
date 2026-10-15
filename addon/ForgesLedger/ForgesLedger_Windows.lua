-- Forge's Ledger: detail windows and hover cards (part of the core addon, v2.8)
-- One builder makes every window the bar opens - the main Ledger window,
-- each segment's details, settings - so they all look and behave the same:
-- a title you can drag, a close button, and a scrolling list of lines.
-- Core and satellites only supply the lines; nothing here knows what they
-- mean. Plain frames with no secure templates, so they open fine in combat.

local _, ns = ...

local W = {}
ns.Windows = W

-- "Tempered Steel" palette, shared with the bar
ns.COLORS = {
    iron = { 0.05, 0.05, 0.07, 0.95 },
    gold = { 0.90, 0.75, 0.25 },
    bone = { 0.92, 0.90, 0.85 },
    dim  = { 0.55, 0.55, 0.55 },
}
local C = ns.COLORS

local WIDTH, ROW_H, MAX_VISIBLE = 360, 18, 22
local windows = {}  -- id -> frame, made the first time each is opened
local made = 0      -- windows made so far, to stagger where new ones appear

-- 1px gold lines along a frame's edges. Plain color textures rather than a
-- backdrop, because they work the same on every game client.
function ns.Trim(f, alpha, sides)
    for _, side in ipairs(sides or { "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], alpha or 0.8)
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
            t:SetHeight(1)
        else
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
            t:SetWidth(1)
        end
    end
end

local function GetRow(f, i)
    if f.rows[i] then return f.rows[i] end
    local r = CreateFrame("Button", nil, f.content)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("RIGHT", f.content, "RIGHT")
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", -2, 0)
    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", 2, 0)
    r.left:SetPoint("RIGHT", r.right, "LEFT", -8, 0)
    r.left:SetJustifyH("LEFT")
    r.left:SetWordWrap(false)
    -- only rows with an action take the mouse, so only they light up
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.12)
    r:SetScript("OnClick", function(self)
        if not self.onClick then return end
        local ok, err = pcall(self.onClick)
        if not ok then print(ns.PREFIX .. tostring(err)) end
        W.RefreshAll()  -- e.g. a settings tick changes what the window shows
    end)
    f.rows[i] = r
    return r
end

local function Render(f)
    local ok, lines = pcall(f.build)
    if not ok or type(lines) ~= "table" then
        lines = { { text = "This window couldn't load: " .. tostring(ok and "no lines" or lines), dim = true } }
    end
    if #lines == 0 then lines = { { text = "Nothing to show yet.", dim = true } } end
    for i, line in ipairs(lines) do
        local r = GetRow(f, i)
        r.left:SetFontObject(line.header and "GameFontNormal" or "GameFontHighlightSmall")
        r.left:SetText((line.indent and "    " or "") .. tostring(line.text or ""))
        r.right:SetText(line.right ~= nil and tostring(line.right) or "")
        local lc = line.color or (line.header and C.gold) or (line.dim and C.dim) or C.bone
        r.left:SetTextColor(lc[1], lc[2], lc[3])
        local rc = line.rightColor or (line.dim and C.dim) or C.gold
        r.right:SetTextColor(rc[1], rc[2], rc[3])
        r.onClick = type(line.onClick) == "function" and line.onClick or nil
        r:EnableMouse(r.onClick ~= nil)
        r:Show()
    end
    for i = #lines + 1, #f.rows do f.rows[i]:Hide() end
    -- grow to fit, up to MAX_VISIBLE rows; past that the list scrolls
    local n = #lines
    local overflow = n > MAX_VISIBLE
    f.content:SetHeight(math.max(1, n * ROW_H))
    f:SetHeight(44 + math.min(n, MAX_VISIBLE) * ROW_H)
    f.scroll:SetPoint("BOTTOMRIGHT", overflow and -30 or -10, 10)
    if f.scrollBar then f.scrollBar:SetShown(overflow) end
    if not overflow then f.scroll:SetVerticalScroll(0) end
end

local function Create(id)
    made = made + 1
    local name = "ForgesLedgerWindow" .. tostring(id):gsub("[^%w]", "")
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(WIDTH, 120)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local step = ((made - 1) % 6) * 24  -- so new windows don't stack exactly
    f:SetPoint("TOP", UIParent, "TOP", -120 + step, -140 - step)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.iron[1], C.iron[2], C.iron[3], C.iron[4])
    local band = f:CreateTexture(nil, "ARTWORK")  -- faint title band
    band:SetPoint("TOPLEFT", 1, -1)
    band:SetPoint("TOPRIGHT", -1, -1)
    band:SetHeight(26)
    band:SetColorTexture(1, 1, 1, 0.04)
    ns.Trim(f, 0.8)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -8)
    f.title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local sf = CreateFrame("ScrollFrame", name .. "Scroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -32)
    sf:SetPoint("BOTTOMRIGHT", -30, 10)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(WIDTH - 50, 1)
    sf:SetScrollChild(content)
    f.scroll, f.content, f.rows = sf, content, {}
    f.scrollBar = sf.ScrollBar or _G[name .. "ScrollScrollBar"]

    tinsert(UISpecialFrames, name)  -- Escape closes it, like the game's own windows
    f:Hide()
    windows[id] = f
    return f
end

-- Open a window, or close it if it's already open (the bar's click toggles).
-- build() returns the lines, each a table:
--   text, right    left and right-aligned text
--   header = true  gold section heading
--   dim = true     grey note
--   indent = true  indented under a heading
--   color, rightColor = { r, g, b }
--   onClick = function  makes the row clickable
-- Returns true if the window is now open.
function W.Toggle(id, title, build)
    local f = windows[id] or Create(id)
    if f:IsShown() then
        f:Hide()
        return false
    end
    return W.Open(id, title, build)
end

-- Open (or bring up to date) without toggling.
function W.Open(id, title, build)
    local f = windows[id] or Create(id)
    f.title:SetText(title or tostring(id))
    f.build = build
    Render(f)
    f:Show()
    f:Raise()
    return true
end

-- Re-draw every open window, e.g. after new data was recorded.
function W.RefreshAll()
    for _, f in pairs(windows) do
        if f:IsShown() and f.build then Render(f) end
    end
end

------------------------------------------------------- roster tooltips ---
-- The bar's hover cards: "who needs what?" across every character. Each
-- one follows the same grammar - gold header, class-colored character
-- rows, an honest footer - drawn in our own frame rather than the game's
-- tooltip, which is what allows the icons, mini progress bars and the
-- gentle open/pulse animations. Display only: safe in combat.
--
-- A plugin's roster() returns:
--   { title = "Great Vault - M+",
--     icon  = "Interface\\Icons\\...",   -- optional; defaults to the anvil
--     rows  = { { name = "Charname", class = "WARRIOR", -- class optional
--                 value = "M+ 3/8",      -- right-hand text
--                 sub = "Raid 2/6",      -- optional grey line under the name
--                 progress = 0.375,      -- optional 0..1: draws the mini bar
--                 pulse = true }, ... }, -- optional: gentle "ready" pulse
--     empty  = "All cooldowns used.",    -- shown when there are no rows
--     footer = { "+3 more" } }           -- optional grey lines
-- Every card ends with "As of each character's last login." - the addon
-- only knows what it saw when each character was last played.

local GREEN = { 0.30, 0.85, 0.45 }
local CLASS_ICONS = "Interface\\TargetingFrame\\UI-Classes-Circles"
local ANVIL = "Interface\\Icons\\Trade_BlackSmithing"
local TIP_PAD, BAR_W, TALL, SHORT = 12, 80, 34, 22
local tip

-- under half = bone, half to nearly done = gold, complete = green
local function Ramp(p)
    if p >= 1 then return GREEN end
    if p >= 0.5 then return C.gold end
    return C.bone
end

local function GetTipRow(i)
    if tip.rows[i] then return tip.rows[i] end
    local r = CreateFrame("Frame", nil, tip)
    r.sep = r:CreateTexture(nil, "ARTWORK")  -- faint line between rows
    r.sep:SetPoint("TOPLEFT", 6, 0)
    r.sep:SetPoint("TOPRIGHT", -6, 0)
    r.sep:SetHeight(1)
    r.sep:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.12)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetTexture(CLASS_ICONS)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.sub:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.track = r:CreateTexture(nil, "ARTWORK")  -- mini progress bar
    r.track:SetSize(BAR_W, 6)
    r.track:SetColorTexture(0, 0, 0, 0.6)
    r.fill = r:CreateTexture(nil, "OVERLAY")
    r.fill:SetHeight(6)
    r.fill:SetPoint("LEFT", r.track, "LEFT")
    -- "ready now": alpha 1 -> 0.85 -> 1 over ~1.2s, looping
    r.pulse = r:CreateAnimationGroup()
    r.pulse:SetLooping("BOUNCE")
    local a = r.pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0.85)
    a:SetDuration(0.6)
    tip.rows[i] = r
    return r
end

local function CreateTip()
    tip = CreateFrame("Frame", "ForgesLedgerRosterTip", UIParent)
    tip:SetFrameStrata("TOOLTIP")
    tip:SetClampedToScreen(true)
    local bg = tip:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.iron[1], C.iron[2], C.iron[3], 0.96)
    ns.Trim(tip, 0.85)
    -- faint glow under the top edge: a few lines fading out
    for i, alpha in ipairs({ 0.22, 0.12, 0.05 }) do
        local g = tip:CreateTexture(nil, "BORDER")
        g:SetPoint("TOPLEFT", 1, -i)
        g:SetPoint("TOPRIGHT", -1, -i)
        g:SetHeight(1)
        g:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], alpha)
    end
    tip.icon = tip:CreateTexture(nil, "ARTWORK")
    tip.icon:SetSize(18, 18)
    tip.icon:SetPoint("TOPLEFT", TIP_PAD, -9)
    tip.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tip.title = tip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tip.title:SetPoint("LEFT", tip.icon, "RIGHT", 7, 0)
    tip.title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    tip.rule = tip:CreateTexture(nil, "ARTWORK")  -- gold underline below the header
    tip.rule:SetPoint("TOPLEFT", 6, -34)
    tip.rule:SetPoint("TOPRIGHT", -6, -34)
    tip.rule:SetHeight(1)
    tip.rule:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.7)
    tip.empty = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tip.empty:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    tip.foot = {}
    tip.rows = {}
    tip:Hide()
end

local function Foot(i)
    if not tip.foot[i] then
        local f = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        tip.foot[i] = f
    end
    return tip.foot[i]
end

local function Layout(data)
    tip.icon:SetTexture(data.icon or ANVIL)
    tip.title:SetText(tostring(data.title or ""))
    local rows = type(data.rows) == "table" and data.rows or {}
    local tall = false
    for _, d in ipairs(rows) do
        if d.sub or d.progress then tall = true end
    end
    local rowH, iconS = tall and TALL or SHORT, tall and 24 or 16
    local width = TIP_PAD * 2 + 25 + tip.title:GetStringWidth()
    local y = -38
    for i, d in ipairs(rows) do
        local r = GetTipRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, y)
        r:SetPoint("RIGHT", tip, "RIGHT")
        r:SetHeight(rowH)
        r.sep:SetShown(i > 1)
        -- class icon and color where the class was recorded; bone otherwise
        local coords = d.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[d.class]
        r.icon:SetSize(iconS, iconS)
        r.icon:ClearAllPoints()
        r.icon:SetPoint("LEFT", TIP_PAD, 0)
        if coords then r.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
        r.icon:SetShown(coords ~= nil)
        local cc = d.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[d.class]
        r.name:SetText(tostring(d.name or "?"))
        r.name:SetTextColor(cc and cc.r or C.bone[1], cc and cc.g or C.bone[2], cc and cc.b or C.bone[3])
        r.name:ClearAllPoints()
        r.sub:SetText(d.sub and tostring(d.sub) or "")
        r.sub:SetShown(d.sub ~= nil)
        if d.sub then
            r.name:SetPoint("TOPLEFT", TIP_PAD + iconS + 8, -4)
            r.sub:ClearAllPoints()
            r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
        else
            r.name:SetPoint("LEFT", TIP_PAD + iconS + 8, 0)
        end
        r.value:SetText(tostring(d.value or ""))
        r.value:ClearAllPoints()
        local p = tonumber(d.progress)
        if p then
            p = math.max(0, math.min(1, p))
            local col = Ramp(p)
            r.value:SetTextColor(col[1], col[2], col[3])
            r.value:SetPoint("TOPRIGHT", -TIP_PAD, -4)
            r.track:ClearAllPoints()
            r.track:SetPoint("BOTTOMRIGHT", -TIP_PAD, 6)
            local fc = p >= 1 and GREEN or C.gold
            r.fill:SetColorTexture(fc[1], fc[2], fc[3], 0.9)
            r.fill:SetWidth(math.max(1, BAR_W * p))
            r.fill:SetShown(p > 0)
        else
            local col = d.valueColor or C.gold
            r.value:SetTextColor(col[1], col[2], col[3])
            r.value:SetPoint("RIGHT", -TIP_PAD, 0)
            r.fill:Hide()
        end
        r.track:SetShown(p ~= nil)
        if d.pulse then
            r.pulse:Play()
        else
            r.pulse:Stop()
            r:SetAlpha(1)
        end
        local left = math.max(r.name:GetStringWidth(), d.sub and r.sub:GetStringWidth() or 0)
        local right = math.max(r.value:GetStringWidth(), p and BAR_W or 0)
        width = math.max(width, TIP_PAD * 2 + iconS + 8 + left + 28 + right)
        r:Show()
        y = y - rowH
    end
    for i = #rows + 1, #tip.rows do
        tip.rows[i].pulse:Stop()
        tip.rows[i]:Hide()
    end
    tip.empty:SetShown(#rows == 0)
    if #rows == 0 then
        tip.empty:SetText(tostring(data.empty or "Nothing to show yet."))
        tip.empty:ClearAllPoints()
        tip.empty:SetPoint("TOPLEFT", TIP_PAD, y - 6)
        width = math.max(width, TIP_PAD * 2 + tip.empty:GetStringWidth())
        y = y - 24
    end
    -- footer: the plugin's notes, then the honesty line every card carries
    local lines = {}
    for _, l in ipairs(type(data.footer) == "table" and data.footer or {}) do tinsert(lines, tostring(l)) end
    tinsert(lines, "As of each character's last login.")
    y = y - 6
    for i, text in ipairs(lines) do
        local f = Foot(i)
        f:SetText(text)
        f:ClearAllPoints()
        f:SetPoint("TOP", tip, "TOP", 0, y)
        f:Show()
        width = math.max(width, TIP_PAD * 2 + f:GetStringWidth())
        y = y - 15
    end
    for i = #lines + 1, #tip.foot do tip.foot[i]:Hide() end
    tip:SetSize(math.max(240, math.ceil(width)), -y + 8)
end

-- Show a roster card above a bar segment. data = what the plugin's roster()
-- returned; anything missing or malformed shows the title and "Data
-- unavailable" instead of an error.
function ns.ShowRoster(owner, data, fallbackTitle)
    if not tip then CreateTip() end
    local failed = { title = fallbackTitle, rows = {}, empty = "Data unavailable" }
    if type(data) ~= "table" or not pcall(Layout, data) then
        pcall(Layout, failed)
    end
    -- above the bar, or below it when the bar is docked at the top
    local top = ns.BarSettings and ns.BarSettings().anchor == "TOP"
    local function Place(offset)
        tip:ClearAllPoints()
        if top then
            tip:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -6 + offset)
        else
            tip:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, 6 - offset)
        end
    end
    -- open: fade in while sliding 6px into place, ~150ms. A short-lived
    -- OnUpdate that removes itself when done - nothing runs per frame after.
    local t = 0
    tip:SetAlpha(0)
    Place(6)
    tip:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        local f = math.min(1, t / 0.15)
        self:SetAlpha(f)
        Place(6 * (1 - f))
        if f >= 1 then self:SetScript("OnUpdate", nil) end
    end)
    tip:Show()
end

function ns.HideRoster()
    if not tip then return end
    tip:SetScript("OnUpdate", nil)
    for _, r in ipairs(tip.rows) do r.pulse:Stop() end
    tip:Hide()
end
