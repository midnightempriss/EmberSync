local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local Professions = {
    name = "professions",
    scope = "character",
    events = {
        "SKILL_LINES_CHANGED",
        "TRADE_SKILL_SHOW",
        "TRADE_SKILL_CLOSE",
        "TRADE_SKILL_LIST_UPDATE",
        "TRADE_SKILL_DETAILS_UPDATE",
        "TRADE_SKILL_DATA_SOURCE_CHANGED",
        "NEW_RECIPE_LEARNED",
        "CHAT_MSG_SKILL",
    },
    priorityEvents = {
        TRADE_SKILL_SHOW = true,
        TRADE_SKILL_LIST_UPDATE = true,
        TRADE_SKILL_DETAILS_UPDATE = true,
        TRADE_SKILL_DATA_SOURCE_CHANGED = true,
        NEW_RECIPE_LEARNED = true,
    },
    tradeSkillOpen = false,
    recipeCatalogs = {},
    debounce = 1,
    minInterval = 30,
    expensive = true,
}

function Professions:HandleEvent(_, event)
    if event == "TRADE_SKILL_SHOW" then
        self.tradeSkillOpen = true
    elseif event == "TRADE_SKILL_CLOSE" then
        self.tradeSkillOpen = false
        return false
    end
end

function Professions:ResetStaging()
    self.tradeSkillOpen = false
    self.recipeCatalogs = {}
end

local function collectProfessionSummary()
    local result = {}
    if type(_G.GetProfessions) ~= "function" or type(_G.GetProfessionInfo) ~= "function" then
        return result, false
    end
    local indices = { _G.GetProfessions() }
    for _, professionIndex in ipairs(indices) do
        if professionIndex then
            local name, icon, skillLevel, maxSkillLevel, numberOfAbilities, spellOffset, skillLine, modifier,
                specializationIndex, specializationOffset = _G.GetProfessionInfo(professionIndex)
            result[#result + 1] = {
                index = professionIndex,
                name = name,
                icon = icon,
                skillLevel = skillLevel,
                maxSkillLevel = maxSkillLevel,
                numberOfAbilities = numberOfAbilities,
                spellOffset = spellOffset,
                skillLine = skillLine,
                modifier = modifier,
                specializationIndex = specializationIndex,
                specializationOffset = specializationOffset,
            }
        end
    end
    return result, true
end

local function catalogKey(skillLineID, parentSkillLineID, displayName)
    return tostring(parentSkillLineID or skillLineID or Util.NormalizeGuildName(displayName or "unknown") or "unknown")
end

