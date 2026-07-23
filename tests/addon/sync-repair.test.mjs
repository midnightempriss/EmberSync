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

const utilityModules = [
  "Core/Namespace.lua",
  "Core/Constants.lua",
  "Core/Util.lua",
  "Core/Coverage.lua",
];

test("secret values fail closed and legacy installation IDs migrate deterministically", async () => {
  await execute(utilityModules, `
    local secret = { __secret = true }
    issecretvalue = function(value)
      return (type(value) == "table" and value.__secret == true) or value == "secret-key"
    end
    assert(EmberSync.Util.NormalizeGuildName(secret) == nil)
    local clean, state = EmberSync.Util.Sanitize({ visible = "yes", hidden = secret })
    assert(clean.visible == "yes" and clean.hidden == nil)
    assert(state.truncated == true and state.secretValuesOmitted == 1)
    local keyed, keyedState = EmberSync.Util.Sanitize({ ["secret-key"] = "hidden", visible = true })
    assert(keyed["secret-key"] == nil and keyed.visible == true)
    assert(keyedState.truncated == true and keyedState.secretValuesOmitted == 1)
    local copied = EmberSync.Util.Copy({ ["secret-key"] = "hidden", visible = true })
    assert(copied["secret-key"] == nil and copied.visible == true)
    assert(EmberSync.Util.EstimateSize(secret) == 0)
    assert(EmberSync.Util.IsPlayerGUID("Player-3676-00000001"))
    assert(not EmberSync.Util.IsPlayerGUID("Player-Test"))
    local first, migrated = EmberSync.Util.NormalizeInstallationId("es-legacy-install")
    local second = EmberSync.Util.NormalizeInstallationId("es-legacy-install")
    assert(migrated == true and first == second and #first == 16)
    assert(first == "m4T9HLOW1j5cZmb-", "cross-runtime migration golden value changed")
    assert(string.match(first, "^[A-Za-z0-9_-]+$") ~= nil)

    GetServerTime = function() return 1000 end
    UnitGUID = function() return "Player-1-00000001" end
    UnitFullName = function() return "Tester", "Dalaran" end
    EmberSync.GuildLock = {
      IsAuthorized = function() return true end,
      GetIdentity = function()
        return { key = "main", name = "Raining Embers", realm = "Dalaran", region = 1,
          rankName = "Member", rankIndex = 5 }
      end,
    }
  ` + await moduleSource("Core/Database.lua"), `
    EmberSyncDB = {
      schemaVersion = 1,
      installationId = "es-legacy-install",
      exports = {
        main = {
          installationId = "es-legacy-install",
          datasets = {
            guild = { installationId = "es-legacy-install" },
          },
          events = {},
          coverage = {},
        },
      },
      settings = { categories = {}, minimap = {} },
      meta = {},
    }
    local db = EmberSync.Database:Ensure()
    assert(#db.installationId == 16)
    assert(db.exports.main.installationId == db.installationId)
    assert(db.exports.main.datasets.guild.installationId == db.installationId)
    assert(db.meta.installationIdMigratedAt == 1000)

    local ok = EmberSync.Database:CommitDataset("guild", "guild", "main",
      { visible = true, hidden = secret },
      EmberSync.Coverage.Partial("guild_components_pending"))
    assert(ok == true)
    local envelope = db.exports.main.datasets.guild
    assert(envelope.coverage.status == "partial")
    assert(envelope.coverage.reason == "guild_components_pending")
    assert(envelope.coverage.truncated == true)
    assert(envelope.coverage.secretValuesOmitted == 1)

    local originalSequence = envelope.sequence
    local originalCapturedAt = envelope.capturedAt
    local coverageOnlyOk, coverageOnlyKey, coverageOnlyDisposition =
      EmberSync.Database:CommitDataset("guild", "guild", "main", {},
        EmberSync.Coverage.Interaction("guild_components_pending"), nil,
        { coverageOnly = true, force = true })
    assert(coverageOnlyOk and coverageOnlyKey == "guild"
      and coverageOnlyDisposition == "coverage_only")
    envelope = db.exports.main.datasets.guild
    assert(envelope.sequence == originalSequence,
      "coverage-only observations must not manufacture a payload sequence")
    assert(envelope.capturedAt > originalCapturedAt,
      "coverage-only observations must advance signed capture time")
    assert(envelope.coverage.status == "interaction_required")
    assert(envelope.payload.visible == true,
      "coverage-only observations must retain the last-good payload")

    UnitGUID = function() return "Player-Test" end
    local rejected, rejectReason = EmberSync.Database:CommitDataset("guild", "guild", "main",
      { visible = true }, EmberSync.Coverage.Complete())
    assert(rejected == false and rejectReason == "source_identity_unreadable")
    UnitGUID = function() return "Player-1-00000001" end

    assert(EmberSync.Database:RecordCollectorAttempt("guild", "test"))
    assert(EmberSync.Database:RecordCollectorResult("guild", false, { error = "temporary" }))
    assert(db.exports.main.collectorHealth.guild.consecutiveFailures == 1)
    assert(EmberSync.Database:RecordCollectorResult("guild", true, {
      outcome = "committed", coverage = EmberSync.Coverage.Complete(),
    }))
    assert(db.exports.main.collectorHealth.guild.consecutiveFailures == 0)
    assert(db.exports.main.collectorHealth.guild.lastSuccessAt == 1000)
    assert(EmberSync.Database:FinalizeActiveExport())
    assert(db.persistedAt == 1000 and db.exports.main.persistedAt == 1000)
  `);
});

