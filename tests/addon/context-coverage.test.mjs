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

test("partial observations cannot resurrect omitted fields or cross provenance", async () => {
  await execute([
    "Core/Namespace.lua",
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Coverage.lua",
  ], `
    local clock = 1000
    local playerGuid = "Player-1-00000001"
    GetServerTime = function() clock = clock + 1; return clock end
    UnitGUID = function() return playerGuid end
    UnitFullName = function() return "Tester", "Dalaran" end
    EmberSync.GuildLock = {
      IsAuthorized = function() return true end,
      GetIdentity = function()
        return { key = "main", name = "Raining Embers", realm = "Dalaran", region = 1,
          rankName = "Member", rankIndex = 5 }
      end,
    }
  ` + await moduleSource("Core/Database.lua"), `
    local db = EmberSync.Database
    assert(db:CommitDataset("calendar", "guild", "main", { records = { 1, 2 } },
      EmberSync.Coverage.Complete()))

    playerGuid = "Player-1-00000002"
    local ok, key, disposition = db:CommitDataset("calendar", "guild", "main", { foreign = true },
      EmberSync.Coverage.Partial("different_source"))
    assert(ok and key == "calendar" and disposition == "preserved_existing_source")
    local envelope = EmberSyncDB.exports.main.datasets.calendar
    assert(envelope.sourceCharacter.id == "Player-1-00000001")
    assert(envelope.coverage.status == "complete")
    assert(envelope.payload.foreign == nil, "cross-source partial data must not be re-attributed")

    playerGuid = "Player-1-00000001"
    assert(db:CommitDataset("calendar", "guild", "main", {
      records = { [1] = 10, [3] = 3 },
      newlyLoadedDetail = "yes",
    }, EmberSync.Coverage.Partial("calendar_context_closed")))
    envelope = EmberSyncDB.exports.main.datasets.calendar
    assert(envelope.payload.records[1] == 10 and envelope.payload.records[2] == nil
      and envelope.payload.records[3] == 3,
      "generic persistence must not resurrect records omitted by a bounded collector")
    assert(envelope.payload.newlyLoadedDetail == "yes",
      "the current partial observation must be stored intact")
    assert(envelope.coverage.status == "partial" and envelope.coverage.preservedLastGood ~= true)

    playerGuid = "Player-1-00000002"
    ok, key, disposition = db:CommitDataset("calendar", "guild", "main", { foreign = "later" },
      EmberSync.Coverage.Partial("different_source_after_partial"))
    assert(ok and disposition ~= "preserved_existing_source")
    envelope = EmberSyncDB.exports.main.datasets.calendar
    assert(envelope.sourceCharacter.id == "Player-1-00000002" and envelope.payload.foreign == "later")
    assert(envelope.payload.records == nil, "cross-source payloads must never be combined")

    playerGuid = "Player-1-00000001"
    assert(db:CommitDataset("calendar", "guild", "main", {},
      EmberSync.Coverage.Forbidden("permission_removed")))
    envelope = EmberSyncDB.exports.main.datasets.calendar
    assert(envelope.payload.records == nil,
      "forbidden observations must not carry data the source can no longer inspect")
    assert(envelope.coverage.status == "forbidden" and envelope.coverage.preservedLastGood ~= true)
  `);
});

