local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local Collections = {
    name = "collections",
    scope = "account",
    events = {
        "COMPANION_UPDATE",
        "PET_JOURNAL_LIST_UPDATE",
        "TOYS_UPDATED",
        "HEIRLOOMS_UPDATED",
        "TRANSMOG_COLLECTION_UPDATED",
        "NEW_MOUNT_ADDED",
        "NEW_PET_ADDED",
        "NEW_TOY_ADDED",
        "NEW_HOUSING_ITEM_ACQUIRED",
    },
    priorityEvents = {
        NEW_MOUNT_ADDED = true,
        NEW_PET_ADDED = true,
        NEW_TOY_ADDED = true,
        NEW_HOUSING_ITEM_ACQUIRED = true,
    },
    debounce = 2,
    minInterval = 120,
    expensive = true,
}

function Collections:HandleEvent(_, event)
    if event == "TRANSMOG_COLLECTION_UPDATED" then
        self.outfitsReady = true
    elseif event == "NEW_HOUSING_ITEM_ACQUIRED" then
        self.housingCatalogReady = true
    end
end

function Collections:ResetStaging()
    self.outfitsReady = false
    self.housingCatalogReady = false
end

local function collectMounts()
    local mounts = {}
    local api = _G.C_MountJournal
    if type(api) ~= "table" or type(api.GetMountIDs) ~= "function"
        or type(api.GetMountInfoByID) ~= "function" then
        return mounts, false, false
    end
    local ok, ids = pcall(api.GetMountIDs)
    if not ok or type(ids) ~= "table" or #ids == 0 then
        return mounts, false, true
    end
    local ready = true
    for index, mountID in ipairs(ids) do
        Util.Cooperate(index, 30)
        local infoOk, name, spellID, icon, active, usable, sourceType, favorite, factionSpecific,
            faction, hidden, collected, mountIDReturned = pcall(api.GetMountInfoByID, mountID)
        if not infoOk or name == nil then
            ready = false
        elseif collected then
            mounts[#mounts + 1] = {
                id = mountIDReturned or mountID,
                spellID = spellID,
                name = name,
                icon = icon,
                sourceType = sourceType,
                favorite = favorite,
                factionSpecific = factionSpecific,
                faction = faction,
                hidden = hidden,
                usable = usable,
                active = active,
            }
        end
    end
    return mounts, ready, true
end

local function collectPets()
    local pets = {}
    local api = _G.C_PetJournal
    if type(api) ~= "table" or type(api.GetNumPets) ~= "function" or type(api.GetPetInfoByIndex) ~= "function" then
        return pets, false, false
    end
    local ok, count = pcall(api.GetNumPets)
    if not ok or type(count) ~= "number" or count <= 0 then
        return pets, false, true
    end
    local ready = true
    for index = 1, count do
        Util.Cooperate(index, 30)
        local infoOk, petID, speciesID, owned, customName, level, favorite, battlePet, icon, petType,
            companionID, tooltipSource, description, tradable, unique, obtainable, displayID =
            pcall(api.GetPetInfoByIndex, index)
        if not infoOk or speciesID == nil then
            ready = false
        elseif owned then
            pets[#pets + 1] = {
                petID = petID,
                speciesID = speciesID,
                customName = customName,
                level = level,
                favorite = favorite,
                battlePet = battlePet,
                icon = icon,
                petType = petType,
                companionID = companionID,
                tooltipSource = tooltipSource,
                description = description,
                tradable = tradable,
                unique = unique,
                obtainable = obtainable,
                displayID = displayID,
            }
        end
    end
    return pets, ready, true
end

local function collectToys()
    local toys = {}
    local api = _G.C_ToyBox
    if type(api) ~= "table" or type(api.GetNumToys) ~= "function"
        or type(api.GetToyFromIndex) ~= "function" or type(api.GetToyInfo) ~= "function"
        or type(_G.PlayerHasToy) ~= "function" then
        return toys, false, false
    end
    local countOk, count = pcall(api.GetNumToys)
    if not countOk or type(count) ~= "number" or count <= 0 then
        return toys, false, true
    end
    local ready = true
    for index = 1, count do
        Util.Cooperate(index, 30)
        local itemOk, itemID = pcall(api.GetToyFromIndex, index)
        if not itemOk or itemID == nil then
            ready = false
        else
            local ownedOk, owned = pcall(_G.PlayerHasToy, itemID)
            if not ownedOk then
                ready = false
            elseif owned then
                local infoOk, name, icon, favorite, hasFanfare, itemQuality = pcall(api.GetToyInfo, itemID)
                if not infoOk or name == nil then
                    ready = false
                else
                    toys[#toys + 1] = {
                        itemID = itemID,
                        name = name,
                        icon = icon,
                        favorite = favorite,
                        hasFanfare = hasFanfare,
                        itemQuality = itemQuality,
                    }
                end
            end
        end
    end
    return toys, ready, true
