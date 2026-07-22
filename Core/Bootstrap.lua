local ADDON_NAME, EmberSync = ...

local CollectorManager = EmberSync.CollectorManager
local GuildLock = EmberSync.GuildLock

local Bootstrap = { initialized = false, frame = nil }

local GUILD_LOCK_EVENTS = {
    PLAYER_ENTERING_WORLD = true,
    PLAYER_GUILD_UPDATE = true,
    GUILD_ROSTER_UPDATE = true,
    INITIAL_CLUBS_LOADED = true,
}

function Bootstrap:Initialize()
    if self.initialized then
        return
    end
    self.initialized = true
    EmberSync.MainWindow:Initialize()
    EmberSync.MinimapButton:Initialize()
    GuildLock:Initialize()
end

function Bootstrap:HandleEvent(event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == ADDON_NAME then
            self:Initialize()
        end
        return
    end
    if not self.initialized then
        return
    end
    if event == "PLAYER_LOGOUT" then
        CollectorManager:Finalize()
        return
    end
    if GUILD_LOCK_EVENTS[event] then
        GuildLock:HandleEvent(event, ...)
    end
    CollectorManager:HandleEvent(event, ...)
end

function Bootstrap:RegisterEvents()
    if type(_G.CreateFrame) ~= "function" then
        return
    end
    local frame = _G.CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, ...)
        self:HandleEvent(event, ...)
    end)
    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_LOGOUT")
    for event in pairs(GUILD_LOCK_EVENTS) do
        pcall(frame.RegisterEvent, frame, event)
    end
    for _, event in ipairs(CollectorManager:GetRegisteredEvents()) do
        pcall(frame.RegisterEvent, frame, event)
    end
    self.frame = frame
end

_G.SLASH_EMBERSYNC1 = "/embersync"
_G.SLASH_EMBERSYNC2 = "/ember"
_G.SlashCmdList = _G.SlashCmdList or {}
_G.SlashCmdList.EMBERSYNC = function(message)
    message = type(message) == "string" and string.lower(message) or ""
    if message == "status" then
        EmberSync:Log("Membership: %s (%s)", GuildLock.state, tostring(GuildLock.reason))
    else
        EmberSync.MainWindow:Toggle()
    end
end

_G.EmberSync_OnAddonCompartmentClick = function()
    EmberSync.MainWindow:Toggle()
end

_G.EmberSync_OnAddonCompartmentEnter = function(button)
    if _G.GameTooltip and button then
        _G.GameTooltip:SetOwner(button, "ANCHOR_LEFT")
        _G.GameTooltip:AddLine("EmberSync", 0.941, 0.353, 0.122)
        _G.GameTooltip:AddLine("Raining Embers guild data sync", 1, 1, 1)
        _G.GameTooltip:Show()
    end
end

_G.EmberSync_OnAddonCompartmentLeave = function()
    if _G.GameTooltip then
        _G.GameTooltip:Hide()
    end
end

Bootstrap:RegisterEvents()
EmberSync:RegisterModule("Bootstrap", Bootstrap)
