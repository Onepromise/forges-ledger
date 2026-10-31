-- PUG Lyfe v1.0 (retail and WoW Forever)
-- Your private PUG journal. Group with someone, thumbs-up or thumbs-down
-- them and leave yourself a note; next time they join your group, a small
-- reminder says what you thought. Personal only: nothing is shared, no
-- messages are sent, and nothing is read from chat.
--
-- How it works
--   * Whenever you're in a group, each new member is remembered (name,
--     class, when, what you were doing, how many groups you've shared).
--     Guildmates and friends are skipped, since they aren't PUGs.
--   * When a group ends (or a Dungeon Finder run completes) and it had
--     people you haven't rated, a small "How was the group?" box offers a
--     thumbs-up or thumbs-down for each, never mid-fight.
--   * When someone you've rated or written a note about joins your group,
--     or you target them, a small reminder appears (also never mid-fight).
--     Their tooltip gets a line too.
--   * /pug opens the list: filter, search, rate, write a note, forget.
--
-- Rules it follows
--   * works on its own; no other addon needed
--   * every game call is checked to exist and pcall-guarded (retail and
--     Forever differ), and unit data the game hides ("secret values") is
--     skipped rather than stored
--   * account-wide: your opinion of a player applies on all your characters
--   * no work every frame: it reacts to group changes and nothing else

local ADDON = "PugLyfe"
local VERSION = "1.0"
local SCHEMA = 1
local PREFIX = "|cffFFD700[PUG Lyfe]|r "
local MEDIA = "Interface\\AddOns\\PugLyfe\\Media\\"

local IS_RETAIL = not (WOW_PROJECT_ID and WOW_PROJECT_MAINLINE) or WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
local GAME = IS_RETAIL and "Retail" or "Forever"

PugLyfeDB = PugLyfeDB or {}

local MAX_SEEN = 300      -- people only seen (never rated or noted) kept, newest first
local MAX_NOTE = 120
local MAX_CONTEXTS = 5

------------------------------------------------------------- game calls ---

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

