local _, EmberSync = ...

local Constants = EmberSync.Constants
local Util = {}

function Util.IsSecret(value)
    if type(_G.issecretvalue) ~= "function" then
        return false
    end
    local ok, result = pcall(_G.issecretvalue, value)
    return ok and result == true
end

function Util.SafeString(value, allowEmpty)
    if Util.IsSecret(value) or type(value) ~= "string" then
        return nil
    end
    if not allowEmpty and value == "" then
        return nil
    end
    return value
end

function Util.SafeNumber(value)
    if Util.IsSecret(value) or type(value) ~= "number"
        or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

function Util.SafeBoolean(value)
    if Util.IsSecret(value) or type(value) ~= "boolean" then
        return nil
    end
    return value
end

function Util.IsPlayerGUID(value)
    value = Util.SafeString(value, false)
    return value ~= nil and value:match("^Player%-%d+%-%x+$") ~= nil
end

local function trim(value)
    if _G.strtrim then
        return _G.strtrim(value)
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.NormalizeGuildName(value)
    value = Util.SafeString(value, true)
    if value == nil then
        return nil
    end
    -- The allowlisted names are ASCII. WoW's Lua runtime does not provide a
    -- general Unicode NFC primitive, so invalid/non-ASCII lookalikes fail closed.
    value = trim(value):gsub("%s+", " ")
    return string.lower(value)
end

function Util.NormalizeRealm(value)
    value = Util.SafeString(value, true)
    if value == nil then
        return nil
    end
    value = string.lower(trim(value))
    return (value:gsub("[%s%-'’]", ""))
end

function Util.Now()
    if type(_G.GetServerTime) == "function" then
        local ok, value = pcall(_G.GetServerTime)
        value = ok and Util.SafeNumber(value) or nil
        if value then
            return value
        end
    end
    if type(_G.time) == "function" then
        local ok, value = pcall(_G.time)
        value = ok and Util.SafeNumber(value) or nil
        if value then
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
        local message = Util.SafeString(packed[2], true)
        return false, message or "protected_or_unreadable_error"
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
        value = ok and Util.SafeNumber(value) or nil
        if value then
            return value
        end
    end
    if type(_G.GetTime) == "function" then
        local ok, value = pcall(_G.GetTime)
        value = ok and Util.SafeNumber(value) or nil
        if value then
            return value
        end
    end
    return os and os.clock and os.clock() or 0
end

function Util.ProfileMilliseconds()
    if type(_G.debugprofilestop) == "function" then
        local ok, value = pcall(_G.debugprofilestop)
        value = ok and Util.SafeNumber(value) or nil
        if value then
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
    if Util.IsSecret(value) then
        return nil
    end
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
        if not Util.IsSecret(key) and (type(key) == "string" or type(key) == "number") then
            local copiedKey = Util.Copy(key, seen)
            if copiedKey ~= nil then
                copied[copiedKey] = Util.Copy(child, seen)
            end
        end
    end
    seen[value] = nil
    return copied
end

