-- Totem Range PROBE v0.1 (throwaway, Step 0)
-- Not the addon: a test build that finds out, on the real client, what the
-- game lets an addon see about totems, position and the minimap. It changes
-- nothing, sends nothing, and registers only plain events (no combat log).
--
-- HOW TO USE (Shaman):
--   1. /reload with this addon enabled.
--   2. Type /trprobe to see the report in chat.
--   3. Drop each totem once (any order) and walk away a bit; the probe logs
--      each cast with what the totem slots, your position and the spell
--      description said.
--   4. Type /trprobe report again, then /reload (or log out) so the numbers
--      are saved, and send the file
--        WTF\Account\<account>\SavedVariables\TotemRange_Probe.lua
--      (the save file is named after the addon folder) to Forge/Luna.

local PREFIX = "|cffFFD700[TotemProbe]|r "
TotemRangeProbeDB = TotemRangeProbeDB or {}
local db = TotemRangeProbeDB
db.log = db.log or {}

local function Try(fn, ...)
    if type(fn) ~= "function" then return false, "missing" end
    return pcall(fn, ...)
end

-- "secret" values can't be read by addons on some clients
local function Secret(v)
    if v ~= nil and type(issecretvalue) == "function" then
        local ok, s = pcall(issecretvalue, v)
        return ok and s or false
    end
    return false
end

local function Show(v)
    if v == nil then return "nil" end
    if Secret(v) then return "<secret>" end
    return tostring(v)
end

local function Say(...) print(PREFIX .. table.concat({ ... }, " ")) end

------------------------------------------------------------ what exists ---

local function Exists(path)
    -- "C_Map.GetPlayerMapPosition" -> true/false (and the type)
    local cur = _G
    for part in path:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return false end
        cur = cur[part]
        if cur == nil then return false end
    end
    return true, type(cur)
end

local APIS = {
    -- totem tracking
    "GetTotemInfo", "GetTotemTimeLeft", "DestroyTotem", "MAX_TOTEMS",
    -- position
    "UnitPosition", "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition",
    "C_Map.GetWorldPosFromMapPos", "C_Map.GetMapInfo", "IsInInstance",
    -- minimap
    "C_Minimap.GetViewRadius", "C_Minimap.GetNumTrackingTypes", "Minimap",
    "GetCVar", "GetCVarBool",
    -- spell data
    "C_Spell.GetSpellInfo", "C_Spell.GetSpellDescription", "GetSpellInfo",
    "GetSpellDescription", "C_Spell.GetSpellName", "C_Spell.GetSpellTexture",
    "C_Spell.IsSpellKnown", "IsPlayerSpell",
    -- hygiene helpers
    "issecretvalue", "C_Secrets", "C_Timer.After", "CombatLogGetCurrentEventInfo",
}

local EVENTS = {
    "PLAYER_TOTEM_UPDATE", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_DEAD", "MINIMAP_UPDATE_ZOOM",
}

-------------------------------------------------------------- the probes ---

local function ClassName()
    local ok, _, token = Try(UnitClass, "player")
    return ok and token or "?"
end