-- Midnight's "secret values" can't be stored or compared by addons.
local function Plain(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end

---------------------------------------------------------------- save data ---

local function DB()
    local db = PugLyfeDB
    db.schemaVersion = SCHEMA
    db.version = GAME
    db.players = type(db.players) == "table" and db.players or {}
    local s = type(db.settings) == "table" and db.settings or {}
    db.settings = s
    local function def(k, v) if s[k] == nil then s[k] = v end end
    def("askAfter", true)       -- offer to rate when a group ends
    def("popup", true)          -- remind me when a rated player joins my group
    def("targetPopup", true)    -- ...or when I target them
    def("tooltip", true)        -- a line on their tooltip
    def("skipKnown", true)      -- ignore guildmates and friends
    def("minimap", true)
    s.angle = tonumber(s.angle) or 215
    return db
end

local function Settings() return DB().settings end

local function Known(rec)
    return type(rec) == "table" and (rec.rating ~= nil or (type(rec.note) == "string" and rec.note ~= ""))
end

-- Keep the list from growing without end: people who were only seen (never
-- rated or noted) are trimmed to the newest MAX_SEEN. Anything you rated or
-- wrote about is never removed.
local function Prune()
    local players, seen = DB().players, {}
    for key, rec in pairs(players) do
        if not Known(rec) then tinsert(seen, { key = key, at = tonumber(rec.lastSeen) or 0 }) end
    end
    if #seen <= MAX_SEEN then return end
    table.sort(seen, function(a, b) return a.at > b.at end)
    for i = MAX_SEEN + 1, #seen do players[seen[i].key] = nil end
end

local function RealmKey(realm)
    realm = Plain(realm)
    if type(realm) ~= "string" or realm == "" then
        realm = Plain(Try(GetNormalizedRealmName)) or Plain(Try(GetRealmName)) or "Unknown"
    end
    return (realm:gsub("[%s%'%-]", ""))
end

local function MyRealm() return Plain(Try(GetRealmName)) or "" end

local function Context()
    local inside = Try(IsInInstance)
    local name = inside and Plain(Try(GetInstanceInfo)) or Plain(Try(GetRealZoneText)) or Plain(Try(GetZoneText))
    return type(name) == "string" and name or ""
end

local function Record(m)
    local db = DB()
    local rec = db.players[m.key]
    local now = time()
    if not rec then
        rec = { name = m.name, realm = m.realm, firstSeen = now, lastSeen = now, times = 0, contexts = {} }
        db.players[m.key] = rec
        Prune()  -- (after lastSeen is set: a brand-new record must not look oldest)
    end
    rec.class = m.class or rec.class
    rec.prevSeen = tonumber(rec.lastSeen)  -- the reminder says "last seen" as of BEFORE today's group
    rec.lastSeen = now
    rec.times = (tonumber(rec.times) or 0) + 1
    local ctx = Context()
    if ctx ~= "" then
        local list = {}
        for _, c in ipairs(type(rec.contexts) == "table" and rec.contexts or {}) do
            if c ~= ctx then tinsert(list, c) end
        end
        tinsert(list, 1, ctx)
        while #list > MAX_CONTEXTS do tremove(list) end
        rec.contexts = list
    end
    return rec
end

local function Day(t) return date("%b %d", t) end

local function Ago(t)
    local d = (time() - (tonumber(t) or 0)) / 86400
    if d < 1 then return "today" end
    if d < 2 then return "yesterday" end
    if d < 60 then return math.floor(d) .. " days ago" end
    return Day(t)
end

local function Label(rec)
    local n = rec.name or "?"
    if rec.realm and rec.realm ~= "" and rec.realm ~= MyRealm() then n = n .. "-" .. rec.realm end
    return n
end

local function ClassColor(rec)
    local c = rec.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[rec.class]
    if c then return { c.r, c.g, c.b } end
    return { 0.92, 0.90, 0.85 }
end

-- the words for a rating
local function RatingText(r)
    if r == "up" then return "Group again" end
    if r == "down" then return "Avoid" end
    return "No rating"
end

--------------------------------------------------------------- the group ---

local function InGroup() return Try(IsInGroup) and true or false end

-- Guildmates and friends aren't PUGs. Each check is optional: a client
-- without it just doesn't skip on that basis.
local function IsKnownPerson(unit)
    if Try(UnitIsInMyGuild, unit) then return true end
    local guid = Plain(Try(UnitGUID, unit))
    if guid then
        if C_FriendList and C_FriendList.IsFriend and Try(C_FriendList.IsFriend, guid) then return true end
        if C_BattleNet and C_BattleNet.GetAccountInfoByGUID and Try(C_BattleNet.GetAccountInfoByGUID, guid) then return true end
    end
    return false
end

-- the other people in my group: { key, name, realm, class }; pending = a
-- member's name hasn't loaded yet (try again shortly)
local function Members()
    local out, pending = {}, false
    local n = tonumber(Plain(Try(GetNumGroupMembers))) or 0
    if n == 0 or not InGroup() then return out, false end
    local raid = Try(IsInRaid)
    local prefix = raid and "raid" or "party"
    local count = raid and n or (n - 1)
    local skip = Settings().skipKnown
    for i = 1, count do
        local unit = prefix .. i
        if Try(UnitExists, unit) and not Try(UnitIsUnit, unit, "player") then
            local name, realm = Try(UnitFullName, unit)
            name = Plain(name)
            if type(name) ~= "string" or name == "" or name == UNKNOWN or name == "Unknown" then
                pending = true
            elseif not (skip and IsKnownPerson(unit)) then
                local _, class = Try(UnitClass, unit)
                tinsert(out, { key = name .. "-" .. RealmKey(realm), name = name, class = Plain(class),
                               realm = (type(Plain(realm)) == "string" and Plain(realm) ~= "") and Plain(realm) or MyRealm() })
            end
        end
    end
    return out, pending
end

------------------------------------------------------------ prompts (UI) ---
-- (declared here; built further down)
local ShowPopup, ShowRate, RefreshWindow

local stint = { members = {}, order = {}, prompted = false }  -- this group, so far
local queue = {}                                              -- prompts waiting for the fight to end
local lastTargetPopup = {}

local function ResetStint() stint = { members = {}, order = {}, prompted = false } end

local function InCombat() return Try(InCombatLockdown) and true or false end

local function Flush()
    if InCombat() then return end
    local q = queue
    queue = {}
    for _, item in ipairs(q) do
        if item.kind == "popup" then ShowPopup(item.recs) else ShowRate(item.recs) end
    end
end

local function Enqueue(kind, recs)
    if #recs == 0 then return end
    tinsert(queue, { kind = kind, recs = recs })
    Flush()
end

-- people from this group I haven't rated
local lastOrder = {}  -- the group that just ended, for /pug rate

local function Unrated(order)
    order = order or stint.order
    local out, players = {}, DB().players
    for i = #order, 1, -1 do
        local key = order[i]
        local rec = players[key]
        if rec and rec.rating == nil then tinsert(out, { key = key, rec = rec }) end
        if #out >= 5 then break end
    end
    return out
end

-- force: asked for with /pug rate (ignores the "ask me" setting and an
-- earlier prompt for this group)
local function PromptRating(force, order)
    if not force and (stint.prompted or not Settings().askAfter) then return end
    local list = Unrated(order)
    if #list == 0 then return false end
    stint.prompted = true
    Enqueue("rate", list)
    return true
end

local function EndStint()
    if #stint.order > 0 then
        PromptRating()
        lastOrder = stint.order
    end
    ResetStint()
end

local retries = 0
local ScanGroup
local function Scan()
    -- a battleground is 40 strangers, not a PUG worth remembering
    local inside, kind = Try(IsInInstance)
    if inside and kind == "pvp" then return end
    local list, pending = Members()
    if #list == 0 and not InGroup() then
        EndStint()
        return
    end
    local known = {}
    for _, m in ipairs(list) do
        if not stint.members[m.key] then
            stint.members[m.key] = true
            tinsert(stint.order, m.key)
            local rec = Record(m)
            if Known(rec) then tinsert(known, { key = m.key, rec = rec, recorded = true }) end
        end
    end
    if Settings().popup then Enqueue("popup", known) end
    if pending and retries < 5 then
        retries = retries + 1
        C_Timer.After(2, ScanGroup)
    elseif not pending then
        retries = 0
    end
end
ScanGroup = Scan

local scanQueued = false
local function QueueScan()
    retries = 0  -- a fresh roster change earns a fresh set of retries
    if scanQueued then return end
    scanQueued = true
    C_Timer.After(0.5, function()  -- a roster change fires several events
        scanQueued = false
        Scan()
    end)
end

---------------------------------------------------------------- rating api ---

local function SetRating(key, rating)
    local rec = DB().players[key]
    if not rec then return end
    rec.rating = rating
    rec.ratedAt = rating and time() or nil
    if RefreshWindow then RefreshWindow() end
end

local function SetNote(key, text)
    local rec = DB().players[key]
    if not rec then return end
    text = strtrim(text or "")
    rec.note = text ~= "" and text:sub(1, MAX_NOTE) or nil
end

local function Forget(key)
    DB().players[key] = nil
    if RefreshWindow then RefreshWindow() end
end

-- the player I'm targeting, as a member record (recorded if new)
local function TargetMember()
    if not (Try(UnitExists, "target") and Try(UnitIsPlayer, "target")) or Try(UnitIsUnit, "target", "player") then return nil end
    local name, realm = Try(UnitFullName, "target")
    name = Plain(name)
    if type(name) ~= "string" or name == "" then return nil end
    local _, class = Try(UnitClass, "target")
    return { key = name .. "-" .. RealmKey(realm), name = name, class = Plain(class),
             realm = (type(Plain(realm)) == "string" and Plain(realm) ~= "") and Plain(realm) or MyRealm() }
end

--------------------------------------------------------------------- UI ---

local IRON, GOLD, BONE, DIM = { 0.06, 0.06, 0.08, 0.97 }, { 0.90, 0.75, 0.25 }, { 0.92, 0.90, 0.85 }, { 0.55, 0.55, 0.55 }
local GREEN, RUST = { 0.45, 0.72, 0.30 }, { 0.88, 0.42, 0.27 }

local function Tex(parent, layer, col, file)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    if file then
        t:SetTexture(MEDIA .. file)
        if col then t:SetVertexColor(col[1], col[2], col[3], col[4] or 1) end
    else
        t:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end
    return t
end

local function Border(f, a)
    for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = Tex(f, "BORDER", { GOLD[1], GOLD[2], GOLD[3], a or 0.8 })
        t:SetPoint(p[1])
        t:SetPoint(p[2])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
    end
end

local function Btn(parent, label, w, col)
    col = col or GOLD
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 80, 22)
    b.bg = Tex(b, "BACKGROUND", { col[1], col[2], col[3], 0.14 })
    b.bg:SetAllPoints()
    Tex(b, "HIGHLIGHT", { 1, 1, 1, 0.10 }):SetAllPoints()
    Border(b, 0.5)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b.text:SetTextColor(col[1], col[2], col[3])
    b.col = col
    return b
