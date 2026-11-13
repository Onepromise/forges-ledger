-- Forge's Ledger: Kill Ledger v1.0
-- A companion to Forge's Ledger, and useful on its own: how many of each mob
-- you have killed, what they drop, how often, and what each drop sells for to
-- a vendor - in a panel, and on the Ledger dashboard.
--
-- Rules it follows (see the app's satellite spec):
--   * nothing hard-coded: mob names, zones, items and vendor prices all come
--     from the game; the addon only counts
--   * every game call is checked to exist and pcall-guarded, so an API change
--     can't break the game UI
--   * drop % is dropEvents / kills, always shown beside the raw kill count so
--     a small sample reads as a small sample
--   * your own loot only (v1); no auction prices, no sharing
--   * one save file per account with a "characters" list, so characters never
--     overwrite each other; the desktop app reads the same file
--   * no work every frame: it reacts to combat-log deaths and loot windows
--
-- HOW A KILL IS CREDITED
--   A kill counts once per corpse (by its GUID) when
--     (a) the combat log reports PARTY_KILL for it - the killing blow came
--         from you, your pet, or a party/raid member (or their pets), or
--     (b) the combat log reports its death (UNIT_DIED) and you, your pet or
--         your group damaged it in the 20 seconds before it died.
--   That is OPT-IN ("/kl combatlog on", then /reload). By default the addon
--   never touches the combat log: modern clients treat it as a protected
--   surface and show a "blocked from an action only available to the
--   Blizzard UI" dialog naming the addon (bug KL-1). Instead, by default a
--   kill counts once per corpse when
--     (c) your target dies and it was tapped by you or your group
--         (not tap-denied), or
--     (d) you open the loot window of a corpse not counted yet.
--
-- HOW LOOT IS ATTRIBUTED
--   When your loot window opens, every item slot is matched to its corpse by
--   the corpse's GUID (GetLootSourceInfo). The corpse must be a kill from the
--   last 10 minutes. Each corpse is counted once, the first time its window
--   opens: an item that was on the corpse counts as one drop event for that
--   kill, and its stack size adds to the quantity. Slots locked for a group
--   roll are skipped.

local VERSION = "1.1"
local SCHEMA = 1
local PREFIX = "|cffFFD700[Kill Ledger]|r "
local KILL_TTL = 600        -- a corpse's loot is attributed for 10 minutes
local TAG_WINDOW = 20       -- damage by your group counts toward tap credit for 20 s
local LOOT_ITEM = 1         -- Enum.LootSlotType.Item

ForgesLedgerKillLedgerDB = ForgesLedgerKillLedgerDB or {}

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

local function CharKey()
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName() or "Unknown"
    realm = realm:gsub("[%s%'%-]", "")  -- same key style as the core addon
    return (name or "Unknown") .. "-" .. realm
end

local function CharData()
    local db = ForgesLedgerKillLedgerDB
    db.schemaVersion = SCHEMA
    db.version = (WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE) and "Forever" or "Retail"
    db.characters = db.characters or {}
    local key = CharKey()
    local c = db.characters[key] or { data = {} }
    c.data = c.data or {}
    c.data.mobs = c.data.mobs or {}
    c.data.session = c.data.session or { startedAt = time(), mobs = {} }
    c.data.session.mobs = c.data.session.mobs or {}
    db.characters[key] = c
    return c
end

local Stamp, ShowToast   -- defined further down (export stamp + session pace; wishlist toast)

local function Touch()
    local c = CharData()
    c.data.name = UnitName("player")
    c.data.class = select(2, UnitClass("player"))
    Stamp(c)
end

---------------------------------------------------------------- the data ---
-- data.mobs[npcId]           = lifetime, data.session.mobs[npcId] = this session
--   { name, zone, kills, lastKill,
--     items = { [itemId] = { dropEvents, qty, name, quality, price, noSell } } }
-- (npcId and itemId are strings, so the save file reads the same everywhere.)

local function NpcId(guid)
    if type(guid) ~= "string" then return nil end
    -- Creature-0-<server>-<instance>-<zone>-<npcId>-<spawn>: the npc id is the
    -- 6th field. The fields before it aren't assumed to be plain numbers.
    local kind, id = guid:match("^(%a+)%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-(%d+)")
    if kind == "Creature" or kind == "Vehicle" then return id end
    return nil
end

-- What the counters saw (shown by /kl debug): where kills come from, and what
-- got thrown away and why. Nothing here is saved.
local DBG = { cleu = 0, secret = 0, noGuid = 0, parseFail = 0, ownPet = 0, notGroup = 0,
              loots = 0, lootCredited = 0, lootLive = 0, shapes = {},
              via = { combatlog = 0, tag = 0, target = 0, loot = 0 } }
local function Shape(guid)
    local s = tostring(guid):gsub("%d+", "N"):gsub("%x%x%x%x%x%x%x+", "H")
    return s
end
local function NoteShape(guid)
    local sh = Shape(guid)
    for _, v in ipairs(DBG.shapes) do if v == sh then return end end
    if #DBG.shapes < 6 then tinsert(DBG.shapes, sh) end
end

local function ItemId(link)
    if type(link) ~= "string" then return nil end
    return link:match("item:(%d+)")
end

local function MobRec(store, npc, name, zone)
    local m = store[npc]
    if not m then
        m = { kills = 0, items = {} }
        store[npc] = m
    end
    m.items = m.items or {}
    if name then m.name = name end
    if zone then m.zone = zone end
    return m
end

local function ItemRec(mob, id)
    local it = mob.items[id]
    if not it then
        it = { dropEvents = 0, qty = 0 }
        mob.items[id] = it
    end
    return it
end

-- Name, quality and vendor price from the game. A price the game doesn't know
-- yet stays nil (shown as "?"); 0 means the item doesn't sell to a vendor.
local function ItemMeta(link)
    local GI = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, quality, _, _, _, _, _, _, icon, price = Try(GI, link)
    return Plain(name), Plain(quality), Plain(price), Plain(icon)
end

local function ApplyMeta(it, name, quality, price, icon)
    if name then it.name = name end
    if icon then it.icon = icon end
    if quality then it.quality = quality end
    if type(price) == "number" then
        it.price = price
        it.noSell = price == 0 or nil
    end
end

local recentKills = {}   -- guid -> { npc, name, zone, at, looted }
local tagged = {}        -- guid -> time your group last hurt it
local killCount = 0

local function Prune()
    local now = time()
    for g, k in pairs(recentKills) do
        if now - k.at > KILL_TTL then recentKills[g] = nil end
    end
    for g, t in pairs(tagged) do
        if now - t > 120 then tagged[g] = nil end
    end
end

local function ZoneName()
    return Plain(Try(GetRealZoneText)) or Plain(Try(GetZoneText)) or nil
end

local function MobName(guid)
    -- the game's own name for the corpse, when it can say
    local name = Plain(Try(UnitName, "target"))
    if name and Try(UnitGUID, "target") == guid then return name end
    return nil
end

local panel, Render  -- the panel code below

-- Credit one kill. `name` may be nil (the loot window knows the name better).
local function CreditKill(guid, name, via)
    local npc = NpcId(guid)
    if not npc or recentKills[guid] then return end
    local zone = ZoneName()
    local c = CharData()
    local d = c.data
    name = name or MobName(guid)
    for _, store in ipairs({ d.mobs, d.session.mobs }) do
        local m = MobRec(store, npc, name, zone)
        m.kills = (m.kills or 0) + 1
        m.lastKill = time()
    end
    recentKills[guid] = { npc = npc, name = name, zone = zone, at = time(), looted = false }
    killCount = killCount + 1
    if via then DBG.via[via] = (DBG.via[via] or 0) + 1 end
    Stamp(c)
    if panel and panel:IsShown() then Render() end
end

-- The wishlist: items you want to see drop. Account-wide, in the save file.
local function Wishlist()
    local db = ForgesLedgerKillLedgerDB
    db.wishlist = type(db.wishlist) == "table" and db.wishlist or {}
    return db.wishlist
end

local function IsWished(id)
    return id ~= nil and Wishlist()[tostring(id)] ~= nil
end

local function SetWish(id, on, name)
    id = tostring(id)
    local w = Wishlist()
    if on then
        w[id] = w[id] or { addedAt = time() }
        if name then w[id].name = name end
    else
        w[id] = nil
    end
end

-- Loot window: attribute own, unlocked item slots to their corpses.
local function ReadLoot()
    local n = Plain(Try(GetNumLootItems)) or 0
    local perCorpse = {}   -- guid -> { [itemId] = { qty, link } }
    local touched = {}
    for slot = 1, n do
        local slotType = Try(GetLootSlotType, slot)
        local sources = { Try(GetLootSourceInfo, slot) }
        for j = 1, #sources, 2 do
            local guid = Plain(sources[j])
            if type(guid) == "string" and NpcId(guid) then
                touched[guid] = true
                if slotType == LOOT_ITEM then
                    local _, _, _, _, _, locked = Try(GetLootSlotInfo, slot)
                    local link = Try(GetLootSlotLink, slot)
                    local id = ItemId(link)
                    if id and not locked then
                        local qty = tonumber(sources[j + 1]) or 1
                        local pc = perCorpse[guid] or {}
                        perCorpse[guid] = pc
                        local e = pc[id] or { qty = 0, link = link }
                        e.qty = e.qty + qty
                        pc[id] = e
                    end
                end
            end
        end
    end
    local c = CharData()
    local d = c.data
    local changed = false
    local wished = {}   -- itemId -> what to celebrate (one toast per item per window)
    DBG.loots = DBG.loots + 1
    for guid in pairs(touched) do
        local k = recentKills[guid]
        -- a corpse you can loot is a kill of yours, whatever else did or didn't
        -- see it die (KL-3). Not while it is still alive and targeted: that is
        -- a pickpocket, not a kill.
        if not k then
            if Try(UnitGUID, "target") == guid and not Plain(Try(UnitIsDead, "target")) then
                DBG.lootLive = DBG.lootLive + 1
            else
                CreditKill(guid, nil, "loot")
                DBG.lootCredited = DBG.lootCredited + 1
                k = recentKills[guid]
            end
        end
        if k and not k.looted then
            k.looted = true
            local name = k.name
            if not name then  -- the loot window's own title is the corpse's name
                name = Plain(Try(UnitName, "npc")) or Plain(Try(UnitName, "target"))
            end
            for _, store in ipairs({ d.mobs, d.session.mobs }) do
                local m = MobRec(store, k.npc, name, k.zone)
                for id, e in pairs(perCorpse[guid] or {}) do
                    local it = ItemRec(m, id)
                    it.dropEvents = it.dropEvents + 1
                    it.qty = it.qty + e.qty
                    ApplyMeta(it, ItemMeta(e.link))
                end
            end
            for id, e in pairs(perCorpse[guid] or {}) do
                if IsWished(id) then
                    local w = wished[id]
                    if not w then
                        w = { id = id, qty = 0, mob = name, npc = k.npc }
                        wished[id] = w
                    end
                    w.qty = w.qty + e.qty
                end
            end
            changed = true
        end
    end
    for id, w in pairs(wished) do
        local m = d.mobs[w.npc]
        local it = m and m.items and m.items[id] or nil
        w.it = it
        w.name = (it and it.name) or (Wishlist()[id] and Wishlist()[id].name)
        pcall(ShowToast, w)
    end
    if changed then
        Stamp(c)
        if panel and panel:IsShown() then Render() end
    end
end

-- Prices the game didn't have the first time: ask again later.
local function FillPrices()
    local d = CharData().data
    for _, store in ipairs({ d.mobs, d.session.mobs }) do
        for _, m in pairs(store) do
            for id, it in pairs(m.items or {}) do
                if it.price == nil or not it.name then
                    ApplyMeta(it, ItemMeta("item:" .. id))
                end
            end
        end
    end
end

----------------------------------------------------------- the numbers ---

local function Summary(m)
    local value, drops = 0, 0
    for _, it in pairs(m.items or {}) do
        if type(it.price) == "number" then value = value + it.price * (it.qty or 0) end
        drops = drops + (it.dropEvents or 0)
    end
    return value, drops
end

-- This session across everything killed: kills, vendor value, seconds, value per hour.
local function SessionStats()
    local d = CharData().data
    local kills, value = 0, 0
    for _, m in pairs(d.session.mobs) do
        kills = kills + (m.kills or 0)
        value = value + (Summary(m))
    end
    local secs = math.max(0, time() - (tonumber(d.session.startedAt) or time()))
    local perHour = secs >= 60 and math.floor(value * 3600 / secs) or nil
    return kills, value, secs, perHour
end

-- Every change to the numbers goes through here: the save file's time stamp, and
-- the session's pace (which the dashboard reads from the same export).
Stamp = function(c)
    c = c or CharData()
    c.exportedAt = time()
    local d = c.data
    if d and d.session then
        local kills, value, secs, perHour = SessionStats()
        d.session.pace = { seconds = secs, kills = kills, value = value, perHour = perHour }
    end
end

local function Coin(c)
    c = math.floor(tonumber(c) or 0)
    if GetCoinTextureString then return GetCoinTextureString(c) end
    return string.format("%dg %ds %dc", math.floor(c / 10000), math.floor(c / 100) % 100, c % 100)
end

local function Pct(it, kills)
    if (kills or 0) <= 0 then return "-" end
    local p = 100 * (it.dropEvents or 0) / kills
    local s = p >= 10 and string.format("%d%%", math.floor(p + 0.5)) or string.format("%.1f%%", p)
    return s .. " (" .. (it.dropEvents or 0) .. "/" .. kills .. ")"
end

local function Sorted(store, mode)
    local list = {}
    for id, m in pairs(store) do
        tinsert(list, { id = id, m = m })
    end
    table.sort(list, function(a, b)
        if mode == "recent" then
            local ta, tb = tonumber(a.m.lastKill) or 0, tonumber(b.m.lastKill) or 0
            if ta ~= tb then return ta > tb end
        end
        if (a.m.kills or 0) ~= (b.m.kills or 0) then return (a.m.kills or 0) > (b.m.kills or 0) end
        return tostring(a.m.name or a.id) < tostring(b.m.name or b.id)
    end)
    return list
end

local function SortedItems(m)
    local list = {}
    for id, it in pairs(m.items or {}) do tinsert(list, { id = id, it = it }) end
    table.sort(list, function(a, b)
        if (a.it.dropEvents or 0) ~= (b.it.dropEvents or 0) then return (a.it.dropEvents or 0) > (b.it.dropEvents or 0) end
        return tostring(a.it.name or a.id) < tostring(b.it.name or b.id)
    end)
    return list
end

---------------------------------------------------------------- the panel ---

local GOLD = { 1, 0.82, 0, 1 }
local BONE = { 0.92, 0.90, 0.85, 1 }
local DIM = { 0.62, 0.60, 0.56, 1 }
local IRON = { 0.07, 0.07, 0.09, 0.96 }
local RUST = { 0.85, 0.40, 0.30, 1 }
local GREEN = { 0.45, 0.85, 0.35, 1 }
local W, H = 940, 540
local LIST_ROWS, ITEM_ROWS, WISH_ROWS = 12, 12, 14

local scope = "session"   -- "session" | "lifetime" | "wishlist"
local sortMode = "kills"  -- "kills" | "recent"
local filterText = ""
local selected            -- npc id
local page, itemPage = 1, 1
local itemMode = false   -- the "Find item" view: search the items you have looted
local itemText = ""      -- what is typed in the item search
local selItem            -- the item whose mobs are listed
local confirmAll = false

-- what the window remembers between logins (the view and the sort, not the numbers)
local function UI()
    local db = ForgesLedgerKillLedgerDB
    db.ui = type(db.ui) == "table" and db.ui or {}
    return db.ui
end

local function Tex(frame, layer, r, g, b, a)
    local t = frame:CreateTexture(nil, layer)
    t:SetColorTexture(r, g, b, a)
    return t
end

local function Border(frame, a)
    local parts = {}
    for i = 1, 4 do parts[i] = Tex(frame, "BORDER", GOLD[1], GOLD[2], GOLD[3], a) end
    parts[1]:SetPoint("TOPLEFT"); parts[1]:SetPoint("TOPRIGHT"); parts[1]:SetHeight(1)
    parts[2]:SetPoint("BOTTOMLEFT"); parts[2]:SetPoint("BOTTOMRIGHT"); parts[2]:SetHeight(1)
    parts[3]:SetPoint("TOPLEFT"); parts[3]:SetPoint("BOTTOMLEFT"); parts[3]:SetWidth(1)
    parts[4]:SetPoint("TOPRIGHT"); parts[4]:SetPoint("BOTTOMRIGHT"); parts[4]:SetWidth(1)
    return parts
end

local function Text(parent, font, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    local c = color or BONE
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

local function Btn(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 90, h or 22)
    b.bg = Tex(b, "BACKGROUND", 1, 1, 1, 0.06)
    b.bg:SetAllPoints()
    Border(b, 0.35)
    b.text = Text(b, "GameFontNormal", GOLD)
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    function b:SetLabel(t) self.text:SetText(t) end
    function b:SetActive(on)
        self.bg:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], on and 0.22 or 0.06)
    end
    return b
