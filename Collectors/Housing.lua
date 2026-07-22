local _, EmberSync = ...

local Coverage = EmberSync.Coverage
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
        "NEIGHBORHOOD_INITIATIVE_UPDATED",
        "INITIATIVE_ACTIVITY_LOG_UPDATED",
        "INITIATIVE_TASK_COMPLETED",
        "INITIATIVE_COMPLETED",
    },
    roster = nil,
    rosterObservedAt = nil,
    debounce = 1,
}

function Housing:HandleEvent(_, event, ...)
    if event == "UPDATE_BULLETIN_BOARD_ROSTER" then
        local first = select(1, ...)
        if type(first) == "table" then
            self.roster = Util.Sanitize(first, { maxDepth = 6, maxEntries = 5000 })
            self.rosterObservedAt = Util.Now()
        end
    end
end

function Housing:ResetStaging()
    self.roster = nil
    self.rosterObservedAt = nil
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

function Housing:Collect(context)
    local housing = _G.C_Housing
    local neighborhood = _G.C_HousingNeighborhood
    local initiative = _G.C_NeighborhoodInitiative
    if type(housing) ~= "table" and type(neighborhood) ~= "table" then
        return {}, Coverage.Unsupported("housing_api_unavailable"), context.sourceCharacter.id
    end

    local payload = { supported = {} }
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
    payload.neighborhood.roster = self.roster
    payload.neighborhood.rosterObservedAt = self.rosterObservedAt

    payload.initiative = {}
    payload.initiative.enabled, payload.supported.initiativeEnabled = safeValue(initiative, "IsInitiativeEnabled")
    payload.initiative.hasAccess, payload.supported.initiativeAccess = safeValue(initiative, "PlayerHasInitiativeAccess")
    payload.initiative.activeNeighborhood, payload.supported.activeInitiativeNeighborhood = safeValue(initiative, "GetActiveNeighborhood")
    payload.initiative.info, payload.supported.initiativeInfo = safeValue(initiative, "GetNeighborhoodInitiativeInfo")
    payload.initiative.activityLog, payload.supported.initiativeActivityLog = safeValue(initiative, "GetInitiativeActivityLogInfo")
    payload.initiative.trackedTasks, payload.supported.initiativeTrackedTasks = safeValue(initiative, "GetTrackedInitiativeTasks")
    payload.initiative.availableHouseXP, payload.supported.availableHouseXP = safeValue(initiative, "GetAvailableHouseXP")

    local hasOwnedHouseData = type(payload.playerOwnedHouses) == "table"
    local coverage
    if hasOwnedHouseData and payload.neighborhood.mapData and self.roster then
        coverage = Coverage.Complete({ bulletinBoardRosterObservedAt = self.rosterObservedAt })
    elseif hasOwnedHouseData then
        coverage = Coverage.Partial("housing_context_limited", {
            opportunity = "Visit a house, neighborhood, and bulletin board to capture contextual data.",
        })
    else
        coverage = Coverage.Partial("housing_data_pending", {
            opportunity = "Open Housing or visit a house to load owned-house data.",
        })
    end
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Housing)
