local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local Housing = {
    name = "housing",
    scope = "character",
    events = {
        "CURRENT_HOUSE_INFO_RECIEVED",
        "CURRENT_HOUSE_INFO_UPDATED",
        "HOUSE_INFO_UPDATED",
        "HOUSE_LEVEL_CHANGED",
        "HOUSE_LEVEL_FAVOR_UPDATED",
        "HOUSE_PLOT_ENTERED",
        "HOUSE_PLOT_EXITED",
        "NEIGHBORHOOD_INFO_UPDATED",
        "NEIGHBORHOOD_MAP_DATA_UPDATED",
        "NEIGHBORHOOD_NAME_UPDATED",
        "UPDATE_BULLETIN_BOARD_ROSTER",
        "UPDATE_BULLETIN_BOARD_MEMBER_TYPE",
        "UPDATE_BULLETIN_BOARD_ROSTER_STATUSES",
        "NEIGHBORHOOD_INITIATIVE_UPDATED",
        "INITIATIVE_ACTIVITY_LOG_UPDATED",
        "INITIATIVE_TASK_COMPLETED",
        "INITIATIVE_COMPLETED",
        "INITIATIVE_TASKS_TRACKED_LIST_CHANGED",
        "INITIATIVE_TASKS_TRACKED_UPDATED",
    },
    neighborhoodInfo = nil,
    neighborhoodInfoObservedAt = nil,
    roster = nil,
    rosterObservedAt = nil,
    rosterStatuses = nil,
    rosterStatusesObservedAt = nil,
    rosterMemberUpdates = {},
    lastInfoRequestAt = nil,
    lastActivityRequestAt = nil,
    requestDiagnostics = {},
    debounce = 1,
    minInterval = 5,
}

local function safeRequest(api, method)
    if type(api) ~= "table" or type(api[method]) ~= "function" then
        return false, false
    end
    local ok = pcall(api[method])
    return true, ok
end

function Housing:HandleEvent(context, event, ...)
    if event == "UPDATE_BULLETIN_BOARD_ROSTER" then
        -- Blizzard's documented payload is (neighborhoodInfo, rosterMemberList).
        -- The first public version accidentally stored neighborhoodInfo as the
        -- roster, which is why older exports can show ownerGUID under `roster`.
        local neighborhoodInfo, rosterMemberList = ...
        if type(neighborhoodInfo) == "table" then
            self.neighborhoodInfo = Util.Sanitize(neighborhoodInfo, { maxDepth = 6, maxEntries = 500 })
            self.neighborhoodInfoObservedAt = Util.Now()
        end
        if type(rosterMemberList) == "table" then
            self.roster = Util.Sanitize(rosterMemberList, { maxDepth = 6, maxEntries = 5000 })
            self.rosterObservedAt = Util.Now()
        end
    elseif event == "UPDATE_BULLETIN_BOARD_ROSTER_STATUSES" then
        local rosterMemberList = ...
        if type(rosterMemberList) == "table" then
            self.rosterStatuses = Util.Sanitize(rosterMemberList, { maxDepth = 5, maxEntries = 5000 })
            self.rosterStatusesObservedAt = Util.Now()
        end
    elseif event == "UPDATE_BULLETIN_BOARD_MEMBER_TYPE" then
        local playerGUID, residentType = ...
        if type(playerGUID) == "string" then
            self.rosterMemberUpdates[playerGUID] = {
                playerGUID = playerGUID,
                residentType = residentType,
                observedAt = Util.Now(),
            }
        end
    elseif event == "NEIGHBORHOOD_INFO_UPDATED" then
        local neighborhoodInfo = ...
        if type(neighborhoodInfo) == "table" then
            self.neighborhoodInfo = Util.Sanitize(neighborhoodInfo, { maxDepth = 6, maxEntries = 500 })
            self.neighborhoodInfoObservedAt = Util.Now()
        end
    elseif event == "NEIGHBORHOOD_NAME_UPDATED" then
        local neighborhoodGUID, neighborhoodName = ...
        if type(self.neighborhoodInfo) == "table" and self.neighborhoodInfo.neighborhoodGUID == neighborhoodGUID then
            self.neighborhoodInfo.neighborhoodName = neighborhoodName
            self.neighborhoodInfoObservedAt = Util.Now()
        end
    elseif event == "INITIATIVE_TASK_COMPLETED" or event == "INITIATIVE_COMPLETED" then
        local label = ...
        local activeNeighborhood
        if type(_G.C_NeighborhoodInitiative) == "table"
            and type(_G.C_NeighborhoodInitiative.GetActiveNeighborhood) == "function" then
            local ok, value = pcall(_G.C_NeighborhoodInitiative.GetActiveNeighborhood)
            activeNeighborhood = ok and value or nil
        end
        Database:AppendEvent("neighborhood_initiative", {
            type = event,
            label = label,
            neighborhoodGUID = activeNeighborhood,
            sourceGuildKey = context.guild.key,
            observedAt = Util.Now(),
        })
    end
