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
    debounce = 2,
}

local function collectMounts()
    local mounts = {}
    local api = _G.C_MountJournal
    if type(api) ~= "table" or type(api.GetMountIDs) ~= "function" then
        return mounts, false
    end
    local ids = api.GetMountIDs() or {}
    for _, mountID in ipairs(ids) do
        local name, spellID, icon, active, usable, sourceType, favorite, factionSpecific,
            faction, hidden, collected, mountIDReturned = api.GetMountInfoByID(mountID)
        if collected then
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
    return mounts, true
end

local function collectPets()
    local pets = {}
    local api = _G.C_PetJournal
    if type(api) ~= "table" or type(api.GetNumPets) ~= "function" or type(api.GetPetInfoByIndex) ~= "function" then
        return pets, false
    end
    local count = api.GetNumPets() or 0
    for index = 1, count do
        local petID, speciesID, owned, customName, level, favorite, battlePet, icon, petType,
            companionID, tooltipSource, description, tradable, unique, obtainable, displayID = api.GetPetInfoByIndex(index)
        if owned then
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
    return pets, true
end

local function collectToys()
    local toys = {}
    local api = _G.C_ToyBox
    if type(api) ~= "table" or type(api.GetNumToys) ~= "function" or type(api.GetToyFromIndex) ~= "function" then
        return toys, false
    end
    for index = 1, (api.GetNumToys() or 0) do
        local itemID = api.GetToyFromIndex(index)
        if itemID and (type(_G.PlayerHasToy) ~= "function" or _G.PlayerHasToy(itemID)) then
            local name, icon, favorite, hasFanfare, itemQuality = api.GetToyInfo(itemID)
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
    return toys, true
end

local function collectTitles()
    local titles = {}
    if type(_G.GetNumTitles) ~= "function" then
        return titles, false
    end
    for titleID = 1, (_G.GetNumTitles() or 0) do
        if type(_G.IsTitleKnown) == "function" and _G.IsTitleKnown(titleID) then
            titles[#titles + 1] = {
                id = titleID,
                name = type(_G.GetTitleName) == "function" and _G.GetTitleName(titleID) or nil,
            }
        end
    end
    return titles, true
end

local function collectHeirlooms()
    local api = _G.C_Heirloom
    if type(api) ~= "table" or type(api.GetHeirloomItemIDs) ~= "function" then
        return {}, false
    end
    local ok, ids = pcall(api.GetHeirloomItemIDs)
    return ok and Util.Sanitize(ids) or {}, true
end

local function collectOutfits()
    local api = _G.C_TransmogCollection
    if type(api) ~= "table" or type(api.GetOutfits) ~= "function" then
        return {}, false
    end
    local ok, outfits = pcall(api.GetOutfits)
    return ok and Util.Sanitize(outfits) or {}, true
end

local function collectHousingCatalog()
    local api = _G.C_HousingCatalog
    if type(api) ~= "table" then
        return {}, false
    end
    local payload = {}
    local methods = { "GetCatalogEntryIDs", "GetAllCatalogEntryIDs", "GetOwnedDecor", "GetCollectedDecor" }
    local supported = false
    for _, method in ipairs(methods) do
        if type(api[method]) == "function" then
            supported = true
            local ok, value = pcall(api[method])
            if ok then
                payload[method] = Util.Sanitize(value)
            end
        end
    end
    return payload, supported
end

function Collections:Collect()
    local mounts, mountsSupported = collectMounts()
    local pets, petsSupported = collectPets()
    local toys, toysSupported = collectToys()
    local titles, titlesSupported = collectTitles()
    local heirlooms, heirloomsSupported = collectHeirlooms()
    local outfits, outfitsSupported = collectOutfits()
    local housingCatalog, housingCatalogSupported = collectHousingCatalog()
    local payload = {
        mounts = mounts,
        pets = pets,
        toys = toys,
        titles = titles,
        heirlooms = heirlooms,
        outfits = outfits,
        housingCatalog = housingCatalog,
    }
    local supported = mountsSupported or petsSupported or toysSupported or titlesSupported
    local coverage = supported and Coverage.Partial("static_catalog_enrichment_deferred", {
        mounts = mountsSupported,
        pets = petsSupported,
        toys = toysSupported,
        titles = titlesSupported,
        heirlooms = heirloomsSupported,
        outfits = outfitsSupported,
        housingCatalog = housingCatalogSupported,
    }) or Coverage.Unsupported("collection_apis_unavailable")
    return payload, coverage, "account"
end

EmberSync.CollectorManager:Register(Collections)