end

local function collectTitles()
    local titles = {}
    if type(_G.GetNumTitles) ~= "function" or type(_G.IsTitleKnown) ~= "function"
        or type(_G.GetTitleName) ~= "function" then
        return titles, false, false
    end
    local countOk, count = pcall(_G.GetNumTitles)
    if not countOk or type(count) ~= "number" or count <= 0 then
        return titles, false, true
    end
    local ready = true
    for titleID = 1, count do
        Util.Cooperate(titleID, 40)
        local knownOk, known = pcall(_G.IsTitleKnown, titleID)
        if not knownOk then
            ready = false
        elseif known then
            local nameOk, name = pcall(_G.GetTitleName, titleID)
            if not nameOk or name == nil then
                ready = false
            else
                titles[#titles + 1] = {
                    id = titleID,
                    name = name,
                }
            end
        end
    end
    return titles, ready, true
end

local function collectHeirlooms()
    local api = _G.C_Heirloom
    if type(api) ~= "table" or type(api.GetHeirloomItemIDs) ~= "function" then
        return {}, false, false
    end
    local ok, ids = pcall(api.GetHeirloomItemIDs)
    if not ok or type(ids) ~= "table" or #ids == 0 then
        return {}, false, true
    end
    return Util.Sanitize(ids), true, true
end

local function collectOutfits(eventReady)
    local api = _G.C_TransmogCollection
    if type(api) ~= "table" or type(api.GetOutfits) ~= "function" then
        return {}, false, false
    end
    local ok, outfits = pcall(api.GetOutfits)
    if not ok or type(outfits) ~= "table" then
        return {}, false, true
    end
    return Util.Sanitize(outfits), next(outfits) ~= nil or eventReady == true, true
end

local function collectHousingCatalog(eventReady)
    local api = _G.C_HousingCatalog
    if type(api) ~= "table" then
        return {}, false, false
    end
    local payload = {}
    local methods = { "GetCatalogEntryIDs", "GetAllCatalogEntryIDs", "GetOwnedDecor", "GetCollectedDecor" }
    local available = false
    local ready = false
    for _, method in ipairs(methods) do
        if type(api[method]) == "function" then
            available = true
            local ok, value = pcall(api[method])
            if ok and type(value) == "table" and (next(value) ~= nil or eventReady == true) then
                payload[method] = Util.Sanitize(value)
                ready = true
            end
        end
    end
    return payload, ready, available
end

function Collections:Collect()
    local mounts, mountsReady, mountsAvailable = collectMounts()
    local pets, petsReady, petsAvailable = collectPets()
    local toys, toysReady, toysAvailable = collectToys()
    local titles, titlesReady, titlesAvailable = collectTitles()
    local heirlooms, heirloomsReady, heirloomsAvailable = collectHeirlooms()
    local outfits, outfitsReady, outfitsAvailable = collectOutfits(self.outfitsReady)
    local housingCatalog, housingCatalogReady, housingCatalogAvailable =
        collectHousingCatalog(self.housingCatalogReady)
    local payload = {
        mounts = mounts,
        pets = pets,
        toys = toys,
        titles = titles,
        heirlooms = heirlooms,
        outfits = outfits,
        housingCatalog = housingCatalog,
    }
    local capability = {
        mounts = mountsReady,
        pets = petsReady,
        toys = toysReady,
        titles = titlesReady,
        heirlooms = heirloomsReady,
        outfits = outfitsReady,
        housingCatalog = housingCatalogReady,
    }
    local availability = {
        mounts = mountsAvailable,
        pets = petsAvailable,
        toys = toysAvailable,
        titles = titlesAvailable,
        heirlooms = heirloomsAvailable,
        outfits = outfitsAvailable,
        housingCatalog = housingCatalogAvailable,
    }
    local allReady = mountsReady and petsReady and toysReady and titlesReady
        and heirloomsReady and outfitsReady and housingCatalogReady
    local anyAvailable = mountsAvailable or petsAvailable or toysAvailable or titlesAvailable
        or heirloomsAvailable or outfitsAvailable or housingCatalogAvailable
    local coverage
    if allReady then
        capability.mountCount = #mounts
        capability.petCount = #pets
        capability.toyCount = #toys
        capability.titleCount = #titles
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
        capability.unavailableCollectionApis = unavailable
        capability.pendingCollectionApis = pending
        capability.actionNeeded = false
        capability.opportunity = "Ready collection catalogs are captured. EmberSync retries APIs that are still loading or unavailable after collection updates without blocking a game frame."
        coverage = Coverage.Partial("collection_apis_loading_or_partially_available", capability)
    else
        coverage = Coverage.Unsupported("collection_apis_unavailable", {
            actionNeeded = false,
            opportunity = "This game client did not expose the supported collection APIs.",
        })
    end
    return payload, coverage, "account"
end

EmberSync.CollectorManager:Register(Collections)
