import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { lua, lauxlib, lualib, to_luastring, to_jsstring } from "fengari";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const addonRoot = path.resolve(testDirectory, "../..");

async function moduleSource(relative) {
  const source = await readFile(path.join(addonRoot, relative), "utf8");
  return `do
local __embersyncModule = function(...)
${source}
end
__embersyncModule("EmberSync", EmberSync)
end
`;
}

async function execute(modules, setup, assertions) {
  const chunks = ["EmberSync = {}\n"];
  for (const module of modules) chunks.push(await moduleSource(module));
  chunks.push(setup, assertions);
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const status = lauxlib.luaL_dostring(L, to_luastring(chunks.join("\n")));
  if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
}

const coreModules = [
  "Core/Namespace.lua",
  "Core/Constants.lua",
  "Core/Util.lua",
  "Core/Coverage.lua",
];

test("collections becomes complete only after every catalog read succeeds", async () => {
  await execute(coreModules, `
    local registered
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    C_MountJournal = {
      GetMountIDs = function() return { 42 } end,
      GetMountInfoByID = function()
        return "Test Mount", 1, 2, false, true, 1, false, false, nil, false, true, 42
      end,
    }
    C_PetJournal = {
      GetNumPets = function() return 1 end,
      GetPetInfoByIndex = function() return "Pet-1", 7, true, "Pet", 1 end,
    }
    C_ToyBox = {
      GetNumToys = function() return 1 end,
      GetToyFromIndex = function() return 100 end,
      GetToyInfo = function() return "Test Toy", 3, false, false, 1 end,
    }
    PlayerHasToy = function() return true end
    GetNumTitles = function() return 1 end
    IsTitleKnown = function() return true end
    GetTitleName = function() return "Test Title" end
    C_Heirloom = { GetHeirloomItemIDs = function() return { 200 } end }
    C_TransmogCollection = { GetOutfits = function() return { { outfitID = 1 } } end }
    C_HousingCatalog = { GetCatalogEntryIDs = function() return { 300 } end }
  ` + await moduleSource("Collectors/Collections.lua"), `
    local payload, coverage = registered:Collect()
    assert(coverage.status == "complete")
    assert(coverage.mounts and coverage.pets and coverage.toys and coverage.titles)
    assert(coverage.heirlooms and coverage.outfits and coverage.housingCatalog)
    assert(#payload.mounts == 1 and #payload.pets == 1 and #payload.toys == 1)
    assert(#payload.heirlooms == 1 and #payload.outfits == 1)
  `);
});

test("collections stays partial for empty static catalogs and failed API calls", async () => {
  await execute(coreModules, `
    local registered
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    C_MountJournal = {
      GetMountIDs = function() return {} end,
      GetMountInfoByID = function() end,
    }
    C_PetJournal = {
      GetNumPets = function() return 1 end,
      GetPetInfoByIndex = function() return nil, 7, false end,
    }
    C_ToyBox = {
      GetNumToys = function() return 1 end,
      GetToyFromIndex = function() return 100 end,
      GetToyInfo = function() return "Test Toy" end,
    }
    PlayerHasToy = function() return false end
    GetNumTitles = function() return 1 end
    IsTitleKnown = function() return false end
    GetTitleName = function() return "Unused" end
    C_Heirloom = { GetHeirloomItemIDs = function() error("not ready") end }
    C_TransmogCollection = { GetOutfits = function() error("not ready") end }
    C_HousingCatalog = { GetCatalogEntryIDs = function() return {} end }
  ` + await moduleSource("Collectors/Collections.lua"), `
    local _, coverage = registered:Collect()
    assert(coverage.status == "partial")
    assert(coverage.reason == "collection_apis_loading_or_partially_available")
    assert(coverage.mounts == false)
    assert(coverage.heirlooms == false)
    assert(coverage.outfits == false)
    assert(coverage.housingCatalog == false)
    assert(coverage.apiAvailability.mounts == true)
    assert(coverage.apiAvailability.heirlooms == true)
    assert(#coverage.pendingCollectionApis >= 4)
  `);
});

test("progression stays partial when present APIs fail or return not-ready catalogs", async () => {
  await execute(coreModules, `
    local registered
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    C_CurrencyInfo = {
      GetCurrencyListSize = function() return 1 end,
      GetCurrencyListInfo = function() error("not ready") end,
    }
    C_Reputation = {
      GetNumFactions = function() error("not ready") end,
      GetFactionDataByIndex = function() end,
    }
    C_MajorFactions = {
      GetMajorFactionIDs = function() return {} end,
      GetMajorFactionData = function() end,
    }
    C_QuestLog = {
      GetNumQuestLogEntries = function() return 0 end,
      GetInfo = function() end,
    }
    GetCategoryList = function() return {} end
    GetCategoryNumAchievements = function() return 0 end
    GetAchievementInfo = function() end
    GetNumSavedInstances = function() return 0 end
    GetSavedInstanceInfo = function() end
    C_WeeklyRewards = { GetActivities = function() error("not ready") end }
  ` + await moduleSource("Collectors/Progression.lua"), `
    local _, coverage = registered:Collect({ sourceCharacter = { id = "Player-One" } })
    assert(coverage.status == "partial")
    assert(coverage.reason == "progression_apis_load_incrementally")
    assert(coverage.currencies == false)
    assert(coverage.reputations == false)
    assert(coverage.majorFactions == false)
    assert(coverage.achievements == false)
    assert(coverage.lockouts == false)
    assert(coverage.weeklyRewards == false)
    assert(coverage.quests == true)
    assert(coverage.apiAvailability.weeklyRewards == true)
    assert(#coverage.pendingProgressionApis >= 6)
  `);
});
