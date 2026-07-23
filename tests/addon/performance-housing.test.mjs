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
  return `do\nlocal __embersyncModule = function(...)\n${source}\nend\n__embersyncModule("EmberSync", EmberSync)\nend\n`;
}

test("housing captures the approved guild neighborhood and full Endeavor objects", async () => {
  const modules = [
    "Core/Namespace.lua",
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Coverage.lua",
  ];
  const source = ["EmberSync = {}\n"];
  for (const module of modules) source.push(await moduleSource(module));
  source.push(`
    local registered
    local appended = {}
    EmberSync.CollectorManager = {
      Register = function(_, collector) registered = collector end,
    }
    EmberSync.Database = {
      GetActiveExport = function() return nil end,
      AppendEvent = function(_, stream, payload)
        appended[#appended + 1] = { stream = stream, payload = payload }
        return true
      end,
    }
    Enum = { NeighborhoodOwnerType = { Guild = 1 } }
    local requests = { house = 0, neighborhood = 0, initiative = 0, activity = 0, discovery = 0 }
    C_Housing = {
      RequestCurrentHouseInfo = function() requests.house = requests.house + 1 end,
      HouseFinderRequestNeighborhoods = function() requests.discovery = requests.discovery + 1 end,
      GetPlayerOwnedHouses = function() return { { neighborhoodGUID = "Housing-Guild" } } end,
      GetOthersOwnedHouses = function() return {} end,
      GetCurrentHouseInfo = function() return { neighborhoodGUID = "Housing-Guild", plotID = 54 } end,
      GetCurrentHouseLevelFavor = function() return { houseLevel = 2, houseFavor = 50 } end,
      GetCurrentNeighborhoodGUID = function() return "Housing-Guild" end,
      GetTrackedHouseGuid = function() return nil end,
      GetHousingAccessFlags = function() return 1 end,
      IsInsideHouse = function() return false end,
      IsInsidePlot = function() return false end,
      IsInsideOwnHouse = function() return false end,
    }
    C_HousingNeighborhood = {
      RequestNeighborhoodInfo = function() requests.neighborhood = requests.neighborhood + 1 end,
      GetNeighborhoodName = function() return "Raining Embers" end,
      GetNeighborhoodMapData = function()
        return { { plotID = 54, ownerName = "Member", ownerType = 1 } }
      end,
      GetCurrentNeighborhoodTextureSuffix = function() return "elwynn" end,
      IsNeighborhoodManager = function() return false end,
      IsNeighborhoodOwner = function() return false end,
    }
    local initiativeInfo = {
      isLoaded = true,
      neighborhoodGUID = "Housing-Guild",
      initiativeID = 44,
      currentCycleID = 9,
      progressRequired = 1000,
      currentProgress = 625,
      playerTotalContribution = 75,
      duration = 86400,
      title = "Guild Endeavor",
      description = "Work together",
      tasks = {
        { ID = 7, taskName = "Decorate", timesCompleted = 2,
          criteriaList = { { requiredValue = 10 } }, requirementsList = {} },
        { ID = 8, taskName = "Gather", timesCompleted = 1,
          criteriaList = {}, requirementsList = {} },
      },
      milestones = { { milestoneOrderIndex = 1, requiredContributionAmount = 500, rewards = {} } },
    }
    local activityInfo = {
      isLoaded = true,
      neighborhoodGUID = "Housing-Guild",
      nextUpdateTime = 12345,
      taskActivity = {
        { taskID = 7, playerName = "Member", taskName = "Decorate", completionTime = 123, amount = 25 },
        { taskID = 8, playerName = "MemberTwo", taskName = "Gather", completionTime = 124, amount = 50 },
      },
    }
    C_NeighborhoodInitiative = {
      RequestNeighborhoodInitiativeInfo = function() requests.initiative = requests.initiative + 1 end,
      RequestInitiativeActivityLog = function() requests.activity = requests.activity + 1 end,
      IsInitiativeEnabled = function() return true end,
      PlayerHasInitiativeAccess = function() return true end,
      GetActiveNeighborhood = function() return "Housing-Guild" end,
      IsViewingActiveNeighborhood = function() return true end,
      IsPlayerInNeighborhoodGroup = function() return false end,
      GetRequiredLevel = function() return 1 end,
      PlayerMeetsRequiredLevel = function() return true end,
      GetNeighborhoodInitiativeInfo = function() return initiativeInfo end,
      GetInitiativeActivityLogInfo = function() return activityInfo end,
      GetTrackedInitiativeTasks = function() return { trackedIDs = { 7 } } end,
      GetAvailableHouseXP = function() return 100 end,
    }
  `);
  source.push(await moduleSource("Collectors/Housing.lua"));
  source.push(`
    assert(registered and registered.name == "housing")
    local context = {
      guild = { key = "main", name = "Raining Embers" },
      sourceCharacter = { id = "Player-Test" },
    }
    local neighborhoodInfo = {
      neighborhoodGUID = "Housing-Guild",
      neighborhoodName = "Raining Embers",
      ownerGUID = "Guild-Test",
      ownerName = "Raining Embers",
      neighborhoodOwnerType = 1,
    }
    local roster = {
      { playerGUID = "Player-Test", residentName = "Resident", plotID = 54, subdivision = 0 },
      { playerGUID = "Player-Two", residentName = "Second", plotID = 10, subdivision = 1 },
    }
    registered:HandleEvent(context, "UPDATE_BULLETIN_BOARD_ROSTER", neighborhoodInfo, roster)
    registered:HandleEvent(context, "NEIGHBORHOOD_LIST_UPDATED", {
      { neighborhoodGUID = "Housing-Guild", ownerName = "Raining Embers" },
      { neighborhoodGUID = "Housing-Guild-Three", ownerName = "Raining Embers",
        neighborhoodName = "Raining Embers", subdivision = 2 },
      { neighborhoodGUID = "Housing-Other", ownerName = "Other Guild" },
    })
    registered:HandleEvent(context, "UPDATE_BULLETIN_BOARD_ROSTER_STATUSES",
      { { playerGUID = "Player-One", isOnline = true } })
    local payload, coverage = registered:Collect(context)

    assert(payload.neighborhood.info.ownerGUID == "Guild-Test")
    assert(payload.neighborhood.roster[1].residentName == "Resident",
      "the second event argument is the roster")
    assert(payload.neighborhood.rosterStatuses[1].isOnline == true)
    assert(payload.guildNeighborhood.isApprovedGuildNeighborhood == true)
    assert(payload.guildNeighborhood.verificationStatus == "approved_guild_owner_verified")
    assert(payload.initiative.info.currentProgress == 625)
    assert(payload.initiative.info.progressRequired == 1000)
    assert(#payload.initiative.info.tasks == 2 and payload.initiative.info.tasks[1].criteriaList[1].requiredValue == 10,
      "full task details are retained")
    assert(#payload.initiative.info.milestones == 1, "full milestone details are retained")
    assert(#payload.initiative.activityLog.taskActivity == 2,
      "the full activity-log entries are retained")
    assert(payload.guildNeighborhood.initiative.taskCount == 2)
    assert(payload.guildNeighborhood.activityLog.entryCount == 2)
    assert(payload.knownSubdivisionCount == 3 and payload.activeSubdivision == 0)
    assert(payload.subdivisionsByIndex["0"].directObservation == true)
    assert(payload.subdivisionsByIndex["0"].exactAvailability == true)
    assert(payload.subdivisionsByIndex["1"].provenance == "roster-derived/shared-layout")
    assert(payload.subdivisionsByIndex["1"].exactAvailability == false)
    assert(payload.subdivisionsByIndex["1"].mapData[1].plotID == 54)
    assert(payload.subdivisionsByIndex["1"].mapData[1].ownerName == nil,
      "a shared layout never carries another subdivision's owner")
    assert(#payload.discovery.neighborhoods == 2,
      "passive discovery retains only the authorized guild")
    assert(payload.neighborhoodsByGuid["Housing-Guild-Three"].provenance == "passive_house_finder")
    assert(payload.subdivisionsByIndex["2"].discoveryProvenance == "passive_house_finder")
    assert(requests.house == 1 and requests.neighborhood == 1 and requests.initiative == 1)
    assert(requests.discovery == 1)
    assert(requests.activity == 1, "activity is requested only after initiative data is loaded")
    assert(coverage.status == "complete")
  `);

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const status = lauxlib.luaL_dostring(L, to_luastring(source.join("\n")));
  if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
});