end

local rows, irows, wrows = {}, {}, {}
local mrows, srows = {}, {}   -- item search: matching items (left), the mobs that dropped one (right)

-- the colour a drop % reads in: common stays quiet, a good drop glows
local function PctColor(p)
    if p >= 50 then return "73b84d" end
    if p >= 10 then return "ffd100" end
    return "9a9890"
end

local function PctText(it, kills)
    if (kills or 0) <= 0 then return "-" end
    local p = 100 * (it.dropEvents or 0) / kills
    local s = p >= 10 and string.format("%d%%", math.floor(p + 0.5)) or string.format("%.1f%%", p)
    -- the raw count always sits beside the percentage
    return "|cff" .. PctColor(p) .. s .. "|r |cff9a9890(" .. (it.dropEvents or 0) .. "/" .. kills .. ")|r"
end

local function Duration(s)
    s = math.max(0, math.floor(tonumber(s) or 0))
    local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
    if h > 0 then return string.format("%dh %02dm", h, m) end
    if m > 0 then return string.format("%dm %02ds", m, s % 60) end
    return s .. "s"
end

local function Store()
    local d = CharData().data
    return scope == "session" and d.session.mobs or d.mobs
end

local function ItemColor(it)
    local q = tonumber(it.quality)
    local col = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if col then return col.r, col.g, col.b end
    return BONE[1], BONE[2], BONE[3]