test("guild tracks component readiness and preserves last-good GMOD before an explicit clear", async () => {
  await execute(utilityModules, `
    local registered
    local motd
    local now = 2000
    local appended = {}
    GetServerTime = function() now = now + 1; return now end
    EmberSync.CollectorManager = { Register = function(_, collector) registered = collector end }
    EmberSync.Database = {
      GetActiveExport = function()
        return {
          datasets = {
            guild = {
              guildKey = "main",
              payload = { motd = "Last good message", motdObservedAt = 1900 },
            },
          },
          events = {},
        }
      end,
      AppendEvent = function(_, stream, payload)
        appended[#appended + 1] = { stream = stream, payload = payload }
        return true
      end,
    }
    C_GuildInfo = {
      GuildRoster = function() end,
      GetGuildInfoText = function() return "Guild info" end,
      GetGuildNewsInfo = function() end,
    }
    GetNumGuildMembers = function() return 1, 1, 1 end
    GetGuildRosterInfo = function()
      return "Member-Dalaran", "Member", 5, 80, "Mage", "Dalaran", "note", "officer",
        true, 0, "MAGE", 100, 1, false, false, 8, "Player-Test"
    end
    GetGuildRosterMOTD = function() return motd end
    GuildControlGetNumRanks = function() return 1 end
    GuildControlGetRankName = function() return "Member" end
    GuildControlGetRankFlags = function() return true end
    GetNumGuildNews = function() return 0 end
    GetNumGuildChallenges = function() return 0 end
    GetGuildChallengeInfo = function() end
    GetNumGuildEvents = function() return 1 end
    GetGuildEventInfo = function()
      return "join", "Member-Dalaran", nil, nil, 0, 0, 0, 1
    end
    GetGuildRewards = function() return {} end
    CanViewOfficerNote = function() return false end
  ` + await moduleSource("Collectors/Guild.lua"), `
    local context = {
      guild = { key = "main", name = "Raining Embers", realm = "Dalaran", region = 1,
        rankIndex = 5, rankName = "Member" },
      sourceCharacter = { id = "Player-Test" },
    }
    local retained, retainedCoverage, _, _, retainedOptions = registered:Collect(context)
    assert(retained.motd == "Last good message" and retained.motdSource == "last_good")
    assert(retained.motdExplicitlyEmpty == false)
    assert(retained.componentCoverage.motd.retainedLastGood == true)
    assert(retainedCoverage.status == "partial")
    assert(retainedOptions.allowCrossSourceReplace == false)
    assert(appended[1].stream == "guild" and appended[1].payload.provenance == "guild_event_log")
    assert(appended[2].stream == "guild_presence"
      and appended[2].payload.totalMembers == 1
      and appended[2].payload.onlineCount == 1)

    motd = nil
    registered:HandleEvent(context, "GUILD_MOTD", "")
    local cleared, clearCoverage, _, _, clearOptions = registered:Collect(context)
    assert(cleared.motd == "" and cleared.motdSource == "event")
    assert(cleared.motdExplicitlyEmpty == true)
    assert(cleared.componentCoverage.motd.status == "complete")
    assert(clearCoverage.status == "complete")
    assert(clearOptions.allowCrossSourceReplace == true)
    assert(cleared.roster[1].officerNote == nil,
      "officer notes remain absent without the in-game permission")
  `);
});