end

-- a round thumbs button: lit when it's the current rating
local function ThumbBtn(parent, up)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(24, 24)
    b.ring = Tex(b, "BORDER", up and GREEN or RUST, "ring.tga")
    b.ring:SetAllPoints()
    b.fill = Tex(b, "BACKGROUND", { (up and GREEN or RUST)[1], (up and GREEN or RUST)[2], (up and GREEN or RUST)[3], 0.30 }, "circle.tga")
    b.fill:SetAllPoints()
    b.fill:Hide()
    b.icon = Tex(b, "ARTWORK", up and GREEN or RUST, up and "thumb_up.tga" or "thumb_down.tga")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint("CENTER")
    Tex(b, "HIGHLIGHT", { 1, 1, 1, 0.15 }, "circle.tga"):SetAllPoints()
    b.up = up
    return b
end

local function SetLit(b, on)
    b.fill:SetShown(on)
    b.icon:SetAlpha(on and 1 or 0.7)
end

local function EditBox(parent, multi, w, h)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetAutoFocus(false)
    e:SetFontObject("GameFontHighlight")
    e:SetMultiLine(multi and true or false)
    e:SetMaxLetters(MAX_NOTE)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

local function Backdrop(f, border)
    Tex(f, "BACKGROUND", IRON):SetAllPoints()
    Border(f, border or 0.85)
end

local function MakeMovable(f, key)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        Settings()[key] = { point, x, y }
    end)
    local pos = Settings()[key]
    f:ClearAllPoints()
    if type(pos) == "table" and type(pos[1]) == "string" then
        f:SetPoint(pos[1], UIParent, pos[1], tonumber(pos[2]) or 0, tonumber(pos[3]) or 0)
        return true
    end
    return false
end

-------------------------------------------------- reminder popup + rate box ---

local popup, popupGen = nil, 0

local function CreatePopup()
    popup = CreateFrame("Frame", "PugLyfePopup", UIParent)
    popup:SetWidth(380)
    popup:SetFrameStrata("HIGH")
    popup:SetClampedToScreen(true)
    Backdrop(popup, 0.9)
    if not MakeMovable(popup, "popupPos") then popup:SetPoint("TOP", UIParent, "TOP", 0, -140) end
    popup.icon = Tex(popup, "ARTWORK", nil, "pug.tga")
    popup.icon:SetSize(26, 26)
    popup.icon:SetPoint("TOPLEFT", 10, -8)
    popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    popup.title:SetPoint("LEFT", popup.icon, "RIGHT", 8, 0)
    popup.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    popup.title:SetText("Played with before")
    local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    popup.rows = {}
    popup:Hide()
end

