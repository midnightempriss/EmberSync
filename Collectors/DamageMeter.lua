local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local DamageMeter = {
    name = "damage_meter",
    scope = "character",
    events = {
        "DAMAGE_METER_COMBAT_SESSION_UPDATED",
        "DAMAGE_METER_CURRENT_SESSION_UPDATED",
        "DAMAGE_METER_RESET",
        "PLAYER_REGEN_ENABLED",
    },
    debounce = 2,
}

function DamageMeter:Collect(context)
    local api = _G.C_DamageMeter
    if type(api) ~= "table" or type(api.IsDamageMeterAvailable) ~= "function"
        or type(api.GetAvailableCombatSessions) ~= "function" then
        return {}, Coverage.Unsupported("damage_meter_api_unavailable"), context.sourceCharacter.id
    end
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        return {}, Coverage.Unavailable("combat_in_progress"), context.sourceCharacter.id
    end
    local ok, available = pcall(api.IsDamageMeterAvailable)
    if not ok or not available then
        return {}, Coverage.Unavailable("damage_meter_not_available"), context.sourceCharacter.id
    end
    local sessions = {}
    local listOk, availableSessions = pcall(api.GetAvailableCombatSessions)
    if listOk and type(availableSessions) == "table" then
        for index = 1, math.min(#availableSessions, 25) do
            local descriptor = availableSessions[index]
            local session
            if type(descriptor) == "table" and descriptor.sessionID and type(api.GetCombatSessionFromID) == "function" then
                local sessionOk, value = pcall(api.GetCombatSessionFromID, descriptor.sessionID)
                session = sessionOk and value or nil
            end
            sessions[#sessions + 1] = {
                descriptor = Util.Sanitize(descriptor),
                session = Util.Sanitize(session),
            }
        end
    end
    return { sessions = sessions, rawCombatEventsIncluded = false }, Coverage.Complete({ sessionCount = #sessions }),
        context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(DamageMeter)