test("calendar initializes passively and persists only clearly guild-scoped records", async () => {
  await execute(utilityModules, `
    local registered
    local opens = 0
    local openedInfo = { title = "Guild Detail", calendarType = "GUILD_EVENT", eventID = 10 }
    GetServerTime = function() return 3000 end
    GetTime = function() return 50 end
    EmberSync.CollectorManager = { Register = function(_, collector) registered = collector end }
    EmberSync.Database = { GetActiveExport = function() return nil end }
    C_Calendar = {
      OpenCalendar = function() opens = opens + 1 end,
      GetMonthInfo = function(offset)
        if offset == 0 then return { numDays = 1, month = 7, year = 2026 } end
      end,
      GetNumDayEvents = function(offset)
        return offset == 0 and 6 or 0
      end,
      GetDayEvent = function(_, _, index)
        if index == 1 then return { title = "Holiday", calendarType = "HOLIDAY" } end
        if index == 2 then return { title = "Guild Event", calendarType = "GUILD_EVENT" } end
        if index == 3 then return { title = "Invite", calendarType = "PLAYER" } end
        if index == 4 then
          return { title = "Guild Announcement", calendarType = "GUILD_ANNOUNCEMENT" }
        end
        if index == 5 then return { title = "Community", calendarType = "COMMUNITY_EVENT" } end
        return { title = "Unknown" }
      end,
      GetEventInfo = function() return openedInfo end,
      GetNumInvites = function() return 1 end,
      GetInviteInfo = function() return { name = "Guild Attendee" } end,
    }
  ` + await moduleSource("Collectors/Calendar.lua"), `
    local context = {
      guild = { key = "main" },
      sourceCharacter = { id = "Player-Test" },
    }
    assert(registered:HandleEvent(context, "PLAYER_ENTERING_WORLD") == false)
    registered:HandleEvent(context, "CALENDAR_OPEN_EVENT")
    openedInfo = { title = "Private Detail", calendarType = "PLAYER", eventID = 11 }
    registered:HandleEvent(context, "CALENDAR_UPDATE_EVENT")
    local payload, coverage, _, _, options = registered:Collect(context)
    assert(opens == 1, "collection reuses the passive initialization cooldown")
    assert(#payload.events == 2 and #payload.guildEvents == 2)
    assert(payload.events[1].info.title == "Guild Event")
    assert(payload.events[2].info.title == "Guild Announcement")
    for _, record in ipairs(payload.events) do
      assert(record.privacyClass == "guild")
      assert(record.info.calendarType == "GUILD_EVENT"
        or record.info.calendarType == "GUILD_ANNOUNCEMENT")
    end
    assert(payload.globalEvents == nil and payload.personalEvents == nil)
    assert(payload.lastOpenedEvent == nil, "opening a personal entry clears the detail pointer")
    assert(EmberSync.Util.TableCount(payload.openedEventDetails) == 1)
    local _, detail = next(payload.openedEventDetails)
    assert(detail.info.title == "Guild Detail" and detail.privacyClass == "guild")
    assert(payload.initialization.openSupported == true and payload.initialization.openRequested == true)
    assert(coverage.status == "partial" and coverage.eventCount == 2)
    assert(coverage.guildEventCount == 2)
    assert(coverage.excludedNonGuildEventCount == nil)
    assert(coverage.personalEventCount == nil and coverage.globalEventCount == nil)
    assert(options.allowCrossSourceReplace == true)
  `);
});