-- recs: { { key, rec } ... }
ShowPopup = function(recs)
    if not popup then CreatePopup() end
    popupGen = popupGen + 1
    local gen = popupGen
    local y, shown = -40, 0
    for i, item in ipairs(recs) do
        if i > 3 then break end
        local rec = item.rec
        local r = popup.rows[i]
        if not r then
            r = CreateFrame("Frame", nil, popup)
            r:SetHeight(40)
            r.thumb = Tex(r, "ARTWORK", nil, "thumb_up.tga")
            r.thumb:SetSize(16, 16)
            r.thumb:SetPoint("TOPLEFT", 12, -2)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            r.name:SetPoint("TOPLEFT", 34, 0)
            r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.info:SetPoint("TOPRIGHT", -14, -2)
            r.info:SetTextColor(DIM[1], DIM[2], DIM[3])
            r.note = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.note:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
            r.note:SetPoint("RIGHT", -14, 0)
            r.note:SetJustifyH("LEFT")
            popup.rows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", popup, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", popup, "RIGHT")
        local c = ClassColor(rec)
        r.name:SetText(Label(rec))
        r.name:SetTextColor(c[1], c[2], c[3])
        local col = rec.rating == "down" and RUST or rec.rating == "up" and GREEN or DIM
        r.thumb:SetTexture(MEDIA .. (rec.rating == "down" and "thumb_down.tga" or rec.rating == "up" and "thumb_up.tga" or "circle.tga"))
        r.thumb:SetVertexColor(col[1], col[2], col[3], rec.rating and 1 or 0.5)
        -- recorded just now: "before" excludes today's group, and "last"
        -- is the sighting before it. A target reminder uses the saved numbers.
        local before = math.max(0, (rec.times or 1) - (item.recorded and 1 or 0))
        local last = item.recorded and rec.prevSeen or rec.lastSeen
        r.info:SetText(RatingText(rec.rating) .. "  \194\183  " .. before .. (before == 1 and " group" or " groups")
            .. " before" .. (last and ("  \194\183  last " .. Ago(last)) or ""))
        r.info:SetTextColor(col[1], col[2], col[3])
        local note = rec.note and ("\"" .. rec.note .. "\"") or ""
        r.note:SetText(note)
        r.note:SetTextColor(BONE[1], BONE[2], BONE[3])
        r:Show()
        shown = shown + 1
        y = y - (note ~= "" and 40 or 26)
    end
    for i = shown + 1, #popup.rows do popup.rows[i]:Hide() end
    popup:SetHeight(-y + 10)
    popup:Show()
    C_Timer.After(15, function() if gen == popupGen and popup:IsShown() then popup:Hide() end end)
end

local rate

local function CreateRate()
    rate = CreateFrame("Frame", "PugLyfeRate", UIParent)
    rate:SetWidth(300)
    rate:SetFrameStrata("HIGH")
    rate:SetClampedToScreen(true)
    Backdrop(rate, 0.9)
    if not MakeMovable(rate, "ratePos") then rate:SetPoint("CENTER", UIParent, "CENTER", 0, -170) end
    rate.icon = Tex(rate, "ARTWORK", nil, "pug.tga")
    rate.icon:SetSize(26, 26)
    rate.icon:SetPoint("TOPLEFT", 10, -8)
    rate.title = rate:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rate.title:SetPoint("LEFT", rate.icon, "RIGHT", 8, 0)
    rate.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    rate.title:SetText("How was the group?")
    local close = CreateFrame("Button", nil, rate, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    rate.rows = {}
    rate:Hide()
end

local function RefreshRate()
    if not rate then return end
    local players = DB().players
    local left = 0
    for _, r in ipairs(rate.rows) do
        if r:IsShown() and r.key then
            local rec = players[r.key]
            SetLit(r.up, rec and rec.rating == "up")
            SetLit(r.down, rec and rec.rating == "down")
            r.name:SetAlpha(rec and rec.rating and 0.55 or 1)
            if rec and not rec.rating then left = left + 1 end
        end
    end
    rate.left = left
end

ShowRate = function(recs)
    if not rate then CreateRate() end
    local y, shown = -38, 0
    for i, item in ipairs(recs) do
        if i > 5 then break end
        local r = rate.rows[i]
        if not r then
            r = CreateFrame("Frame", nil, rate)
            r:SetHeight(28)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            r.name:SetPoint("LEFT", 14, 0)
            r.name:SetWidth(170)
            r.name:SetJustifyH("LEFT")
            r.name:SetWordWrap(false)
            r.down = ThumbBtn(r, false)
            r.down:SetPoint("RIGHT", -14, 0)
            r.up = ThumbBtn(r, true)
            r.up:SetPoint("RIGHT", r.down, "LEFT", -8, 0)
            local function rateIt(b, value)
                b:SetScript("OnClick", function()
                    local rec = DB().players[r.key]
                    if rec and rec.rating == value then
                        SetRating(r.key, nil)  -- the lit thumb again: clear it
                    else
                        SetRating(r.key, value)
                    end
                    RefreshRate()
                end)
            end
            rateIt(r.up, "up")
            rateIt(r.down, "down")
            rate.rows[i] = r
        end
        r.key = item.key
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", rate, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", rate, "RIGHT")
        local c = ClassColor(item.rec)
        r.name:SetText(Label(item.rec))
        r.name:SetTextColor(c[1], c[2], c[3])
        r:Show()
        shown = shown + 1
        y = y - 30
    end
    for i = shown + 1, #rate.rows do rate.rows[i]:Hide(); rate.rows[i].key = nil end
    if not rate.hint then
        rate.hint = rate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rate.hint:SetTextColor(DIM[1], DIM[2], DIM[3])
        rate.hint:SetText("Add a note any time: /pug")
    end
    rate.hint:ClearAllPoints()
    rate.hint:SetPoint("TOPLEFT", rate, "TOPLEFT", 14, y - 4)
    rate:SetHeight(-y + 24)
    RefreshRate()
    rate:Show()
end

----------------------------------------------------------- the main window ---

local W, H, LIST_W, ROW_H, ROWS = 590, 430, 280, 26, 12
local win, rows, offset, selected, filter, search, panel = nil, {}, 0, nil, "all", "", "detail"

local FILTERS = {
    { "all", "All" }, { "up", "Group again" }, { "down", "Avoid" }, { "new", "Unrated" },
}