end

function Housing:ResetStaging()
    self.neighborhoodInfo = nil
    self.neighborhoodInfoObservedAt = nil
    self.roster = nil
    self.rosterObservedAt = nil
    self.rosterStatuses = nil
    self.rosterStatusesObservedAt = nil
    self.rosterMemberUpdates = {}
    self.lastInfoRequestAt = nil
    self.lastActivityRequestAt = nil
    self.requestDiagnostics = {}
end

local function safeValue(api, method, ...)
    if type(api) ~= "table" or type(api[method]) ~= "function" then
        return nil, false
    end
    local results = { pcall(api[method], ...) }
    if not results[1] then
        return nil, true
    end
    table.remove(results, 1)
    if #results == 1 then
        return Util.Sanitize(results[1]), true
    end
    return Util.Sanitize(results), true
end

local function getPreviousPayload(context)
    local export = Database:GetActiveExport(false)
    if type(export) ~= "table" or type(export.datasets) ~= "table" then
        return nil
    end
    local envelope = export.datasets["housing:" .. tostring(context.sourceCharacter.id)]
    return type(envelope) == "table" and type(envelope.payload) == "table" and envelope.payload or nil
end

local function useLastLoaded(current, previous, expectedNeighborhoodGUID)
    if type(current) == "table" and current.isLoaded ~= false then
        return current, false
    end
    if type(previous) == "table" and previous.isLoaded == true
        and (not expectedNeighborhoodGUID or previous.neighborhoodGUID == expectedNeighborhoodGUID) then
        return Util.Copy(previous), true
    end
    return current, false
end

local function classifyGuildNeighborhood(context, neighborhoodInfo, neighborhoodName, activeNeighborhood)
    local ownerName = type(neighborhoodInfo) == "table" and neighborhoodInfo.ownerName or nil
    local ownerNameMatches = Util.NormalizeGuildName(ownerName or neighborhoodName)
        == Util.NormalizeGuildName(context.guild.name)
    local guildOwnerType = type(_G.Enum) == "table" and type(_G.Enum.NeighborhoodOwnerType) == "table"
        and _G.Enum.NeighborhoodOwnerType.Guild or nil
    local ownerType = type(neighborhoodInfo) == "table" and neighborhoodInfo.neighborhoodOwnerType or nil
    local ownerTypeMatches = guildOwnerType ~= nil and ownerType == guildOwnerType
    local neighborhoodGUID = type(neighborhoodInfo) == "table" and neighborhoodInfo.neighborhoodGUID
        or activeNeighborhood
    local status
    if ownerNameMatches and ownerTypeMatches then
        status = "approved_guild_owner_verified"
    elseif ownerNameMatches and guildOwnerType == nil then
        status = "guild_owner_type_unavailable"
    elseif type(neighborhoodInfo) ~= "table" then
        status = "neighborhood_info_pending"
    else
        status = "not_approved_guild_neighborhood"
    end
    return {
        guildKey = context.guild.key,
        expectedGuildName = context.guild.name,
        neighborhoodGUID = neighborhoodGUID,
        neighborhoodName = type(neighborhoodInfo) == "table" and neighborhoodInfo.neighborhoodName
            or neighborhoodName,
        ownerGUID = type(neighborhoodInfo) == "table" and neighborhoodInfo.ownerGUID or nil,
        ownerName = ownerName,
        ownerType = ownerType,
        expectedGuildOwnerType = guildOwnerType,
        ownerNameMatches = ownerNameMatches,
        ownerTypeMatches = ownerTypeMatches,
        isApprovedGuildNeighborhood = ownerNameMatches and ownerTypeMatches,
        verificationStatus = status,
    }