function Util.Sanitize(value, options, state, depth)
    options = options or {}
    state = state or { entries = 0, seen = {}, truncated = false }
    depth = depth or 0
    if Util.IsSecret(value) then
        state.truncated = true
        state.secretValuesOmitted = (state.secretValuesOmitted or 0) + 1
        return nil, state
    end
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
        if Util.IsSecret(key) then
            state.truncated = true
            state.secretValuesOmitted = (state.secretValuesOmitted or 0) + 1
        elseif keyType == "string" or keyType == "number" then
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
    if Util.IsSecret(value) then
        return 0
    end
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
    if Util.IsSecret(left) or Util.IsSecret(right) then
        return false
    end
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
        if Util.IsSecret(key) then
            return false
        end
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
        if Util.IsSecret(key) then
            return false
        end
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
        local values = { pcall(_G.UnitFullName, "player") }
        if values[1] then
            name, realm = values[2], values[3]
        end
    elseif type(_G.UnitName) == "function" then
        local values = { pcall(_G.UnitName, "player") }
        if values[1] then
            name, realm = values[2], values[3]
        end
    end
    name = Util.SafeString(name, true)
    realm = Util.SafeString(realm, true)
    if not realm or realm == "" then
        if type(_G.GetRealmName) == "function" then
            local ok, value = pcall(_G.GetRealmName)
            realm = ok and Util.SafeString(value, true) or nil
        end
    end
    local guid
    if type(_G.UnitGUID) == "function" then
        local ok, value = pcall(_G.UnitGUID, "player")
        guid = ok and Util.SafeString(value, false) or nil
        if guid and not Util.IsPlayerGUID(guid) then
            guid = nil
        end
    end
    return {
        id = guid,
        name = name,
        realm = realm,
        rankIndex = Util.SafeNumber(rankIndex),
    }
end

local INSTALLATION_ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function hash32(value, seed)
    local hash = seed
    for index = 1, #value do
        -- Multiplier 33 keeps every intermediate below Lua's exact 53-bit
        -- integer range, so the migration is identical in Lua, Rust, and JS.
        hash = (hash * 33 + string.byte(value, index) + index) % 4294967296
    end
    return math.floor(hash)
end

local function appendUint32Bytes(bytes, value)
    bytes[#bytes + 1] = math.floor(value / 16777216) % 256
    bytes[#bytes + 1] = math.floor(value / 65536) % 256
    bytes[#bytes + 1] = math.floor(value / 256) % 256
    bytes[#bytes + 1] = value % 256
end

local function encodeInstallationSeed(seed)
    local bytes = {}
    appendUint32Bytes(bytes, hash32(seed, 5381))
    appendUint32Bytes(bytes, hash32(seed, 52711))
    appendUint32Bytes(bytes, hash32(seed, 1315423911))
    local output = {}
    for index = 1, #bytes, 3 do
        local value = bytes[index] * 65536 + bytes[index + 1] * 256 + bytes[index + 2]
        output[#output + 1] = string.sub(INSTALLATION_ID_ALPHABET, math.floor(value / 262144) % 64 + 1,
            math.floor(value / 262144) % 64 + 1)
        output[#output + 1] = string.sub(INSTALLATION_ID_ALPHABET, math.floor(value / 4096) % 64 + 1,
            math.floor(value / 4096) % 64 + 1)
        output[#output + 1] = string.sub(INSTALLATION_ID_ALPHABET, math.floor(value / 64) % 64 + 1,
            math.floor(value / 64) % 64 + 1)
        output[#output + 1] = string.sub(INSTALLATION_ID_ALPHABET, value % 64 + 1, value % 64 + 1)
    end
    return table.concat(output)
end

function Util.NormalizeInstallationId(value)
    value = Util.SafeString(value, false)
    if value and #value == Constants.INSTALLATION_ID_LENGTH and value:match("^[A-Za-z0-9_-]+$") then
        return value, false
    end
    local seed = value
    if not seed then
        local guid = ""
        if type(_G.UnitGUID) == "function" then
            local ok, candidate = pcall(_G.UnitGUID, "player")
            guid = ok and Util.SafeString(candidate, true) or ""
        end
        seed = table.concat({
            tostring(Util.Now()),
            guid,
            tostring(math.random(100000, 999999999)),
            tostring(math.random(0, 2147483647)),
        }, ":")
    end
    return encodeInstallationSeed(seed), value ~= nil
end

function Util.MakeInstallationId()
    local value = Util.NormalizeInstallationId(nil)
    return value
end

function Util.TableCount(value)
    local count = 0
    if not Util.IsSecret(value) and type(value) == "table" then
        for _ in pairs(value) do
            count = count + 1
        end
    end
    return count
end

EmberSync:RegisterModule("Util", Util)
