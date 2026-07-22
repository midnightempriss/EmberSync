local _, EmberSync = ...

local Util = EmberSync.Util
local Coverage = EmberSync.Coverage

local Character = {
    name = "character",
    scope = "character",
    events = {
        "PLAYER_LEVEL_UP",
        "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_MONEY",
        "PLAYER_SPECIALIZATION_CHANGED",
        "ACTIVE_TALENT_GROUP_CHANGED",
        "ZONE_CHANGED_NEW_AREA",
        "UPDATE_INVENTORY_DURABILITY",
    },
    minInterval = 5,
}

local function collectEquipment()
    local equipment = {}
    if type(_G.GetInventoryItemLink) ~= "function" then
        return equipment
    end
    for slot = 1, 19 do
        local link = _G.GetInventoryItemLink("player", slot)
        local itemID = type(_G.GetInventoryItemID) == "function" and _G.GetInventoryItemID("player", slot) or nil
        local currentDurability, maximumDurability
        if type(_G.GetInventoryItemDurability) == "function" then
            currentDurability, maximumDurability = _G.GetInventoryItemDurability(slot)
        end
        if link or itemID then
            equipment[slot] = {
                itemID = itemID,
                itemLink = link,
                currentDurability = currentDurability,
                maximumDurability = maximumDurability,
            }
        end
    end
    return equipment
end

local function collectTalents(specializationID)
    local result = {}
    local classTalents = _G.C_ClassTalents
    local traits = _G.C_Traits
    if type(classTalents) ~= "table" or type(traits) ~= "table"
        or type(classTalents.GetActiveConfigID) ~= "function" then
        return result, false
    end
    local activeConfigID = classTalents.GetActiveConfigID()
    result.activeConfigID = activeConfigID
    if specializationID and type(classTalents.GetConfigIDsBySpecID) == "function" then
        local ok, ids = pcall(classTalents.GetConfigIDsBySpecID, specializationID)
        result.savedConfigIDs = ok and Util.Sanitize(ids) or nil
    end
    if activeConfigID and type(traits.GetConfigInfo) == "function" then
        local ok, info = pcall(traits.GetConfigInfo, activeConfigID)
        result.configInfo = ok and Util.Sanitize(info) or nil
    end
    if activeConfigID and type(traits.GetTreeNodes) == "function" then
        local ok, nodeIDs = pcall(traits.GetTreeNodes, activeConfigID)
        if ok and type(nodeIDs) == "table" then
            result.nodes = {}
            for index, nodeID in ipairs(nodeIDs) do
                Util.Cooperate(index, 25)
                local nodeOk, nodeInfo = pcall(traits.GetNodeInfo, activeConfigID, nodeID)
                if nodeOk and nodeInfo then
                    result.nodes[#result.nodes + 1] = Util.Sanitize(nodeInfo)
                end
            end
        end
    end
    return result, true
end

function Character:Collect(context)
    local guid = type(_G.UnitGUID) == "function" and _G.UnitGUID("player") or nil
    local name, realm = context.sourceCharacter.name, context.sourceCharacter.realm
    local raceName, raceFile, raceID
    if type(_G.UnitRace) == "function" then
        raceName, raceFile, raceID = _G.UnitRace("player")
    end
    local className, classFile, classID
    if type(_G.UnitClass) == "function" then
        className, classFile, classID = _G.UnitClass("player")
    end
    local factionName, factionGroup
    if type(_G.UnitFactionGroup) == "function" then
        factionName, factionGroup = _G.UnitFactionGroup("player")
    end
    local equippedItemLevel, totalItemLevel
    if type(_G.GetAverageItemLevel) == "function" then
        equippedItemLevel, totalItemLevel = _G.GetAverageItemLevel()
    end
    local specializationIndex = type(_G.GetSpecialization) == "function" and _G.GetSpecialization() or nil
    local specialization
    local specializationID
    if specializationIndex and type(_G.GetSpecializationInfo) == "function" then
        local specID, specName, description, icon, role, primaryStat = _G.GetSpecializationInfo(specializationIndex)
        specializationID = specID
        specialization = {
            index = specializationIndex,
            id = specID,
            name = specName,
            description = description,
            icon = icon,
            role = role,
            primaryStat = primaryStat,
        }
    end
    local mapID = type(_G.C_Map) == "table" and type(_G.C_Map.GetBestMapForUnit) == "function"
        and _G.C_Map.GetBestMapForUnit("player") or nil

    local payload = {
        id = guid,
        name = name,
        realm = realm,
        level = type(_G.UnitLevel) == "function" and _G.UnitLevel("player") or nil,
        race = { name = raceName, file = raceFile, id = raceID },
        class = { name = className, file = classFile, id = classID },
        faction = { name = factionName, group = factionGroup },
        guildKey = context.guild.key,
        money = type(_G.GetMoney) == "function" and _G.GetMoney() or nil,
        healthMaximum = type(_G.UnitHealthMax) == "function" and _G.UnitHealthMax("player") or nil,
        powerMaximum = type(_G.UnitPowerMax) == "function" and _G.UnitPowerMax("player") or nil,
        itemLevel = { equipped = equippedItemLevel, total = totalItemLevel },
        specialization = specialization,
        talents = collectTalents(specializationID),
        equipment = collectEquipment(),
        location = {
            mapID = mapID,
            zone = type(_G.GetZoneText) == "function" and _G.GetZoneText() or nil,
            subzone = type(_G.GetSubZoneText) == "function" and _G.GetSubZoneText() or nil,
        },
        restedXP = type(_G.GetXPExhaustion) == "function" and _G.GetXPExhaustion() or nil,
    }
    if type(_G.C_PlayerInfo) == "table" and type(_G.C_PlayerInfo.GetPlayerMythicPlusRatingSummary) == "function" then
        local ok, rating = pcall(_G.C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
        payload.mythicPlusRating = ok and Util.Sanitize(rating) or nil
    end

    local coverage = guid and Coverage.Complete() or Coverage.Partial("character_guid_pending")
    return payload, coverage, guid
end

EmberSync.CollectorManager:Register(Character)