-- the list, filtered and searched: newest first
local function Listing()
    local out = {}
    local q = search:lower()
    for key, rec in pairs(DB().players) do
        local ok = true
        if filter == "up" then ok = rec.rating == "up"
        elseif filter == "down" then ok = rec.rating == "down"
        elseif filter == "new" then ok = rec.rating == nil end
        if ok and q ~= "" then ok = (rec.name or ""):lower():find(q, 1, true) ~= nil end
        if ok then tinsert(out, { key = key, rec = rec }) end
    end
    table.sort(out, function(a, b)
        local x, y = tonumber(a.rec.lastSeen) or 0, tonumber(b.rec.lastSeen) or 0
        if x ~= y then return x > y end
        return a.key < b.key
    end)
    return out
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, win.list)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", win.list, "TOPLEFT", 2, -4 - (i - 1) * ROW_H)
    r:SetPoint("RIGHT", win.list, "RIGHT", -2, 0)
    r.sel = Tex(r, "BACKGROUND", { GOLD[1], GOLD[2], GOLD[3], 0.12 })
    r.sel:SetAllPoints()
    Tex(r, "HIGHLIGHT", { 1, 1, 1, 0.05 }):SetAllPoints()
    r.thumb = r:CreateTexture(nil, "ARTWORK")
    r.thumb:SetSize(14, 14)
    r.thumb:SetPoint("LEFT", 8, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetPoint("LEFT", 30, 0)
    r.name:SetWidth(150)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.when = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.when:SetPoint("RIGHT", -8, 0)
    r.when:SetTextColor(DIM[1], DIM[2], DIM[3])
    r:SetScript("OnClick", function(self)
        selected, panel = self.key, "detail"
        RefreshWindow()
    end)
    rows[i] = r
    return r
end

local function RenderList()
    local list = Listing()
    offset = math.max(0, math.min(offset, #list - ROWS))
    for i = 1, ROWS do
        local item, r = list[offset + i], GetRow(i)
        if not item then
            r:Hide()
        else
            local rec = item.rec
            r.key = item.key
            local c = ClassColor(rec)
            r.name:SetText(Label(rec))
            r.name:SetTextColor(c[1], c[2], c[3])
            r.when:SetText(Day(rec.lastSeen or 0))
            local col = rec.rating == "down" and RUST or rec.rating == "up" and GREEN or DIM
            r.thumb:SetTexture(MEDIA .. (rec.rating == "down" and "thumb_down.tga" or rec.rating == "up" and "thumb_up.tga" or "circle.tga"))
            r.thumb:SetVertexColor(col[1], col[2], col[3], rec.rating and 1 or 0.35)
            r.sel:SetShown(item.key == selected)
            r:Show()
        end
    end
    win.empty:SetShown(#list == 0)
    if #list == 0 then
        local anyone = next(DB().players) ~= nil
        win.empty:SetText(anyone and "Nobody matches." or "Nobody yet.\nGroup up and they'll appear here.")
    end
    win.count:SetText(#list .. (#list == 1 and " player" or " players"))
end

local function RenderDetail()
    local d = win.detail
    local rec = selected and DB().players[selected]
    d.none:SetShown(rec == nil)
    d.body:SetShown(rec ~= nil)
    if not rec then return end
    local c = ClassColor(rec)
    d.name:SetText(Label(rec))
    d.name:SetTextColor(c[1], c[2], c[3])
    d.meta:SetText("Grouped " .. (rec.times or 0) .. (rec.times == 1 and " time" or " times")
        .. "  \194\183  first " .. Day(rec.firstSeen or 0) .. "  \194\183  last " .. Day(rec.lastSeen or 0))
    d.where:SetText(type(rec.contexts) == "table" and #rec.contexts > 0 and ("Seen in: " .. table.concat(rec.contexts, ", ")) or "")
    SetLit(d.up, rec.rating == "up")
    SetLit(d.down, rec.rating == "down")
    d.state:SetText(RatingText(rec.rating))
    local col = rec.rating == "down" and RUST or rec.rating == "up" and GREEN or DIM
    d.state:SetTextColor(col[1], col[2], col[3])
    d.note.key = selected
    d.note:SetText(rec.note or "")
    d.placeholder:SetShown((rec.note or "") == "")
    d.forget.armed = false
    d.forget.text:SetText("Forget this player")
end

local SETTING_ROWS = {
    { "askAfter", "Ask me to rate after a group" },
    { "popup", "Remind me when I group with someone I've rated" },
    { "targetPopup", "Remind me when I target them" },
    { "tooltip", "Add a line to their tooltip" },
    { "skipKnown", "Skip guildmates and friends" },
    { "minimap", "Show the minimap button" },
}

local UpdateMinimap

local function RenderSettings()
    local s = Settings()
    for _, t in ipairs(win.settings.toggles) do
        local on = s[t.key] and true or false
        t.state:SetText(on and "On" or "Off")
        t.state:SetTextColor((on and GREEN or DIM)[1], (on and GREEN or DIM)[2], (on and GREEN or DIM)[3])
    end
end

local function Export()
    local lines = { "PUG Lyfe - " .. GAME .. " - " .. date("%Y-%m-%d") }
    local list = {}
    for key, rec in pairs(DB().players) do
        if Known(rec) then tinsert(list, { key = key, rec = rec }) end
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    for _, it in ipairs(list) do
        local r = it.rec
        tinsert(lines, it.key .. " | " .. (r.rating == "up" and "group again" or r.rating == "down" and "avoid" or "-")
            .. " | " .. (r.note or "") .. " | last seen " .. Day(r.lastSeen or 0) .. " | " .. (r.times or 0) .. "x")
    end
    return table.concat(lines, "\n")
end

RefreshWindow = function()
    if not (win and win:IsShown()) then return end
    for _, f in ipairs(FILTERS) do
        local b = win.filters[f[1]]
        b.bg:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], filter == f[1] and 0.35 or 0.10)
    end
    RenderList()
    win.detail:SetShown(panel == "detail")
    win.settings:SetShown(panel == "settings")
    win.export:SetShown(panel == "export")
    if panel == "detail" then RenderDetail() end
    if panel == "settings" then RenderSettings() end
    if panel == "export" then win.export.text:SetText(Export()) end
end

local function CreateWindow()
    win = CreateFrame("Frame", "PugLyfeWindow", UIParent)
    win:SetSize(W, H)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    Backdrop(win, 0.85)
    if not MakeMovable(win, "winPos") then win:SetPoint("CENTER") end
    tinsert(UISpecialFrames, "PugLyfeWindow")

    win.icon = Tex(win, "ARTWORK", nil, "pug.tga")
    win.icon:SetSize(34, 34)
    win.icon:SetPoint("TOPLEFT", 12, -8)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", win.icon, "RIGHT", 8, 4)
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    title:SetText("PUG Lyfe")
    local sub = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -1)
    sub:SetTextColor(DIM[1], DIM[2], DIM[3])
    sub:SetText("Your private PUG journal. Nothing here is shared.")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    win.gear = Btn(win, "Settings", 70)
    win.gear:SetPoint("RIGHT", close, "LEFT", -6, 0)
    win.gear:SetScript("OnClick", function() panel = panel == "settings" and "detail" or "settings"; RefreshWindow() end)

    -- filters and search
    win.filters = {}
    local x = 14
    for _, f in ipairs(FILTERS) do
        local b = Btn(win, f[2], f[1] == "up" and 84 or 64)
        b:SetPoint("TOPLEFT", win, "TOPLEFT", x, -54)
        b:SetScript("OnClick", function() filter, offset = f[1], 0; RefreshWindow() end)
        win.filters[f[1]] = b
        x = x + b:GetWidth() + 4
    end
    win.count = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.count:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -58)
    win.count:SetTextColor(DIM[1], DIM[2], DIM[3])

    -- left: the list
    win.list = CreateFrame("Frame", nil, win)
    win.list:SetPoint("TOPLEFT", 12, -112)
    win.list:SetPoint("BOTTOMLEFT", 12, 12)
    win.list:SetWidth(LIST_W)
    Tex(win.list, "BACKGROUND", { 0, 0, 0, 0.35 }):SetAllPoints()
    Border(win.list, 0.3)
    win.list:EnableMouseWheel(true)
    win.list:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 3)
        RenderList()
    end)
    win.empty = win.list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    win.empty:SetPoint("TOP", 0, -30)
    win.empty:SetTextColor(DIM[1], DIM[2], DIM[3])
    local sbox = CreateFrame("Frame", nil, win)
    sbox:SetPoint("TOPLEFT", 12, -82)
    sbox:SetSize(LIST_W, 24)
    Tex(sbox, "BACKGROUND", { 0, 0, 0, 0.5 }):SetAllPoints()
    Border(sbox, 0.3)
    win.search = EditBox(sbox, false)
    win.search:SetPoint("TOPLEFT", 8, -4)
    win.search:SetPoint("BOTTOMRIGHT", -8, 4)
    win.search:SetMaxLetters(24)
    win.search.ph = sbox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.search.ph:SetPoint("LEFT", 10, 0)
    win.search.ph:SetTextColor(DIM[1], DIM[2], DIM[3])
    win.search.ph:SetText("Search by name")
    win.search:SetScript("OnTextChanged", function(self, userInput)
        win.search.ph:SetShown((self:GetText() or "") == "")
        if not userInput then return end
        search, offset = strtrim(self:GetText() or ""), 0
        RenderList()
    end)

    -- right: the chosen player
    local PX, PW = 12 + LIST_W + 12, W - (12 + LIST_W + 12) - 12
    local d = CreateFrame("Frame", nil, win)
    d:SetPoint("TOPLEFT", PX, -82)
    d:SetPoint("BOTTOMRIGHT", -12, 12)
    win.detail = d
    d.none = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.none:SetPoint("TOP", 0, -60)
    d.none:SetTextColor(DIM[1], DIM[2], DIM[3])
    d.none:SetText("Pick someone from the list.\nOr target a player and type /pug up or /pug down.")
    d.body = CreateFrame("Frame", nil, d)
    d.body:SetAllPoints()
    d.name = d.body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.name:SetPoint("TOPLEFT", 4, -4)
    d.meta = d.body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.meta:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -6)
    d.meta:SetTextColor(DIM[1], DIM[2], DIM[3])
    d.where = d.body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.where:SetPoint("TOPLEFT", d.meta, "BOTTOMLEFT", 0, -4)
    d.where:SetWidth(PW - 8)
    d.where:SetJustifyH("LEFT")
    d.where:SetTextColor(BONE[1], BONE[2], BONE[3])
    d.up = ThumbBtn(d.body, true)
    d.up:SetSize(34, 34)
    d.up:SetPoint("TOPLEFT", 4, -92)
    d.down = ThumbBtn(d.body, false)
    d.down:SetSize(34, 34)
    d.down:SetPoint("LEFT", d.up, "RIGHT", 10, 0)
    d.state = d.body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    d.state:SetPoint("LEFT", d.down, "RIGHT", 14, 0)
    local function rateSel(b, value)
        b:SetScript("OnClick", function()
            local rec = selected and DB().players[selected]
            if not rec then return end
            if rec.rating == value then
                SetRating(selected, nil)  -- the lit thumb again: clear it
            else
                SetRating(selected, value)
            end
        end)
    end
    rateSel(d.up, "up")
    rateSel(d.down, "down")
    local nl = d.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nl:SetPoint("TOPLEFT", 4, -146)
    nl:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    nl:SetText("Your note (private)")
    local nb = CreateFrame("Frame", nil, d.body)
    nb:SetPoint("TOPLEFT", nl, "BOTTOMLEFT", 0, -6)
    nb:SetPoint("RIGHT", d.body, "RIGHT", -4, 0)
    nb:SetHeight(86)
    Tex(nb, "BACKGROUND", { 0, 0, 0, 0.5 }):SetAllPoints()
    Border(nb, 0.3)
    d.note = EditBox(nb, true)
    d.note:SetPoint("TOPLEFT", 8, -6)
    d.note:SetPoint("BOTTOMRIGHT", -8, 6)
    d.note:SetTextColor(BONE[1], BONE[2], BONE[3])
    d.placeholder = nb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.placeholder:SetPoint("TOPLEFT", 10, -8)
    d.placeholder:SetTextColor(DIM[1], DIM[2], DIM[3])
    d.placeholder:SetText("e.g. great healer, knows the mechanics")
    d.note:SetScript("OnTextChanged", function(self, userInput)
        d.placeholder:SetShown((self:GetText() or "") == "")
        if userInput and self.key then SetNote(self.key, self:GetText()) end
    end)
    nb:EnableMouse(true)
    nb:SetScript("OnMouseDown", function() d.note:SetFocus() end)
    d.forget = Btn(d.body, "Forget this player", 130, RUST)
    d.forget:SetPoint("BOTTOMLEFT", 4, 4)
    d.forget:SetScript("OnClick", function(self)
        -- two clicks: a stray click never loses a page
        if not self.armed then
            self.armed = true
            self.text:SetText("Click again to forget")
            return
        end
        local key = selected
        selected = nil
        if key then Forget(key) end
    end)

    -- settings
    local sp = CreateFrame("Frame", nil, win)
    sp:SetPoint("TOPLEFT", PX, -82)
    sp:SetPoint("BOTTOMRIGHT", -12, 12)
    win.settings = sp
    sp.toggles = {}
    local y = -8
    for _, t in ipairs(SETTING_ROWS) do
        local row = CreateFrame("Button", nil, sp)
        row:SetPoint("TOPLEFT", 4, y)
        row:SetPoint("RIGHT", sp, "RIGHT", -4, 0)
        row:SetHeight(24)
        Tex(row, "HIGHLIGHT", { 1, 1, 1, 0.05 }):SetAllPoints()
        local l = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l:SetPoint("LEFT", 2, 0)
        l:SetText(t[2])
        local st = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        st:SetPoint("RIGHT", -4, 0)
        row:SetScript("OnClick", function()
            local s = Settings()
            s[t[1]] = not s[t[1]]
            if t[1] == "minimap" and UpdateMinimap then UpdateMinimap() end
            RenderSettings()
        end)
        tinsert(sp.toggles, { key = t[1], state = st })
        y = y - 28
    end
    local ex = Btn(sp, "Export my notes", 130)
    ex:SetPoint("TOPLEFT", 4, y - 12)
    ex:SetScript("OnClick", function() panel = "export"; RefreshWindow() end)
    local foot = sp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    foot:SetPoint("BOTTOMLEFT", 4, 4)
    foot:SetPoint("RIGHT", -4, 0)
    foot:SetJustifyH("LEFT")
    foot:SetTextColor(DIM[1], DIM[2], DIM[3])
    foot:SetText("Everything stays on your PC: nothing is sent, and chat is never read.\nPUG Lyfe v" .. VERSION .. "  \194\183  by Forge at Crescent Cove")
    sp:Hide()

    -- export: your notes as text, selected for copying
    local ep = CreateFrame("Frame", nil, win)
    ep:SetPoint("TOPLEFT", PX, -82)
    ep:SetPoint("BOTTOMRIGHT", -12, 12)
    win.export = ep
    local eh = ep:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    eh:SetPoint("TOPLEFT", 4, -4)
    eh:SetTextColor(DIM[1], DIM[2], DIM[3])
    eh:SetText("Press Ctrl+C to copy your rated players and notes.")
    local scroll = CreateFrame("ScrollFrame", nil, ep)
    scroll:SetPoint("TOPLEFT", 4, -24)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    ep.text = EditBox(scroll, true)
    ep.text:SetWidth(PW - 16)
    ep.text:SetMaxLetters(0)
    ep.text:SetTextColor(BONE[1], BONE[2], BONE[3])
    ep.text:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(ep.text)
    ep:Hide()

    win:SetScript("OnShow", function()
        win.search:SetText(search)
        RefreshWindow()
    end)
    win:Hide()