-- 1. totem tracking: what GetTotemInfo gives for each slot
local function ProbeTotems()
    local out = {}
    local maxT = tonumber(_G.MAX_TOTEMS) or 4
    for slot = 1, math.max(maxT, 4) do
        local r = { pcall(GetTotemInfo, slot) }
        local row = { slot = slot, ok = r[1] }
        if r[1] then
            -- (haveTotem, name, startTime, duration, icon [, modelID / spellID...])
            for i = 2, math.min(#r, 9) do row[i - 1] = Show(r[i]) end
        else
            row.err = tostring(r[2])
        end
        local tl = { pcall(GetTotemTimeLeft, slot) }
        row.timeLeft = tl[1] and Show(tl[2]) or ("err: " .. tostring(tl[2]))
        out[#out + 1] = row
    end
    return out
end

-- 2. position: what UnitPosition and the map APIs return right now
local function ProbePosition()
    local p = { }
    local inst, kind = nil, nil
    local ok, a, b = Try(IsInInstance)
    if ok then p.instance, p.instanceType = Show(a), Show(b) end
    local r = { pcall(UnitPosition, "player") }
    p.unitPosition = r[1] and { Show(r[2]), Show(r[3]), Show(r[4]), Show(r[5]) } or ("err: " .. tostring(r[2]))
    p.unitPositionSecret = r[1] and (Secret(r[2]) or Secret(r[3])) or nil
    local okM, mapID = Try(function() return C_Map.GetBestMapForUnit("player") end)
    p.mapID = okM and Show(mapID) or "n/a"
    if okM and mapID and not Secret(mapID) then
        local okP, pos = Try(function() return C_Map.GetPlayerMapPosition(mapID, "player") end)
        if okP and pos and pos.GetXY then
            local x, y = pos:GetXY()
            p.mapPosition = { Show(x), Show(y) }
        else
            p.mapPosition = okP and "nil (no map position here)" or ("err: " .. tostring(pos))
        end
        -- world coordinates from the map position: usable as a yards fallback?
        local okW, cont, world = Try(function()
            local pos = C_Map.GetPlayerMapPosition(mapID, "player")
            if not pos then return nil end
            return C_Map.GetWorldPosFromMapPos(mapID, pos)
        end)
        p.worldPos = okW and cont and { Show(cont), world and Show(world.x) or "?", world and Show(world.y) or "?" } or "n/a"
    end
    return p
end

-- 3. minimap: can a ring be scaled to yards?
local function ProbeMinimap()
    local m = {}
    local ok, r = Try(function() return C_Minimap.GetViewRadius() end)
    m.viewRadius = ok and Show(r) or ("n/a: " .. tostring(r))
    if Minimap then
        local okZ, z = Try(function() return Minimap:GetZoom() end)
        m.zoom = okZ and Show(z) or "n/a"
        local okN, n = Try(function() return Minimap:GetZoomLevels() end)
        m.zoomLevels = okN and Show(n) or "n/a"
        local okW, w = Try(function() return Minimap:GetWidth() end)
        m.width = okW and Show(w) or "n/a"
        local okS, s = Try(function() return Minimap:GetEffectiveScale() end)
        m.effectiveScale = okS and Show(s) or "n/a"
        local okR, rot = Try(GetCVar, "rotateMinimap")
        m.rotateMinimap = okR and Show(rot) or "n/a"
        local okI, indoors = Try(function() return GetCVar("minimapZoom") end)
        m.cvarZoom = okI and Show(indoors) or "n/a"
        -- can we draw a texture parented to the minimap?
        local okT, tex = pcall(function()
            local f = CreateFrame("Frame", nil, Minimap)
            local t = f:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1, 0, 0, 0.2)
            t:SetSize(20, 20)
            t:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
            f:Hide()
            return "ok"
        end)
        m.canAnchorTextureToMinimap = okT and tex or ("err: " .. tostring(tex))
    else
        m.minimap = "no Minimap frame"
    end
    return m
end

-- 4. spell data: where a radius could come from (the game's own description)
local function Description(spellID)
    local fns = {
        function() return C_Spell.GetSpellDescription(spellID) end,
        function() return GetSpellDescription(spellID) end,
    }
    for _, fn in ipairs(fns) do
        local ok, d = pcall(fn)
        if ok and type(d) == "string" and d ~= "" and not Secret(d) then return d end
    end
    return nil
end

local function SpellName(spellID)
    local fns = {
        function() local i = C_Spell.GetSpellInfo(spellID); return i and i.name end,
        function() return (GetSpellInfo(spellID)) end,
    }
    for _, fn in ipairs(fns) do
        local ok, n = pcall(fn)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return nil
end

-- every "N yard(s)" number in a text, in order
local function Yards(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for n in text:gmatch("(%d+%.?%d*)%s*[yY]ards?") do out[#out + 1] = tonumber(n) end
    for n in text:gmatch("(%d+%.?%d*)%s*[yY]d") do out[#out + 1] = tonumber(n) end
    return out
end

------------------------------------------------------------- the report ---

local function Report()
    wipe(db.report or {})
    db.report = { class = ClassName(), at = date("%Y-%m-%d %H:%M"), apis = {}, events = db.events or {} }
    Say("Totem Range probe report (class " .. db.report.class .. ")")
    if db.report.class ~= "SHAMAN" then Say("  (not a Shaman: totem slots will be empty; the other checks still count)") end
    -- apis
    local present, missing = {}, {}
    for _, name in ipairs(APIS) do
        local ok, ty = Exists(name)
        db.report.apis[name] = ok and ty or false
        if ok then tinsert(present, name) else tinsert(missing, name) end
    end
    Say("  game functions found:   " .. table.concat(present, ", "))
    Say("  game functions MISSING: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
    -- events
    local evOk, evNo = {}, {}
    for _, e in ipairs(db.eventsTried or {}) do
        if e.ok then tinsert(evOk, e.name .. " (fired " .. (e.count or 0) .. "x)") else tinsert(evNo, e.name) end
    end
    Say("  events registered:      " .. table.concat(evOk, ", "))
    if #evNo > 0 then Say("  events REFUSED:         " .. table.concat(evNo, ", ")) end
    -- totems
    db.report.totems = ProbeTotems()
    for _, r in ipairs(db.report.totems) do
        Say(string.format("  totem slot %d: %s", r.slot, r.ok
            and ("have=" .. tostring(r[1]) .. " name=" .. tostring(r[2]) .. " start=" .. tostring(r[3]) .. " dur=" .. tostring(r[4]) .. " icon=" .. tostring(r[5]) .. " extra=" .. tostring(r[6]) .. "," .. tostring(r[7]) .. " timeLeft=" .. tostring(r.timeLeft))
            or ("ERROR " .. tostring(r.err))))
    end
    -- position
    db.report.position = ProbePosition()
    local p = db.report.position
    Say("  position: instance=" .. tostring(p.instance) .. "/" .. tostring(p.instanceType) .. "  mapID=" .. tostring(p.mapID))
    Say("    UnitPosition: " .. (type(p.unitPosition) == "table" and table.concat(p.unitPosition, ", ") or tostring(p.unitPosition)) .. (p.unitPositionSecret and "   <-- SECRET: unreadable here" or ""))
    Say("    map position: " .. (type(p.mapPosition) == "table" and table.concat(p.mapPosition, ", ") or tostring(p.mapPosition)))
    Say("    world position: " .. (type(p.worldPos) == "table" and table.concat(p.worldPos, ", ") or tostring(p.worldPos)))
    -- minimap
    db.report.minimap = ProbeMinimap()
    local m = db.report.minimap
    Say("  minimap: viewRadius=" .. tostring(m.viewRadius) .. " zoom=" .. tostring(m.zoom) .. " width=" .. tostring(m.width)
        .. " scale=" .. tostring(m.effectiveScale) .. " rotate=" .. tostring(m.rotateMinimap)
        .. " canAnchorTexture=" .. tostring(m.canAnchorTextureToMinimap))
    Say("  logged casts so far: " .. #db.log .. " (drop your totems, then /reload to save)")
end

------------------------------------------------------------ cast logging ---

local function LogCast(spellID)
    local entry = { t = date("%H:%M:%S"), spellID = spellID, name = SpellName(spellID) }
    local desc = Description(spellID)
    if desc then
        entry.desc = desc:sub(1, 240)
        entry.yards = Yards(desc)
    end
    entry.position = ProbePosition()
    entry.totems = ProbeTotems()
    tinsert(db.log, entry)
    while #db.log > 60 do tremove(db.log, 1) end
    return entry
end

-- the totem slots lag the cast by a moment: look again shortly after
local function LogCastWithFollowUp(spellID)
    local entry = LogCast(spellID)
    if C_Timer and C_Timer.After then
        C_Timer.After(0.4, function()
            entry.totemsAfter = ProbeTotems()
            entry.positionAfter = ProbePosition()
        end)
    end
    local y = entry.yards and #entry.yards > 0 and table.concat(entry.yards, "/") or "none in text"
    Say(string.format("cast %s (id %s): yards in description: %s", tostring(entry.name or "?"), tostring(spellID), y))
end

------------------------------------------------------------------ events ---

db.events = db.events or {}
db.eventsTried = {}
local frame = CreateFrame("Frame")
local counts = {}
for _, name in ipairs(EVENTS) do
    local ok = pcall(frame.RegisterEvent, frame, name)
    tinsert(db.eventsTried, { name = name, ok = ok and true or false, count = 0 })
end

frame:SetScript("OnEvent", function(_, event, a, b, c)
    for _, e in ipairs(db.eventsTried) do
        if e.name == event then e.count = (e.count or 0) + 1 end
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" and a == "player" then
        -- (unit, castGUID, spellID)
        local id = tonumber(c)
        if id and not Secret(c) then pcall(LogCastWithFollowUp, id) end
    elseif event == "PLAYER_TOTEM_UPDATE" then
        db.lastTotemEvent = { t = date("%H:%M:%S"), slot = Show(a) }
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        db.lastZoneEvent = { t = date("%H:%M:%S"), event = event, mapID = ProbePosition().mapID }
    end
end)

---------------------------------------------------------------- /trprobe ---

SLASH_TOTEMRANGEPROBE1 = "/trprobe"
SlashCmdList["TOTEMRANGEPROBE"] = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "clear" then
        wipe(db.log)
        Say("Log cleared.")
    elseif msg == "log" then
        Say(#db.log .. " logged casts:")
        for i = math.max(1, #db.log - 9), #db.log do
            local e = db.log[i]
            Say(string.format("  %s %s (%s) yards:%s", e.t, tostring(e.name), tostring(e.spellID), e.yards and table.concat(e.yards, "/") or "-"))
        end
    else
        Report()
    end
end

Say("loaded. Type /trprobe for the report; drop your totems, then /reload and send the save file.")
