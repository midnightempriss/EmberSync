import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import luaparse from "luaparse";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const addonRoot = path.resolve(testDirectory, "../..");

async function findLuaFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (["node_modules", "desktop", "protocol"].includes(entry.name)) continue;
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await findLuaFiles(target));
    else if (entry.name.endsWith(".lua")) files.push(target);
  }
  return files;
}

test("all addon Lua parses as Lua 5.1", async () => {
  const files = await findLuaFiles(addonRoot);
  assert.ok(files.length >= 20, "expected the complete addon module set");
  for (const file of files) {
    const source = await readFile(file, "utf8");
    assert.doesNotThrow(
      () => luaparse.parse(source, { luaVersion: "5.1", locations: true }),
      path.relative(addonRoot, file),
    );
  }
});

test("TOC targets Retail 12.0.7 and every listed Lua file exists", async () => {
  const toc = await readFile(path.join(addonRoot, "EmberSync.toc"), "utf8");
  assert.match(toc, /^## Interface: 120007$/m);
  assert.match(toc, /^## SavedVariables: EmberSyncDB$/m);
  assert.match(toc, /^## AddonCompartmentFunc: EmberSync_OnAddonCompartmentClick$/m);
  const luaPaths = toc.split(/\r?\n/).filter((line) => line.trim().endsWith(".lua"));
  for (const relative of luaPaths) {
    const source = await readFile(path.join(addonRoot, ...relative.split("\\")), "utf8");
    assert.ok(source.length > 0, `${relative} should not be empty`);
  }
});

test("privacy exclusions and exact nonmember copy are source-enforced", async () => {
  const constants = await readFile(path.join(addonRoot, "Core/Constants.lua"), "utf8");
  assert.ok(constants.includes(
    "EmberSync is exclusively for members of Raining Embers and Raining Embers Alts. This character is not a member of an approved Raining Embers guild, so EmberSync serves no purpose for this character.",
  ));
  assert.ok(constants.includes('WEBSITE_URL = "https://rainingembers.org"'));

  const bootstrapSources = await Promise.all((await findLuaFiles(addonRoot)).map((file) => readFile(file, "utf8")));
  const source = bootstrapSources.join("\n");
  for (const forbiddenEvent of [
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_BN_WHISPER",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "COMBAT_LOG_EVENT_UNFILTERED",
  ]) {
    assert.ok(!source.includes(`\"${forbiddenEvent}\"`), `${forbiddenEvent} must never be registered`);
  }
  assert.ok(!source.includes("GetInboxText"), "mail bodies must never be requested");
});