end

local function ToggleWindow(show)
    if not win then CreateWindow() end
    if show == nil then show = not win:IsShown() end
    if show then
        if panel ~= "detail" then panel = "detail" end
        win:Show()
    else
        win:Hide()
    end
end

local function OpenOn(key)
    if not win then CreateWindow() end
    selected, panel, filter, search = key, "detail", "all", ""
    win:Show()
    RefreshWindow()
end

------------------------------------------------------------- minimap button ---

local mini
UpdateMinimap = function()
    if not Minimap then return end
    local s = Settings()
    if not mini then
        mini = CreateFrame("Button", "PugLyfeMinimapButton", Minimap)
        mini:SetSize(31, 31)
        mini:SetFrameStrata("MEDIUM")
        mini:SetFrameLevel(8)
        local icon = mini:CreateTexture(nil, "BACKGROUND")
        icon:SetTexture(MEDIA .. "pug.tga")
        icon:SetSize(22, 22)
        icon:SetPoint("CENTER")
        local border = mini:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        mini:RegisterForClicks("AnyUp")
        mini:RegisterForDrag("LeftButton")
        mini:SetScript("OnClick", function() ToggleWindow() end)
        mini:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local cx, cy = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                Settings().angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
                UpdateMinimap()
            end)
        end)
        mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        mini:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("PUG Lyfe")
            GameTooltip:AddLine("Click to open your PUG journal. Drag to move.", 1, 1, 1)
            GameTooltip:Show()
        end)
        mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local a = math.rad(s.angle)
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
    mini:SetShown(s.minimap)