test("housing resolves the observed alt-guild API mix without crossing guild identities", async () => {
  const modules = [
    "Core/Namespace.lua",
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Coverage.lua",
  ];
  const source = ["EmberSync = {}\n"];
  for (const module of modules) source.push(await moduleSource(module));
  source.push(`
    local registered
    local appended = {}
    EmberSync.CollectorManager = {
      Register = function(_, collector) registered = collector end,
    }
    EmberSync.Database = {
      GetActiveExport = function() return nil end,
      AppendEvent = function(_, stream, payload)
        appended[#appended + 1] = { stream = stream, payload = payload }
        return true
      end,
    }
    Enum = { NeighborhoodOwnerType = { Guild = 1 } }

    local altGUID = "Housing-4-2-16196-67E7"
    local mainGUID = "Housing-4-1-1056-45B4"
    local currentGUID = altGUID
    local activeGUID = altGUID
    local initiativeGUID = altGUID
    local activityGUID = altGUID
    local visibleName = "Raining Embers Alts"

    C_Housing = {
      RequestCurrentHouseInfo = function() end,
      GetCurrentNeighborhoodGUID = function() return currentGUID end,
      GetPlayerOwnedHouses = function() return {} end,
    }
    C_HousingNeighborhood = {
      RequestNeighborhoodInfo = function() end,
      GetNeighborhoodName = function() return visibleName end,
      GetNeighborhoodMapData = function() return { { plotID = 19 } } end,
    }
    C_NeighborhoodInitiative = {
      RequestNeighborhoodInitiativeInfo = function() end,
      RequestInitiativeActivityLog = function() end,
      GetActiveNeighborhood = function() return activeGUID end,
      IsViewingActiveNeighborhood = function() return true end,
      GetNeighborhoodInitiativeInfo = function()
        return {
          isLoaded = true,
          neighborhoodGUID = initiativeGUID,
          initiativeID = 16,
          currentCycleID = 10,
          currentProgress = 250,
          progressRequired = 1000,
          tasks = { { ID = 1, taskName = "Alt Endeavor" } },
          milestones = {},
        }
      end,
      GetInitiativeActivityLogInfo = function()
        return {
          isLoaded = true,
          neighborhoodGUID = activityGUID,
          taskActivity = { { taskID = 1, playerName = "Alt Member" } },
        }
      end,
    }
  `);
  source.push(await moduleSource("Collectors/Housing.lua"));
  source.push(`
    local altContext = {
      guild = { key = "alt", name = "Raining Embers Alts" },
      sourceCharacter = { id = "Player-Alt" },
    }
    local hybridInfo = {
      neighborhoodGUID = mainGUID,
      neighborhoodName = "Raining Embers Alts",
      ownerGUID = "Guild-1171-00000466FC3D",
      ownerName = "Raining Embers",
      neighborhoodOwnerType = 1,
      locationName = "Founder's Point",
    }
    local altRoster = {
      { playerGUID = "Player-Alt", residentName = "Alt Member", plotID = 19 },
    }

    registered:HandleEvent(altContext, "UPDATE_BULLETIN_BOARD_ROSTER", hybridInfo, altRoster)
    registered:HandleEvent(altContext, "NEIGHBORHOOD_NAME_UPDATED", mainGUID, "Raining Embers")
    assert(registered.neighborhoodInfo.neighborhoodName == "Raining Embers Alts",
      "a late name event for the stale reported GUID cannot replace the active alt name")
    registered:HandleEvent(altContext, "INITIATIVE_TASK_COMPLETED", "Alt Endeavor")
    local payload, coverage = registered:Collect(altContext)
    assert(payload.guildNeighborhood.isApprovedGuildNeighborhood == true)
    assert(payload.guildNeighborhood.verificationStatus
      == "approved_guild_context_verified_with_api_inconsistency")
    assert(payload.guildNeighborhood.neighborhoodGUID == altGUID)
    assert(payload.guildNeighborhood.neighborhoodName == "Raining Embers Alts")
    assert(payload.guildNeighborhood.ownerName == "Raining Embers")
    assert(payload.guildNeighborhood.canonicalOwnerName == "Raining Embers Alts")
    assert(payload.guildNeighborhood.reportedOwnerName == "Raining Embers")
    assert(payload.guildNeighborhood.reportedNeighborhoodGUID == mainGUID)
    assert(payload.guildNeighborhood.ownerNameMatches == false)
    assert(payload.guildNeighborhood.reportedGuidMatches == false)
    assert(payload.guildNeighborhood.apiIdentityInconsistent == true)
    assert(payload.guildNeighborhood.sourceCharacterInRoster == true)
    assert(payload.neighborhood.info.neighborhoodGUID == altGUID)
    assert(payload.neighborhood.info.ownerName == "Raining Embers Alts")
    assert(payload.neighborhood.info.locationName == nil,
      "a location coupled to the stale bulletin identity must not be canonicalized as alt data")
    assert(payload.neighborhood.reportedInfo.neighborhoodGUID == mainGUID)
    assert(payload.neighborhood.reportedInfo.ownerName == "Raining Embers")
    assert(payload.neighborhood.reportedInfo.diagnosticOnly == true)
    assert(payload.initiative.info.neighborhoodGUID == altGUID)
    assert(payload.initiative.activityLog.neighborhoodGUID == altGUID)
    assert(coverage.status == "complete")
    assert(#appended == 1 and appended[1].payload.neighborhoodGUID == altGUID,
      "a verified alt initiative event is attributed to the alt neighborhood")

    registered:ResetStaging()
    local mainContext = {
      guild = { key = "main", name = "Raining Embers" },
      sourceCharacter = { id = "Player-Alt" },
    }
    registered:HandleEvent(mainContext, "UPDATE_BULLETIN_BOARD_ROSTER", hybridInfo, altRoster)
    local wrongGuildPayload, wrongGuildCoverage = registered:Collect(mainContext)
    assert(wrongGuildPayload.guildNeighborhood.isApprovedGuildNeighborhood == false,
      "a stale main ownerName must not authorize an actively selected alt neighborhood")
    assert(wrongGuildCoverage.status == "interaction_required")
    assert(wrongGuildPayload.neighborhood.info == nil and wrongGuildPayload.neighborhood.roster == nil)
    assert(wrongGuildPayload.initiative.info == nil and wrongGuildPayload.initiative.activityLog == nil,
      "a rejected neighborhood must not serialize its Endeavor or activity-log data")

    registered:ResetStaging()
    activityGUID = mainGUID
    registered:HandleEvent(altContext, "UPDATE_BULLETIN_BOARD_ROSTER", hybridInfo, altRoster)
    registered:HandleEvent(altContext, "INITIATIVE_TASK_COMPLETED", "Mismatched Endeavor")
    local mismatchPayload, mismatchCoverage = registered:Collect(altContext)
    assert(mismatchPayload.guildNeighborhood.isApprovedGuildNeighborhood == false)
    assert(mismatchPayload.guildNeighborhood.verificationStatus == "neighborhood_guid_mismatch")
    assert(mismatchCoverage.status == "interaction_required")
    assert(string.find(mismatchCoverage.opportunity, "Raining Embers Alts", 1, true) ~= nil)
    assert(mismatchPayload.initiative.info == nil and mismatchPayload.initiative.activityLog == nil)
    assert(#appended == 1, "an event with cross-GUID payload evidence must fail closed")

    registered:ResetStaging()
    activityGUID = nil
    registered:HandleEvent(altContext, "UPDATE_BULLETIN_BOARD_ROSTER", hybridInfo, altRoster)
    local missingGuidPayload, missingGuidCoverage = registered:Collect(altContext)
    assert(missingGuidPayload.guildNeighborhood.isApprovedGuildNeighborhood == true)
    assert(missingGuidPayload.initiative.activityLog == nil)
    assert(missingGuidPayload.initiative.activityLogRejected.rejectionReason
      == "activity_neighborhood_guid_unverified")
    assert(missingGuidCoverage.status == "partial",
      "a loaded activity block without a canonical GUID cannot make coverage complete")

    registered:ResetStaging()
    activityGUID = altGUID
    registered:HandleEvent(altContext, "UPDATE_BULLETIN_BOARD_ROSTER", hybridInfo, {})
    local noRosterPayload, noRosterCoverage = registered:Collect(altContext)
    assert(noRosterPayload.guildNeighborhood.isApprovedGuildNeighborhood == false)
    assert(noRosterCoverage.status == "interaction_required")
  `);

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const status = lauxlib.luaL_dostring(L, to_luastring(source.join("\n")));
  if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
});