test("calendar purges legacy personal and global entries from retained last-good data", async () => {
  await execute(utilityModules, `
    local registered
    GetServerTime = function() return 3100 end
    GetTime = function() return 60 end
    EmberSync.CollectorManager = { Register = function(_, collector) registered = collector end }
    EmberSync.Database = {
      GetActiveExport = function()
        return {
          datasets = {
            calendar = {
              capturedAt = 2500,
              sourceCharacter = { id = "Player-Test" },
              payload = {
                months = { { month = 7, year = 2026, numDays = 31 } },
                events = {
                  { info = { title = "Guild Event", calendarType = "GUILD_EVENT" } },
                  { info = { title = "Private Invite", calendarType = "PLAYER" } },
                  { info = { title = "Holiday", calendarType = "HOLIDAY" } },
                },
                guildEvents = {
                  { info = { title = "Guild Event", calendarType = "GUILD_EVENT" } },
                },
                personalEvents = {
                  { info = { title = "Private Invite", calendarType = "PLAYER" } },
                },
                globalEvents = {
                  { info = { title = "Holiday", calendarType = "HOLIDAY" } },
                },
                lastOpenedEvent = {
                  info = { title = "Private Detail", calendarType = "PLAYER" },
                  privacyClass = "personal",
                },
                openedEventDetails = {
                  guild = {
                    info = { title = "Guild Detail", calendarType = "GUILD_ANNOUNCEMENT" },
                    privacyClass = "guild",
                  },
                  private = {
                    info = { title = "Private Detail", calendarType = "PLAYER" },
                    privacyClass = "personal",
                  },
                  global = {
                    info = { title = "Global Detail", calendarType = "HOLIDAY" },
                    privacyClass = "global",
                  },
                },
              },
            },
          },
        }
      end,
    }
    C_Calendar = {
      OpenCalendar = function() end,
      GetMonthInfo = function() return nil end,
      GetNumDayEvents = function() return 0 end,
      GetDayEvent = function() return nil end,
    }
  ` + await moduleSource("Collectors/Calendar.lua"), `
    local context = {
      guild = { key = "main" },
      sourceCharacter = { id = "Player-Test" },
    }
    local payload, coverage, _, _, options = registered:Collect(context)
    assert(#payload.events == 1 and #payload.guildEvents == 1)
    assert(payload.events[1].info.title == "Guild Event")
    assert(payload.personalEvents == nil and payload.globalEvents == nil)
    assert(payload.lastOpenedEvent == nil)
    assert(EmberSync.Util.TableCount(payload.openedEventDetails) == 1)
    assert(payload.openedEventDetails.guild.info.title == "Guild Detail")
    assert(payload.openedEventDetails.private == nil and payload.openedEventDetails.global == nil)
    assert(coverage.reason == "calendar_initialization_pending")
    assert(coverage.retainedLastGood == true and coverage.lastGoodCapturedAt == 2500)
    assert(options.allowCrossSourceReplace == true)
  `);
});

