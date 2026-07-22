local ADDON_NAME, EmberSync = ...

if type(EmberSync) ~= "table" then
    EmberSync = {}
end

_G.EmberSync = EmberSync

EmberSync.name = ADDON_NAME or "EmberSync"
EmberSync.version = "0.1.0"
EmberSync.modules = EmberSync.modules or {}
EmberSync.collectors = EmberSync.collectors or {}
EmberSync.listeners = EmberSync.listeners or {}

function EmberSync:RegisterModule(name, module)
    assert(type(name) == "string" and name ~= "", "module name is required")
    assert(type(module) == "table", "module must be a table")
    self.modules[name] = module
    self[name] = module
    return module
end

function EmberSync:On(eventName, callback)
    if type(callback) ~= "function" then
        return
    end
    self.listeners[eventName] = self.listeners[eventName] or {}
    table.insert(self.listeners[eventName], callback)
end

function EmberSync:Emit(eventName, ...)
    local callbacks = self.listeners[eventName]
    if not callbacks then
        return
    end
    for index = 1, #callbacks do
        local ok, err = pcall(callbacks[index], ...)
        if not ok and self.Log then
            self:Log("Listener failed for %s: %s", eventName, tostring(err))
        end
    end
end

function EmberSync:Log(message, ...)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, message, ...)
        message = ok and formatted or message
    end
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cfff05a1fEmberSync:|r " .. message)
    end
end
