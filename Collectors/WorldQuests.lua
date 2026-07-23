local _, EmberSync = ...

local Constants = EmberSync.Constants
local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local WorldQuests = {
    name = "world_quests",
    scope = "character",
    events = {
        "PLAYER_ENTERING_WORLD",
        "ZONE_CHANGED",
        "ZONE_CHANGED_NEW_AREA",
        "QUEST_LOG_UPDATE",
        "QUEST_ACCEPTED",
        "QUEST_TURNED_IN",
        "QUEST_DATA_LOAD_RESULT",
        "TASK_PROGRESS_UPDATE",
        "AREA_POIS_UPDATED",
    },
    priorityEvents = {
        ZONE_CHANGED_NEW_AREA = true,
        AREA_POIS_UPDATED = true,
    },
    debounce = 2,
    minInterval = 60,
    expensive = true,
}

local function getPreviousPayload(context)
    local export = Database:GetActiveExport(false)
    local key = "world_quests:" .. tostring(context.sourceCharacter.id)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets[key] or nil
    if type(envelope) ~= "table" or type(envelope.sourceCharacter) ~= "table"
        or envelope.sourceCharacter.id ~= context.sourceCharacter.id
        or type(envelope.payload) ~= "table" then
        return nil
    end
    return envelope.payload
end

