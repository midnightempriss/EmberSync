local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local Progression = {
    name = "progression",
    scope = "character",
    events = {
        "CURRENCY_DISPLAY_UPDATE",
        "QUEST_LOG_UPDATE",
        "ACHIEVEMENT_EARNED",
        "CRITERIA_UPDATE",
        "UPDATE_FACTION",
        "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
        "UPDATE_INSTANCE_INFO",
        "WEEKLY_REWARDS_UPDATE",
    },
    debounce = 1.5,
}

local function collectCurrencies()
    local result = {}
    local api = _G.C_CurrencyInfo
    if type(api) ~= "table" or type(api.GetCurrencyListSize) ~= "function"
        or type(api.GetCurrencyListInfo) ~= "function" then
        return result, false
    end
    for index = 1, (api.GetCurrencyListSize() or 0) do
        local info = api.GetCurrencyListInfo(index)
        if info then
            result[#result + 1] = Util.Sanitize(info)
        end
    end
    return result, true
end

local function collectReputations()
    local result = {}
    local api = _G.C_Reputation
    if type(api) == "table" and type(api.GetNumFactions) == "function"
        and type(api.GetFactionDataByIndex) == "function" then
        for index = 1, (api.GetNumFactions() or 0) do
            local info = api.GetFactionDataByIndex(index)
            if info and not info.isHeader then
                result[#result + 1] = Util.Sanitize(info)
            end
        end
        return result, true
    end
    if type(_G.GetNumFactions) == "function" and type(_G.GetFactionInfo) == "function" then
        for index = 1, (_G.GetNumFactions() or 0) do
            local name, description, standingID, bottomValue, topValue, earnedValue,
                atWar, canToggleAtWar, isHeader, isCollapsed, hasRep, isWatched, isChild, factionID = _G.GetFactionInfo(index)
            if not isHeader then
                result[#result + 1] = {
                    id = factionID,
                    name = name,
                    description = description,
                    standingID = standingID,
                    bottomValue = bottomValue,
                    topValue = topValue,
                    earnedValue = earnedValue,
                    atWar = atWar,
                    canToggleAtWar = canToggleAtWar,
                    hasRep = hasRep,
                    isWatched = isWatched,
                    isChild = isChild,
                }
            end
        end
        return result, true
    end
    return result, false
end

local function collectMajorFactions()
    local result = {}
    local api = _G.C_MajorFactions
    if type(api) ~= "table" or type(api.GetMajorFactionIDs) ~= "function"
        or type(api.GetMajorFactionData) ~= "function" then
        return result, false
    end
    for _, factionID in ipairs(api.GetMajorFactionIDs() or {}) do
        local ok, data = pcall(api.GetMajorFactionData, factionID)
        if ok and data then
            result[#result + 1] = Util.Sanitize(data)
        end
    end
    return result, true
end

local function collectQuests()
    local result = {}
    local api = _G.C_QuestLog
    if type(api) ~= "table" or type(api.GetNumQuestLogEntries) ~= "function"
        or type(api.GetInfo) ~= "function" then
        return result, false
    end
    local count = api.GetNumQuestLogEntries() or 0
    for index = 1, count do
        local info = api.GetInfo(index)
        if info and not info.isHeader then
            result[#result + 1] = Util.Sanitize(info)
        end
    end
    return result, true
end

local function collectAchievements()
    local result = {}
    if type(_G.GetCategoryList) ~= "function" or type(_G.GetCategoryNumAchievements) ~= "function"
        or type(_G.GetAchievementInfo) ~= "function" then
        return result, false
    end
    for _, categoryID in ipairs(_G.GetCategoryList() or {}) do
        local count = _G.GetCategoryNumAchievements(categoryID, true) or 0
        for index = 1, count do
            local achievementID, name, points, completed, month, day, year, description, flags,
                icon, rewardText, isGuild, wasEarnedByMe, earnedBy = _G.GetAchievementInfo(categoryID, index)
            if completed or wasEarnedByMe then
                result[#result + 1] = {
                    id = achievementID,
                    name = name,
                    points = points,
                    completed = completed,
                    completedDate = { month = month, day = day, year = year },
                    description = description,
                    flags = flags,
                    icon = icon,
                    rewardText = rewardText,
                    isGuild = isGuild,
                    wasEarnedByMe = wasEarnedByMe,
                    earnedBy = earnedBy,
                }
            end
        end
    end
    return result, true
end

local function collectLockouts()
    local result = {}
    if type(_G.GetNumSavedInstances) ~= "function" or type(_G.GetSavedInstanceInfo) ~= "function" then
        return result, false
    end
    for index = 1, (_G.GetNumSavedInstances() or 0) do
        local name, lockoutID, reset, difficultyID, locked, extended, instanceIDMostSig,
            isRaid, maxPlayers, difficultyName, numEncounters, encounterProgress = _G.GetSavedInstanceInfo(index)
        result[#result + 1] = {
            name = name,
            lockoutID = lockoutID,
            resetSeconds = reset,
            difficultyID = difficultyID,
            difficultyName = difficultyName,
            locked = locked,
            extended = extended,
            instanceIDMostSig = instanceIDMostSig,
            isRaid = isRaid,
            maxPlayers = maxPlayers,
            numEncounters = numEncounters,
            encounterProgress = encounterProgress,
        }
    end
    return result, true
end

local function collectWeeklyRewards()
    local api = _G.C_WeeklyRewards
    if type(api) ~= "table" or type(api.GetActivities) ~= "function" then
        return {}, false
    end
    local ok, activities = pcall(api.GetActivities)
    return ok and Util.Sanitize(activities) or {}, true
end

function Progression:Collect(context)
    local currencies, currenciesSupported = collectCurrencies()
    local reputations, reputationsSupported = collectReputations()
    local majorFactions, majorFactionsSupported = collectMajorFactions()
    local quests, questsSupported = collectQuests()
    local achievements, achievementsSupported = collectAchievements()
    local lockouts, lockoutsSupported = collectLockouts()
    local weeklyRewards, weeklyRewardsSupported = collectWeeklyRewards()
    local payload = {
        currencies = currencies,
        reputations = reputations,
        majorFactions = majorFactions,
        quests = quests,
        achievements = achievements,
        lockouts = lockouts,
        weeklyRewards = weeklyRewards,
    }
    local supported = currenciesSupported or reputationsSupported or questsSupported or achievementsSupported
    local coverage = supported and Coverage.Partial("progression_apis_load_incrementally", {
        currencies = currenciesSupported,
        reputations = reputationsSupported,
        majorFactions = majorFactionsSupported,
        quests = questsSupported,
        achievements = achievementsSupported,
        lockouts = lockoutsSupported,
        weeklyRewards = weeklyRewardsSupported,
    }) or Coverage.Unsupported("progression_apis_unavailable")
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Progression)