end

function Housing:Collect(context)
    local housing = _G.C_Housing
    local neighborhood = _G.C_HousingNeighborhood
    local initiative = _G.C_NeighborhoodInitiative
    if type(housing) ~= "table" and type(neighborhood) ~= "table" then
        return {}, Coverage.Unsupported("housing_api_unavailable"), context.sourceCharacter.id
    end

    local payload = { supported = {}, requests = {} }
    payload.playerOwnedHouses, payload.supported.playerOwnedHouses = safeValue(housing, "GetPlayerOwnedHouses")
    payload.otherOwnedHouses, payload.supported.otherOwnedHouses = safeValue(housing, "GetOthersOwnedHouses")
    payload.currentHouse, payload.supported.currentHouse = safeValue(housing, "GetCurrentHouseInfo")
    payload.currentHouseLevelFavor, payload.supported.currentHouseLevelFavor = safeValue(housing, "GetCurrentHouseLevelFavor")
    payload.currentNeighborhoodGUID, payload.supported.currentNeighborhoodGUID = safeValue(housing, "GetCurrentNeighborhoodGUID")
    payload.trackedHouseGUID, payload.supported.trackedHouseGUID = safeValue(housing, "GetTrackedHouseGuid")
    payload.accessFlags, payload.supported.accessFlags = safeValue(housing, "GetHousingAccessFlags")
    payload.isInsideHouse, payload.supported.isInsideHouse = safeValue(housing, "IsInsideHouse")
    payload.isInsidePlot, payload.supported.isInsidePlot = safeValue(housing, "IsInsidePlot")
    payload.isInsideOwnHouse, payload.supported.isInsideOwnHouse = safeValue(housing, "IsInsideOwnHouse")

    payload.neighborhood = {}
    payload.neighborhood.name, payload.supported.neighborhoodName = safeValue(neighborhood, "GetNeighborhoodName")
    payload.neighborhood.mapData, payload.supported.neighborhoodMapData = safeValue(neighborhood, "GetNeighborhoodMapData")
    payload.neighborhood.currentTexture, payload.supported.neighborhoodTexture = safeValue(neighborhood, "GetCurrentNeighborhoodTextureSuffix")
    payload.neighborhood.isManager, payload.supported.neighborhoodManager = safeValue(neighborhood, "IsNeighborhoodManager")
    payload.neighborhood.isOwner, payload.supported.neighborhoodOwner = safeValue(neighborhood, "IsNeighborhoodOwner")
    payload.neighborhood.info = self.neighborhoodInfo
    payload.neighborhood.infoObservedAt = self.neighborhoodInfoObservedAt
    payload.neighborhood.roster = self.roster
    payload.neighborhood.rosterObservedAt = self.rosterObservedAt
    payload.neighborhood.rosterStatuses = self.rosterStatuses
    payload.neighborhood.rosterStatusesObservedAt = self.rosterStatusesObservedAt
    payload.neighborhood.rosterMemberUpdates = self.rosterMemberUpdates

    payload.initiative = {}
    payload.initiative.enabled, payload.supported.initiativeEnabled = safeValue(initiative, "IsInitiativeEnabled")
    payload.initiative.hasAccess, payload.supported.initiativeAccess = safeValue(initiative, "PlayerHasInitiativeAccess")
    payload.initiative.activeNeighborhood, payload.supported.activeInitiativeNeighborhood = safeValue(initiative, "GetActiveNeighborhood")
    payload.initiative.isViewingActiveNeighborhood, payload.supported.isViewingActiveNeighborhood =
        safeValue(initiative, "IsViewingActiveNeighborhood")
    payload.initiative.isPlayerInNeighborhoodGroup, payload.supported.isPlayerInNeighborhoodGroup =
        safeValue(initiative, "IsPlayerInNeighborhoodGroup")
    payload.initiative.requiredLevel, payload.supported.initiativeRequiredLevel = safeValue(initiative, "GetRequiredLevel")
    payload.initiative.meetsRequiredLevel, payload.supported.initiativeMeetsRequiredLevel =
        safeValue(initiative, "PlayerMeetsRequiredLevel")
    payload.initiative.info, payload.supported.initiativeInfo = safeValue(initiative, "GetNeighborhoodInitiativeInfo")
    payload.initiative.activityLog, payload.supported.initiativeActivityLog = safeValue(initiative, "GetInitiativeActivityLogInfo")
    payload.initiative.trackedTasks, payload.supported.initiativeTrackedTasks = safeValue(initiative, "GetTrackedInitiativeTasks")
    payload.initiative.availableHouseXP, payload.supported.availableHouseXP = safeValue(initiative, "GetAvailableHouseXP")

    local previous = getPreviousPayload(context)
    local previousInitiative = type(previous) == "table" and previous.initiative or nil
    payload.initiative.info, payload.initiative.infoPreservedFromLastLoaded = useLastLoaded(
        payload.initiative.info,
        type(previousInitiative) == "table" and previousInitiative.info or nil,
        payload.initiative.activeNeighborhood
    )
    payload.initiative.activityLog, payload.initiative.activityLogPreservedFromLastLoaded = useLastLoaded(
        payload.initiative.activityLog,
        type(previousInitiative) == "table" and previousInitiative.activityLog or nil,
        payload.initiative.activeNeighborhood
    )

    local now = Util.MonotonicTime()
    self.requestDiagnostics.currentHouseInfoSupported = type(housing) == "table"
        and type(housing.RequestCurrentHouseInfo) == "function"
    self.requestDiagnostics.neighborhoodInfoSupported = type(neighborhood) == "table"
        and type(neighborhood.RequestNeighborhoodInfo) == "function"
    self.requestDiagnostics.initiativeInfoSupported = type(initiative) == "table"
        and type(initiative.RequestNeighborhoodInitiativeInfo) == "function"
    self.requestDiagnostics.initiativeActivityLogSupported = type(initiative) == "table"
        and type(initiative.RequestInitiativeActivityLog) == "function"
    if not self.lastInfoRequestAt or now - self.lastInfoRequestAt >= 15 then
        local currentSupported, currentRequested = safeRequest(housing, "RequestCurrentHouseInfo")
        local neighborhoodSupported, neighborhoodRequested = safeRequest(neighborhood, "RequestNeighborhoodInfo")
        local initiativeSupported, initiativeRequested = safeRequest(initiative, "RequestNeighborhoodInitiativeInfo")
        self.requestDiagnostics.currentHouseInfoSupported = currentSupported
        self.requestDiagnostics.currentHouseInfoSucceeded = currentRequested
        self.requestDiagnostics.neighborhoodInfoSupported = neighborhoodSupported
        self.requestDiagnostics.neighborhoodInfoSucceeded = neighborhoodRequested
        self.requestDiagnostics.initiativeInfoSupported = initiativeSupported
        self.requestDiagnostics.initiativeInfoSucceeded = initiativeRequested
        self.lastInfoRequestAt = now
    end

    local liveInitiativeInfo = payload.initiative.info
    local canRequestActivity = type(liveInitiativeInfo) == "table" and liveInitiativeInfo.isLoaded == true
        and payload.initiative.isViewingActiveNeighborhood == true
    if canRequestActivity and (not self.lastActivityRequestAt or now - self.lastActivityRequestAt >= 15) then
        local supported, requested = safeRequest(initiative, "RequestInitiativeActivityLog")
        self.requestDiagnostics.initiativeActivityLogSupported = supported
        self.requestDiagnostics.initiativeActivityLogSucceeded = requested
        self.lastActivityRequestAt = now
    end
    self.requestDiagnostics.activityWaitingForInitiative = not canRequestActivity
    payload.requests = Util.Copy(self.requestDiagnostics)

    payload.guildNeighborhood = classifyGuildNeighborhood(
        context,
        payload.neighborhood.info,
        payload.neighborhood.name,
        payload.initiative.activeNeighborhood
    )
    if type(payload.initiative.info) == "table" then
        payload.guildNeighborhood.initiative = {
            neighborhoodGUID = payload.initiative.info.neighborhoodGUID,
            initiativeID = payload.initiative.info.initiativeID,
            currentCycleID = payload.initiative.info.currentCycleID,
            currentProgress = payload.initiative.info.currentProgress,
            progressRequired = payload.initiative.info.progressRequired,
            playerTotalContribution = payload.initiative.info.playerTotalContribution,
            isLoaded = payload.initiative.info.isLoaded,
            taskCount = type(payload.initiative.info.tasks) == "table" and #payload.initiative.info.tasks or 0,
            milestoneCount = type(payload.initiative.info.milestones) == "table" and #payload.initiative.info.milestones or 0,
        }
    end
    if type(payload.initiative.activityLog) == "table" then
        payload.guildNeighborhood.activityLog = {
            neighborhoodGUID = payload.initiative.activityLog.neighborhoodGUID,
            isLoaded = payload.initiative.activityLog.isLoaded,
            nextUpdateTime = payload.initiative.activityLog.nextUpdateTime,
            entryCount = type(payload.initiative.activityLog.taskActivity) == "table"
                and #payload.initiative.activityLog.taskActivity or 0,
        }
    end

    local hasOwnedHouseData = type(payload.playerOwnedHouses) == "table"
    local initiativeLoaded = type(payload.initiative.info) == "table" and payload.initiative.info.isLoaded == true
    local activityLoaded = type(payload.initiative.activityLog) == "table"
        and payload.initiative.activityLog.isLoaded == true
    local coverage
    if payload.guildNeighborhood.isApprovedGuildNeighborhood and initiativeLoaded and activityLoaded
        and payload.neighborhood.mapData and self.roster then
        coverage = Coverage.Complete({
            bulletinBoardRosterObservedAt = self.rosterObservedAt,
            initiativeTaskCount = payload.guildNeighborhood.initiative.taskCount,
            initiativeActivityCount = payload.guildNeighborhood.activityLog.entryCount,
        })
    elseif payload.guildNeighborhood.isApprovedGuildNeighborhood then
        coverage = Coverage.Partial("guild_neighborhood_context_partial", {
            initiativeLoaded = initiativeLoaded,
            initiativeActivityLogLoaded = activityLoaded,
            neighborhoodMapLoaded = type(payload.neighborhood.mapData) == "table",
            bulletinBoardRosterLoaded = type(self.roster) == "table",
            opportunity = "Open Housing > Endeavors for progress and activity, and use the guild neighborhood bulletin board for its roster.",
        })
    elseif type(payload.neighborhood.info) == "table" then
        coverage = Coverage.Interaction("approved_guild_neighborhood_not_active")
        coverage.opportunity = "Select or visit the Raining Embers guild neighborhood, then open Housing > Endeavors."
    else
        coverage = Coverage.Interaction("guild_neighborhood_data_pending")
        coverage.opportunity = "Visit the Raining Embers guild neighborhood or open its Housing dashboard to load neighborhood data."
    end
    coverage.hasOwnedHouseData = hasOwnedHouseData
    coverage.guildNeighborhoodVerification = payload.guildNeighborhood.verificationStatus
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Housing)
