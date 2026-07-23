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
    priorityEvents = {
        UPDATE_INSTANCE_INFO = true,
        WEEKLY_REWARDS_UPDATE = true,
    },
    debounce = 1.5,
    minInterval = 60,
    expensive = true,
}

function Progression:HandleEvent(_, event)
    if event == "UPDATE_INSTANCE_INFO" then
        self.lockoutsReady = true
    elseif event == "WEEKLY_REWARDS_UPDATE" then
        self.weeklyRewardsReady = true
    end
end

function Progression:ResetStaging()
    self.lockoutsReady = false
    self.lockoutsRequested = false
    self.weeklyRewardsReady = false
end

local function collectCurrencies()
    local result = {}
    local api = _G.C_CurrencyInfo
    if type(api) ~= "table" or type(api.GetCurrencyListSize) ~= "function"
        or type(api.GetCurrencyListInfo) ~= "function" then
        return result, false, false
    end
    local countOk, count = pcall(api.GetCurrencyListSize)
    if not countOk or type(count) ~= "number" or count < 0 then
        return result, false, true
    end
    local ready = true
    for index = 1, count do
        Util.Cooperate(index, 40)
        local infoOk, info = pcall(api.GetCurrencyListInfo, index)
        if not infoOk or info == nil then
            ready = false
        else
            result[#result + 1] = Util.Sanitize(info)
        end
    end
    return result, ready, true
end

local function collectReputations()
    local result = {}
    local api = _G.C_Reputation
    if type(api) == "table" and type(api.GetNumFactions) == "function"
        and type(api.GetFactionDataByIndex) == "function" then
        local countOk, count = pcall(api.GetNumFactions)
        if countOk and type(count) == "number" and count >= 0 then
            local ready = true
            for index = 1, count do
                Util.Cooperate(index, 40)
                local infoOk, info = pcall(api.GetFactionDataByIndex, index)
                if not infoOk or info == nil then
                    ready = false
                elseif not info.isHeader then
                    result[#result + 1] = Util.Sanitize(info)
                end
            end
            return result, ready, true
        end
    end
    if type(_G.GetNumFactions) == "function" and type(_G.GetFactionInfo) == "function" then
        local countOk, count = pcall(_G.GetNumFactions)
        if not countOk or type(count) ~= "number" or count < 0 then
            return result, false, true
        end
        local ready = true
        for index = 1, count do
            Util.Cooperate(index, 40)
            local infoOk, name, description, standingID, bottomValue, topValue, earnedValue,
                atWar, canToggleAtWar, isHeader, isCollapsed, hasRep, isWatched, isChild, factionID =
                pcall(_G.GetFactionInfo, index)
            if not infoOk or name == nil then
                ready = false
            elseif not isHeader then
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
        return result, ready, true
    end
    local available = type(api) == "table"
        and (type(api.GetNumFactions) == "function" or type(api.GetFactionDataByIndex) == "function")
    return result, false, available
end

local function collectMajorFactions()
    local result = {}
    local api = _G.C_MajorFactions
    if type(api) ~= "table" or type(api.GetMajorFactionIDs) ~= "function"
        or type(api.GetMajorFactionData) ~= "function" then
        return result, false, false
    end
    local idsOk, ids = pcall(api.GetMajorFactionIDs)
    if not idsOk or type(ids) ~= "table" or next(ids) == nil then
        return result, false, true
    end
    local ready = true
    for index, factionID in ipairs(ids) do
        Util.Cooperate(index, 20)
        local ok, data = pcall(api.GetMajorFactionData, factionID)
        if ok and data then
            result[#result + 1] = Util.Sanitize(data)
        else
            ready = false
        end
    end
    return result, ready, true
end

local function collectQuests()
    local result = {}
    local api = _G.C_QuestLog
    if type(api) ~= "table" or type(api.GetNumQuestLogEntries) ~= "function"
        or type(api.GetInfo) ~= "function" then
        return result, false, false
    end
    local countOk, count = pcall(api.GetNumQuestLogEntries)
    if not countOk or type(count) ~= "number" or count < 0 then
        return result, false, true
    end
    local ready = true
    for index = 1, count do
        Util.Cooperate(index, 30)
        local infoOk, info = pcall(api.GetInfo, index)
        if not infoOk or info == nil then
            ready = false
        elseif not info.isHeader then
            result[#result + 1] = Util.Sanitize(info)
        end
    end
    return result, ready, true
end

local function collectAchievements()
    local result = {}
    if type(_G.GetCategoryList) ~= "function" or type(_G.GetCategoryNumAchievements) ~= "function"
        or type(_G.GetAchievementInfo) ~= "function" then
        return result, false, false
    end
    local categoriesOk, categories = pcall(_G.GetCategoryList)
    if not categoriesOk or type(categories) ~= "table" or next(categories) == nil then
        return result, false, true
    end
    local ready = true
    local scanned = 0
    for _, categoryID in ipairs(categories) do
        local countOk, count = pcall(_G.GetCategoryNumAchievements, categoryID, true)
        if not countOk or type(count) ~= "number" or count < 0 then
            ready = false
        else
            for index = 1, count do
                scanned = scanned + 1
                Util.Cooperate(scanned, 25)
                local infoOk, achievementID, name, points, completed, month, day, year, description, flags,
                    icon, rewardText, isGuild, wasEarnedByMe, earnedBy =
                    pcall(_G.GetAchievementInfo, categoryID, index)
                if not infoOk or achievementID == nil then
                    ready = false
                elseif completed or wasEarnedByMe then
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
    end
    return result, ready, true
end

local function collectLockouts(eventReady)
    local result = {}
    if type(_G.GetNumSavedInstances) ~= "function" or type(_G.GetSavedInstanceInfo) ~= "function" then
        return result, false, false
    end
    local countOk, count = pcall(_G.GetNumSavedInstances)
    if not countOk or type(count) ~= "number" or count < 0 then
        return result, false, true
    end
    local ready = count > 0 or eventReady == true
    for index = 1, count do
        Util.Cooperate(index, 20)
        local infoOk, name, lockoutID, reset, difficultyID, locked, extended, instanceIDMostSig,
            isRaid, maxPlayers, difficultyName, numEncounters, encounterProgress =
            pcall(_G.GetSavedInstanceInfo, index)
        if not infoOk or name == nil then
            ready = false
        else
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
    end
    return result, ready, true
end

local function collectWeeklyRewards(eventReady)
    local api = _G.C_WeeklyRewards
    if type(api) ~= "table" or type(api.GetActivities) ~= "function" then
        return {}, false, false
    end
    local ok, activities = pcall(api.GetActivities)
    if not ok or type(activities) ~= "table" then
        return {}, false, true
    end
    local ready = next(activities) ~= nil or eventReady == true
    return Util.Sanitize(activities), ready, true
end

function Progression:Collect(context)
    if not self.lockoutsReady and not self.lockoutsRequested and type(_G.RequestRaidInfo) == "function" then
        local ok = pcall(_G.RequestRaidInfo)
        if ok then
            self.lockoutsRequested = true
        end
    end
    local currencies, currenciesReady, currenciesAvailable = collectCurrencies()
    local reputations, reputationsReady, reputationsAvailable = collectReputations()
    local majorFactions, majorFactionsReady, majorFactionsAvailable = collectMajorFactions()
    local quests, questsReady, questsAvailable = collectQuests()
    local achievements, achievementsReady, achievementsAvailable = collectAchievements()
    local lockouts, lockoutsReady, lockoutsAvailable = collectLockouts(self.lockoutsReady)
    local weeklyRewards, weeklyRewardsReady, weeklyRewardsAvailable =
        collectWeeklyRewards(self.weeklyRewardsReady)
    local payload = {
        currencies = currencies,
        reputations = reputations,
        majorFactions = majorFactions,
        quests = quests,
        achievements = achievements,
        lockouts = lockouts,
        weeklyRewards = weeklyRewards,
    }
    local capability = {
        currencies = currenciesReady,
        reputations = reputationsReady,
        majorFactions = majorFactionsReady,
        quests = questsReady,
        achievements = achievementsReady,
        lockouts = lockoutsReady,
        weeklyRewards = weeklyRewardsReady,
    }
    local availability = {
        currencies = currenciesAvailable,
        reputations = reputationsAvailable,
        majorFactions = majorFactionsAvailable,
        quests = questsAvailable,
        achievements = achievementsAvailable,
        lockouts = lockoutsAvailable,
        weeklyRewards = weeklyRewardsAvailable,
    }
    local allReady = currenciesReady and reputationsReady and majorFactionsReady
        and questsReady and achievementsReady and lockoutsReady and weeklyRewardsReady
    local anyAvailable = currenciesAvailable or reputationsAvailable or majorFactionsAvailable
        or questsAvailable or achievementsAvailable or lockoutsAvailable or weeklyRewardsAvailable
    local coverage
    if allReady then
        capability.currencyCount = #currencies
        capability.reputationCount = #reputations
        capability.majorFactionCount = #majorFactions
        capability.questCount = #quests
        capability.achievementCount = #achievements
        capability.lockoutCount = #lockouts
        capability.weeklyRewardCount = #weeklyRewards
        capability.apiAvailability = availability
        coverage = Coverage.Complete(capability)
    elseif anyAvailable then
        local unavailable = {}
        local pending = {}
        for key, value in pairs(capability) do
            if value ~= true then
                if availability[key] then
                    pending[#pending + 1] = key
                else
                    unavailable[#unavailable + 1] = key
                end
            end
        end
        table.sort(unavailable)
        table.sort(pending)
        capability.apiAvailability = availability
        capability.unavailableProgressionApis = unavailable
        capability.pendingProgressionApis = pending
        capability.opportunity = "Progression APIs load incrementally; EmberSync retries after quest, currency, reputation, lockout, and weekly-reward updates."
        capability.actionNeeded = false
        coverage = Coverage.Partial("progression_apis_load_incrementally", capability)
    else
        coverage = Coverage.Unsupported("progression_apis_unavailable", {
            actionNeeded = false,
            opportunity = "This game client did not expose the supported progression APIs.",
        })
    end
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Progression)