local function safeMapInfo(mapID)
    local api = _G.C_Map
    if type(api) ~= "table" or type(api.GetMapInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(api.GetMapInfo, mapID)
    return ok and type(info) == "table" and Util.Sanitize(info, {
        maxDepth = 5,
        maxEntries = 200,
    }) or nil
end

local function discoverMapIDs(previous)
    local api = _G.C_Map
    if type(api) ~= "table" or type(api.GetBestMapForUnit) ~= "function" then
        return {}, nil, nil
    end
    local currentOk, currentMapID = pcall(api.GetBestMapForUnit, "player")
    currentMapID = currentOk and Util.SafeNumber(currentMapID) or nil
    if not currentMapID then
        return {}, nil, nil
    end

    local ids = {}
    local seen = {}
    local function add(value)
        value = Util.SafeNumber(value)
        value = value and math.floor(value) or nil
        if value and value > 0 and not seen[value] and #ids < Constants.WORLD_QUEST_MAP_LIMIT then
            seen[value] = true
            ids[#ids + 1] = value
        end
    end

    local expansionCatalog = type(Constants.WORLD_QUEST_CURRENT_EXPANSION) == "table"
        and Constants.WORLD_QUEST_CURRENT_EXPANSION or nil
    local expansionRootMapID = expansionCatalog
        and Util.SafeNumber(expansionCatalog.rootMapID) or nil
    local expansionRootInfo = expansionRootMapID and safeMapInfo(expansionRootMapID) or nil
    local hasExpansionCatalog = type(expansionRootInfo) == "table"
        and Util.SafeNumber(expansionRootInfo.mapID) == expansionRootMapID
    if hasExpansionCatalog then
        for _, mapID in ipairs(type(expansionCatalog.mapIDs) == "table"
            and expansionCatalog.mapIDs or {}) do
            add(mapID)
        end
    end
    add(currentMapID)
    local continentType = type(_G.Enum) == "table" and type(_G.Enum.UIMapType) == "table"
        and _G.Enum.UIMapType.Continent or 2
    local rootMapID
    local cursor = currentMapID
    for _ = 1, 10 do
        local info = safeMapInfo(cursor)
        if type(info) ~= "table" then
            break
        end
        if info.mapType == continentType then
            rootMapID = info.mapID or cursor
            break
        end
        local parentMapID = Util.SafeNumber(info.parentMapID)
        if not parentMapID or parentMapID == cursor then
            break
        end
        cursor = parentMapID
    end
    rootMapID = rootMapID or currentMapID

    local catalogRootMapID = hasExpansionCatalog and expansionRootMapID or rootMapID
    if type(api.GetMapChildrenInfo) == "function"
        and (not hasExpansionCatalog or rootMapID == expansionRootMapID) then
        local ok, children = pcall(api.GetMapChildrenInfo, catalogRootMapID, nil, true)
        if ok and type(children) == "table" then
            table.sort(children, function(left, right)
                local leftMapID = type(left) == "table" and Util.SafeNumber(left.mapID) or nil
                local rightMapID = type(right) == "table" and Util.SafeNumber(right.mapID) or nil
                return (leftMapID or 0) < (rightMapID or 0)
            end)
            local zoneType = type(_G.Enum) == "table" and type(_G.Enum.UIMapType) == "table"
                and _G.Enum.UIMapType.Zone or 3
            for _, child in ipairs(children) do
                if type(child) == "table" and (child.mapType == zoneType or child.mapID == currentMapID) then
                    add(child.mapID)
                end
            end
        end
    end

    -- Maps observed in earlier zero-touch sessions remain eligible, allowing a
    -- player to populate an expansion catalog naturally as they travel.
    if type(previous) == "table"
        and Util.SafeNumber(previous.expansionRootMapID) == catalogRootMapID then
        for mapKey in pairs(type(previous.mapsById) == "table" and previous.mapsById or {}) do
            add(tonumber(mapKey))
        end
    end
    return ids, currentMapID, catalogRootMapID, rootMapID
end

local function safeQuestCall(root, method, ...)
    if type(root) ~= "table" or type(root[method]) ~= "function" then
        return nil, false
    end
    local values = { pcall(root[method], ...) }
    if not values[1] then
        return nil, false
    end
    table.remove(values, 1)
    if #values == 1 then
        return Util.Sanitize(values[1], { maxDepth = 6, maxEntries = 1000 }), true
    end
    return Util.Sanitize(values, { maxDepth = 6, maxEntries = 1000 }), true
end

local function collectItemRewards(questID)
    local rewards = {}
    if type(_G.GetNumQuestLogRewards) ~= "function"
        or type(_G.GetQuestLogRewardInfo) ~= "function" then
        return rewards, false
    end
    local ok, count = pcall(_G.GetNumQuestLogRewards, questID)
    count = ok and Util.SafeNumber(count) or nil
    if not count then
        return rewards, false
    end
    for index = 1, math.min(count, 50) do
        local values = { pcall(_G.GetQuestLogRewardInfo, index, questID) }
        if values[1] then
            rewards[#rewards + 1] = {
                name = values[2],
                texture = values[3],
                quantity = values[4],
                quality = values[5],
                isUsable = values[6],
                itemID = values[7],
                itemLevel = values[8],
            }
        end
    end
    return rewards, true
end

local function collectCurrencyRewards(questID)
    local rewards = {}
    if type(_G.GetNumQuestLogRewardCurrencies) ~= "function"
        or type(_G.GetQuestLogRewardCurrencyInfo) ~= "function" then
        return rewards, false
    end
    local ok, count = pcall(_G.GetNumQuestLogRewardCurrencies, questID)
    count = ok and Util.SafeNumber(count) or nil
    if not count then
        return rewards, false
    end
    for index = 1, math.min(count, 50) do
        local values = { pcall(_G.GetQuestLogRewardCurrencyInfo, index, questID) }
        if values[1] then
            rewards[#rewards + 1] = {
                name = values[2],
                texture = values[3],
                quantity = values[4],
                currencyID = values[5],
                quality = values[6],
            }
        end
    end
    return rewards, true
end

local function collectQuest(candidate, mapID, observedAt)
    if type(candidate) ~= "table" then
        return nil
    end
    local questID = Util.SafeNumber(candidate.questID or candidate.questId)
    questID = questID and math.floor(questID) or nil
    if not questID or questID <= 0 then
        return nil
    end

    if type(_G.C_QuestLog) == "table" and type(_G.C_QuestLog.IsWorldQuest) == "function" then
        local ok, isWorldQuest = pcall(_G.C_QuestLog.IsWorldQuest, questID)
        if ok and Util.SafeBoolean(isWorldQuest) == false then
            return nil
        end
    end

    local taskInfo = {}
    local taskInfoReady = false
    if type(_G.C_TaskQuest) == "table"
        and type(_G.C_TaskQuest.GetQuestInfoByQuestID) == "function" then
        local values = { pcall(_G.C_TaskQuest.GetQuestInfoByQuestID, questID) }
        if values[1] then
            taskInfoReady = true
            taskInfo = {
                title = values[2],
                factionID = values[3],
                capped = values[4],
            }
        end
    end
    if not Util.SafeString(taskInfo.title, true)
        and type(_G.C_QuestLog) == "table"
        and type(_G.C_QuestLog.GetTitleForQuestID) == "function" then
        local ok, title = pcall(_G.C_QuestLog.GetTitleForQuestID, questID)
        taskInfo.title = ok and Util.SafeString(title, true) or nil
    end

    local objectives, objectivesReady = safeQuestCall(_G.C_QuestLog, "GetQuestObjectives", questID)
    local tagInfo, tagInfoReady = safeQuestCall(_G.C_QuestLog, "GetQuestTagInfo", questID)
    local timeLeftMinutes
    local timeReady = false
    if type(_G.C_TaskQuest) == "table"
        and type(_G.C_TaskQuest.GetQuestTimeLeftMinutes) == "function" then
        local ok, value = pcall(_G.C_TaskQuest.GetQuestTimeLeftMinutes, questID)
        timeLeftMinutes = ok and Util.SafeNumber(value) or nil
        timeReady = ok and timeLeftMinutes ~= nil
    end
    local money
    local moneyReady = false
    if type(_G.GetQuestLogRewardMoney) == "function" then
        local ok, value = pcall(_G.GetQuestLogRewardMoney, questID)
        money = ok and Util.SafeNumber(value) or nil
        moneyReady = ok and money ~= nil
    end
    local experience
    local experienceReady = false
    if type(_G.GetQuestLogRewardXP) == "function" then
        local ok, value = pcall(_G.GetQuestLogRewardXP, questID)
        experience = ok and Util.SafeNumber(value) or nil
        experienceReady = ok and experience ~= nil
    end
    local itemRewards, itemRewardsSupported = collectItemRewards(questID)
    local currencyRewards, currencyRewardsSupported = collectCurrencyRewards(questID)
    return {
        questID = questID,
        title = taskInfo.title,
        factionID = taskInfo.factionID,
        capped = taskInfo.capped,
        mapID = mapID,
        x = candidate.x,
        y = candidate.y,
        inProgress = candidate.inProgress,
        numObjectives = candidate.numObjectives,
        objectives = objectives,
        tagInfo = tagInfo,
        rewards = {
            money = money,
            experience = experience,
            items = itemRewards,
            currencies = currencyRewards,
            itemRewardsSupported = itemRewardsSupported,
            currencyRewardsSupported = currencyRewardsSupported,
        },
        timeLeftMinutes = timeLeftMinutes,
        expiresAt = timeLeftMinutes and observedAt + math.max(0, timeLeftMinutes * 60) or nil,
        observedAt = observedAt,
        provenance = "direct_task_api",
        fieldCoverage = {
            taskInfo = taskInfoReady,
            objectives = objectivesReady,
            tagInfo = tagInfoReady,
            time = timeReady,
            position = Util.SafeNumber(candidate.x) ~= nil and Util.SafeNumber(candidate.y) ~= nil,
            moneyReward = moneyReady,
            experienceReward = experienceReady,
            itemRewards = itemRewardsSupported,
            currencyRewards = currencyRewardsSupported,
        },
    }
end

local function retainUnexpired(previousMap, observedAt)
    if type(previousMap) ~= "table" then
        return nil
    end
    local retained = Util.Copy(previousMap)
    retained.quests = {}
    for _, quest in pairs(type(previousMap.quests) == "table" and previousMap.quests or {}) do
        local expiresAt = type(quest) == "table" and Util.SafeNumber(quest.expiresAt) or nil
        if type(quest) == "table" and (not expiresAt or expiresAt > observedAt) then
            retained.quests[#retained.quests + 1] = Util.Copy(quest)
        end
    end
    retained.provenance = "last_good"
    retained.stale = true
    retained.retainedAt = observedAt
    return retained
end

function WorldQuests:Collect(context)
    local taskApi = _G.C_TaskQuest
    if type(taskApi) ~= "table" or type(taskApi.GetQuestsForPlayerByMapID) ~= "function" then
        return {}, Coverage.Unsupported("world_quest_api_unavailable"), context.sourceCharacter.id
    end

    local previous = getPreviousPayload(context)
    local mapIDs, currentMapID, rootMapID, currentContextRootMapID = discoverMapIDs(previous)
    if #mapIDs == 0 then
        return type(previous) == "table" and Util.Copy(previous) or {},
            Coverage.Interaction("world_quest_map_context_unavailable", {
                retainedLastGood = type(previous) == "table",
            }), context.sourceCharacter.id
    end

    local observedAt = Util.Now()
    local mapsById = {}
    local mapCatalog = {}
    local directMapCount = 0
    local retainedMapCount = 0
    local questCount = 0
    local failedMapIDs = {}
    local missingQuestFieldSet = {}
    local previousMaps = type(previous) == "table" and type(previous.mapsById) == "table"
        and previous.mapsById or {}

    for index, mapID in ipairs(mapIDs) do
        Util.Cooperate(index, 4)
        local ok, candidates = pcall(taskApi.GetQuestsForPlayerByMapID, mapID)
        local mapKey = tostring(mapID)
        local info = safeMapInfo(mapID)
        mapCatalog[#mapCatalog + 1] = {
            mapID = mapID,
            name = type(info) == "table" and info.name or nil,
            mapType = type(info) == "table" and info.mapType or nil,
            parentMapID = type(info) == "table" and info.parentMapID or nil,
        }
        if ok and (candidates == nil or type(candidates) == "table") then
            candidates = type(candidates) == "table" and candidates or {}
            local quests = {}
            local mapMissingFieldSet = {}
            for questIndex, candidate in ipairs(candidates) do
                if questIndex > Constants.WORLD_QUESTS_PER_MAP_LIMIT then
                    break
                end
                Util.Cooperate(questIndex, 25)
                local quest = collectQuest(candidate, mapID, observedAt)
                if quest then
                    quests[#quests + 1] = quest
                    for field, available in pairs(quest.fieldCoverage or {}) do
                        if available ~= true then
                            missingQuestFieldSet[field] = true
                            mapMissingFieldSet[field] = true
                        end
                    end
                end
            end
            local mapMissingFields = {}
            for field in pairs(mapMissingFieldSet) do
                mapMissingFields[#mapMissingFields + 1] = field
            end
            table.sort(mapMissingFields)
            mapsById[mapKey] = {
                mapID = mapID,
                mapInfo = info,
                quests = quests,
                observedAt = observedAt,
                provenance = "direct_task_api",
                stale = false,
                coverage = #mapMissingFields == 0
                    and Coverage.Complete({ questCount = #quests })
                    or Coverage.Partial("world_quest_details_partially_available", {
                        questCount = #quests,
                        missingFields = mapMissingFields,
                    }),
            }
            directMapCount = directMapCount + 1
            questCount = questCount + #quests
        else
            failedMapIDs[#failedMapIDs + 1] = mapID
            local retained = retainUnexpired(previousMaps[mapKey], observedAt)
            if retained then
                mapsById[mapKey] = retained
                retainedMapCount = retainedMapCount + 1
                questCount = questCount + #retained.quests
            else
                mapsById[mapKey] = {
                    mapID = mapID,
                    mapInfo = info,
                    quests = {},
                    observedAt = observedAt,
                    provenance = "unavailable",
                    stale = true,
                    coverage = Coverage.Unavailable("world_quest_map_query_failed"),
                }
            end
        end
    end

    local payload = {
        catalogVersion = Constants.WORLD_QUEST_MAP_CATALOG_VERSION,
        expansionKey = type(Constants.WORLD_QUEST_CURRENT_EXPANSION) == "table"
            and Constants.WORLD_QUEST_CURRENT_EXPANSION.key or nil,
        currentMapID = currentMapID,
        expansionRootMapID = rootMapID,
        currentContextRootMapID = currentContextRootMapID,
        observedAt = observedAt,
        mapCatalog = mapCatalog,
        mapsById = mapsById,
    }
    local missingQuestFields = {}
    for field in pairs(missingQuestFieldSet) do
        missingQuestFields[#missingQuestFields + 1] = field
    end
    table.sort(missingQuestFields)
    local details = {
        catalogVersion = payload.catalogVersion,
        expansionKey = payload.expansionKey,
        mapCount = #mapIDs,
        directMapCount = directMapCount,
        retainedMapCount = retainedMapCount,
        questCount = questCount,
        failedMapIDs = failedMapIDs,
        missingQuestFields = missingQuestFields,
        passive = true,
    }
    local coverage
    if #failedMapIDs > 0 then
        coverage = Coverage.Partial("world_quest_maps_partially_available", details)
    elseif #missingQuestFields > 0 then
        coverage = Coverage.Partial("world_quest_details_partially_available", details)
    else
        coverage = Coverage.Complete(details)
    end
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(WorldQuests)
