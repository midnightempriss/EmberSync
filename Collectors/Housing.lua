local _, EmberSync = ...

local Constants = EmberSync.Constants
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
        "NEIGHBORHOOD_LIST_UPDATED",
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
    discoveredNeighborhoods = nil,
    discoveredNeighborhoodsObservedAt = nil,
    lastDiscoveryRequestAt = nil,
    stagingGuildKey = nil,
    stagingSourceCharacterId = nil,
    stagingNeighborhoodGUID = nil,
    pendingInitiativeEvents = {},
    lastVerifiedContext = nil,
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

local function nonEmptyGUID(value)
    return Util.SafeString(value, false)
end

local function getRuntimeNeighborhoodGUID()
    local activeNeighborhood
    if type(_G.C_NeighborhoodInitiative) == "table"
        and type(_G.C_NeighborhoodInitiative.GetActiveNeighborhood) == "function" then
        local ok, value = pcall(_G.C_NeighborhoodInitiative.GetActiveNeighborhood)
        activeNeighborhood = ok and nonEmptyGUID(value) or nil
    end
    if activeNeighborhood then
        return activeNeighborhood
    end

    if type(_G.C_Housing) == "table" and type(_G.C_Housing.GetCurrentNeighborhoodGUID) == "function" then
        local ok, value = pcall(_G.C_Housing.GetCurrentNeighborhoodGUID)
        return ok and nonEmptyGUID(value) or nil
    end
    return nil
end

local function clearStagingData(self)
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
    self.pendingInitiativeEvents = {}
    self.lastVerifiedContext = nil
end

local function ensureStagingContext(self, context, neighborhoodGUID)
    local guildKey = type(context.guild) == "table" and context.guild.key or nil
    local sourceCharacterId = type(context.sourceCharacter) == "table" and context.sourceCharacter.id or nil
    local contextChanged = self.stagingGuildKey ~= nil and (
        self.stagingGuildKey ~= guildKey
        or self.stagingSourceCharacterId ~= sourceCharacterId
    )
    local neighborhoodChanged = self.stagingNeighborhoodGUID ~= nil and neighborhoodGUID ~= nil
        and self.stagingNeighborhoodGUID ~= neighborhoodGUID
    if contextChanged or neighborhoodChanged then
        clearStagingData(self)
    end
    self.stagingGuildKey = guildKey
    self.stagingSourceCharacterId = sourceCharacterId
    self.stagingNeighborhoodGUID = neighborhoodGUID or self.stagingNeighborhoodGUID
end

function Housing:HandleEvent(context, event, ...)
    local runtimeNeighborhoodGUID = getRuntimeNeighborhoodGUID()
    ensureStagingContext(self, context, runtimeNeighborhoodGUID)
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
        if nonEmptyGUID(playerGUID) then
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
        neighborhoodGUID = nonEmptyGUID(neighborhoodGUID)
        neighborhoodName = Util.SafeString(neighborhoodName, true)
        local stagedGUID = self.stagingNeighborhoodGUID
        local matchesStagedNeighborhood = stagedGUID ~= nil and stagedGUID == neighborhoodGUID
        local matchesReportedNeighborhood = stagedGUID == nil
            and type(self.neighborhoodInfo) == "table"
            and self.neighborhoodInfo.neighborhoodGUID == neighborhoodGUID
        if type(self.neighborhoodInfo) == "table"
            and (matchesStagedNeighborhood or matchesReportedNeighborhood) then
            self.neighborhoodInfo.neighborhoodName = neighborhoodName
            self.neighborhoodInfoObservedAt = Util.Now()
        end
    elseif event == "NEIGHBORHOOD_LIST_UPDATED" then
        local neighborhoods = ...
        if type(neighborhoods) == "table" then
            self.discoveredNeighborhoods = Util.Sanitize(neighborhoods, {
                maxDepth = 6,
                maxEntries = 5000,
            })
            self.discoveredNeighborhoodsObservedAt = Util.Now()
        end
    elseif event == "INITIATIVE_TASK_COMPLETED" or event == "INITIATIVE_COMPLETED" then
        local label = ...
        if #self.pendingInitiativeEvents >= 100 then
            table.remove(self.pendingInitiativeEvents, 1)
        end
        self.pendingInitiativeEvents[#self.pendingInitiativeEvents + 1] = {
            type = event,
            label = label,
            neighborhoodGUID = runtimeNeighborhoodGUID,
            sourceGuildKey = context.guild.key,
            sourceCharacterId = context.sourceCharacter.id,
            observedAt = Util.Now(),
        }
    end