test("guild bank materializes newly observed transactions once into the canonical event stream", async () => {
  await execute(utilityModules, `
    local registered
    local now = 3500
    local appended = {}
    local activeExport = { datasets = {}, events = { guild_bank = {} } }
    GetServerTime = function() now = now + 1; return now end
    GetTime = function() return now end
    EmberSync.CollectorManager = { Register = function(_, collector) registered = collector end }
    EmberSync.Database = {
      GetActiveExport = function() return activeExport end,
      AppendEvent = function(_, stream, payload)
        appended[#appended + 1] = { stream = stream, payload = EmberSync.Util.Copy(payload) }
        activeExport.events[stream] = activeExport.events[stream] or {}
        activeExport.events[stream][#activeExport.events[stream] + 1] = {
          capturedAt = payload.observedAt,
          payload = EmberSync.Util.Copy(payload),
        }
        return true
      end,
    }
    GetNumGuildBankTabs = function() return 1 end
    GetGuildBankTabInfo = function() return "Supplies", 1, true, true, 10, 10 end
    GetGuildBankItemInfo = function() return nil end
    GetGuildBankItemLink = function() return nil end
    GetNumGuildBankTransactions = function() return 1 end
    GetGuildBankTransaction = function()
      return "deposit", "Member-Dalaran", "|Hitem:123|h[Test Item]|h", 2, 1, nil, 0, 0, 0, 1
    end
    GetGuildBankText = function() return "Bank text" end
    GetGuildBankMoney = function() return 100 end
    GetGuildBankWithdrawMoney = function() return 50 end
  ` + await moduleSource("Collectors/GuildBank.lua"), `
    registered.isOpen = true
    registered.loadedTabs[1] = true
    registered.loadedLogs[1] = true
    registered.loadedText[1] = true
    local context = {
      guild = { key = "main", rankIndex = 5, rankName = "Member" },
      sourceCharacter = { id = "Player-Test" },
    }
    local payload, coverage = registered:Collect(context)
    assert(coverage.status == "complete")
    assert(payload.tabs[1].transactions[1].type == "deposit")
    assert(#appended == 1 and appended[1].stream == "guild_bank")
    assert(appended[1].payload.provenance == "guild_bank_log")
    assert(appended[1].payload.tabIndex == 1)
    registered:Collect(context)
    assert(#appended == 1, "a retained transaction snapshot must not be appended twice")
  `);
});

test("world quests enumerate current-expansion maps without accepting or tracking quests", async () => {
  await execute(utilityModules, `
    local registered
    GetServerTime = function() return 4000 end
    EmberSync.CollectorManager = { Register = function(_, collector) registered = collector end }
    EmberSync.Database = { GetActiveExport = function() return nil end }
    Enum = { UIMapType = { Continent = 2, Zone = 3 } }
    C_Map = {
      GetBestMapForUnit = function() return 101 end,
      GetMapInfo = function(id)
        if id == 101 then return { mapID = 101, parentMapID = 100, mapType = 3, name = "Zone One" } end
        if id == 102 then return { mapID = 102, parentMapID = 100, mapType = 3, name = "Zone Two" } end
        return { mapID = 100, parentMapID = 1, mapType = 2, name = "Continent" }
      end,
      GetMapChildrenInfo = function()
        return {
          { mapID = 101, mapType = 3 },
          { mapID = 102, mapType = 3 },
        }
      end,
    }
    C_TaskQuest = {
      GetQuestsForPlayerByMapID = function(id)
        if id == 101 then return { { questId = 5001, x = 0.25, y = 0.75 } } end
        return {}
      end,
      GetQuestInfoByQuestID = function() return "World Quest", 99, false end,
      GetQuestTimeLeftMinutes = function() return 30 end,
    }
    C_QuestLog = {
      IsWorldQuest = function() return true end,
      GetQuestObjectives = function() return { { text = "Do the thing", numRequired = 1 } } end,
      GetQuestTagInfo = function() return { tagID = 1 } end,
    }
    GetNumQuestLogRewards = function() return 0 end
    GetQuestLogRewardInfo = function() end
    GetNumQuestLogRewardCurrencies = function() return 0 end
    GetQuestLogRewardCurrencyInfo = function() end
    GetQuestLogRewardMoney = function() return 0 end
    GetQuestLogRewardXP = function() return 0 end
  ` + await moduleSource("Collectors/WorldQuests.lua"), `
    local payload, coverage = registered:Collect({
      sourceCharacter = { id = "Player-Test" },
      guild = { key = "main" },
    })
    assert(coverage.status == "complete")
    assert(payload.currentMapID == 101 and payload.expansionRootMapID == 100)
    assert(payload.mapsById["101"].quests[1].questID == 5001)
    assert(payload.mapsById["101"].quests[1].expiresAt == 5800)
    assert(payload.mapsById["102"].coverage.status == "complete")
    assert(coverage.questCount == 1 and coverage.passive == true)

    GetQuestLogRewardXP = nil
    local _, partialCoverage = registered:Collect({
      sourceCharacter = { id = "Player-Test" },
      guild = { key = "main" },
    })
    assert(partialCoverage.status == "partial")
    assert(partialCoverage.reason == "world_quest_details_partially_available")
    assert(partialCoverage.missingQuestFields[1] == "experienceReward")
  `);
});

