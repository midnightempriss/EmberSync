local MAX_ENTRIES = 512
local MAX_JSON_BYTES = 1500000 -- SavedVariables quoting may expand bytes by up to four.
local enabled = false
local supportedBuild = false
local journalReady = false
local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end
local function public(v)
    local ok, secret = call(issecretvalue, v)
    if not ok or secret then return nil end
    return v
end
local function stringValue(v)
    v = public(v)
    if type(v) ~= "string" or #v == 0 or #v > 200 then return nil end
    return v
end
local function numberValue(v, maximum)
    v = public(v)
    if type(v) ~= "number" or v ~= v or v < 0 or v > (maximum or 9007199254740991) or v % 1 ~= 0 then return nil end
    return v
end
local function quote(v)
    return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        return string.format('\\u%04x', string.byte(c))
    end) .. '"'
end
local function json(v)
    if v == nil then return "null" end
    if type(v) == "string" then return quote(v) end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then return string.format("%.0f", v) end
    local result = {}
    if v._array then
        for i = 1, #v do result[i] = json(v[i]) end
        return "[" .. table.concat(result, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do result[#result+1] = quote(k) .. ":" .. json(v[k]) end
    return "{" .. table.concat(result, ",") .. "}"
end
local function scope()
    local ok, name, _, _, realm = call(GetGuildInfo, "player")
    if not ok then return nil end
    name, realm = stringValue(name), stringValue(realm)
    -- Guild founding realm must come from the API; never use player's realm.
    if not name or not realm then return nil end
    if name == "Raining Embers" and realm == "Dalaran" then return "main" end
    if name == "Raining Embers Alts" and (realm == "Wyrmrest Accord" or realm == "WyrmrestAccord") then return "alts" end
end
local function validJournal(db)
    if type(db) ~= "table" or db.version ~= 2 or not stringValue(db.epoch) or not numberValue(db.seq) or not numberValue(db.dropped) or type(db.entries) ~= "table" then return false end
    local count, bytes = 0, 0
    for index, raw in pairs(db.entries) do
        if not numberValue(index, MAX_ENTRIES) or index == 0 or type(raw) ~= "string" or #raw > 256000 then return false end
        count, bytes = count + 1, bytes + #raw
    end
    if count ~= #db.entries or bytes > MAX_JSON_BYTES then return false end
    for i = 1, count do if type(db.entries[i]) ~= "string" then return false end end
    return true
end
local function append(record, guild)
    if not enabled or not supportedBuild or not journalReady then return end
    if not guild or scope() ~= guild then return end
    local db = EmberSyncJournalV2
    local ok, timestamp = call(GetServerTime)
    timestamp = ok and numberValue(timestamp)
    if not timestamp or timestamp == 0 or db.seq >= 9007199254740991 or db.dropped > 9007199254740991 - MAX_ENTRIES then return end
    db.seq = db.seq + 1
    record.guild, record.epoch, record.seq = guild, db.epoch, db.seq
    record.collectedAt, record.build, record.dropped = timestamp, db.build, db.dropped
    local encoded = json(record)
    -- An oversized optional window must not suppress a valid native record.
    if #encoded > 256000 and record.providerLogs ~= nil then
        record.providerLogs = nil
        encoded = json(record)
    end
    if #encoded > 256000 then db.dropped = db.dropped + 1; return end
    local bytes = 0
    for _, raw in ipairs(db.entries) do bytes = bytes + #raw end
    local evicted = 0
    while evicted < #db.entries and (#db.entries - evicted >= MAX_ENTRIES or bytes + #encoded > MAX_JSON_BYTES) do
        evicted = evicted + 1
        bytes = bytes - #db.entries[evicted]
        record.dropped = db.dropped + evicted
        encoded = json(record)
        if #encoded > 256000 and record.providerLogs ~= nil then
            record.providerLogs = nil
            encoded = json(record)
        end
        if #encoded > 256000 then db.dropped = db.dropped + 1; return end
    end
    for i = 1, evicted do table.remove(db.entries, 1) end
    db.dropped = db.dropped + evicted
    db.entries[#db.entries+1] = encoded
end
local function roster()
    if not enabled or not supportedBuild then return end
    local guild = scope()
    if not guild then return end
    if type(GetNumGuildMembers) ~= "function" or type(GetGuildRosterInfo) ~= "function" then
        append({kind="coverage", coverage="unsupported"}, guild); return
    end
    local ok, count = call(GetNumGuildMembers)
    count = ok and numberValue(count, 2000)
    if not count or count == 0 then
        append({kind="coverage", coverage="unavailable"}, guild); return
    end
    local members = {_array=true}; local seen = {}; local complete=true; local sampled = {}
    for i = 1, count do
        local ok, name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, guid = call(GetGuildRosterInfo, i)
        name, guid, online = stringValue(name), stringValue(guid), public(online)
        sampled[i] = {name=name, id=guid, online=online}
        -- Do not compare protected values or infer realms from local character context.
        local id = guid
        if not ok or not id or not name or type(online) ~= "boolean" or seen[id] then complete=false
        else seen[id]=true; members[#members+1]={id=id,name=name,online=online} end
    end
    -- Equal counts alone cannot prove the same roster was read throughout.
    for i = 1, count do
        local ok, name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, guid = call(GetGuildRosterInfo, i)
        name, guid, online = stringValue(name), stringValue(guid), public(online)
        local original = sampled[i]
        if not ok or name ~= original.name or guid ~= original.id or online ~= original.online then complete=false end
    end
    local ok, finalCount = call(GetNumGuildMembers)
    finalCount = ok and numberValue(finalCount, 2000)
    if finalCount ~= count or #members ~= count then complete=false end
    append({kind="roster", coverage=complete and "complete" or "partial", members=members}, guild)
end
local function appendLog(record, guild)
    -- Optional adapter failure must never suppress native Blizzard evidence.
    if EmberSyncProviders and type(EmberSyncProviders.Collect) == "function" then
        local providerOK, providers = pcall(EmberSyncProviders.Collect, guild)
        if providerOK then record.providerLogs = providers end
    end
    append(record, guild)
end
local function failedLog(coverage, guild)
    local record = {kind="log",coverage=coverage,rows={_array=true}}
    if EmberSyncProviders and type(EmberSyncProviders.Collect) == "function" then
        local providerOK, providers = pcall(EmberSyncProviders.Collect, guild)
        if providerOK and providers then
            record.providerLogs = providers; append(record, guild); return
        end
    end
    append({kind="coverage",coverage=coverage}, guild)
end
local function log()
    if not enabled or not supportedBuild then return end
    local guild = scope()
    if not guild then return end
    if type(GetNumGuildEvents) ~= "function" or type(GetGuildEventInfo) ~= "function" then
        failedLog("unsupported", guild); return
    end
    local ok, count = call(GetNumGuildEvents)
    count = ok and numberValue(count, 200)
    if not count then failedLog("unavailable", guild); return end
    local rows = {_array=true}; local complete=true; local sampled = {}
    for i=1,count do
        local ok,kind,p1,p2,_,year,month,day,hour = call(GetGuildEventInfo, i)
        kind,p1,p2 = stringValue(kind),stringValue(p1),stringValue(p2)
        year,month,day,hour=numberValue(year,10000),numberValue(month,10000),numberValue(day,10000),numberValue(hour,10000)
        sampled[i] = {kind=kind,p1=p1,p2=p2,year=year,month=month,day=day,hour=hour}
        if not ok or not kind or not year or not month or not day or not hour then complete=false
        elseif kind=="invite" or kind=="join" or kind=="quit" or kind=="remove" or kind=="promote" or kind=="demote" then
            rows[#rows+1]={type=kind,player1=p1,player2=p2,age={year,month,day,hour,_array=true}}
        else complete=false end
    end
    for i = 1, count do
        local ok,kind,p1,p2,_,year,month,day,hour = call(GetGuildEventInfo, i)
        kind,p1,p2 = stringValue(kind),stringValue(p1),stringValue(p2)
        year,month,day,hour=numberValue(year,10000),numberValue(month,10000),numberValue(day,10000),numberValue(hour,10000)
        local original = sampled[i]
        if not ok or kind ~= original.kind or p1 ~= original.p1 or p2 ~= original.p2 or year ~= original.year or month ~= original.month or day ~= original.day or hour ~= original.hour then complete=false end
    end
    local ok, finalCount = call(GetNumGuildEvents)
    finalCount = ok and numberValue(finalCount, 200)
    if finalCount ~= count then complete=false end
    appendLog({kind="log",coverage=complete and "complete" or "partial",rows=rows}, guild)
end
local function request()
    if not enabled or not supportedBuild then return end
    local guild = scope()
    if not guild then return end
    local rosterAPI = C_GuildInfo and C_GuildInfo.GuildRoster
    local rosterOK = call(rosterAPI)
    local logOK = call(QueryGuildEventLog)
    if type(rosterAPI) ~= "function" or type(QueryGuildEventLog) ~= "function" then
        append({kind="coverage",coverage="unsupported"}, guild)
    elseif not rosterOK or not logOK then append({kind="coverage",coverage="unavailable"}, guild) end
    if (type(QueryGuildEventLog) ~= "function" or not logOK) and EmberSyncProviders and EmberSyncProviders.Enabled() then
        failedLog(type(QueryGuildEventLog) ~= "function" and "unsupported" or "unavailable", guild)
    end
end
local frame = CreateFrame("Frame")
for _, event in ipairs({"ADDON_LOADED","PLAYER_ENTERING_WORLD","PLAYER_GUILD_UPDATE","GUILD_ROSTER_UPDATE","GUILD_EVENT_LOG_UPDATE"}) do frame:RegisterEvent(event) end
frame:SetScript("OnEvent",function(_,event,name)
    if event=="ADDON_LOADED" and name=="EmberSync" then
        local ok,version,build,_,interface=call(GetBuildInfo)
        version,build,interface=stringValue(version),stringValue(build),numberValue(interface)
        supportedBuild = ok and version and #version <= 80 and version:match("^12%.1%.") ~= nil and interface==120100 and build=="69587"
        if type(EmberSyncJournalV2)~="table" or EmberSyncJournalV2.version~=2 then
            local timeOK, timestamp = call(GetServerTime)
            timestamp = timeOK and numberValue(timestamp)
            EmberSyncJournalV2={version=2,epoch=tostring(timestamp or "unavailable-time").."-"..tostring(math.random(100000,999999)),seq=0,dropped=0,entries={},build=version or "unknown"}
        end
        journalReady = validJournal(EmberSyncJournalV2)
        if EmberSyncProviders and type(EmberSyncProviders.SetJournalReady) == "function" then EmberSyncProviders.SetJournalReady(journalReady) end
        enabled=journalReady and EmberSyncJournalV2.consent==true
        EmberSyncJournalV2.build=version or "unknown"
        print("EmberSync: /embersync start to consent; /embersync stop to pause; /embersync plugins for optional addons. Save with /reload or logout. Build: "..(version or "unknown"))
        if not journalReady then print("EmberSync: invalid saved journal; collection paused. Preserve the existing export for review.") end
    elseif event=="GUILD_ROSTER_UPDATE" then pcall(roster)
    elseif event=="GUILD_EVENT_LOG_UPDATE" then pcall(log)
    elseif event=="PLAYER_ENTERING_WORLD" or event=="PLAYER_GUILD_UPDATE" then pcall(request) end
end)
SLASH_EMBERSYNC1="/embersync"
SlashCmdList.EMBERSYNC=function(command)
    if not EmberSyncJournalV2 then return end
    if command=="plugins" then
        if EmberSyncProviders and type(EmberSyncProviders.Show) == "function" then
            local ok = pcall(EmberSyncProviders.Show)
            if not ok then print("EmberSync: plugin checklist unavailable; see README for optional addons.") end
        end
    elseif command=="plugin grm on" or command=="plugin grm off" then
        if not journalReady then print("EmberSync: invalid saved journal; preserve the export for review."); return end
        local value = command=="plugin grm on"
        if EmberSyncProviders and EmberSyncProviders.SetEnabled(value) then
            print(value and "EmberSync: GRM contribution enabled; /embersync start is also required." or "EmberSync: GRM contribution disabled.")
        else print("EmberSync: provider settings unavailable; preserve the export for review.") end
    elseif command=="start" then
        if not supportedBuild then print("EmberSync: unsupported build; collection paused."); return end
        if not journalReady then print("EmberSync: invalid saved journal; collection paused."); return end
        enabled=true; EmberSyncJournalV2.consent=true; request()
    elseif command=="stop" then enabled=false; EmberSyncJournalV2.consent=false
    elseif command=="scan" then request()
    else print("EmberSync: start / stop / scan / plugins; plugin grm on / off. Saved after reload/logout; no network or credentials in addon.") end
end
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(60, function() pcall(request) end) end