end

function Housing:ResetStaging()
    clearStagingData(self)
    self.discoveredNeighborhoods = nil
    self.discoveredNeighborhoodsObservedAt = nil
    self.lastDiscoveryRequestAt = nil
    self.stagingGuildKey = nil
    self.stagingSourceCharacterId = nil
    self.stagingNeighborhoodGUID = nil
end

function Housing:Finalize(context)
    local verified = self.lastVerifiedContext
    if type(context) ~= "table" or type(context.guild) ~= "table"
        or type(context.sourceCharacter) ~= "table" or type(verified) ~= "table"
        or verified.guildKey ~= context.guild.key
        or verified.sourceCharacterId ~= context.sourceCharacter.id then
        return
    end
    local pending = self.pendingInitiativeEvents
    self.pendingInitiativeEvents = {}
    for _, event in ipairs(pending) do
        if event.sourceGuildKey == verified.guildKey
            and event.sourceCharacterId == verified.sourceCharacterId
            and event.neighborhoodGUID == verified.neighborhoodGUID then
            Database:AppendEvent("neighborhood_initiative", event)
        end
    end
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

local function entryIsNewer(candidate, existing)
    local candidateDirect = type(candidate) == "table" and candidate.directObservation == true
    local existingDirect = type(existing) == "table" and existing.directObservation == true
    if candidateDirect ~= existingDirect then
        return candidateDirect
    end
    return (tonumber(type(candidate) == "table" and candidate.observedAt) or 0)
        >= (tonumber(type(existing) == "table" and existing.observedAt) or 0)
end

local function mergeEntry(target, key, candidate)
    if type(key) ~= "string" or type(candidate) ~= "table" then
        return
    end
    if target[key] == nil or entryIsNewer(candidate, target[key]) then
        target[key] = Util.Copy(candidate)
    end
end

local function getPreviousNeighborhoodCatalog(context)
    local byGuid = {}
    local bySubdivision = {}
    local export = Database:GetActiveExport(false)
    if type(export) ~= "table" or type(export.datasets) ~= "table" then
        return byGuid, bySubdivision
    end
    for key, envelope in pairs(export.datasets) do
        if type(key) == "string" and string.sub(key, 1, 8) == "housing:"
            and type(envelope) == "table" and envelope.guildKey == context.guild.key
            and type(envelope.payload) == "table" then
            for guid, entry in pairs(type(envelope.payload.neighborhoodsByGuid) == "table"
                and envelope.payload.neighborhoodsByGuid or {}) do
                mergeEntry(byGuid, guid, entry)
            end
            for subdivision, entry in pairs(type(envelope.payload.subdivisionsByIndex) == "table"
                and envelope.payload.subdivisionsByIndex or {}) do
                mergeEntry(bySubdivision, subdivision, entry)
            end
        end
    end
    return byGuid, bySubdivision
end

local DERIVED_LAYOUT_OMIT_KEYS = {
    house = true,
    houseinfo = true,
    owner = true,
    ownerguid = true,
    ownername = true,
    ownertype = true,
    player = true,
    playerguid = true,
    playername = true,
    resident = true,
    residentname = true,
    residenttype = true,
    occupied = true,
    isoccupied = true,
    isowned = true,
    isclaimed = true,
    claimable = true,
    available = true,
    isavailable = true,
    plotstatus = true,
    status = true,
    houseguid = true,
    housename = true,
    name = true,
    guid = true,
}