test("profession recipe catalogs accumulate per learned profession before becoming complete", async () => {
  await execute([
    "Core/Namespace.lua",
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Coverage.lua",
  ], `
    local registered
    local now = 2000
    GetServerTime = function() now = now + 1; return now end
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    EmberSync.Database = { GetActiveExport = function() return nil end }
    local includeEnchanting = true
    GetProfessions = function()
      if includeEnchanting then return 1, 2 end
      return 1
    end
    GetProfessionInfo = function(index)
      if index == 1 then return "Alchemy", 1, 100, 100, 1, 0, 171, 0, 0, 0 end
      return "Enchanting", 2, 100, 100, 1, 0, 333, 0, 0, 0
    end
    local current = 171
    C_TradeSkillUI = {
      IsTradeSkillReady = function() return true end,
      GetTradeSkillLine = function()
        local name = current == 171 and "Alchemy" or "Enchanting"
        return current, name, 100, 100, 0, current, name
      end,
      GetAllRecipeIDs = function() return current == 171 and { 101, 102 } or { 201 } end,
      GetRecipeInfo = function(id) return { recipeID = id, name = "Recipe " .. id } end,
    }
  ` + await moduleSource("Collectors/Professions.lua"), `
    local context = { sourceCharacter = { id = "Player-One" } }
    registered:HandleEvent(context, "TRADE_SKILL_SHOW")
    local first, firstCoverage = registered:Collect(context)
    assert(firstCoverage.status == "partial")
    assert(firstCoverage.observedProfessionCount == 1)
    assert(first.recipeCatalogs["171"].recipeCount == 2)

    current = 333
    registered:HandleEvent(context, "TRADE_SKILL_LIST_UPDATE")
    local second, secondCoverage = registered:Collect(context)
    assert(secondCoverage.status == "complete")
    assert(secondCoverage.observedProfessionCount == 2)
    assert(second.recipeCatalogs["171"].recipeCount == 2)
    assert(second.recipeCatalogs["333"].recipeCount == 1)
    assert(#second.recipes == 3)

    includeEnchanting = false
    current = 171
    local third, thirdCoverage = registered:Collect(context)
    assert(thirdCoverage.status == "complete")
    assert(third.recipeCatalogs["333"] == nil,
      "catalogs for unlearned professions must be pruned")
    assert(#third.recipes == 2)
    assert(registered:HandleEvent(context, "TRADE_SKILL_CLOSE") == false)
  `);
});

test("progression is complete when every targeted API enumerates successfully", async () => {
  await execute([
    "Core/Namespace.lua",
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Coverage.lua",
  ], `
    local registered
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    C_CurrencyInfo = { GetCurrencyListSize = function() return 1 end,
      GetCurrencyListInfo = function() return { name = "Test Currency", quantity = 1 } end }
    C_Reputation = { GetNumFactions = function() return 1 end,
      GetFactionDataByIndex = function() return { name = "Test Faction", isHeader = false } end }
    C_MajorFactions = { GetMajorFactionIDs = function() return { 1 } end,
      GetMajorFactionData = function() return { factionID = 1, name = "Test Renown" } end }
    C_QuestLog = { GetNumQuestLogEntries = function() return 0 end, GetInfo = function() end }
    GetCategoryList = function() return { 1 } end
    GetCategoryNumAchievements = function() return 0 end
    GetAchievementInfo = function() end
    GetNumSavedInstances = function() return 0 end
    GetSavedInstanceInfo = function() end
    C_WeeklyRewards = { GetActivities = function() return {} end }
  ` + await moduleSource("Collectors/Progression.lua"), `
    registered:HandleEvent(nil, "UPDATE_INSTANCE_INFO")
    registered:HandleEvent(nil, "WEEKLY_REWARDS_UPDATE")
    local payload, coverage = registered:Collect({ sourceCharacter = { id = "Player-One" } })
    assert(coverage.status == "complete")
    assert(coverage.currencies and coverage.reputations and coverage.majorFactions)
    assert(coverage.quests and coverage.achievements and coverage.lockouts and coverage.weeklyRewards)
    assert(#payload.weeklyRewards == 0)
  `);
});

test("context collectors use priority open events and suppress close recrawls", async () => {
  const [manager, auction, calendar, crafting, guildBank, inventory, mail, professions] =
    await Promise.all([
      readFile(path.join(addonRoot, "Core/CollectorManager.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/AuctionHouse.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/Calendar.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/Crafting.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/GuildBank.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/Inventory.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/Mail.lua"), "utf8"),
      readFile(path.join(addonRoot, "Collectors/Professions.lua"), "utf8"),
    ]);

  assert.match(manager, /isPriorityTrigger/);
  assert.match(manager, /preferRerunTrigger/);
  assert.match(manager, /C_Timer\.After\(delay or 0\.25/);
  assert.doesNotMatch(manager, /priority and 0/);
  assert.match(manager, /result == false/);
  assert.match(manager, /collector\.finalizeSynchronous == true/);
  for (const source of [auction, calendar, crafting, guildBank, inventory, mail, professions]) {
    assert.match(source, /priorityEvents/);
    assert.match(source, /return false/);
  }
  assert.match(guildBank, /GUILDBANKBAGSLOTS_CHANGED[\s\S]*self\.isOpen = true/);
  assert.match(guildBank, /QueryGuildBankTab/);
});