test("performance guards prevent synchronous combat recrawls and event churn", async () => {
  const [manager, database, damage, progression, collections, housing] = await Promise.all([
    readFile(path.join(addonRoot, "Core/CollectorManager.lua"), "utf8"),
    readFile(path.join(addonRoot, "Core/Database.lua"), "utf8"),
    readFile(path.join(addonRoot, "Collectors/DamageMeter.lua"), "utf8"),
    readFile(path.join(addonRoot, "Collectors/Progression.lua"), "utf8"),
    readFile(path.join(addonRoot, "Collectors/Collections.lua"), "utf8"),
    readFile(path.join(addonRoot, "Collectors/Housing.lua"), "utf8"),
  ]);

  assert.match(manager, /coroutine\.create/);
  assert.match(manager, /collector\.allowInCombat ~= true and isInCombat\(\)/);
  assert.match(manager, /minInterval/);
  assert.match(manager, /COLLECTOR_HEARTBEAT_SECONDS/);
  assert.match(database, /Util\.DeepEqual\(existing\.payload, sanitized\)/);
  assert.match(database, /DATABASE_SIZE_CHECK_SEQUENCE_INTERVAL/);
  assert.doesNotMatch(damage, /"DAMAGE_METER_(?:COMBAT_SESSION|CURRENT_SESSION)_UPDATED"/);
  assert.match(damage, /"PLAYER_REGEN_ENABLED"/);
  assert.match(progression, /expensive = true/);
  assert.match(collections, /expensive = true/);
  assert.match(housing, /RequestNeighborhoodInitiativeInfo/);
  assert.match(housing, /RequestInitiativeActivityLog/);
  assert.doesNotMatch(housing, /SetViewingNeighborhood/,
    "collection must not silently change the neighborhood selected by the user");
});