local function copySharedLayout(value, depth)
    depth = depth or 0
    if Util.IsSecret(value) or depth > 8 then
        return nil
    end
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        local normalizedKey = type(key) == "string" and string.lower(key) or nil
        if not normalizedKey or not DERIVED_LAYOUT_OMIT_KEYS[normalizedKey] then
            local copied = copySharedLayout(child, depth + 1)
            if copied ~= nil then
                result[key] = copied
            end
        end
    end
    return result
end

local function groupRosterBySubdivision(roster)
    local groups = {}
    if type(roster) ~= "table" then
        return groups
    end
    for _, resident in pairs(roster) do
        if type(resident) == "table" then
            local subdivision = Util.SafeNumber(resident.subdivision)
            if subdivision then
                local key = tostring(math.floor(subdivision))
                groups[key] = groups[key] or {}
                groups[key][#groups[key] + 1] = Util.Copy(resident)
            end
        end
    end
    return groups
end

local function sourceSubdivision(roster, sourceCharacterId)
    sourceCharacterId = nonEmptyGUID(sourceCharacterId)
    if type(roster) ~= "table" or not sourceCharacterId then
        return nil
    end
    for _, resident in pairs(roster) do
        if type(resident) == "table" and nonEmptyGUID(resident.playerGUID) == sourceCharacterId then
            local subdivision = Util.SafeNumber(resident.subdivision)
            return subdivision and math.floor(subdivision) or nil
        end
    end
    return nil
end

local function filterDiscoveredNeighborhoods(context, neighborhoods)
    local filtered = {}
    local expectedName = Util.NormalizeGuildName(context.guild.name)
    if type(neighborhoods) ~= "table" or not expectedName then
        return filtered
    end
    for _, entry in pairs(neighborhoods) do
        if type(entry) == "table" then
            local ownerName = entry.ownerName or entry.neighborhoodName or entry.name
            if Util.NormalizeGuildName(ownerName) == expectedName then
                filtered[#filtered + 1] = Util.Copy(entry)
            end
        end
    end
    return filtered
end

local function buildNeighborhoodCatalog(context, payload)
    local byGuid, bySubdivision = getPreviousNeighborhoodCatalog(context)
    local roster = type(payload.neighborhood) == "table" and payload.neighborhood.roster or nil
    local rosterGroups = groupRosterBySubdivision(roster)
    local activeSubdivision = sourceSubdivision(roster, context.sourceCharacter.id)
    local verified = type(payload.guildNeighborhood) == "table"
        and payload.guildNeighborhood.isApprovedGuildNeighborhood == true
    local directGuid = verified and nonEmptyGUID(payload.guildNeighborhood.neighborhoodGUID) or nil
    local directMap = verified and type(payload.neighborhood.mapData) == "table"
        and payload.neighborhood.mapData or nil
    local observedAt = Util.Now()

    for _, discovered in ipairs(type(payload.discovery) == "table"
        and type(payload.discovery.neighborhoods) == "table"
        and payload.discovery.neighborhoods or {}) do
        local guid = nonEmptyGUID(discovered.neighborhoodGUID or discovered.guid)
        local subdivision = Util.SafeNumber(discovered.subdivision or discovered.subdivisionIndex)
        subdivision = subdivision and math.floor(subdivision) or nil
        local candidate = {
            neighborhoodGUID = guid,
            neighborhoodName = discovered.neighborhoodName or discovered.name,
            subdivision = subdivision,
            discovery = Util.Copy(discovered),
            observedAt = payload.discovery.observedAt or observedAt,
            sourceGuildKey = context.guild.key,
            sourceCharacterId = context.sourceCharacter.id,
            provenance = "passive_house_finder",
            discoveryProvenance = "passive_house_finder",
            geometryProvenance = "unavailable",
            availabilityProvenance = "unavailable",
            directObservation = false,
            exactAvailability = false,
        }
        if guid then
            mergeEntry(byGuid, guid, candidate)
        end
        if subdivision ~= nil then
            local subdivisionKey = tostring(subdivision)
            local existing = bySubdivision[subdivisionKey]
            if type(existing) == "table" then
                existing.neighborhoodGUID = existing.neighborhoodGUID or guid
                existing.neighborhoodName = existing.neighborhoodName or candidate.neighborhoodName
                existing.discovery = Util.Copy(discovered)
                existing.discoveryObservedAt = candidate.observedAt
                existing.discoveryProvenance = "passive_house_finder"
            else
                bySubdivision[subdivisionKey] = Util.Copy(candidate)
            end
        end
    end

    if directGuid then
        local direct = {
            neighborhoodGUID = directGuid,
            neighborhoodName = payload.guildNeighborhood.neighborhoodName,
            subdivision = activeSubdivision,
            mapData = Util.Copy(directMap),
            roster = Util.Copy(roster),
            rosterObservedAt = payload.neighborhood.rosterObservedAt,
            neighborhoodInfo = Util.Copy(payload.neighborhood.info),
            initiative = Util.Copy(payload.guildNeighborhood.initiative),
            activityLog = Util.Copy(payload.guildNeighborhood.activityLog),
            observedAt = observedAt,
            sourceGuildKey = context.guild.key,
            sourceCharacterId = context.sourceCharacter.id,
            provenance = "direct",
            geometryProvenance = "direct",
            availabilityProvenance = "direct",
            directObservation = true,
            exactAvailability = type(directMap) == "table",
        }
        mergeEntry(byGuid, directGuid, direct)
        if activeSubdivision ~= nil then
            mergeEntry(bySubdivision, tostring(activeSubdivision), direct)
        end
    end

    local layoutTemplate
    local layoutSourceSubdivision
    if directMap then
        layoutTemplate = copySharedLayout(directMap)
        layoutSourceSubdivision = activeSubdivision
    else
        for subdivision, entry in pairs(bySubdivision) do
            if type(entry) == "table" and entry.directObservation == true
                and type(entry.mapData) == "table" then
                layoutTemplate = copySharedLayout(entry.mapData)
                layoutSourceSubdivision = tonumber(subdivision)
                break
            end
        end
    end

    for subdivision, residents in pairs(rosterGroups) do
        local existing = bySubdivision[subdivision]
        if type(existing) == "table" and existing.directObservation == true then
            existing.roster = Util.Copy(residents)
            existing.rosterObservedAt = payload.neighborhood.rosterObservedAt
            existing.rosterProvenance = "direct_bulletin_roster"
        else
            bySubdivision[subdivision] = {
                subdivision = tonumber(subdivision),
                neighborhoodGUID = type(existing) == "table" and existing.neighborhoodGUID or nil,
                neighborhoodName = type(existing) == "table" and existing.neighborhoodName or nil,
                discovery = type(existing) == "table" and Util.Copy(existing.discovery) or nil,
                discoveryObservedAt = type(existing) == "table" and existing.discoveryObservedAt or nil,
                discoveryProvenance = type(existing) == "table" and existing.discoveryProvenance or nil,
                mapData = Util.Copy(layoutTemplate),
                layoutSourceSubdivision = layoutSourceSubdivision,
                roster = Util.Copy(residents),
                rosterObservedAt = payload.neighborhood.rosterObservedAt,
                observedAt = observedAt,
                sourceGuildKey = context.guild.key,
                sourceCharacterId = context.sourceCharacter.id,
                provenance = "roster-derived/shared-layout",
                geometryProvenance = layoutTemplate and "shared-layout" or "unavailable",
                availabilityProvenance = "roster-derived",
                rosterProvenance = "direct_bulletin_roster",
                directObservation = false,
                exactAvailability = false,
            }
        end
    end

    return byGuid, bySubdivision, Util.TableCount(bySubdivision), activeSubdivision
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

local function rosterContainsSourceCharacter(roster, sourceCharacterId)
    if type(roster) ~= "table" or type(sourceCharacterId) ~= "string" then
        return false
    end
    for _, resident in pairs(roster) do
        if type(resident) == "table" and resident.playerGUID == sourceCharacterId then
            return true
        end
    end
    return false
end

local function classifyGuildNeighborhood(context, payload)
    local neighborhoodInfo = payload.neighborhood.info
    local neighborhoodName = payload.neighborhood.name
    local ownerName = type(neighborhoodInfo) == "table" and neighborhoodInfo.ownerName or nil
    local infoNeighborhoodName = type(neighborhoodInfo) == "table" and neighborhoodInfo.neighborhoodName or nil
    local expectedGuildName = Util.NormalizeGuildName(context.guild.name)
    local ownerNameMatches = Util.NormalizeGuildName(ownerName) == expectedGuildName
    local neighborhoodNameMatches = Util.NormalizeGuildName(neighborhoodName) == expectedGuildName
    local infoNeighborhoodNameMatches = Util.NormalizeGuildName(infoNeighborhoodName) == expectedGuildName
    local reportedNeighborhoodNameMatches = infoNeighborhoodName == nil or infoNeighborhoodNameMatches
    local guildOwnerType = type(_G.Enum) == "table" and type(_G.Enum.NeighborhoodOwnerType) == "table"
        and _G.Enum.NeighborhoodOwnerType.Guild or nil
    local ownerType = type(neighborhoodInfo) == "table"
        and Util.SafeNumber(neighborhoodInfo.neighborhoodOwnerType) or nil
    local ownerTypeMatches = guildOwnerType ~= nil and ownerType == guildOwnerType

    local currentNeighborhoodGUID = nonEmptyGUID(payload.currentNeighborhoodGUID)
    local activeNeighborhoodGUID = nonEmptyGUID(payload.initiative.activeNeighborhood)
    local initiativeNeighborhoodGUID = type(payload.initiative.info) == "table"
        and payload.initiative.info.isLoaded == true
        and nonEmptyGUID(payload.initiative.info.neighborhoodGUID) or nil
    local activityNeighborhoodGUID = type(payload.initiative.activityLog) == "table"
        and payload.initiative.activityLog.isLoaded == true
        and nonEmptyGUID(payload.initiative.activityLog.neighborhoodGUID) or nil
    local reportedNeighborhoodGUID = type(neighborhoodInfo) == "table"
        and nonEmptyGUID(neighborhoodInfo.neighborhoodGUID) or nil
    local neighborhoodGUID = activeNeighborhoodGUID
        or currentNeighborhoodGUID
        or initiativeNeighborhoodGUID
        or activityNeighborhoodGUID
    local guidConsensus = neighborhoodGUID ~= nil
    local guidEvidenceCount = 0
    local function considerGuid(candidate)
        if candidate then
            guidEvidenceCount = guidEvidenceCount + 1
            if candidate ~= neighborhoodGUID then
                guidConsensus = false
            end
        end
    end
    considerGuid(currentNeighborhoodGUID)
    considerGuid(activeNeighborhoodGUID)
    considerGuid(initiativeNeighborhoodGUID)
    considerGuid(activityNeighborhoodGUID)
    local reportedGuidMatches = reportedNeighborhoodGUID == nil
        or neighborhoodGUID == nil
        or reportedNeighborhoodGUID == neighborhoodGUID
    local viewingActiveMatches = payload.initiative.isViewingActiveNeighborhood ~= false
    local sourceCharacterInRoster = rosterContainsSourceCharacter(
        payload.neighborhood.roster,
        context.sourceCharacter.id
    )
    local ownerGUID = type(neighborhoodInfo) == "table" and nonEmptyGUID(neighborhoodInfo.ownerGUID) or nil

    local directlyVerified = neighborhoodNameMatches
        and ownerNameMatches
        and ownerTypeMatches
        and guidConsensus
        and reportedGuidMatches
        and reportedNeighborhoodNameMatches
        and viewingActiveMatches
    -- Retail can return a hybrid bulletin-board object after switching guild
    -- neighborhoods: its visible neighborhood name and owner GUID belong to the
    -- active guild while ownerName/neighborhoodGUID still describe the prior
    -- selection. Accept that narrow case only when three independent live APIs
    -- agree on the active GUID and the authorized source character is present in
    -- the bulletin roster. The inconsistent fields remain diagnostic evidence.
    local apiInconsistencyVerified = neighborhoodNameMatches
        and infoNeighborhoodNameMatches
        and ownerTypeMatches
        and ownerGUID ~= nil
        and guidConsensus
        and guidEvidenceCount >= 3
        and currentNeighborhoodGUID == neighborhoodGUID
        and activeNeighborhoodGUID == neighborhoodGUID
        and initiativeNeighborhoodGUID == neighborhoodGUID
        and viewingActiveMatches
        and sourceCharacterInRoster
    local isApproved = directlyVerified or apiInconsistencyVerified
    local apiIdentityInconsistent = isApproved and (
        not ownerNameMatches
        or not reportedGuidMatches
    )
    local status
    if directlyVerified then
        status = "approved_guild_owner_verified"
    elseif apiInconsistencyVerified then
        status = "approved_guild_context_verified_with_api_inconsistency"
    elseif not guidConsensus then
        status = "neighborhood_guid_mismatch"
    elseif neighborhoodNameMatches and guildOwnerType == nil then
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
        neighborhoodName = neighborhoodName or infoNeighborhoodName,
        ownerGUID = ownerGUID,
        ownerName = ownerName,
        canonicalOwnerName = isApproved and context.guild.name or nil,
        reportedOwnerName = ownerName,
        reportedNeighborhoodGUID = reportedNeighborhoodGUID,
        ownerType = ownerType,
        expectedGuildOwnerType = guildOwnerType,
        ownerNameMatches = ownerNameMatches,
        neighborhoodNameMatches = neighborhoodNameMatches,
        infoNeighborhoodNameMatches = infoNeighborhoodNameMatches,
        reportedNeighborhoodNameMatches = reportedNeighborhoodNameMatches,
        ownerTypeMatches = ownerTypeMatches,
        currentNeighborhoodGUID = currentNeighborhoodGUID,
        activeNeighborhoodGUID = activeNeighborhoodGUID,
        initiativeNeighborhoodGUID = initiativeNeighborhoodGUID,
        activityNeighborhoodGUID = activityNeighborhoodGUID,
        reportedGuidMatches = reportedGuidMatches,
        guidEvidenceCount = guidEvidenceCount,
        guidConsensus = guidConsensus,
        sourceCharacterInRoster = sourceCharacterInRoster,
        apiIdentityInconsistent = apiIdentityInconsistent,
        isApprovedGuildNeighborhood = isApproved,
        verificationStatus = status,
    }
end

local function neighborhoodBlockIsBound(block, neighborhoodGUID)
    return type(block) == "table"
        and block.isLoaded == true
        and neighborhoodGUID ~= nil
        and nonEmptyGUID(block.neighborhoodGUID) == neighborhoodGUID
end

local function summarizeRejectedBlock(block, reason)
    if type(block) ~= "table" then
        return nil
    end
    return {
        isLoaded = block.isLoaded == true,
        reportedNeighborhoodGUID = nonEmptyGUID(block.neighborhoodGUID),
        rejectionReason = reason,
    }
end

local function canonicalizeInconsistentNeighborhoodInfo(payload, context)
    local reportedInfo = payload.neighborhood.info
    if type(reportedInfo) ~= "table" then
        return
    end
    payload.neighborhood.reportedInfo = {
        neighborhoodGUID = reportedInfo.neighborhoodGUID,
        neighborhoodName = reportedInfo.neighborhoodName,
        ownerGUID = reportedInfo.ownerGUID,
        ownerName = reportedInfo.ownerName,
        neighborhoodOwnerType = reportedInfo.neighborhoodOwnerType,
        observedAt = payload.neighborhood.infoObservedAt,
        diagnosticOnly = true,
    }
    local canonicalInfo = Util.Copy(reportedInfo)
    canonicalInfo.neighborhoodGUID = payload.guildNeighborhood.neighborhoodGUID
    canonicalInfo.neighborhoodName = context.guild.name
    canonicalInfo.ownerName = context.guild.name
    canonicalInfo.locationName = nil
    canonicalInfo.apiIdentityInconsistent = true
    payload.neighborhood.info = canonicalInfo
end

local function removeUnverifiedGuildNeighborhoodPayload(payload)
    local verificationStatus = payload.guildNeighborhood.verificationStatus
    payload.currentNeighborhoodGUID = nil
    payload.neighborhood = {
        rejected = true,
        rejectionReason = verificationStatus,
    }
    payload.initiative = {
        rejected = true,
        rejectionReason = verificationStatus,
    }
end

function Housing:Collect(context)
    local housing = _G.C_Housing
    local neighborhood = _G.C_HousingNeighborhood
    local initiative = _G.C_NeighborhoodInitiative
    if type(housing) ~= "table" and type(neighborhood) ~= "table" then
        return {}, Coverage.Unsupported("housing_api_unavailable"), context.sourceCharacter.id
    end
    ensureStagingContext(self, context, getRuntimeNeighborhoodGUID())

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
    self.requestDiagnostics.neighborhoodDiscoverySupported = type(housing) == "table"
        and type(housing.HouseFinderRequestNeighborhoods) == "function"
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
    if not self.lastDiscoveryRequestAt
        or now - self.lastDiscoveryRequestAt >= Constants.HOUSING_DISCOVERY_COOLDOWN_SECONDS then
        local supported, requested = safeRequest(housing, "HouseFinderRequestNeighborhoods")
        self.requestDiagnostics.neighborhoodDiscoverySupported = supported
        self.requestDiagnostics.neighborhoodDiscoverySucceeded = requested
        self.lastDiscoveryRequestAt = now
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
    payload.discovery = {
        neighborhoods = filterDiscoveredNeighborhoods(context, self.discoveredNeighborhoods),
        observedAt = self.discoveredNeighborhoodsObservedAt,
        provenance = "passive_house_finder",
    }

    local hadNeighborhoodInfo = type(payload.neighborhood.info) == "table"
    payload.guildNeighborhood = classifyGuildNeighborhood(context, payload)
    local initiativeBound = neighborhoodBlockIsBound(
        payload.initiative.info,
        payload.guildNeighborhood.neighborhoodGUID
    )
    local activityBound = neighborhoodBlockIsBound(
        payload.initiative.activityLog,
        payload.guildNeighborhood.neighborhoodGUID
    )
    if payload.guildNeighborhood.isApprovedGuildNeighborhood
        and payload.guildNeighborhood.apiIdentityInconsistent then
        canonicalizeInconsistentNeighborhoodInfo(payload, context)
    end
    if payload.guildNeighborhood.isApprovedGuildNeighborhood then
        self.lastVerifiedContext = {
            guildKey = context.guild.key,
            sourceCharacterId = context.sourceCharacter.id,
            neighborhoodGUID = payload.guildNeighborhood.neighborhoodGUID,
        }
        if not initiativeBound then
            payload.initiative.infoRejected = summarizeRejectedBlock(
                payload.initiative.info,
                "initiative_neighborhood_guid_unverified"
            )
            payload.initiative.info = nil
        end
        if not activityBound then
            payload.initiative.activityLogRejected = summarizeRejectedBlock(
                payload.initiative.activityLog,
                "activity_neighborhood_guid_unverified"
            )
            payload.initiative.activityLog = nil
        end
    else
        removeUnverifiedGuildNeighborhoodPayload(payload)
    end

    if initiativeBound and type(payload.initiative.info) == "table" then
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
    if activityBound and type(payload.initiative.activityLog) == "table" then
        payload.guildNeighborhood.activityLog = {
            neighborhoodGUID = payload.initiative.activityLog.neighborhoodGUID,
            isLoaded = payload.initiative.activityLog.isLoaded,
            nextUpdateTime = payload.initiative.activityLog.nextUpdateTime,
            entryCount = type(payload.initiative.activityLog.taskActivity) == "table"
                and #payload.initiative.activityLog.taskActivity or 0,
        }
    end

    payload.neighborhoodsByGuid, payload.subdivisionsByIndex,
        payload.knownSubdivisionCount, payload.activeSubdivision =
        buildNeighborhoodCatalog(context, payload)
    payload.neighborhoodCatalogVersion = Constants.HOUSING_NEIGHBORHOOD_CATALOG_VERSION

    local pendingInitiativeEvents = self.pendingInitiativeEvents
    self.pendingInitiativeEvents = {}
    for _, pendingEvent in ipairs(pendingInitiativeEvents) do
        if payload.guildNeighborhood.isApprovedGuildNeighborhood
            and pendingEvent.sourceGuildKey == context.guild.key
            and pendingEvent.sourceCharacterId == context.sourceCharacter.id
            and pendingEvent.neighborhoodGUID == payload.guildNeighborhood.neighborhoodGUID then
            Database:AppendEvent("neighborhood_initiative", pendingEvent)
        elseif payload.guildNeighborhood.verificationStatus == "neighborhood_info_pending"
            and pendingEvent.sourceGuildKey == context.guild.key
            and pendingEvent.sourceCharacterId == context.sourceCharacter.id then
            self.pendingInitiativeEvents[#self.pendingInitiativeEvents + 1] = pendingEvent
        end
    end

    local hasOwnedHouseData = type(payload.playerOwnedHouses) == "table"
    local initiativeLoaded = payload.guildNeighborhood.isApprovedGuildNeighborhood and initiativeBound
    local activityLoaded = payload.guildNeighborhood.isApprovedGuildNeighborhood and activityBound
    local coverage
    if payload.guildNeighborhood.isApprovedGuildNeighborhood and initiativeLoaded and activityLoaded
        and payload.neighborhood.mapData and self.roster then
        coverage = Coverage.Complete({
            bulletinBoardRosterObservedAt = self.rosterObservedAt,
            initiativeTaskCount = payload.guildNeighborhood.initiative.taskCount,
            initiativeActivityCount = payload.guildNeighborhood.activityLog.entryCount,
            knownSubdivisionCount = payload.knownSubdivisionCount,
            activeSubdivision = payload.activeSubdivision,
        })
    elseif payload.guildNeighborhood.isApprovedGuildNeighborhood then
        coverage = Coverage.Partial("guild_neighborhood_context_partial", {
            initiativeLoaded = initiativeLoaded,
            initiativeActivityLogLoaded = activityLoaded,
            neighborhoodMapLoaded = type(payload.neighborhood.mapData) == "table",
            bulletinBoardRosterLoaded = type(self.roster) == "table",
            knownSubdivisionCount = payload.knownSubdivisionCount,
            activeSubdivision = payload.activeSubdivision,
            opportunity = "Open Housing > Endeavors for progress and activity, and use the guild neighborhood bulletin board for its roster.",
        })
    elseif hadNeighborhoodInfo then
        coverage = Coverage.Interaction("approved_guild_neighborhood_not_active")
        coverage.opportunity = "Select or visit the " .. context.guild.name
            .. " guild neighborhood, then open Housing > Endeavors."
    else
        coverage = Coverage.Interaction("guild_neighborhood_data_pending")
        coverage.opportunity = "Visit the " .. context.guild.name
            .. " guild neighborhood or open its Housing dashboard to load neighborhood data."
    end
    coverage.hasOwnedHouseData = hasOwnedHouseData
    coverage.guildNeighborhoodVerification = payload.guildNeighborhood.verificationStatus
    coverage.guildNeighborhoodApiIdentityInconsistent = payload.guildNeighborhood.apiIdentityInconsistent
    coverage.neighborhoodCatalogVersion = payload.neighborhoodCatalogVersion
    coverage.passiveDiscoverySupported = self.requestDiagnostics.neighborhoodDiscoverySupported
    coverage.passiveDiscoveryObservedAt = self.discoveredNeighborhoodsObservedAt
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Housing)