end

-- the best-known drop of a mob (its "top drop"), for the list row
local function TopItem(m)
    local best, bestId
    for id, it in pairs(m.items or {}) do
        if not best or (it.dropEvents or 0) > (best.dropEvents or 0) then best, bestId = it, id end
    end
    return best, bestId
end

local function Visible(store)
    -- the mobs the list shows: filtered by the search box, in the chosen order
    local list = Sorted(store, sortMode)
    local f = filterText ~= "" and filterText:lower() or nil
    if not f then return list end
    local out = {}
    for _, e in ipairs(list) do
        local hay = (tostring(e.m.name or "") .. " " .. tostring(e.m.zone or "")):lower()
        if hay:find(f, 1, true) then tinsert(out, e) end
    end
    return out
end

-- Item search over the recorded data of the current view (this session / lifetime).
-- Returns the matching items (by name) and, for each, every mob that dropped it
-- RANKED by drop chance: highest % first, ties go to the bigger sample (more kills).
local function SearchItems(store, query)
    local q = strtrim(query or ""):lower()
    if q == "" then return {} end
    local byId = {}
    for npc, m in pairs(store) do
        for id, it in pairs(m.items or {}) do
            local name = tostring(it.name or "")
            if name:lower():find(q, 1, true) then
                local e = byId[id]
                if not e then e = { id = id, name = name, it = it, mobs = {} }; byId[id] = e end
                local kills = m.kills or 0
                tinsert(e.mobs, { npc = npc, m = m, it = it, kills = kills,
                                  pct = kills > 0 and (100 * (it.dropEvents or 0) / kills) or 0 })
            end
        end
    end
    local out = {}
    for _, e in pairs(byId) do
        table.sort(e.mobs, function(a, b)
            if a.pct ~= b.pct then return a.pct > b.pct end
            if a.kills ~= b.kills then return a.kills > b.kills end
            return tostring(a.m.name or a.npc) < tostring(b.m.name or b.npc)
        end)
        e.best = e.mobs[1]
        tinsert(out, e)
    end
    table.sort(out, function(a, b)
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

local function UpdateStrip()
    if not panel then return end
    local kills, value, secs, perHour = SessionStats()
    panel.strip:SetText(string.format("Session  %s   |   %d kills   |   %s   |   %s",
        Duration(secs), kills, Coin(value), perHour and (Coin(perHour) .. " per hour") or "per hour: soon"))
    panel.stripSub:SetText("started " .. date("%H:%M", tonumber(CharData().data.session.startedAt) or time()))
end

local function SetItemIcon(tex, it, id)
    local icon = it and it.icon
    if not icon and id then
        local GI = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
        icon = Plain(Try(GI, tonumber(id)))
    end
    if icon then tex:SetTexture(icon) else tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

function Render()
    if not panel then return end
    local isWish = scope == "wishlist"
    panel.tabSession:SetActive(scope == "session")
    panel.tabLife:SetActive(scope == "lifetime")
    panel.tabWish:SetActive(isWish)
    UpdateStrip()
    panel.tabItem:SetActive(itemMode and not isWish)
    for _, f in ipairs(panel.mobUI) do f:SetShown(not isWish and not itemMode) end
    for _, f in ipairs(panel.wishUI) do f:SetShown(isWish) end
    for _, f in ipairs(panel.itemUI) do f:SetShown(itemMode and not isWish) end

    if isWish then
        -- ---- the wishlist view
        local list = {}
        for id, w in pairs(Wishlist()) do tinsert(list, { id = id, w = w }) end
        table.sort(list, function(a, b) return tostring(a.w.name or a.id) < tostring(b.w.name or b.id) end)
        panel.wishEmpty:SetText(#list == 0 and "Nothing on your wishlist yet. Click Wish on any drop row, or type /kl wish and shift-click an item. When one of these drops for you, you get a toast and a sound." or "")
        -- how many of each you have seen drop, from the lifetime numbers
        local seen = {}
        for _, m in pairs(CharData().data.mobs) do
            for id, it in pairs(m.items or {}) do seen[id] = (seen[id] or 0) + (it.qty or 0) end
        end
        for i = 1, WISH_ROWS do
            local r, e = wrows[i], list[i]
            if e then
                r.id = e.id
                local meta = nil
                for _, m in pairs(CharData().data.mobs) do if m.items and m.items[e.id] then meta = m.items[e.id] break end end
                r.name:SetText(tostring(e.w.name or (meta and meta.name) or ("Item " .. e.id)))
                r.name:SetTextColor(ItemColor(meta or {}))
                SetItemIcon(r.icon, meta, e.id)
                r.seen:SetText((seen[e.id] or 0) > 0 and ("seen " .. seen[e.id] .. " so far") or "not seen yet")
                r:Show()
            else
                r.id = nil
                r:Hide()
            end
        end
        panel.head3:SetText(#list .. " on your wishlist")
        panel.foot:SetText("Your own loot only. A wishlisted drop gives you a toast and a sound.")
        return
    end

    if itemMode then
        -- ---- the item search: which of my mobs dropped this, best chance first
        local store0 = Store()
        local res = SearchItems(store0, itemText)
        local viewName = scope == "session" and "this session" or "lifetime"
        local found
        for _, e in ipairs(res) do if e.id == selItem then found = e end end
        if not found then found = res[1]; selItem = found and found.id or nil end
        local shownN = math.min(#res, LIST_ROWS)
        for i = 1, LIST_ROWS do
            local r, e = mrows[i], res[i]
            if e then
                r.id = e.id
                r.link = "item:" .. e.id
                SetItemIcon(r.icon, e.it, e.id)
                r.name:SetText(e.name)
                r.name:SetTextColor(ItemColor(e.it))
                r.info:SetText(#e.mobs .. (#e.mobs == 1 and " mob" or " mobs"))
                r.sel:SetShown(e.id == selItem)
                r:Show()
            else
                r.id = nil
                r:Hide()
            end
        end
        panel.imore:SetText(#res > LIST_ROWS and ("+" .. (#res - LIST_ROWS) .. " more items - type more of the name") or "")
        for _, r in ipairs(srows) do r:Hide() end
        if itemText == "" then
            panel.iempty:SetText("Type an item name to see which of your mobs dropped it, and how often.")
        elseif #res == 0 then
            panel.iempty:SetText("\"" .. itemText .. "\" has not dropped for you yet in this view (" .. viewName .. ").")
        else
            panel.iempty:SetText("")
        end
        panel.iempty:SetShown(panel.iempty:GetText() ~= "")
        panel.scolhead:SetShown(found ~= nil)
        if found then
            panel.sname:SetText(found.name)
            panel.sname:SetTextColor(ItemColor(found.it))
            local b = found.best
            panel.ssub:SetText(string.format("Best source: %s (%s)   |   dropped from %d of your mobs, %s",
                tostring(b.m.name or b.npc), PctText(b.it, b.kills):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""),
                #found.mobs, viewName))
            local max = #found.mobs
            for i = 1, ITEM_ROWS do
                local r, e = srows[i], found.mobs[i]
                if e then
                    r.npc, r.id = e.npc, found.id
                    r.link = "item:" .. found.id
                    r.best:SetShown(i == 1)
                    r.name:SetText(tostring(e.m.name or ("Mob " .. e.npc)))
                    r.zone:SetText(tostring(e.m.zone or ""))
                    r.pct:SetText(PctText(e.it, e.kills))
                    local de = e.it.dropEvents or 0
                    r.avg:SetText(de > 0 and string.format("%.1f", (e.it.qty or 0) / de) or "-")
                    if e.it.noSell then r.each:SetText("no sell")
                    elseif type(e.it.price) == "number" then r.each:SetText(Coin(e.it.price))
                    else r.each:SetText("?") end
                    local wished = IsWished(found.id)
                    r.wish:SetLabel(wished and "On list" or "Wish")
                    r.wish:SetActive(wished)
                    r:Show()
                end
            end
            panel.smore:SetText(max > ITEM_ROWS and ("+" .. (max - ITEM_ROWS) .. " more mobs with lower odds") or "")
        else
            panel.sname:SetText("")
            panel.ssub:SetText("")
            panel.smore:SetText("")
        end
        panel.head3:SetText(string.format("Item search - %s: %d match%s", viewName, #res, #res == 1 and "" or "es"))
        panel.foot:SetText("Searches only what Kill Ledger recorded from your own loot. It is not a drop database. Ranked by drop chance.")
        return
    end

    -- ---- the mob list (left)
    local store = Store()
    local list = Visible(store)
    local pages = math.max(1, math.ceil(#list / LIST_ROWS))
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    panel.sortBtn:SetLabel(sortMode == "recent" and "Sort: recent" or "Sort: kills")
    local first = (page - 1) * LIST_ROWS
    for i = 1, LIST_ROWS do
        local row, e = rows[i], list[first + i]
        if e then
            row.npc = e.id
            row.name:SetText(tostring(e.m.name or ("Mob " .. e.id)))
            row.zone:SetText(tostring(e.m.zone or ""))
            row.kills:SetText((e.m.kills or 0) .. " kills")
            local top = TopItem(e.m)
            row.top:SetText(top and ("top " .. PctText(top, e.m.kills)) or "no drops yet")
            row.value:SetText(Coin((Summary(e.m))))
            row.sel:SetShown(e.id == selected)
            row:Show()
        else
            row.npc = nil
            row:Hide()
        end
    end
    if not selected or not store[selected] then
        selected = list[1] and list[1].id or nil
    end
    for i = 1, LIST_ROWS do
        if rows[i].npc then rows[i].sel:SetShown(rows[i].npc == selected) end
    end
    panel.pageLabel:SetText(#list > 0 and ("Page " .. page .. " of " .. pages) or "")
    panel.prev:SetShown(page > 1)
    panel.next:SetShown(page < pages)
    local totalKills, totalValue = 0, 0
    for _, e in ipairs(Sorted(store, sortMode)) do
        totalKills = totalKills + (e.m.kills or 0)
        totalValue = totalValue + Summary(e.m)
    end
    local nAll = 0
    for _ in pairs(store) do nAll = nAll + 1 end
    panel.head3:SetText(string.format("%s: %d kills, %d mobs, %s in vendor value",
        scope == "session" and "This session" or "Lifetime", totalKills, nAll, Coin(totalValue)))

    -- ---- the detail (right)
    local m = selected and store[selected]
    for _, r in ipairs(irows) do r:Hide() end
    if not m then
        panel.dname:SetText("")
        panel.dsub:SetText("")
        panel.empty:SetText(#list == 0 and filterText ~= "" and ("No mob matches \"" .. filterText .. "\".")
            or (scope == "session" and "Nothing killed yet this session. Kill something and loot it - it shows up here."
                or "No kills recorded yet."))
        panel.empty:Show()
        panel.colhead:Hide()
        panel.more:SetText("")
        panel.resetMob:Hide()
        panel.iprev:Hide(); panel.inext:Hide(); panel.ipage:SetText("")
    else
        panel.empty:Hide()
        panel.colhead:Show()
        local value = Summary(m)
        local kills = m.kills or 0
        panel.dname:SetText(tostring(m.name or ("Mob " .. selected)))
        panel.dsub:SetText(string.format("%s   |   Killed %d   |   Vendor value %s%s",
            tostring(m.zone or "?"), kills, Coin(value),
            kills > 0 and ("   (" .. Coin(value / kills) .. " per kill)") or ""))
        local items = SortedItems(m)
        local ipages = math.max(1, math.ceil(#items / ITEM_ROWS))
        if itemPage > ipages then itemPage = ipages end
        if itemPage < 1 then itemPage = 1 end
        local ifirst = (itemPage - 1) * ITEM_ROWS
        for i = 1, ITEM_ROWS do
            local r, e = irows[i], items[ifirst + i]
            if e then
                local it = e.it
                r.id = e.id
                r.link = "item:" .. e.id
                SetItemIcon(r.icon, it, e.id)
                r.name:SetText(tostring(it.name or ("Item " .. e.id)))
                r.name:SetTextColor(ItemColor(it))
                r.pct:SetText(PctText(it, kills))
                local de = it.dropEvents or 0
                r.avg:SetText(de > 0 and string.format("%.1f", (it.qty or 0) / de) or "-")
                if it.noSell then
                    r.each:SetText("no sell")
                    r.total:SetText("-")
                elseif type(it.price) == "number" then
                    r.each:SetText(Coin(it.price))
                    r.total:SetText(Coin(it.price * (it.qty or 0)))
                else
                    r.each:SetText("?")
                    r.total:SetText("?")
                end
                local wished = IsWished(e.id)
                r.wish:SetLabel(wished and "On list" or "Wish")
                r.wish:SetActive(wished)
                r:Show()
            end
        end
        panel.iprev:SetShown(itemPage > 1)
        panel.inext:SetShown(itemPage < ipages)
        panel.ipage:SetText(#items > ITEM_ROWS and string.format("Items %d-%d of %d", ifirst + 1, math.min(#items, ifirst + ITEM_ROWS), #items) or "")
        panel.more:SetText(#items == 0 and "No drops seen yet." or "")
        panel.resetMob:Show()
    end
    panel.resetAll:SetLabel(confirmAll and "Click again to confirm" or "Reset all")
    panel.resetAll:SetWidth(confirmAll and 150 or 90)
    panel.foot:SetText(ForgesLedgerKillLedgerDB.countMode == "combatlog"
        and "Counting kills from the combat log. Your own loot only; drop % = drops / kills."
        or "Counting kills when your target dies or you loot a corpse. Your own loot only; drop % = drops / kills.")
end

local function SetScope(s)
    scope, page, itemPage, selected, confirmAll = s, 1, 1, nil, false
    if s ~= "wishlist" then UI().scope = s else itemMode = false end
    Render()
end

local function SetItemMode(on)
    itemMode = on and true or false
    if itemMode and scope == "wishlist" then
        scope = (UI().scope == "lifetime") and "lifetime" or "session"
    end
    Render()
end

local function ItemTooltip(row)
    if not row.link then return end
    pcall(function()
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(row.link)
        GameTooltip:Show()
    end)
end

local function HideTooltip() pcall(function() GameTooltip:Hide() end) end

local function CreatePanel()
    local ui = UI()
    if ui.scope == "lifetime" or ui.scope == "session" then scope = ui.scope end
    if ui.sort == "recent" or ui.sort == "kills" then sortMode = ui.sort end
    panel = CreateFrame("Frame", "ForgesLedgerKillLedgerPanel", UIParent)
    panel:SetSize(W, H)
    panel:SetFrameStrata("HIGH")
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        ForgesLedgerKillLedgerDB.panelPos = { point, rel, x, y }
    end)
    Tex(panel, "BACKGROUND", IRON[1], IRON[2], IRON[3], IRON[4]):SetAllPoints()
    Border(panel, 0.85)
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    -- hide the frame directly: the template's own click goes through Blizzard's
    -- panel manager, which can refuse in combat (the window then won't close)
    close:SetScript("OnClick", function() panel:Hide() end)
    close:SetPoint("TOPRIGHT", 2, 2)
    panel.close = close
    local pos = ForgesLedgerKillLedgerDB.panelPos
    if type(pos) == "table" and type(pos[1]) == "string" then
        panel:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    end
    panel.mobUI, panel.wishUI = {}, {}

    -- header: title, the session strip, the three views
    panel.title = Text(panel, "GameFontNormalLarge", GOLD)
    panel.title:SetPoint("TOPLEFT", 16, -12)
    panel.title:SetText("Kill Ledger")
    panel.strip = Text(panel, "GameFontNormal", BONE)
    panel.strip:SetPoint("LEFT", panel.title, "RIGHT", 22, 0)
    panel.stripSub = Text(panel, "GameFontHighlightSmall", DIM)
    panel.stripSub:SetPoint("TOPLEFT", 16, -34)
    panel.head3 = Text(panel, "GameFontHighlightSmall", DIM)
    panel.head3:SetPoint("LEFT", panel.stripSub, "RIGHT", 16, 0)
    panel.tabSession = Btn(panel, "This session", 100, 22)
    panel.tabSession:SetPoint("TOPRIGHT", -290, -38)
    panel.tabSession:SetScript("OnClick", function() SetScope("session") end)
    panel.tabLife = Btn(panel, "Lifetime", 80, 22)
    panel.tabLife:SetPoint("LEFT", panel.tabSession, "RIGHT", 6, 0)
    panel.tabLife:SetScript("OnClick", function() SetScope("lifetime") end)
    panel.tabWish = Btn(panel, "Wishlist", 80, 22)
    panel.tabWish:SetPoint("LEFT", panel.tabLife, "RIGHT", 6, 0)
    panel.tabWish:SetScript("OnClick", function() SetScope("wishlist") end)
    panel.tabItem = Btn(panel, "Find item", 90, 22)
    panel.tabItem:SetPoint("LEFT", panel.tabWish, "RIGHT", 6, 0)
    panel.tabItem:SetScript("OnClick", function() SetItemMode(not itemMode) end)
    panel.itemUI = {}

    -- left: search, sort, the mobs
    local function MobPart(f) tinsert(panel.mobUI, f); return f end
    local sb = MobPart(CreateFrame("Frame", nil, panel))
    sb:SetSize(214, 22)
    sb:SetPoint("TOPLEFT", 14, -64)
    Tex(sb, "BACKGROUND", 0, 0, 0, 0.5):SetAllPoints()
    Border(sb, 0.3)
    panel.search = CreateFrame("EditBox", nil, sb)
    panel.search:SetPoint("TOPLEFT", 6, -2)
    panel.search:SetPoint("BOTTOMRIGHT", -6, 2)
    panel.search:SetFontObject("GameFontHighlight")
    panel.search:SetAutoFocus(false)
    panel.search:SetMaxLetters(40)
    panel.searchHint = Text(sb, "GameFontHighlightSmall", DIM)
    panel.searchHint:SetPoint("LEFT", 8, 0)
    panel.searchHint:SetText("Search mobs or zones")
    panel.search:SetScript("OnTextChanged", function(self)
        filterText = strtrim(self:GetText() or "")
        panel.searchHint:SetShown((self:GetText() or "") == "")
        page, selected = 1, nil
        Render()
    end)
    panel.search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    panel.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    panel.sortBtn = MobPart(Btn(panel, "Sort: kills", 100, 22))
    panel.sortBtn:SetPoint("LEFT", sb, "RIGHT", 6, 0)
    panel.sortBtn:SetScript("OnClick", function()
        sortMode = sortMode == "kills" and "recent" or "kills"
        UI().sort = sortMode
        page = 1
        Render()
    end)
    for i = 1, LIST_ROWS do
        local r = MobPart(CreateFrame("Button", nil, panel))
        r:SetSize(344, 32)
        r:SetPoint("TOPLEFT", 12, -92 - (i - 1) * 34)
        r.sel = Tex(r, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.18)
        r.sel:SetAllPoints()
        r.sel:Hide()
        Tex(r, "BORDER", 1, 1, 1, 0.05):SetPoint("BOTTOMLEFT")
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("TOPLEFT", 4, -2)
        r.name:SetWidth(200)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.kills = Text(r, "GameFontNormal", GOLD)
        r.kills:SetPoint("TOPRIGHT", -6, -2)
        r.zone = Text(r, "GameFontHighlightSmall", DIM)
        r.zone:SetPoint("BOTTOMLEFT", 4, 3)
        r.zone:SetWidth(120)
        r.zone:SetJustifyH("LEFT")
        r.zone:SetWordWrap(false)
        r.top = Text(r, "GameFontHighlightSmall")
        r.top:SetPoint("BOTTOMLEFT", 128, 3)
        r.value = Text(r, "GameFontHighlightSmall", BONE)
        r.value:SetPoint("BOTTOMRIGHT", -6, 3)
        r:SetScript("OnClick", function(self)
            if self.npc then selected, itemPage, confirmAll = self.npc, 1, false; Render() end
        end)
        rows[i] = r
    end
    panel.prev = MobPart(Btn(panel, "<", 28, 20))
    panel.prev:SetPoint("BOTTOMLEFT", 14, 40)
    panel.prev:SetScript("OnClick", function() page = page - 1; Render() end)
    panel.next = MobPart(Btn(panel, ">", 28, 20))
    panel.next:SetPoint("LEFT", panel.prev, "RIGHT", 4, 0)
    panel.next:SetScript("OnClick", function() page = page + 1; Render() end)
    panel.pageLabel = MobPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.pageLabel:SetPoint("LEFT", panel.next, "RIGHT", 8, 0)

    -- right: the drop table
    panel.dname = MobPart(Text(panel, "GameFontNormalLarge", BONE))
    panel.dname:SetPoint("TOPLEFT", 376, -64)
    panel.dsub = MobPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.dsub:SetPoint("TOPLEFT", 376, -90)
    panel.empty = MobPart(Text(panel, "GameFontHighlight", DIM))
    panel.empty:SetPoint("TOPLEFT", 376, -124)
    panel.empty:SetWidth(540)
    panel.empty:SetJustifyH("LEFT")
    panel.empty:SetWordWrap(true)
    panel.colhead = MobPart(CreateFrame("Frame", nil, panel))
    panel.colhead:SetSize(552, 18)
    panel.colhead:SetPoint("TOPLEFT", 376, -112)
    for _, c in ipairs({ { "Item", 28 }, { "Drop %", 184 }, { "Avg", 296 }, { "Each", 332 }, { "Total", 424 } }) do
        local fs = Text(panel.colhead, "GameFontNormal", GOLD)
        fs:SetPoint("LEFT", c[2], 0)
        fs:SetText(c[1])
    end
    for i = 1, ITEM_ROWS do
        local r = MobPart(CreateFrame("Button", nil, panel))
        r:SetSize(552, 26)
        r:SetPoint("TOPLEFT", 376, -132 - (i - 1) * 28)
        Tex(r, "HIGHLIGHT", 1, 1, 1, 0.06):SetAllPoints()
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(22, 22)
        r.icon:SetPoint("LEFT", 2, 0)
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", 28, 0)
        r.name:SetWidth(152)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.pct = Text(r, "GameFontHighlight")
        r.pct:SetPoint("LEFT", 184, 0)
        r.avg = Text(r, "GameFontHighlight", DIM)
        r.avg:SetPoint("LEFT", 296, 0)
        r.each = Text(r, "GameFontHighlight", DIM)
        r.each:SetPoint("LEFT", 332, 0)
        r.total = Text(r, "GameFontHighlight")
        r.total:SetPoint("LEFT", 424, 0)
        r.wish = Btn(r, "Wish", 58, 20)
        r.wish:SetPoint("RIGHT", -2, 0)
        r.wish:SetScript("OnClick", function()
            if not r.id then return end
            local on = not IsWished(r.id)
            local items = selected and Store()[selected] and Store()[selected].items
            SetWish(r.id, on, items and items[r.id] and items[r.id].name)
            Render()
        end)
        r:SetScript("OnEnter", ItemTooltip)
        r:SetScript("OnLeave", HideTooltip)
        irows[i] = r
    end
    panel.more = MobPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.more:SetPoint("TOPLEFT", 376, -132 - ITEM_ROWS * 28)
    panel.iprev = MobPart(Btn(panel, "<", 28, 20))
    panel.iprev:SetPoint("BOTTOMLEFT", 376, 40)
    panel.iprev:SetScript("OnClick", function() itemPage = itemPage - 1; Render() end)
    panel.inext = MobPart(Btn(panel, ">", 28, 20))
    panel.inext:SetPoint("LEFT", panel.iprev, "RIGHT", 4, 0)
    panel.inext:SetScript("OnClick", function() itemPage = itemPage + 1; Render() end)
    panel.ipage = MobPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.ipage:SetPoint("LEFT", panel.inext, "RIGHT", 8, 0)

    -- bottom: resets and the note
    panel.resetMob = MobPart(Btn(panel, "Reset this mob", 110, 22))
    panel.resetMob:SetPoint("BOTTOMRIGHT", -16, 38)
    panel.resetMob:SetScript("OnClick", function()
        if selected then
            local d = CharData().data
            d.mobs[selected] = nil
            d.session.mobs[selected] = nil
            selected, confirmAll = nil, false
            Stamp(CharData())
            Render()
        end
    end)
    panel.resetAll = MobPart(Btn(panel, "Reset all", 90, 22))
    panel.resetAll:SetPoint("RIGHT", panel.resetMob, "LEFT", -6, 0)
    panel.resetAll:SetScript("OnClick", function()
        if not confirmAll then
            confirmAll = true
            C_Timer.After(5, function() confirmAll = false; if panel:IsShown() then Render() end end)
        else
            local d = CharData().data
            d.mobs, d.session.mobs = {}, {}
            for g in pairs(recentKills) do recentKills[g] = nil end
            selected, confirmAll = nil, false
            Stamp(CharData())
        end
        Render()
    end)

    -- the item search view
    local function ItemPart(f) tinsert(panel.itemUI, f); return f end
    local ib = ItemPart(CreateFrame("Frame", nil, panel))
    ib:SetSize(330, 22)
    ib:SetPoint("TOPLEFT", 14, -64)
    Tex(ib, "BACKGROUND", 0, 0, 0, 0.5):SetAllPoints()
    Border(ib, 0.3)
    panel.isearch = CreateFrame("EditBox", nil, ib)
    panel.isearch:SetPoint("TOPLEFT", 6, -2)
    panel.isearch:SetPoint("BOTTOMRIGHT", -6, 2)
    panel.isearch:SetFontObject("GameFontHighlight")
    panel.isearch:SetAutoFocus(false)
    panel.isearch:SetMaxLetters(40)
    panel.isearchHint = Text(ib, "GameFontHighlightSmall", DIM)
    panel.isearchHint:SetPoint("LEFT", 8, 0)
    panel.isearchHint:SetText("Search items you have looted")
    panel.isearch:SetScript("OnTextChanged", function(self)
        itemText = strtrim(self:GetText() or "")
        panel.isearchHint:SetShown((self:GetText() or "") == "")
        selItem = nil
        Render()
    end)
    panel.isearch:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    panel.isearch:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    for i = 1, LIST_ROWS do
        local r = ItemPart(CreateFrame("Button", nil, panel))
        r:SetSize(344, 32)
        r:SetPoint("TOPLEFT", 12, -92 - (i - 1) * 34)
        r.sel = Tex(r, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.18)
        r.sel:SetAllPoints()
        r.sel:Hide()
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(24, 24)
        r.icon:SetPoint("LEFT", 4, 0)
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", 34, 0)
        r.name:SetWidth(220)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.info = Text(r, "GameFontHighlightSmall", DIM)
        r.info:SetPoint("RIGHT", -6, 0)
        r:SetScript("OnClick", function(self) if self.id then selItem = self.id; Render() end end)
        r:SetScript("OnEnter", ItemTooltip)
        r:SetScript("OnLeave", HideTooltip)
        mrows[i] = r
        r:Hide()
    end
    panel.imore = ItemPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.imore:SetPoint("BOTTOMLEFT", 14, 40)
    panel.iempty = ItemPart(Text(panel, "GameFontHighlight", DIM))
    panel.iempty:SetPoint("TOPLEFT", 376, -124)
    panel.iempty:SetWidth(540)
    panel.iempty:SetJustifyH("LEFT")
    panel.iempty:SetWordWrap(true)
    panel.sname = ItemPart(Text(panel, "GameFontNormalLarge", BONE))
    panel.sname:SetPoint("TOPLEFT", 376, -64)
    panel.ssub = ItemPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.ssub:SetPoint("TOPLEFT", 376, -90)
    panel.scolhead = ItemPart(CreateFrame("Frame", nil, panel))
    panel.scolhead:SetSize(552, 18)
    panel.scolhead:SetPoint("TOPLEFT", 376, -112)
    for _, c in ipairs({ { "Mob", 4 }, { "Zone", 156 }, { "Drop %", 262 }, { "Avg", 372 }, { "Each", 410 } }) do
        local fs = Text(panel.scolhead, "GameFontNormal", GOLD)
        fs:SetPoint("LEFT", c[2], 0)
        fs:SetText(c[1])
    end
    for i = 1, ITEM_ROWS do
        local r = ItemPart(CreateFrame("Button", nil, panel))
        r:SetSize(552, 26)
        r:SetPoint("TOPLEFT", 376, -132 - (i - 1) * 28)
        Tex(r, "HIGHLIGHT", 1, 1, 1, 0.06):SetAllPoints()
        r.best = Tex(r, "BACKGROUND", 0.45, 0.85, 0.35, 0.12)   -- the best source stands out
        r.best:SetAllPoints()
        r.best:Hide()
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", 4, 0)
        r.name:SetWidth(148)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.zone = Text(r, "GameFontHighlightSmall", DIM)
        r.zone:SetPoint("LEFT", 156, 0)
        r.zone:SetWidth(100)
        r.zone:SetJustifyH("LEFT")
        r.zone:SetWordWrap(false)
        r.pct = Text(r, "GameFontHighlight")
        r.pct:SetPoint("LEFT", 262, 0)
        r.avg = Text(r, "GameFontHighlight", DIM)
        r.avg:SetPoint("LEFT", 372, 0)
        r.each = Text(r, "GameFontHighlight", DIM)
        r.each:SetPoint("LEFT", 410, 0)
        r.wish = Btn(r, "Wish", 58, 20)
        r.wish:SetPoint("RIGHT", -2, 0)
        r.wish:SetScript("OnClick", function()
            if not r.id then return end
            SetWish(r.id, not IsWished(r.id), (function()
                for _, e in ipairs(SearchItems(Store(), itemText)) do if e.id == r.id then return e.name end end
            end)())
            Render()
        end)
        r:SetScript("OnClick", function(self)
            -- open that mob's own detail, as the mob list does
            if self.npc then
                itemMode, selected, itemPage, confirmAll = false, self.npc, 1, false
                Render()
            end
        end)
        r:SetScript("OnEnter", ItemTooltip)
        r:SetScript("OnLeave", HideTooltip)
        srows[i] = r
        r:Hide()
    end
    panel.smore = ItemPart(Text(panel, "GameFontHighlightSmall", DIM))
    panel.smore:SetPoint("TOPLEFT", 376, -132 - ITEM_ROWS * 28)

    -- the wishlist view
    local function WishPart(f) tinsert(panel.wishUI, f); return f end
    panel.wishEmpty = WishPart(Text(panel, "GameFontHighlight", DIM))
    panel.wishEmpty:SetPoint("TOPLEFT", 16, -70)
    panel.wishEmpty:SetWidth(700)
    panel.wishEmpty:SetJustifyH("LEFT")
    panel.wishEmpty:SetWordWrap(true)
    for i = 1, WISH_ROWS do
        local r = WishPart(CreateFrame("Button", nil, panel))
        r:SetSize(560, 28)
        r:SetPoint("TOPLEFT", 16, -118 - (i - 1) * 30)
        Tex(r, "HIGHLIGHT", 1, 1, 1, 0.06):SetAllPoints()
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(22, 22)
        r.icon:SetPoint("LEFT", 2, 0)
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", 32, 0)
        r.name:SetWidth(300)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.seen = Text(r, "GameFontHighlightSmall", DIM)
        r.seen:SetPoint("LEFT", 346, 0)
        r.remove = Btn(r, "Remove", 70, 20)
        r.remove:SetPoint("RIGHT", -2, 0)
        r.remove:SetScript("OnClick", function()
            if r.id then SetWish(r.id, false); Render() end
        end)
        r:SetScript("OnEnter", function(self) if self.id then self.link = "item:" .. self.id; ItemTooltip(self) end end)
        r:SetScript("OnLeave", HideTooltip)
        wrows[i] = r
        r:Hide()
    end

    panel.foot = Text(panel, "GameFontHighlightSmall", DIM)
    panel.foot:SetPoint("BOTTOMLEFT", 14, 14)
    panel.foot:SetWidth(W - 28)
    panel.foot:SetJustifyH("LEFT")

    -- the strip ticks once a second while the window is open
    local acc = 0
    panel:SetScript("OnUpdate", function(_, dt)
        acc = acc + (tonumber(dt) or 0)
        if acc >= 1 then acc = 0; UpdateStrip() end
    end)
    panel.rows, panel.irows, panel.wrows, panel.mrows, panel.srows = rows, irows, wrows, mrows, srows   -- (the tests look at the rows)
    tinsert(UISpecialFrames, "ForgesLedgerKillLedgerPanel")
    panel:Hide()
end

local function ShowPanel()
    if not panel then CreatePanel() end
    FillPrices()
    panel:Show()
    Render()
end

local function TogglePanel()
    if panel and panel:IsShown() then panel:Hide() else ShowPanel() end
end

------------------------------------------------------------------- toasts ---
-- A wishlisted item dropped for you: one toast per item per loot window,
-- shown one at a time, with a sound. Plain frames and OnUpdate (no animation
-- groups), so it behaves the same on every client.

local toast, toastQueue, toastCur = nil, {}, nil
local TOAST_IN, TOAST_HOLD, TOAST_OUT = 0.25, 3.2, 0.6

local function ToastSound()
    if type(PlaySound) ~= "function" then return end
    local id = (SOUNDKIT and (SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.UI_LEGENDARY_LOOT_TOAST)) or 888
    pcall(PlaySound, id)
end

local function NextToast()
    local t = tremove(toastQueue, 1)
    if not t then toastCur = nil; toast:Hide(); return end
    toastCur = { age = 0, data = t }
    SetItemIcon(toast.icon, t.it, t.id)
    toast.title:SetText("Wishlist drop!")
    toast.item:SetText(tostring(t.name or ("Item " .. t.id)) .. (t.qty > 1 and (" x" .. t.qty) or ""))
    toast.item:SetTextColor(ItemColor(t.it or {}))
    toast.sub:SetText(t.mob and ("from " .. t.mob) or "")
    toast:SetAlpha(0)
    toast:Show()
    ToastSound()
end

local function CreateToast()
    toast = CreateFrame("Frame", "ForgesLedgerKillLedgerToast", UIParent)
    toast:SetSize(340, 66)
    toast:SetFrameStrata("FULLSCREEN_DIALOG")
    toast:SetPoint("TOP", UIParent, "TOP", 0, -150)
    toast:EnableMouse(false)
    Tex(toast, "BACKGROUND", IRON[1], IRON[2], IRON[3], 0.95):SetAllPoints()
    Border(toast, 0.9)
    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetSize(44, 44)
    toast.icon:SetPoint("LEFT", 10, 0)
    toast.title = Text(toast, "GameFontNormal", GOLD)
    toast.title:SetPoint("TOPLEFT", 64, -10)
    toast.item = Text(toast, "GameFontNormalLarge", BONE)
    toast.item:SetPoint("TOPLEFT", 64, -26)
    toast.item:SetWidth(266)
    toast.item:SetJustifyH("LEFT")
    toast.item:SetWordWrap(false)
    toast.sub = Text(toast, "GameFontHighlightSmall", DIM)
    toast.sub:SetPoint("BOTTOMLEFT", 64, 8)
    toast:SetScript("OnUpdate", function(_, dt)
        if not toastCur then return end
        toastCur.age = toastCur.age + (tonumber(dt) or 0)
        local a = toastCur.age
        local alpha = 1
        if a < TOAST_IN then alpha = a / TOAST_IN
        elseif a > TOAST_IN + TOAST_HOLD then alpha = 1 - (a - TOAST_IN - TOAST_HOLD) / TOAST_OUT end
        toast:SetAlpha(math.max(0, math.min(1, alpha)))
        if a >= TOAST_IN + TOAST_HOLD + TOAST_OUT then NextToast() end
    end)
    toast:Hide()
end

-- t = { id, name, qty, mob, it }
ShowToast = function(t)
    if not toast then CreateToast() end
    tinsert(toastQueue, t)
    if not toastCur then NextToast() end
end

------------------------------------------------------------------ events ---

local function IsGroup(flags)
    -- affiliation bits: mine 0x1, party 0x2, raid 0x4 (pets and guardians
    -- carry their owner's affiliation)
    return (tonumber(flags) or 0) % 8 ~= 0
end

local DAMAGE = {
    SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true, SPELL_BUILDING_DAMAGE = true, DAMAGE_SHIELD = true,
}

local function OnCombatLog()
    local info = { Try(CombatLogGetCurrentEventInfo) }
    DBG.cleu = DBG.cleu + 1
    local sub = Plain(info[2])
    if not sub then DBG.secret = DBG.secret + 1; return end
    local srcGUID, srcFlags = Plain(info[4]), Plain(info[6])
    local dstGUID, dstFlags = Plain(info[8]), Plain(info[10])
    if type(dstGUID) ~= "string" then
        if sub == "PARTY_KILL" or sub == "UNIT_DIED" then DBG.noGuid = DBG.noGuid + 1 end
        return
    end
    if not NpcId(dstGUID) then
        if (sub == "PARTY_KILL" or sub == "UNIT_DIED") and not dstGUID:find("^Player") then
            DBG.parseFail = DBG.parseFail + 1
            NoteShape(dstGUID)
        end
        return
    end
    if IsGroup(dstFlags) then DBG.ownPet = DBG.ownPet + 1; return end  -- your own pet dying isn't a kill
    if sub == "PARTY_KILL" then
        -- it only fires for your group, but check the source anyway
        if srcFlags ~= nil and not IsGroup(srcFlags) then DBG.notGroup = DBG.notGroup + 1; return end
        CreditKill(dstGUID, Plain(info[9]), "combatlog")
    elseif DAMAGE[sub] then
        if IsGroup(srcFlags) then tagged[dstGUID] = time() end
    elseif sub == "UNIT_DIED" then
        local t = tagged[dstGUID]
        if t and time() - t <= TAG_WINDOW then CreditKill(dstGUID, Plain(info[9]), "tag") end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
-- The combat log is opt-in (see the header): registering for it is what
-- trips the blocked-action dialog on clients that restrict it.
local cleuOK = false
if ForgesLedgerKillLedgerDB.combatLog == true then
    cleuOK = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
end
ForgesLedgerKillLedgerDB.countMode = cleuOK and "combatlog" or "observed"
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UNIT_HEALTH")

-- Target watching: remember a hostile creature you target; when it is dead
-- and wasn't tap-denied (tagged by you or your group), that is a kill.
local watched
local function Watch()
    watched = nil
    if not Plain(Try(UnitExists, "target")) then return end
    if Plain(Try(UnitIsPlayer, "target")) then return end
    local guid = Plain(Try(UnitGUID, "target"))
    if NpcId(guid) then watched = guid end
end

local function TargetDied()
    if not watched or recentKills[watched] then return end
    if Try(UnitGUID, "target") ~= watched then return end
    if not Plain(Try(UnitIsDead, "target")) then return end
    if Plain(Try(UnitIsTapDenied, "target")) then return end   -- someone else's kill
    CreditKill(watched, Plain(Try(UnitName, "target")), "target")
end

------------------------------------------------------------ enemy tooltip ---
-- Hover an enemy and see what it has dropped FOR YOU: lifetime data, looked up by
-- npc id only (no scans). Nothing is added for players, non-creatures or mobs
-- Kill Ledger has no kills for. Only the player's own recorded kills and loot.
local TIP_DROPS = 5

local function DropTooltip(tooltip)
    local db = ForgesLedgerKillLedgerDB
    if type(db) ~= "table" or db.tooltip == false then return end
    local ok, unit = pcall(function() return select(2, tooltip:GetUnit()) end)
    unit = ok and Plain(unit) or nil
    if type(unit) ~= "string" then return end
    if Plain(Try(UnitIsPlayer, unit)) then return end
    local npc = NpcId(Plain(Try(UnitGUID, unit)))
    if not npc then return end
    local m = CharData().data.mobs[npc]
    local kills = m and tonumber(m.kills) or 0
    if kills <= 0 then return end
    tooltip:AddLine("|cffffd100Kill Ledger|r  " .. kills .. (kills == 1 and " kill" or " kills") .. " (lifetime)")
    local list = {}
    for id, it in pairs(m.items or {}) do
        tinsert(list, { id = id, it = it, pct = 100 * (it.dropEvents or 0) / kills })
    end
    table.sort(list, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        if (a.it.dropEvents or 0) ~= (b.it.dropEvents or 0) then return (a.it.dropEvents or 0) > (b.it.dropEvents or 0) end
        return tostring(a.it.name or a.id) < tostring(b.it.name or b.id)
    end)
    if #list == 0 then
        tooltip:AddLine("  No drops recorded yet", 0.62, 0.60, 0.56)
        return
    end
    for i = 1, math.min(TIP_DROPS, #list) do
        local e = list[i]
        local left = "  " .. tostring(e.it.name or ("Item " .. e.id))
        if IsWished(e.id) then left = left .. "  |cffffd100wish|r" end
        local price = e.it.noSell and "no sell" or (type(e.it.price) == "number" and Coin(e.it.price) or "")
        local right = PctText(e.it, kills) .. (price ~= "" and ("  " .. price) or "")
        local r, g, b = ItemColor(e.it)
        tooltip:AddDoubleLine(left, right, r, g, b, 1, 1, 1)
    end
    if #list > TIP_DROPS then
        tooltip:AddLine("  +" .. (#list - TIP_DROPS) .. " more in /kl", 0.62, 0.60, 0.56)
    end
end

local function HookDropTooltip()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tooltip) pcall(DropTooltip, tooltip) end)
    elseif GameTooltip and GameTooltip.HookScript then
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tooltip) pcall(DropTooltip, tooltip) end)
    end
end

local priceTimer = false
frame:SetScript("OnEvent", function(_, event, a, b)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        pcall(OnCombatLog)
    elseif event == "PLAYER_TARGET_CHANGED" then
        pcall(Watch)
    elseif event == "UNIT_HEALTH" then
        if a == "target" then pcall(TargetDied) end
    elseif event == "LOOT_OPENED" then
        pcall(ReadLoot)
        Prune()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if not priceTimer then
            priceTimer = true
            C_Timer.After(2, function()
                priceTimer = false
                pcall(FillPrices)
                if panel and panel:IsShown() then Render() end
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- a fresh login starts a fresh session; a /reload keeps it
        if a == true then
            CharData().data.session = { startedAt = time(), mobs = {} }
        end
        Touch()
    elseif event == "PLAYER_LOGIN" then
        Touch()
        HookDropTooltip()
        C_Timer.After(5, function() pcall(FillPrices) end)
    end
end)

-------------------------------------------------------------------- /kl ---

SLASH_FORGESLEDGERKILLLEDGER1 = "/kl"
SLASH_FORGESLEDGERKILLLEDGER2 = "/killledger"
SlashCmdList["FORGESLEDGERKILLLEDGER"] = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "" or cmd == "open" then
        TogglePanel()
    elseif cmd == "session" or cmd == "lifetime" then
        ShowPanel()
        SetScope(cmd)
    elseif cmd == "sort recent" or cmd == "sort kills" then
        sortMode = cmd:match("%S+$")
        UI().sort = sortMode
        print(PREFIX .. "Mobs sorted by " .. (sortMode == "recent" and "most recent kill." or "most kills."))
        if panel and panel:IsShown() then Render() end
    elseif cmd == "wishlist" then
        local n = 0
        for id, w in pairs(Wishlist()) do
            n = n + 1
            print("  " .. tostring(w.name or ("item " .. id)) .. "  (item " .. id .. ")")
        end
        print(PREFIX .. (n == 0 and "Your wishlist is empty. /kl wish [shift-click an item], or Wish on a drop row."
            or (n .. " on your wishlist. /kl wish <item> adds or removes one.")))
    elseif cmd:match("^wish%s") or cmd:match("^unwish%s") then
        local arg = strtrim(msg or ""):match("^%S+%s+(.+)$") or ""
        local id = ItemId(arg) or arg:match("^%d+$")
        if not id then
            print(PREFIX .. "Shift-click an item (or give its number): /kl wish [item]")
        else
            local remove = cmd:match("^unwish") ~= nil or IsWished(id)
            local name = arg:match("%[(.-)%]") or (ItemMeta("item:" .. id))
            SetWish(id, not remove, name)
            print(PREFIX .. (remove and "Removed from" or "Added to") .. " your wishlist: " .. tostring(name or ("item " .. id)))
            if panel and panel:IsShown() then Render() end
        end
    elseif cmd == "tooltip on" or cmd == "tooltip off" or cmd == "tooltip" then
        if cmd ~= "tooltip" then ForgesLedgerKillLedgerDB.tooltip = (cmd == "tooltip on") end
        print(PREFIX .. "Enemy tooltip lines are " .. (ForgesLedgerKillLedgerDB.tooltip == false and "OFF" or "ON")
            .. ". /kl tooltip on|off")
    elseif cmd == "combatlog on" or cmd == "combatlog off" then
        ForgesLedgerKillLedgerDB.combatLog = (cmd == "combatlog on")
        print(PREFIX .. "Combat-log counting " .. (cmd == "combatlog on" and "ON" or "OFF") .. " after /reload."
            .. (cmd == "combatlog on" and " If the game shows a blocked-action dialog, turn it off again." or ""))
    elseif cmd == "debug" then
        print(PREFIX .. "mode: " .. tostring(ForgesLedgerKillLedgerDB.countMode)
            .. " | combat-log events seen: " .. DBG.cleu .. " (secret/unreadable: " .. DBG.secret .. ")")
        print("  kills counted via: combat log " .. DBG.via.combatlog .. ", damage tag " .. DBG.via.tag
            .. ", target death " .. DBG.via.target .. ", loot window " .. DBG.via.loot)
        print("  dropped: no guid " .. DBG.noGuid .. ", guid not parsed " .. DBG.parseFail
            .. ", own pet " .. DBG.ownPet .. ", source not your group " .. DBG.notGroup)
        print("  loot windows: " .. DBG.loots .. " (corpses first counted there: " .. DBG.lootCredited
            .. ", living target skipped: " .. DBG.lootLive .. ")")
        if #DBG.shapes > 0 then print("  guid shapes not parsed: " .. table.concat(DBG.shapes, "  ")) end
    elseif cmd == "reset session" then
        CharData().data.session = { startedAt = time(), mobs = {} }
        print(PREFIX .. "Session cleared.")
        if panel and panel:IsShown() then Render() end
    else
        print(PREFIX .. "v" .. VERSION .. " commands:")
        print("  /kl - open or close the panel")
        print("  /kl session, /kl lifetime - open on that view")
        print("  /kl sort recent|kills - order the mob list")
        print("  /kl wishlist - list your wishlist; /kl wish [item] adds or removes one")
        print("  /kl tooltip on|off - show what an enemy has dropped for you when you hover it (on by default)")
        print("  /kl reset session - clear this session's numbers")
        print("  /kl debug - what the counters saw (for bug reports)")
        print("  /kl combatlog on|off - count kills from the combat log instead (needs /reload; off by default)")
        print("  (resetting one mob or everything is in the panel)")
    end
end

-- for the tests and the app's support page
ForgesLedgerKillLedger = { version = VERSION, schema = SCHEMA }
