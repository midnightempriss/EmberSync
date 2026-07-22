local _, EmberSync = ...

local Constants = EmberSync.Constants
local Util = {}

local function trim(value)
    if _G.strtrim then
        return _G.strtrim(value)
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.NormalizeGuildName(value)
    if type(value) ~= "string" then
        return nil
    end
    -- The allowlisted names are ASCII. WoW's Lua runtime does not provide a
    -- general Unicode NFC primitive, so invalid/non-ASCII lookalikes fail closed.
    value = trim(value):gsub("%s+", " ")
    return string.lower(value)
end

function Util.NormalizeRealm(value)
    if type(value) ~= "string" then
        return nil
    end
    value = string.lower(trim(value))
    return (value:gsub("[%s%-'’]", ""))
end

function Util.Now()
    if type(_G.GetServerTime) == "function" then
        local ok, value = pcall(_G.GetServerTime)
        if ok and type(value) == "number" then
            return value
        end
    end
    if type(_G.time) == "function" then
        local ok, value = pcall(_G.time)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os and os.time and os.time() or 0
end

function Util.SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false, "unsupported"
    end
    local packed = { pcall(fn, ...) }
    if not packed[1] then
        return false, tostring(packed[2])
    end
    table.remove(packed, 1)
    return true, unpack(packed)
end

-- Large catalog walks and SavedVariables normalization must never monopolize a
-- rendered frame. CollectorManager runs collection inside coroutines; yielding
-- here lets it resume bounded chunks on later frames. Direct calls made during
-- logout or by tests stay synchronous because there is no running coroutine.
function Util.Cooperate(index, interval)
    interval = interval or Constants.COOPERATIVE_WORK_INTERVAL or 200
    if type(index) ~= "number" or interval < 1 or index % interval ~= 0
        or type(_G.coroutine) ~= "table" or type(_G.coroutine.running) ~= "function"
        or type(_G.coroutine.yield) ~= "function" then
        return false
    end
    local thread, isMain = _G.coroutine.running()
    if thread and not isMain then
        _G.coroutine.yield("embersync_work_slice")
        return true
    end
    return false
end

function Util.MonotonicTime()
    if type(_G.GetTimePreciseSec) == "function" then
        local ok, value = pcall(_G.GetTimePreciseSec)
        if ok and type(value) == "number" then
            return value
        end
    end
    if type(_G.GetTime) == "function" then
        local ok, value = pcall(_G.GetTime)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os and os.clock and os.clock() or 0
end

function Util.ProfileMilliseconds()
    if type(_G.debugprofilestop) == "function" then
        local ok, value = pcall(_G.debugprofilestop)
        if ok and type(value) == "number" then
            return value
        end
    end
    return Util.MonotonicTime() * 1000
end

function Util.CallPath(root, name, ...)
    if type(root) ~= "table" then
        return false, "unsupported"
    end
    return Util.SafeCall(root[name], ...)
end

function Util.Copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true
    local copied = {}
    for key, child in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            copied[Util.Copy(key, seen)] = Util.Copy(child, seen)
        end
    end
    seen[value] = nil
    return copied
end

function Util.Sanitize(value, options, state, depth)
    options = options or {}
    state = state or { entries = 0, seen = {}, truncated = false }
    depth = depth or 0
    local valueType = type(value)

    if valueType == "nil" or valueType == "boolean" then
        return value, state
    end
    if valueType == "string" then
        local maxStringBytes = options.maxStringBytes or 65536
        if #value > maxStringBytes then
            state.truncated = true
            return string.sub(value, 1, maxStringBytes), state
        end
        return value, state
    end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            state.truncated = true
            return nil, state
        end
        return value, state
    end
    if valueType ~= "table" then
        state.truncated = true
        return nil, state
    end

    local maxDepth = options.maxDepth or Constants.MAX_SANITIZE_DEPTH
    local maxEntries = options.maxEntries or Constants.MAX_SANITIZE_ENTRIES
    if depth >= maxDepth or state.seen[value] then
        state.truncated = true
        return nil, state
    end

    state.seen[value] = true
    local output = {}
    for key, child in pairs(value) do
        if state.entries >= maxEntries then
            state.truncated = true
            break
        end
        local keyType = type(key)
        if keyType == "string" or keyType == "number" then
            state.entries = state.entries + 1
            Util.Cooperate(state.entries)
            local cleanChild = Util.Sanitize(child, options, state, depth + 1)
            if cleanChild ~= nil then
                output[key] = cleanChild
            end
        else
            state.truncated = true
        end
    end
    state.seen[value] = nil
    return output, state
end

function Util.EstimateSize(value, seen, state)
    local valueType = type(value)
    if valueType == "nil" then
        return 0
    elseif valueType == "boolean" then
        return 1
    elseif valueType == "number" then
        return 16
    elseif valueType == "string" then
        return #value + 8
    elseif valueType ~= "table" then
        return 0
    end
    seen = seen or {}
    state = state or { entries = 0 }
    if seen[value] then
        return 0
    end
    seen[value] = true
    local size = 8
    for key, child in pairs(value) do
        state.entries = state.entries + 1
        Util.Cooperate(state.entries)
        size = size + Util.EstimateSize(key, seen, state) + Util.EstimateSize(child, seen, state)
    end
    return size
end

function Util.DeepEqual(left, right, state)
    if left == right then
        return true
    end
    if type(left) ~= type(right) or type(left) ~= "table" then
        return false
    end
    state = state or { entries = 0, seen = {} }
    if state.seen[left] == right then
        return true
    end
    state.seen[left] = right
    for key, value in pairs(left) do
        state.entries = state.entries + 1
        Util.Cooperate(state.entries)
        if right[key] == nil and value ~= nil then
            return false
        end
        if not Util.DeepEqual(value, right[key], state) then
            return false
        end
    end
    for key in pairs(right) do
        state.entries = state.entries + 1
        Util.Cooperate(state.entries)
        if left[key] == nil and right[key] ~= nil then
            return false
        end
    end
    return true
end

function Util.Array(...)
    local count = select("#", ...)
    local result = {}
    for index = 1, count do
        result[index] = select(index, ...)
    end
    return result
end

function Util.GetPlayerIdentity(rankIndex)
    local name, realm
    if type(_G.UnitFullName) == "function" then
        name, realm = _G.UnitFullName("player")
    elseif type(_G.UnitName) == "function" then
        name, realm = _G.UnitName("player")
    end
    if not realm or realm == "" then
        realm = type(_G.GetRealmName) == "function" and _G.GetRealmName() or nil
    end
    return {
        id = type(_G.UnitGUID) == "function" and _G.UnitGUID("player") or nil,
        name = name,
        realm = realm,
        rankIndex = rankIndex,
    }
end

function Util.MakeInstallationId()
    local guid = type(_G.UnitGUID) == "function" and (_G.UnitGUID("player") or "") or ""
    local seed = tostring(Util.Now()) .. ":" .. guid .. ":" .. tostring(math.random(100000, 999999999))
    local hash = 2166136261
    for index = 1, #seed do
        hash = (hash * 16777619 + string.byte(seed, index)) % 4294967296
    end
    return "es-" .. tostring(math.floor(hash)) .. "-" .. tostring(math.random(0, 2147483647))
end

function Util.TableCount(value)
    local count = 0
    if type(value) == "table" then
        for _ in pairs(value) do
            count = count + 1
        end
    end
    return count
end

EmberSync:RegisterModule("Util", Util)
