import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { lua, lauxlib, lualib, to_luastring, to_jsstring } from "fengari";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const addonRoot = path.resolve(testDirectory, "../..");

test("the complete TOC load order initializes without a WoW client", async () => {
  const toc = await readFile(path.join(addonRoot, "EmberSync.toc"), "utf8");
  const modules = toc.split(/\r?\n/).filter((line) => line.trim().endsWith(".lua"));
  const chunks = [`
    local frame = {}
    function frame:SetScript(name, callback) self[name] = callback end
    function frame:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
    function CreateFrame() return frame end
    SlashCmdList = {}
    EmberSync = {}
  `];
  for (const relative of modules) {
    const source = await readFile(path.join(addonRoot, ...relative.split("\\")), "utf8");
    chunks.push(`do
      local __module = function(...)
        ${source}
      end
      __module("EmberSync", EmberSync)
    end`);
  }
  chunks.push(`
    local count = 0
    for _ in pairs(EmberSync.collectors) do count = count + 1 end
    assert(count == 17, "expected all seventeen collectors")
    assert(EmberSync.Bootstrap and EmberSync.Bootstrap.frame, "bootstrap event frame missing")
    assert(EmberSync.Bootstrap.frame.events.ADDON_LOADED)
    assert(EmberSync.Bootstrap.frame.events.PLAYER_LOGOUT)
  `);

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const status = lauxlib.luaL_dostring(L, to_luastring(chunks.join("\n")));
  if (status !== lua.LUA_OK) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
  }
});
