-- Optional, read-only adapters. No third-party addon source is bundled.
-- GRM's internal row layout is pinned to the researched Retail 1.99422 release.
local PROVIDER = "guild-roster-manager"
local ADDON = "Guild_Roster_Manager"
local SUPPORTED_VERSION = "1.99422"
local MAX_ROWS, MAX_INSPECT = 200, 1000
local KEYS = {main="Raining Embers-Dalaran", alts="Raining Embers Alts-WyrmrestAccord"}
local Providers = {}
local journalReady = false
EmberSyncProviders = Providers

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end
local function public(value)
    local ok, secret = call(issecretvalue, value)
    if not ok or secret then return nil end
    return value
end
local function text(value, limit)
    value = public(value)
    if type(value) ~= "string" or #value == 0 or #value > limit then return nil end
    return value
end
local function integer(value, low, high)
    value = public(value)
    if type(value) ~= "number" or value ~= value or value < low or value > high or value % 1 ~= 0 then return nil end
    return value
end
local function validUTF8(value)
    local i = 1
    while i <= #value do
        local a = string.byte(value, i)
        if a < 128 then i = i + 1
        else
            local size = a >= 194 and a <= 223 and 2 or a >= 224 and a <= 239 and 3 or a >= 240 and a <= 244 and 4 or nil
            if not size or i + size - 1 > #value then return false end
            local b = string.byte(value, i+1)
            if b < 128 or b > 191 or (a == 224 and b < 160) or (a == 237 and b > 159) or (a == 240 and b < 144) or (a == 244 and b > 143) then return false end
            for n = 2, size-1 do
                local continuation = string.byte(value, i+n)
                if continuation < 128 or continuation > 191 then return false end
            end
            i = i + size
        end
    end
    return true
end
local function addonAPI(name, legacy)
    local api = public(C_AddOns)
    if type(api) == "table" then
        local fn = public(rawget(api, name))
        if type(fn) == "function" then return fn, true end
    end
    return legacy, false
end
function Providers.Status()
    local installed
    local ok, value = call(addonAPI("DoesAddOnExist", nil), ADDON)
    value = public(value)
    if ok and type(value) == "boolean" then installed = value end
    if installed == nil then
        local infoOK, name = call(addonAPI("GetAddOnInfo", GetAddOnInfo), ADDON)
        if infoOK then installed = text(name, 200) == ADDON end
    end
    local versionOK, version = call(addonAPI("GetAddOnMetadata", GetAddOnMetadata), ADDON, "Version")
    version = versionOK and text(version, 80) or nil
    if version and (version:find("[%z\1-\31\127|]") or not validUTF8(version)) then version = nil end
    local loadFunction, modern = addonAPI("IsAddOnLoaded", IsAddOnLoaded)
    local loadOK, loading, loaded = call(loadFunction, ADDON)
    loading, loaded = public(loading), public(loaded)
    -- Current C_AddOns returns loaded-or-loading, then actually-loaded.
    -- Legacy API returns only the loaded boolean.
    local isLoaded = loadOK and ((modern and loaded == true) or (not modern and loading == true)) or false
    local grm = public(GRM)
    local getter = type(grm) == "table" and public(rawget(grm, "GetLog")) or nil
    return {installed=installed, loaded=isLoaded, version=version or "unknown",
        supported=installed == true and isLoaded and version == SUPPORTED_VERSION and type(getter) == "function"}
end
function Providers.SetJournalReady(value)
    journalReady = value == true
end
function Providers.Enabled()
    local db = public(EmberSyncJournalV2)
    local flags = type(db) == "table" and public(rawget(db, "providers")) or nil
    return type(flags) == "table" and public(rawget(flags, PROVIDER)) == true
end
function Providers.SetEnabled(value)
    local db = public(EmberSyncJournalV2)
    if not journalReady or type(db) ~= "table" or type(value) ~= "boolean" then return false end
    local flags = rawget(db, "providers")
    local flagsOK, secret = call(issecretvalue, flags)
    if not flagsOK or secret then return false end
    -- Preserve malformed persisted settings instead of silently overwriting them.
    if flags ~= nil and type(flags) ~= "table" then return false end
    if flags == nil then flags = {}; rawset(db, "providers", flags) end
    rawset(flags, PROVIDER, value)
    return true
end
local function actor(value)
    value = text(value, 220)
    if not value then return nil end
    local colored = value:match("^|c%x%x%x%x%x%x%x%x(.-)|r$")
    if colored then value = colored end
    -- Color is the only GRM presentation syntax accepted. Never parse log text,
    -- hyperlinks, textures, or escape sequences into a character identity.
    if #value == 0 or #value > 200 or value:find("[%z\1-\31\127|]") or value:match("^%s*$") or not validUTF8(value) then return nil end
    return value
end
local function calendar(value)
    value = public(value)
    if type(value) ~= "table" then return nil end
    local day = integer(rawget(value, 1), 1, 31)
    local month = integer(rawget(value, 2), 1, 12)
    local year = integer(rawget(value, 3), 2000, 9999)
    local hour = integer(rawget(value, 4), 0, 23)
    local minute = integer(rawget(value, 5), 0, 59)
    if not day or not month or not year or not hour or not minute then return nil end
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local days = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if day > days[month] then return nil end
    -- GRM stores calendar/server-clock labels. No timezone or UTC conversion.
    return {day, month, year, hour, minute, _array=true}
