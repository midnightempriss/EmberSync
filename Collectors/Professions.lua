local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local Professions = {
    name = "professions",
    scope = "character",
    events = {
        "SKILL_LINES_CHANGED",
        "TRADE_SKILL_SHOW",
        "TRADE_SKILL_CLOSE",
        "TRADE_SKILL_LIST_UPDATE",
        "NEW_RECIPE_LEARNED",
        "CHAT_MSG_SKILL",
    },
    debounce = 1,
    minInterval = 30,
    expensive = true,
}

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

local function collectRecipes()
    local api = _G.C_TradeSkillUI
    if type(api) ~= "table" or type(api.IsTradeSkillReady) ~= "function"
        or type(api.GetAllRecipeIDs) ~= "function" or not api.IsTradeSkillReady() then
        return {}, false
    end
    local recipes = {}
    for index, recipeID in ipairs(api.GetAllRecipeIDs() or {}) do
        Util.Cooperate(index, 25)
        local info = type(api.GetRecipeInfo) == "function" and api.GetRecipeInfo(recipeID) or nil
        recipes[#recipes + 1] = { id = recipeID, info = Util.Sanitize(info) }
    end
    return recipes, true
end

function Professions:Collect(context)
    local professions, summarySupported = collectProfessionSummary()
    local recipes, recipesLoaded = collectRecipes()
    local payload = { professions = professions, recipes = recipes }
    if not summarySupported then
        return payload, Coverage.Unsupported("profession_api_unavailable"), context.sourceCharacter.id
    end
    local coverage = recipesLoaded and Coverage.Complete({ recipeCount = #recipes })
        or Coverage.Partial("open_each_profession_for_recipes", {
            opportunity = "Open each profession window to capture its complete recipe list.",
        })
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Professions)