local function collectCurrentRecipeCatalog()
    local api = _G.C_TradeSkillUI
    if type(api) ~= "table" or type(api.IsTradeSkillReady) ~= "function"
        or type(api.GetAllRecipeIDs) ~= "function" or type(api.GetTradeSkillLine) ~= "function" then
        return nil, false
    end
    local readyOk, ready = pcall(api.IsTradeSkillReady)
    if not readyOk or ready ~= true then
        return nil, true
    end
    local lineOk, skillLineID, displayName, rank, maxRank, modifier, parentSkillLineID,
        parentDisplayName = pcall(api.GetTradeSkillLine)
    if not lineOk or type(skillLineID) ~= "number" then
        return nil, true
    end
    local idsOk, ids = pcall(api.GetAllRecipeIDs)
    if not idsOk or type(ids) ~= "table" then
        return nil, true
    end
    local recipes = {}
    for index, recipeID in ipairs(ids) do
        Util.Cooperate(index, 25)
        local info
        if type(api.GetRecipeInfo) == "function" then
            local infoOk, value = pcall(api.GetRecipeInfo, recipeID)
            info = infoOk and value or nil
        end
        recipes[#recipes + 1] = { id = recipeID, info = Util.Sanitize(info) }
    end
    return {
        key = catalogKey(skillLineID, parentSkillLineID, parentDisplayName or displayName),
        skillLineID = skillLineID,
        displayName = displayName,
        rank = rank,
        maxRank = maxRank,
        modifier = modifier,
        parentSkillLineID = parentSkillLineID,
        parentDisplayName = parentDisplayName,
        observedAt = Util.Now(),
        recipeCount = #recipes,
        recipes = recipes,
    }, true
end

local function restorePreviousCatalogs(context, target)
    local export = Database:GetActiveExport(false)
    if type(export) ~= "table" or type(export.datasets) ~= "table" then
        return
    end
    local envelope = export.datasets["professions:" .. tostring(context.sourceCharacter.id)]
    if type(envelope) ~= "table" or type(envelope.sourceCharacter) ~= "table"
        or envelope.sourceCharacter.id ~= context.sourceCharacter.id or type(envelope.payload) ~= "table"
        or type(envelope.payload.recipeCatalogs) ~= "table" then
        return
    end
    for key, catalog in pairs(envelope.payload.recipeCatalogs) do
        if target[key] == nil and type(catalog) == "table" then
            target[key] = Util.Copy(catalog)
        end
    end
end

local function professionObserved(profession, catalogs)
    local expectedID = profession.skillLine
    local expectedName = Util.NormalizeGuildName(profession.name or "") or ""
    for _, catalog in pairs(catalogs) do
        if (type(expectedID) == "number"
                and (catalog.skillLineID == expectedID or catalog.parentSkillLineID == expectedID))
            or (expectedName ~= "" and (
                Util.NormalizeGuildName(catalog.displayName or "") == expectedName
                or Util.NormalizeGuildName(catalog.parentDisplayName or "") == expectedName
            )) then
            return true
        end
    end
    return false
end

local function pruneStaleCatalogs(professions, catalogs)
    for key, catalog in pairs(catalogs) do
        local matched = false
        if type(catalog) == "table" then
            for _, profession in ipairs(professions) do
                if professionObserved(profession, { [key] = catalog }) then
                    matched = true
                    break
                end
            end
        end
        if not matched then
            catalogs[key] = nil
        end
    end
end

function Professions:Collect(context)
    restorePreviousCatalogs(context, self.recipeCatalogs)
    local professions, summarySupported = collectProfessionSummary()
    if summarySupported then
        -- Learned professions are an enumerable source of truth. Drop saved
        -- recipe catalogs for professions this character has since unlearned
        -- instead of retaining them indefinitely.
        pruneStaleCatalogs(professions, self.recipeCatalogs)
    end
    local currentCatalog, recipeApiSupported = collectCurrentRecipeCatalog()
    if currentCatalog then
        self.recipeCatalogs[currentCatalog.key] = currentCatalog
    end

    local observedProfessions = 0
    local missingNames = {}
    for _, profession in ipairs(professions) do
        if professionObserved(profession, self.recipeCatalogs) then
            observedProfessions = observedProfessions + 1
        else
            missingNames[#missingNames + 1] = profession.name or tostring(profession.skillLine or "profession")
        end
    end
    local flattenedRecipes = {}
    for _, catalog in pairs(self.recipeCatalogs) do
        for _, recipe in ipairs(catalog.recipes or {}) do
            flattenedRecipes[#flattenedRecipes + 1] = Util.Copy(recipe)
            Util.Cooperate(#flattenedRecipes, 50)
        end
    end
    local payload = {
        professions = professions,
        recipeCatalogs = Util.Copy(self.recipeCatalogs),
        recipes = flattenedRecipes,
    }
    if not summarySupported then
        return payload, Coverage.Unsupported("profession_api_unavailable"), context.sourceCharacter.id
    end

    local allObserved = #professions == 0 or observedProfessions == #professions
    if allObserved and recipeApiSupported then
        return payload, Coverage.Complete({
            professionCount = #professions,
            observedProfessionCount = observedProfessions,
            recipeCount = #flattenedRecipes,
        }), context.sourceCharacter.id
    end
    return payload, Coverage.Partial("open_each_profession_for_recipes", {
        professionCount = #professions,
        observedProfessionCount = observedProfessions,
        recipeCount = #flattenedRecipes,
        missingProfessions = missingNames,
        opportunity = #missingNames > 0
            and ("Open these profession windows and wait for their recipe lists: " .. table.concat(missingNames, ", ") .. ".")
            or "Open each profession window and wait for its recipe list to finish loading.",
    }), context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Professions)
