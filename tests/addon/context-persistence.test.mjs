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

test("guild-bank requests stay serialized without re-attributing closed-context data", async () => {
  await execute(coreModules, `
    local registered
    local now = 50
    local queries = {}
    local secretItemLink = {}
    issecretvalue = function(value) return value == secretItemLink end
    GetTime = function() return now end
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    EmberSync.Database = {
      GetActiveExport = function()
        return {
          datasets = {
            guild_bank = {
              sourceCharacter = { id = "Player-One" },
              payload = {
                tabs = {
                  [1] = { items = { [1] = { itemLink = "item:1" } } },
                },
              },
            },
          },
        }
      end,
    }
    GetNumGuildBankTabs = function() return 2 end
    GetGuildBankTabInfo = function(tab)
      if tab == 1 then return "Supplies", 1, true, true, 10, 10 end
      return nil, nil, nil, nil, nil, nil
    end
    QueryGuildBankTab = function(tab) queries[#queries + 1] = { "items", tab } end
    QueryGuildBankLog = function(tab) queries[#queries + 1] = { "log", tab } end
    QueryGuildBankText = function(tab) queries[#queries + 1] = { "text", tab } end
    GetGuildBankItemInfo = function(tab, slot)
      if tab == 1 and slot == 1 then return 7549241, 7, false, false, 1 end
      return nil
    end
    GetGuildBankItemLink = function(tab, slot)
      if tab == 1 and slot == 1 then
        return "|cnIQ1:|Hitem:238511::::::::90:257:::::::::|h[Fixture Leather |A:Professions-ChatIcon-Quality-12-Tier1:17:15::1|a]|h|r"
      end
      if tab == 1 and slot == 2 then return secretItemLink end
      return nil
    end
    GetNumGuildBankTransactions = function() return 0 end
    GetGuildBankText = function(tab) return "Text " .. tab end
    GetGuildBankMoney = function() return 100 end
    GetGuildBankWithdrawMoney = function() return 50 end
  ` + await moduleSource("Collectors/GuildBank.lua"), `
    local context = {
      sourceCharacter = { id = "Player-One" },
      guild = { key = "main", rankIndex = 5, rankName = "Member" },
    }
    local closed, closedCoverage, _, _, closedOptions = registered:Collect(context)
    assert(closedCoverage.status == "interaction_required")
    assert(next(closed) == nil)
    assert(closedOptions.coverageOnly == true,
      "closed context must preserve the old envelope instead of re-enveloping privileged payloads")

    registered:HandleEvent(context, "GUILDBANKFRAME_OPENED")
    local first, firstCoverage = registered:Collect(context)
    assert(firstCoverage.status == "partial")
    assert(firstCoverage.reason == "guild_bank_permissions_pending")
    assert(#queries == 3 and queries[1][2] == 1 and queries[3][2] == 1)
    assert(first.tabs[1].items[1].itemLink == "item:1")

    registered:Collect(context)
    assert(#queries == 3, "an outstanding tab request must block overlapping requests")
    registered:HandleEvent(context, "GUILDBANKBAGSLOTS_CHANGED")
    local itemPass = registered:Collect(context)
    assert(itemPass.tabs[1].items[1].itemID == 238511)
    assert(itemPass.tabs[1].items[1].iconFileID == 7549241)
    assert(itemPass.tabs[1].items[1].texture == 7549241)
    assert(itemPass.tabs[1].items[2] == nil,
      "secret item links must be omitted before string matching or comparison")
    assert(#queries == 3, "item response alone must not advance past pending log/text")
    registered:HandleEvent(context, "GUILDBANKLOG_UPDATE")
    registered:Collect(context)
    assert(#queries == 3, "log response alone must not advance past pending text")
    registered:HandleEvent(context, "GUILDBANK_UPDATE_TEXT", 1)
    local second, secondCoverage = registered:Collect(context)
    assert(#queries == 6 and queries[4][2] == 2 and queries[6][2] == 2)
    assert(secondCoverage.reason == "guild_bank_permissions_pending")
    assert(secondCoverage.status ~= "forbidden",
      "unknown tab metadata must remain fail-closed/loading, not rank-forbidden")

    registered:HandleEvent(context, "GUILDBANKFRAME_CLOSED")
    assert(registered.activeRequest == nil)
  `);
});

test("inventory restores bounded same-source bank snapshots without claiming fresh completeness", async () => {
  await execute(coreModules, `
    local registered
    EmberSync.CollectorManager = { Register = function(_, value) registered = value end }
    EmberSync.Database = {
      GetActiveExport = function()
        return {
          datasets = {
            ["inventory:Player-One"] = {
              sourceCharacter = { id = "Player-One" },
              payload = {
                banks = { { index = 90, slots = 1, items = { [1] = { itemID = 42 } } } },
                bankTypes = { 0, 2 },
              },
            },
          },
        }
      end,
    }
    C_Container = {
      GetContainerNumSlots = function() return 0 end,
      GetContainerItemInfo = function() return nil end,
    }
    Enum = { BankType = { Character = 0, Account = 2 }, BagIndex = {} }
  ` + await moduleSource("Collectors/Inventory.lua"), `
    local context = { sourceCharacter = { id = "Player-One" } }
    local payload, coverage = registered:Collect(context)
    assert(coverage.status == "partial")
    assert(coverage.personalBankObservedThisSession == false)
    assert(coverage.warbandBankObservedThisSession == false)
    assert(#payload.banks == 1 and payload.banks[1].index == 90)
    assert(#payload.bankTypes == 2)

    registered:ResetStaging()
    local other = registered:Collect({ sourceCharacter = { id = "Player-Two" } })
    assert(#other.banks == 0, "bank payloads must never restore across source characters")

    registered:ResetStaging()
    C_Bank = {
      FetchViewableBankTypes = function() return { 0, 2 } end,
      FetchPurchasedBankTabData = function() return {} end,
    }
    registered:HandleEvent(context, "BANKFRAME_OPENED")
    local fresh, freshCoverage = registered:Collect(context)
    assert(freshCoverage.status == "complete")
    assert(#fresh.banks == 1, "fresh enumeration may retain same-source saved bank tabs")
  `);
});