test("collector jobs yield across frames and defer bulk work until combat ends", async () => {
  const source = ["EmberSync = {}\n"];
  for (const module of [
    "Core/Namespace.lua",
    "Core/Constants.lua",
    "Core/Util.lua",
    "Core/Coverage.lua",
  ]) source.push(await moduleSource(module));
  source.push(`
    local clock = 100
    local inCombat = false
    local timers = {}
    GetTimePreciseSec = function() return clock end
    GetServerTime = function() return 1000 + math.floor(clock) end
    UnitGUID = function() return "Player-1-00000001" end
    UnitFullName = function() return "Tester", "Dalaran" end
    InCombatLockdown = function() return inCombat end
    C_Timer = {
      After = function(delay, callback)
        timers[#timers + 1] = { delay = delay or 0, callback = callback }
      end,
      NewTicker = function() return { Cancel = function() end } end,
    }
    local commits = 0
    EmberSync.Database = {
      IsCategoryEnabled = function() return true end,
      Ensure = function() return {} end,
      CommitDataset = function(_, name)
        commits = commits + 1
        return true, name, "unchanged"
      end,
    }
    EmberSync.GuildLock = {
      IsAuthorized = function() return true end,
      GetIdentity = function()
        return { key = "main", name = "Raining Embers", realm = "Dalaran", region = 1, rankIndex = 5 }
      end,
      OnChanged = function() end,
    }
  `);
  source.push(await moduleSource("Core/CollectorManager.lua"));
  source.push(`
    local runs = 0
    EmberSync.Constants.STATE_DATASETS.sliced_test = true
    EmberSync.Constants.STATE_DATASETS.expensive_logout_test = true
    local collector = {
      name = "sliced_test",
      scope = "account",
      minInterval = 10,
      events = { "SLICED_TEST_EVENT" },
      Collect = function()
        runs = runs + 1
        for index = 1, 450 do
          EmberSync.Util.Cooperate(index, 100)
        end
        return { value = runs }, EmberSync.Coverage.Complete(), "account"
      end,
    }
    local manager = EmberSync.CollectorManager
    manager:Register(collector)
    manager.running = true
    manager.generation = 1
    assert(manager:Run("sliced_test", "test") == true)
    assert(runs == 1 and commits == 0, "the first work slice must yield before commit")
    while #timers > 0 do
      local timer = table.remove(timers, 1)
      clock = clock + timer.delay
      timer.callback()
    end
    assert(commits == 1)
    assert(manager:GetPerformanceStats().sliced_test.lastYieldCount >= 4)

    clock = clock + 11
    inCombat = true
    assert(manager:Run("sliced_test", "combat_event") == false)
    assert(runs == 1 and manager.deferred.sliced_test == "combat_event")
    inCombat = false
    manager:HandleEvent("PLAYER_REGEN_ENABLED")
    while #timers > 0 do
      local timer = table.remove(timers, 1)
      clock = clock + timer.delay
      timer.callback()
    end
    assert(runs == 2 and commits == 2, "deferred work runs after combat")

    local logoutCatalogRuns = 0
    manager:Register({
      name = "expensive_logout_test",
      scope = "account",
      expensive = true,
      Collect = function()
        logoutCatalogRuns = logoutCatalogRuns + 1
        return {}, EmberSync.Coverage.Complete(), "account"
      end,
    })
    manager:Finalize()
    assert(logoutCatalogRuns == 0,
      "logout must persist completed data without synchronously recrawling expensive catalogs")
  `);

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const status = lauxlib.luaL_dostring(L, to_luastring(source.join("\n")));
  if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
});
