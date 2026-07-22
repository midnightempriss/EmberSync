local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local MythicPlus = {
    name = "mythic_plus",
    scope = "character",
    events = {
        "CHALLENGE_MODE_MAPS_UPDATE",
        "CHALLENGE_MODE_COMPLETED",
        "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE",
        "MYTHIC_PLUS_NEW_WEEKLY_RECORD",
        "WEEKLY_REWARDS_UPDATE",
    },
    debounce = 1,
}

local function call(api, method, ...)
    if type(api) ~= "table" or type(api[method]) ~= "function" then
        return nil, false
    end
    local values = { pcall(api[method], ...) }
    if not values[1] then
        return nil, true
    end
    table.remove(values, 1)
    return Util.Sanitize(#values == 1 and values[1] or values), true
end

function MythicPlus:Collect(context)
    local challenge = _G.C_ChallengeMode
    local mythic = _G.C_MythicPlus
    if type(challenge) ~= "table" and type(mythic) ~= "table" then
        return {}, Coverage.Unsupported("mythic_plus_api_unavailable"), context.sourceCharacter.id
    end
    local payload, supported = {}, {}
    payload.mapTable, supported.mapTable = call(challenge, "GetMapTable")
    payload.overallDungeonScore, supported.overallDungeonScore = call(challenge, "GetOverallDungeonScore")
    payload.ownedKeystoneMapID, supported.ownedKeystoneMapID = call(challenge, "GetOwnedKeystoneChallengeMapID")
    payload.ownedKeystoneLevel, supported.ownedKeystoneLevel = call(challenge, "GetOwnedKeystoneLevel")
    payload.currentAffixes, supported.currentAffixes = call(mythic, "GetCurrentAffixes")
    payload.runHistory, supported.runHistory = call(mythic, "GetRunHistory", false, true)
    payload.mapScores = {}
    if type(payload.mapTable) == "table" and type(challenge) == "table"
        and type(challenge.GetMapScoreInfo) == "function" then
        for _, mapID in ipairs(payload.mapTable) do
            local ok, value = pcall(challenge.GetMapScoreInfo, mapID)
            if ok and value then
                payload.mapScores[tostring(mapID)] = Util.Sanitize(value)
            end
        end
        supported.mapScores = true
    end
    payload.supported = supported
    return payload, Coverage.Complete(), context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(MythicPlus)
