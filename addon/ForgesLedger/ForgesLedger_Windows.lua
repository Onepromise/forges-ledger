-- Forge's Ledger: detail windows (part of the core addon, v2.5)
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