test("world quests keep the versioned current-expansion catalog outside its continent", async () => {
  await execute(utilityModules, `
    local registered
    GetServerTime = function() return 4500 end
    EmberSync.CollectorManager = { Register = function(_, collector) registered = collector end }
    EmberSync.Database = { GetActiveExport = function() return nil end }
    Enum = { UIMapType = { Continent = 2, Zone = 3 } }
    C_Map = {
      GetBestMapForUnit = function() return 84 end,
      GetMapInfo = function(id)
        if id == 84 then return { mapID = 84, parentMapID = 13, mapType = 3, name = "Stormwind" } end
        if id == 13 then return { mapID = 13, parentMapID = 947, mapType = 2, name = "Eastern Kingdoms" } end
        if id == 2537 then return { mapID = 2537, parentMapID = 13, mapType = 2, name = "Quel'Thalas" } end
        return { mapID = id, parentMapID = 2537, mapType = 3, name = "Midnight Zone" }
      end,
      GetMapChildrenInfo = function() return {} end,
    }
    C_TaskQuest = {
      GetQuestsForPlayerByMapID = function() return {} end,
    }
  ` + await moduleSource("Collectors/WorldQuests.lua"), `
    local payload, coverage = registered:Collect({
      sourceCharacter = { id = "Player-Test" },
      guild = { key = "main" },
    })
    assert(payload.currentMapID == 84)
    assert(payload.currentContextRootMapID == 13)
    assert(payload.expansionRootMapID == 2537)
    assert(payload.expansionKey == "midnight")
    assert(payload.mapsById["2395"] ~= nil and payload.mapsById["2405"] ~= nil)
    assert(payload.mapsById["2413"] ~= nil and payload.mapsById["2437"] ~= nil)
    assert(payload.mapsById["84"] ~= nil, "the active map is captured alongside the expansion catalog")
    assert(coverage.mapCount >= 7)
  `);
});

test("the Lua registry contains every approved state dataset and event stream", async () => {
  const constants = await readFile(path.join(addonRoot, "Core/Constants.lua"), "utf8");
  const worldQuests = await readFile(path.join(addonRoot, "Collectors/WorldQuests.lua"), "utf8");
  for (const dataset of [
    "auction_house", "calendar", "character", "collections", "crafting", "damage_meter",
    "guild", "guild_bank", "housing", "inventory", "mail_metadata", "mythic_plus",
    "professions", "progression", "pvp", "world_quests",
  ]) {
    assert.match(constants, new RegExp(`\\b${dataset.replaceAll("_", "\\_")}\\s*=\\s*true`));
  }
  for (const stream of [
    "events.guild_chat", "events.officer_chat", "events.guild", "events.guild_bank",
    "events.guild_presence", "events.neighborhood_initiative",
  ]) {
    assert.ok(constants.includes(`["${stream}"] = true`));
  }
  assert.ok(!constants.includes("guild_chat = true"),
    "guild chat is event-only and cannot reappear as a state dataset");
  assert.ok(!worldQuests.includes("AcceptQuest") && !worldQuests.includes("AddQuestWatch"));
});
