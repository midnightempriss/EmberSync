local MAX_ENTRIES = 512
local MAX_JSON_BYTES = 1500000 -- SavedVariables quoting may expand bytes by up to four.
local enabled = false
local supportedBuild = false
local function public(v)
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    return v
end
local function stringValue(v)
    v = public(v)
    if type(v) ~= "string" or #v > 200 then return nil end
    return v
end
local function numberValue(v)
    v = public(v)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 9007199254740991 then return nil end
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
    local name, _, _, realm = GetGuildInfo("player")
    name, realm = stringValue(name), stringValue(realm)
    -- Guild founding realm must come from the API; never use player's realm.
    if not name or not realm then return nil end
    if name == "Raining Embers" and realm:gsub("%s", "") == "Dalaran" then return "main" end
    if name == "Raining Embers Alts" and realm:gsub("%s", "") == "WyrmrestAccord" then return "alts" end
end
local function append(record)
    if not enabled or not supportedBuild then return end
    local guild = scope()
    if not guild then return end
    local db = EmberSyncJournalV2
    db.seq = db.seq + 1
    record.guild, record.epoch, record.seq = guild, db.epoch, db.seq
    record.collectedAt, record.build, record.dropped = GetServerTime(), db.build, db.dropped
    local encoded = json(record)
    if #encoded > 256000 then db.dropped = db.dropped + 1; return end
    local bytes = #encoded
    for _, raw in ipairs(db.entries) do bytes = bytes + #raw end
    while #db.entries > 0 and (#db.entries >= MAX_ENTRIES or bytes > MAX_JSON_BYTES) do
        bytes = bytes - #db.entries[1]
        table.remove(db.entries, 1); db.dropped = db.dropped + 1
    end
    record.dropped = db.dropped
    encoded = json(record)
    db.entries[#db.entries+1] = encoded
end
local function roster()
    if not enabled or not supportedBuild or not scope() then return end
    local count = numberValue(GetNumGuildMembers())
    if not count or count == 0 or count > 2000 then
        append({kind="coverage", coverage="unavailable"}); return
    end
    local members = {_array=true}; local seen = {}; local complete=true
    for i = 1, count do
        local name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
        name, guid, online = stringValue(name), stringValue(guid), public(online)
        -- Do not compare protected values or infer realms from local character context.
        local id = guid
        if not id or not name or type(online) ~= "boolean" or seen[id] then complete=false
        else seen[id]=true; members[#members+1]={id=id,name=name,online=online} end
    end
    local finalCount = numberValue(GetNumGuildMembers())
    if finalCount ~= count or #members ~= count then complete=false end
    append({kind="roster", coverage=complete and "complete" or "partial", members=members})
end
local function log()
    if not enabled or not supportedBuild or not scope() then return end
    if type(GetNumGuildEvents) ~= "function" or type(GetGuildEventInfo) ~= "function" then
        append({kind="coverage",coverage="unsupported"}); return
    end
    local count = numberValue(GetNumGuildEvents())
    if not count or count > 200 then append({kind="coverage",coverage="unavailable"}); return end
    local rows = {_array=true}; local complete=true
    for i=1,count do
        local kind,p1,p2,_,year,month,day,hour = GetGuildEventInfo(i)
        kind,p1,p2 = stringValue(kind),stringValue(p1),stringValue(p2)
        year,month,day,hour=numberValue(year),numberValue(month),numberValue(day),numberValue(hour)
        if not kind or not year or not month or not day or not hour then complete=false
        elseif kind=="invite" or kind=="join" or kind=="quit" or kind=="remove" or kind=="promote" or kind=="demote" then
            rows[#rows+1]={type=kind,player1=p1,player2=p2,age={year,month,day,hour,_array=true}}
        else complete=false end
    end
    append({kind="log",coverage=complete and "complete" or "partial",rows=rows})
end
local function request()
    if not enabled or not supportedBuild or not scope() then return end
    if C_GuildInfo and type(C_GuildInfo.GuildRoster)=="function" then pcall(C_GuildInfo.GuildRoster) end
    if type(QueryGuildEventLog)=="function" then pcall(QueryGuildEventLog) end
end
local frame = CreateFrame("Frame")
for _, event in ipairs({"ADDON_LOADED","PLAYER_ENTERING_WORLD","PLAYER_GUILD_UPDATE","GUILD_ROSTER_UPDATE","GUILD_EVENT_LOG_UPDATE"}) do frame:RegisterEvent(event) end
frame:SetScript("OnEvent",function(_,event,name)
    if event=="ADDON_LOADED" and name=="EmberSync" then
        local version,build,_,interface=GetBuildInfo()
        version,build,interface=stringValue(version),stringValue(build),numberValue(interface)
        supportedBuild = version and version:match("^12%.1%.") ~= nil and interface==120100 and build=="69587"
        if type(EmberSyncJournalV2)~="table" or EmberSyncJournalV2.version~=2 then
            EmberSyncJournalV2={version=2,epoch=tostring(GetServerTime()).."-"..tostring(math.random(100000,999999)),seq=0,dropped=0,entries={},build=version or "unknown"}
        end
        enabled=EmberSyncJournalV2.consent==true
        EmberSyncJournalV2.build=version or "unknown"
        print("EmberSync: /embersync start to consent; /embersync stop to pause. Save with /reload or logout. Build: "..(version or "unknown"))
    elseif event=="GUILD_ROSTER_UPDATE" then pcall(roster)
    elseif event=="GUILD_EVENT_LOG_UPDATE" then pcall(log)
    elseif event=="PLAYER_ENTERING_WORLD" or event=="PLAYER_GUILD_UPDATE" then pcall(request) end
end)
SLASH_EMBERSYNC1="/embersync"
SlashCmdList.EMBERSYNC=function(command)
    if not EmberSyncJournalV2 then return end
    if command=="start" then
        if not supportedBuild then print("EmberSync: unsupported build; collection paused."); return end
        enabled=true; EmberSyncJournalV2.consent=true; request()
    elseif command=="stop" then enabled=false; EmberSyncJournalV2.consent=false
    elseif command=="scan" then request()
    else print("EmberSync: start / stop / scan. Saved after reload/logout; no network or credentials in addon.") end
end
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(60, function() pcall(request) end) end
