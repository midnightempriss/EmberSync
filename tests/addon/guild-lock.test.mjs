import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { lua, lauxlib, lualib, to_luastring, to_jsstring } from "fengari";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const addonRoot = path.resolve(testDirectory, "../..");
const modules = [
  "Core/Namespace.lua",
  "Core/Constants.lua",
  "Core/Util.lua",
  "Core/Coverage.lua",
  "Core/GuildLock.lua",
  "Core/Database.lua",
];

async function moduleSource(relative) {
  const source = await readFile(path.join(addonRoot, relative), "utf8");
  return `do\nlocal __embersyncModule = function(...)\n${source}\nend\n__embersyncModule("EmberSync", EmberSync)\nend\n`;
}

async function execute(assertions) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const source = ["EmberSync = {}\n"];
  for (const module of modules) source.push(await moduleSource(module));
  source.push(assertions);
  const status = lauxlib.luaL_dostring(L, to_luastring(source.join("\n")));
  if (status !== lua.LUA_OK) {
    const message = to_jsstring(lua.lua_tostring(L, -1));
    throw new Error(message);
  }
  return L;
}

test("guild lock accepts only the two canonical guild identities", async () => {
  await execute(`
    local lock = EmberSync.GuildLock
    local function valid(overrides)
      local value = {
        region = 1,
        inGuild = true,
        guildName = "Raining Embers",
        guildRealm = "Dalaran",
        playerRealm = "Stormrage",
        rankName = "Member",
        rankIndex = 5,
        clubsInitialized = true,
        clubApiSupported = true,
        clubId = 123,
        clubInfo = { name = "Raining Embers", clubType = 1 },
        selfMember = { name = "Test" },
        expectedGuildClubType = 1,
        worldReady = true,
      }
      for key, child in pairs(overrides or {}) do value[key] = child end
      return value
    end

    local state, reason, identity = lock:Resolve(valid())
    assert(state == "authorized_main" and reason == "verified" and identity.key == "main")

    state, reason, identity = lock:Resolve(valid({
      guildName = "  RAINING   EMBERS ALTS ",
      guildRealm = "Wyrmrest-Accord",
      clubInfo = { name = "Raining Embers alts", clubType = 1 },
    }))
    assert(state == "authorized_alt" and identity.realm == "Wyrmrest Accord")

    local sameRealm = valid({ playerRealm = "Dalaran" })
    sameRealm.guildRealm = nil
    state = lock:Resolve(sameRealm)
    assert(state == "authorized_main", "same-realm nil may be inferred")

    local crossRealm = valid({ playerRealm = "Stormrage" })
    crossRealm.guildRealm = nil
    state, reason = lock:Resolve(crossRealm)
    assert(state == "verifying" and reason == "guild_realm_pending", "cross-realm nil must not use player realm")

    crossRealm.finalAttempt = true
    state, reason = lock:Resolve(crossRealm)
    assert(state == "denied" and reason == "verification_incomplete")

    state, reason = lock:Resolve(valid({ guildRealm = "Tichondrius" }))
    assert(state == "denied" and reason == "wrong_guild_realm")

    state, reason = lock:Resolve(valid({ guildName = "Raining Embers", clubInfo = { name = "Impostor", clubType = 1 } }))
    assert(state == "denied" and reason == "club_name_mismatch")

    state, reason = lock:Resolve(valid({ region = 2 }))
    assert(state == "denied" and reason == "wrong_region")

    state, reason = lock:Resolve(valid({ inGuild = false, guildName = nil }))
    assert(state == "denied" and reason == "not_in_guild")

    state, reason = lock:Resolve(valid({ inGuild = false, guildName = nil, worldReady = false }))
    assert(state == "verifying" and reason == "guild_info_pending")
  `);
});

test("denied or verifying state cannot initialize SavedVariables", async () => {
  const L = await execute(`
    EmberSync.GuildLock.state = "denied"
    EmberSync.GuildLock.identity = nil
    local db, reason = EmberSync.Database:Ensure()
    assert(db == nil and reason == "not_authorized")
    assert(EmberSyncDB == nil)
    local committed = EmberSync.Database:CommitDataset("guild", "guild", "main", { secret = true },
      EmberSync.Coverage.Complete())
    assert(committed == false and EmberSyncDB == nil)
    committed = EmberSync.Database:AppendEvent("guild_chat", { message = "must not save" })
    assert(committed == false and EmberSyncDB == nil)

    EmberSync.GuildLock.state = "verifying"
    db, reason = EmberSync.Database:Ensure()
    assert(db == nil and EmberSyncDB == nil)

    EmberSync.GuildLock.state = "authorized_main"
    EmberSync.GuildLock.identity = {
      key = "main", name = "Raining Embers", realm = "Dalaran", region = 1,
      rankName = "Member", rankIndex = 5,
    }
    db = EmberSync.Database:Ensure()
    assert(type(db) == "table" and db.schemaVersion == 1)
    assert(db.exports.main == nil, "export remains lazy until an authorized commit")
    committed = EmberSync.Database:CommitDataset("guild", "guild", "main", { memberCount = 1 },
      EmberSync.Coverage.Complete())
    assert(committed == true)
    assert(db.exports.main.guild.key == "main")
    assert(db.exports.main.datasets.guild.guild.name == "Raining Embers")
  `);
  assert.ok(L);
});

test("hard-coded constants match the accepted allowlist", async () => {
  const L = await execute(`
    local c = EmberSync.Constants
    assert(c.GUILDS.main.name == "Raining Embers")
    assert(c.GUILDS.main.realm == "Dalaran")
    assert(c.GUILDS.alt.name == "Raining Embers Alts")
    assert(c.GUILDS.alt.realm == "Wyrmrest Accord")
    assert(c.GUILDS.main.region == 1 and c.GUILDS.alt.region == 1)
    assert(c.WEBSITE_URL == "https://rainingembers.org")
  `);
  assert.ok(L);
});