end

---------------------------------------------------------------- tooltips ---

local function TooltipLine(tooltip)
    if not Settings().tooltip then return end
    local ok, unit = pcall(function() return select(2, tooltip:GetUnit()) end)
    if not ok or not unit or not Try(UnitIsPlayer, unit) or Try(UnitIsUnit, unit, "player") then return end
    local name, realm = Try(UnitFullName, unit)
    name = Plain(name)
    if type(name) ~= "string" or name == "" then return end
    local rec = DB().players[name .. "-" .. RealmKey(realm)]
    if not Known(rec) then return end
    local col = rec.rating == "down" and "|cffe06a45" or rec.rating == "up" and "|cff73b84d" or "|cff999999"
    tooltip:AddLine("PUG Lyfe: " .. col .. RatingText(rec.rating) .. "|r" .. (rec.note and ("  -  " .. rec.note) or ""))
end

local function HookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tooltip) pcall(TooltipLine, tooltip) end)
    elseif GameTooltip and GameTooltip.HookScript then
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tooltip) pcall(TooltipLine, tooltip) end)
    end
end

----------------------------------------------------------------- events ---

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "LFG_COMPLETION_REWARD", "PLAYER_TARGET_CHANGED",
                     "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
    pcall(frame.RegisterEvent, frame, e)  -- in case a client lacks one