end
local function row(value)
    value = public(value)
    if type(value) ~= "table" then return nil end
    local kind = integer(rawget(value, 1), 0, 100)
    local result, date
    if kind == 7 or kind == 8 or kind == 9 then
        local subject = actor(rawget(value, 5))
        if not subject then return nil end
        local rejoin = kind == 7 or kind == 9 or public(rawget(value, 7)) == true
        result = {type=rejoin and "rejoin" or "join", subject=subject}
        if public(rawget(value, 3)) == true then result.invitedBy = actor(rawget(value, 4)) end
        date = calendar(rawget(value, 6))
    elseif kind == 10 then
        local subject, kicked = actor(rawget(value, 3)), public(rawget(value, 4))
        if not subject or type(kicked) ~= "boolean" then return nil end
        result = {type=kicked and "remove" or "quit", subject=subject}
        date = calendar(rawget(value, 11))
    else return nil end
    if date then result.calendarDate = date end
    return result
end
function Providers.Collect(guild)
    if not Providers.Enabled() or not KEYS[guild] then return nil end
    local status = Providers.Status()
    local result = {provider=PROVIDER, version=status.version, coverage="unavailable", rows={_array=true}}
    if status.installed ~= true or not status.loaded then return {_array=true, result} end
    if not status.supported then result.coverage="unsupported"; return {_array=true, result} end
    local grm = public(GRM)
    local getter = type(grm) == "table" and public(rawget(grm, "GetLog")) or nil
    local ok, entries = call(getter, KEYS[guild])
    entries = public(entries)
    if not ok or type(entries) ~= "table" then return {_array=true, result} end
    local lengthOK, count = pcall(function() return #entries end)
    count = lengthOK and integer(count, 0, 1000000) or nil
    if not count then return {_array=true, result} end
    local rows = {_array=true}
    -- The retained window can have gaps or a user-edited history. It is always
    -- partial. Bound inspected records as well as exported records.
    for i=count, math.max(1, count-MAX_INSPECT+1), -1 do
        local sanitized = row(rawget(entries, i))
        if sanitized then
            table.insert(rows, 1, sanitized)
            if #rows >= MAX_ROWS then break end
        end
    end
    result.coverage, result.rows = "partial", rows
    return {_array=true, result}
end

local panel, statusText, consentText, toggle, dot
local function refreshPanel()
    local status = Providers.Status()
    local installed = status.installed == true and "Installed" or status.installed == false and "Not installed" or "Status unavailable"
    if status.installed == true then dot:SetColorTexture(0.15, 0.85, 0.25, 1)
    elseif status.installed == false then dot:SetColorTexture(0.9, 0.2, 0.2, 1)
    else dot:SetColorTexture(0.9, 0.7, 0.15, 1) end
    local compatibility = status.supported and "Compatible" or not status.loaded and "Not loaded" or "Unsupported version/API"
    statusText:SetText("Guild Roster Manager: "..installed.."\n"..compatibility.." | Version: "..status.version.." | Tested: "..SUPPORTED_VERSION)
    local active = Providers.Enabled()
    consentText:SetText(active and "GRM contribution: enabled. Collection also requires /embersync start." or "GRM contribution: off. Enable only if you want these records in your EmberSync export.")
    toggle:SetText(active and "Disable GRM contribution" or "Enable GRM contribution")
end
function Providers.Show()
    if not panel then
        panel = CreateFrame("Frame", "EmberSyncProviderPanel", UIParent, "UIPanelDialogTemplate")
        panel:SetSize(560, 350); panel:SetPoint("CENTER")
        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 20, -18); title:SetText("EmberSync optional addons")
        dot = panel:CreateTexture(nil, "ARTWORK"); dot:SetSize(12,12); dot:SetPoint("TOPLEFT", 24, -58)
        statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        statusText:SetPoint("TOPLEFT", 45, -56); statusText:SetWidth(490); statusText:SetJustifyH("LEFT")
        local details = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        details:SetPoint("TOPLEFT", 24, -112); details:SetWidth(510); details:SetJustifyH("LEFT")
        details:SetText("Optional: GRM contributes retained joins, rejoins, departures and known Invited by labels. Its partial history is shown separately from Blizzard invitations.\n\nOnly these fields and calendar labels are exported. Notes, officer notes, chat, birthdays, ban reasons and alt relationships are excluded. GRM dates have no verified timezone.\n\nInstall separately from the official project:\ncurseforge.com/wow/addons/guild-roster-manager")
        consentText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        consentText:SetPoint("TOPLEFT", 24, -245); consentText:SetWidth(510); consentText:SetJustifyH("LEFT")
        toggle = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        toggle:SetSize(245, 28); toggle:SetPoint("BOTTOMLEFT", 24, 20)
        toggle:SetScript("OnClick", function()
            if not Providers.SetEnabled(not Providers.Enabled()) then print("EmberSync: invalid saved provider settings; preserve the export for review.") end
            refreshPanel()
        end)
        local refresh = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        refresh:SetSize(120, 28); refresh:SetPoint("BOTTOMRIGHT", -24, 20); refresh:SetText("Refresh")
        refresh:SetScript("OnClick", refreshPanel)
    end
    refreshPanel(); panel:Show()
end
