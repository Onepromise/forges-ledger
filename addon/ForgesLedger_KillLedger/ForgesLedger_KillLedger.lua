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

local VERSION = "1.0"
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

local function Touch()
    local c = CharData()
    c.exportedAt = time()
    c.data.name = UnitName("player")
    c.data.class = select(2, UnitClass("player"))
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
    local name, _, quality, _, _, _, _, _, _, _, price = Try(GI, link)
    return Plain(name), Plain(quality), Plain(price)
end

local function ApplyMeta(it, name, quality, price)
    if name then it.name = name end
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
    c.exportedAt = time()
    if panel and panel:IsShown() then Render() end
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
            changed = true
        end
    end
    if changed then
        c.exportedAt = time()
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

local function Sorted(store)
    local list = {}
    for id, m in pairs(store) do
        tinsert(list, { id = id, m = m })
    end
    table.sort(list, function(a, b)
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
local W, H = 660, 470
local LIST_ROWS, ITEM_ROWS = 14, 12

local scope = "session"   -- "session" or "lifetime"
local selected            -- npc id
local page = 1
local confirmAll = false

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

local rows, irows = {}, {}

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

function Render()
    if not panel then return end
    local store = Store()
    local list = Sorted(store)
    local pages = math.max(1, math.ceil(#list / LIST_ROWS))
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    panel.tabSession:SetActive(scope == "session")
    panel.tabLife:SetActive(scope == "lifetime")
    -- the left list
    local first = (page - 1) * LIST_ROWS
    local selectedShown = false
    for i = 1, LIST_ROWS do
        local row, e = rows[i], list[first + i]
        if e then
            row.npc = e.id
            row.name:SetText(tostring(e.m.name or ("Mob " .. e.id)))
            row.kills:SetText(tostring(e.m.kills or 0))
            row.sel:SetShown(e.id == selected)
            if e.id == selected then selectedShown = true end
            row:Show()
        else
            row.npc = nil
            row:Hide()
        end
    end
    if not selected or not store[selected] then
        selected = list[1] and list[1].id or nil
        if selected and rows[1].npc == selected then rows[1].sel:Show() end
    end
    panel.pageLabel:SetText(#list > 0 and ("Page " .. page .. " of " .. pages) or "")
    panel.prev:SetShown(page > 1)
    panel.next:SetShown(page < pages)
    local totalKills, totalValue = 0, 0
    for _, e in ipairs(list) do
        totalKills = totalKills + (e.m.kills or 0)
        totalValue = totalValue + Summary(e.m)
    end
    panel.head3:SetText(string.format("%s: %d kills, %d mobs, %s in vendor value",
        scope == "session" and "This session" or "Lifetime", totalKills, #list, Coin(totalValue)))
    -- the detail
    local m = selected and store[selected]
    for _, r in ipairs(irows) do r:Hide() end
    if not m then
        panel.dname:SetText("")
        panel.dsub:SetText("")
        panel.empty:SetText(scope == "session"
            and "Nothing killed yet this session. Kill something and loot it - it shows up here."
            or "No kills recorded yet.")
        panel.empty:Show()
        panel.colhead:Hide()
        panel.more:SetText("")
        panel.resetMob:Hide()
    else
        panel.empty:Hide()
        panel.colhead:Show()
        local value, _ = Summary(m)
        local kills = m.kills or 0
        panel.dname:SetText(tostring(m.name or ("Mob " .. selected)))
        panel.dsub:SetText(string.format("%s   |   Killed %d   |   Vendor value %s%s",
            tostring(m.zone or "?"), kills, Coin(value),
            kills > 0 and ("   (" .. Coin(value / kills) .. " per kill)") or ""))
        local items = SortedItems(m)
        for i = 1, ITEM_ROWS do
            local r, e = irows[i], items[i]
            if e then
                local it = e.it
                r.name:SetText(tostring(it.name or ("Item " .. e.id)))
                r.name:SetTextColor(ItemColor(it))
                r.pct:SetText(Pct(it, kills))
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
                r:Show()
            end
        end
        panel.more:SetText(#items > ITEM_ROWS and ("+" .. (#items - ITEM_ROWS) .. " more items - see them on the dashboard") or
            (#items == 0 and "No drops seen yet." or ""))
        panel.resetMob:Show()
    end
    panel.resetAll:SetLabel(confirmAll and "Click again to confirm" or "Reset all")
    panel.resetAll:SetWidth(confirmAll and 150 or 90)
    panel.foot:SetText(ForgesLedgerKillLedgerDB.countMode == "combatlog"
        and "Counting kills from the combat log. Your own loot only; drop % = drops / kills."
        or "Counting kills when your target dies or you loot a corpse. Your own loot only; drop % = drops / kills.")
end

local function CreatePanel()
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
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
    panel.title = Text(panel, "GameFontNormalLarge", GOLD)
    panel.title:SetPoint("TOPLEFT", 16, -14)
    panel.title:SetText("Kill Ledger")
    panel.head3 = Text(panel, "GameFontHighlightSmall", DIM)
    panel.head3:SetPoint("TOPLEFT", 16, -38)

    panel.tabSession = Btn(panel, "This session", 100, 22)
    panel.tabSession:SetPoint("TOPRIGHT", -150, -14)
    panel.tabSession:SetScript("OnClick", function() scope, page, selected, confirmAll = "session", 1, nil, false; Render() end)
    panel.tabLife = Btn(panel, "Lifetime", 90, 22)
    panel.tabLife:SetPoint("LEFT", panel.tabSession, "RIGHT", 6, 0)
    panel.tabLife:SetScript("OnClick", function() scope, page, selected, confirmAll = "lifetime", 1, nil, false; Render() end)

    -- left: the mobs
    local lh = Text(panel, "GameFontNormal", GOLD)
    lh:SetPoint("TOPLEFT", 16, -64)
    lh:SetText("Mob")
    local lk = Text(panel, "GameFontNormal", GOLD)
    lk:SetPoint("TOPLEFT", 196, -64)
    lk:SetText("Kills")
    for i = 1, LIST_ROWS do
        local r = CreateFrame("Button", nil, panel)
        r:SetSize(230, 22)
        r:SetPoint("TOPLEFT", 12, -82 - (i - 1) * 24)
        r.sel = Tex(r, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.18)
        r.sel:SetAllPoints()
        r.sel:Hide()
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", 4, 0)
        r.name:SetWidth(176)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.kills = Text(r, "GameFontNormal", GOLD)
        r.kills:SetPoint("LEFT", 186, 0)
        r:SetScript("OnClick", function(self)
            if self.npc then selected, confirmAll = self.npc, false; Render() end
        end)
        rows[i] = r
    end
    panel.prev = Btn(panel, "<", 28, 20)
    panel.prev:SetPoint("BOTTOMLEFT", 16, 44)
    panel.prev:SetScript("OnClick", function() page = page - 1; Render() end)
    panel.next = Btn(panel, ">", 28, 20)
    panel.next:SetPoint("LEFT", panel.prev, "RIGHT", 4, 0)
    panel.next:SetScript("OnClick", function() page = page + 1; Render() end)
    panel.pageLabel = Text(panel, "GameFontHighlightSmall", DIM)
    panel.pageLabel:SetPoint("LEFT", panel.next, "RIGHT", 8, 0)

    -- right: the drop table
    panel.dname = Text(panel, "GameFontNormalLarge", BONE)
    panel.dname:SetPoint("TOPLEFT", 262, -64)
    panel.dsub = Text(panel, "GameFontHighlightSmall", DIM)
    panel.dsub:SetPoint("TOPLEFT", 262, -88)
    panel.empty = Text(panel, "GameFontHighlight", DIM)
    panel.empty:SetPoint("TOPLEFT", 262, -120)
    panel.empty:SetWidth(380)
    panel.empty:SetJustifyH("LEFT")
    panel.empty:SetWordWrap(true)
    panel.colhead = CreateFrame("Frame", nil, panel)
    panel.colhead:SetSize(390, 18)
    panel.colhead:SetPoint("TOPLEFT", 262, -112)
    local cols = { { "Item", 0 }, { "Drop %", 150 }, { "Avg", 238 }, { "Each", 276 }, { "Total", 340 } }
    for _, c in ipairs(cols) do
        local fs = Text(panel.colhead, "GameFontNormal", GOLD)
        fs:SetPoint("LEFT", c[2], 0)
        fs:SetText(c[1])
    end
    for i = 1, ITEM_ROWS do
        local r = CreateFrame("Frame", nil, panel)
        r:SetSize(390, 22)
        r:SetPoint("TOPLEFT", 262, -132 - (i - 1) * 24)
        r.name = Text(r, "GameFontHighlight")
        r.name:SetPoint("LEFT", 0, 0)
        r.name:SetWidth(146)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.pct = Text(r, "GameFontHighlight")
        r.pct:SetPoint("LEFT", 150, 0)
        r.avg = Text(r, "GameFontHighlight", DIM)
        r.avg:SetPoint("LEFT", 238, 0)
        r.each = Text(r, "GameFontHighlight", DIM)
        r.each:SetPoint("LEFT", 276, 0)
        r.total = Text(r, "GameFontHighlight")
        r.total:SetPoint("LEFT", 340, 0)
        irows[i] = r
    end
    panel.more = Text(panel, "GameFontHighlightSmall", DIM)
    panel.more:SetPoint("TOPLEFT", 262, -132 - ITEM_ROWS * 24)

    -- bottom: resets and the note
    panel.resetMob = Btn(panel, "Reset this mob", 110, 22)
    panel.resetMob:SetPoint("BOTTOMRIGHT", -16, 40)
    panel.resetMob:SetScript("OnClick", function()
        if selected then
            local d = CharData().data
            d.mobs[selected] = nil
            d.session.mobs[selected] = nil
            selected, confirmAll = nil, false
            CharData().exportedAt = time()
            Render()
        end
    end)
    panel.resetAll = Btn(panel, "Reset all", 90, 22)
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
            CharData().exportedAt = time()
        end
        Render()
    end)
    panel.foot = Text(panel, "GameFontHighlightSmall", DIM)
    panel.foot:SetPoint("BOTTOMLEFT", 16, 14)
    panel.foot:SetWidth(W - 32)
    panel.foot:SetJustifyH("LEFT")
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
        scope, page, selected = cmd, 1, nil
        ShowPanel()
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
        print("  /kl reset session - clear this session's numbers")
        print("  /kl debug - what the counters saw (for bug reports)")
        print("  /kl combatlog on|off - count kills from the combat log instead (needs /reload; off by default)")
        print("  (resetting one mob or everything is in the panel)")
    end
end

-- for the tests and the app's support page
ForgesLedgerKillLedger = { version = VERSION, schema = SCHEMA }