end
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        DB()
        UpdateMinimap()
        HookTooltips()
        QueueScan()
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        QueueScan()
    elseif event == "LFG_COMPLETION_REWARD" then
        PromptRating()  -- a Dungeon Finder run just finished
    elseif event == "PLAYER_REGEN_ENABLED" then
        Flush()
    elseif event == "PLAYER_TARGET_CHANGED" then
        if not Settings().targetPopup then return end
        local m = TargetMember()
        local rec = m and DB().players[m.key]
        if Known(rec) and (time() - (lastTargetPopup[m.key] or 0)) > 600 and not stint.members[m.key] then
            lastTargetPopup[m.key] = time()
            Enqueue("popup", { { key = m.key, rec = rec } })
        end
    end
end)

----------------------------------------------------------------- /pug ---

local function ReportTarget(rating, rest, isNote)
    local m = TargetMember()
    if not m then
        print(PREFIX .. "Target a player first.")
        return
    end
    local rec = DB().players[m.key]
    if not rec then
        local db = DB()
        rec = { name = m.name, realm = m.realm, class = m.class, firstSeen = time(), lastSeen = time(), times = 0, contexts = {} }
        db.players[m.key] = rec
    end
    if rating then SetRating(m.key, rating) end
    -- /pug note with nothing after it clears the note; /pug up|down keeps it
    if isNote or (rest and rest ~= "") then SetNote(m.key, rest or "") end
    print(PREFIX .. Label(rec) .. ": " .. RatingText(rec.rating) .. (rec.note and ("  -  " .. rec.note) or ""))
end

SLASH_PUGLYFE1 = "/pug"
SLASH_PUGLYFE2 = "/puglyfe"
SlashCmdList.PUGLYFE = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ToggleWindow()
    elseif cmd == "up" or cmd == "like" or cmd == "good" then
        ReportTarget("up", rest)
    elseif cmd == "down" or cmd == "avoid" or cmd == "bad" then
        ReportTarget("down", rest)
    elseif cmd == "note" then
        ReportTarget(nil, rest, true)
    elseif cmd == "rate" then
        local order = #stint.order > 0 and stint.order or lastOrder
        if #order == 0 then
            print(PREFIX .. "No group to rate yet.")
        elseif not PromptRating(true, order) then
            print(PREFIX .. "Everyone from that group is rated already.")
        end
    elseif cmd == "find" or cmd == "who" then
        search, filter = rest, "all"
        ToggleWindow(true)
        if win and win.search then win.search:SetText(rest) end
        RefreshWindow()
    elseif cmd == "export" then
        if not win then CreateWindow() end
        panel = "export"
        win:Show()
        RefreshWindow()
    elseif cmd == "minimap" then
        Settings().minimap = not Settings().minimap
        UpdateMinimap()
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /pug - open your journal")
        print("  /pug up [note] or /pug down [note] - rate the player you're targeting")
        print("  /pug note <text> - leave a note on your target")
        print("  /pug rate - ask about the people from this group")
        print("  /pug find <name> - search")
        print("  /pug export - your notes as copyable text")
        print("  /pug minimap - show or hide the minimap button")
    end
end
