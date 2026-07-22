local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local PvP = {
    name = "pvp",
    scope = "character",
    events = {
        "PVP_RATED_STATS_UPDATE",
        "PVP_REWARDS_UPDATE",
        "HONOR_LEVEL_UPDATE",
        "HONOR_XP_UPDATE",
        "PLAYER_PVP_KILLS_CHANGED",
    },
    debounce = 1,
    minInterval = 15,
}

local function collectRated()
    local result = {}
    if type(_G.GetPersonalRatedInfo) ~= "function" then
        return result, false
    end
    for bracketIndex = 1, 6 do
        local rating, seasonBest, weeklyBest, seasonPlayed, seasonWon, weeklyPlayed, weeklyWon,
            lastWeeksBest, hasWon, pvpTier, ranking, roundsSeasonPlayed, roundsSeasonWon,
            roundsWeeklyPlayed, roundsWeeklyWon = _G.GetPersonalRatedInfo(bracketIndex)
        if rating ~= nil then
            result[bracketIndex] = {
                rating = rating,
                seasonBest = seasonBest,
                weeklyBest = weeklyBest,
                seasonPlayed = seasonPlayed,
                seasonWon = seasonWon,
                weeklyPlayed = weeklyPlayed,
                weeklyWon = weeklyWon,
                lastWeeksBest = lastWeeksBest,
                hasWon = hasWon,
                pvpTier = pvpTier,
                ranking = ranking,
                roundsSeasonPlayed = roundsSeasonPlayed,
                roundsSeasonWon = roundsSeasonWon,
                roundsWeeklyPlayed = roundsWeeklyPlayed,
                roundsWeeklyWon = roundsWeeklyWon,
            }
        end
    end
    return result, true
end

function PvP:Collect(context)
    local rated, ratedSupported = collectRated()
    local rewards
    if type(_G.C_PvP) == "table" and type(_G.C_PvP.GetPVPRewards) == "function" then
        local ok, value = pcall(_G.C_PvP.GetPVPRewards)
        rewards = ok and Util.Sanitize(value) or nil
    end
    local payload = {
        rated = rated,
        rewards = rewards,
        honorLevel = type(_G.UnitHonorLevel) == "function" and _G.UnitHonorLevel("player") or nil,
        honorableKills = type(_G.GetPVPLifetimeStats) == "function" and select(1, _G.GetPVPLifetimeStats()) or nil,
    }
    local coverage = ratedSupported and Coverage.Complete() or Coverage.Unsupported("rated_pvp_api_unavailable")
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(PvP)
