local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local Guild = {
    name = "guild",
    scope = "guild",
    events = {
        "GUILD_ROSTER_UPDATE",
        "GUILD_MOTD",
        "GUILD_NEWS_UPDATE",
        "GUILD_RANKS_UPDATE",
        "GUILD_REWARDS_LIST",
        "GUILD_CHALLENGE_UPDATED",
        "GUILD_EVENT_LOG_UPDATE",
    },
    priorityEvents = {
        GUILD_MOTD = true,
        GUILD_ROSTER_UPDATE = true,
        GUILD_NEWS_UPDATE = true,
        GUILD_RANKS_UPDATE = true,
        GUILD_EVENT_LOG_UPDATE = true,
    },
    debounce = 1,
    minInterval = 15,
    componentSignals = {},
    stagedMotd = nil,
    stagedMotdObserved = false,
    stagedMotdObservedAt = nil,
}

local function collectRanks()
    local ranks = {}
    if type(_G.GuildControlGetNumRanks) ~= "function" then
        return ranks, false, false
    end
    local ok, count = pcall(_G.GuildControlGetNumRanks)
    count = ok and Util.SafeNumber(count) or nil
    if not count then
        return ranks, true, false
    end
    for index = 1, count do
        local flags
        if type(_G.GuildControlGetRankFlags) == "function" then
            local values = { pcall(_G.GuildControlGetRankFlags, index) }
            if values[1] then
                table.remove(values, 1)
                flags = Util.Sanitize(values)
            end
        end
        local name
        if type(_G.GuildControlGetRankName) == "function" then
            local nameOk, value = pcall(_G.GuildControlGetRankName, index)
            name = nameOk and Util.SafeString(value, true) or nil
        end
        ranks[index] = {
            index = index - 1,
            name = name,
            flags = flags,
        }
    end
    return ranks, true, count > 0
end

local function collectRoster(canViewOfficerNote)
    local roster = {}
    if type(_G.GetNumGuildMembers) ~= "function" or type(_G.GetGuildRosterInfo) ~= "function" then
        return roster, false, nil, false
    end
    local countValues = { pcall(_G.GetNumGuildMembers) }
    if not countValues[1] then
        return roster, true, nil, false
    end
    local total = Util.SafeNumber(countValues[2])
    local online = Util.SafeNumber(countValues[3])
    local onlineAndMobile = Util.SafeNumber(countValues[4])
    if not total then
        return roster, true, nil, false
    end
    local fullyRead = total > 0
    for index = 1, total do
        Util.Cooperate(index, 30)
        local values = { pcall(_G.GetGuildRosterInfo, index) }
        if values[1] then
            roster[#roster + 1] = {
                id = values[18],
                name = values[2],
                rankName = values[3],
                rankIndex = values[4],
                level = values[5],
                className = values[6],
                zone = values[7],
                publicNote = values[8],
                officerNote = canViewOfficerNote and values[9] or nil,
                isOnline = values[10],
                status = values[11],
                classFile = values[12],
                achievementPoints = values[13],
                achievementRank = values[14],
                isMobile = values[15],
                canScrollOfResurrection = values[16],
                reputationStanding = values[17],
            }
        else
            fullyRead = false
        end
    end
    return roster, true, {
        total = total,
        online = online,
        onlineAndMobile = onlineAndMobile,
    }, fullyRead and #roster == total
end

local function collectNews()
    local news = {}
    if type(_G.GetNumGuildNews) ~= "function" or type(_G.C_GuildInfo) ~= "table"
        or type(_G.C_GuildInfo.GetGuildNewsInfo) ~= "function" then
        return news, false, false
    end
    local countOk, count = pcall(_G.GetNumGuildNews)
    count = countOk and Util.SafeNumber(count) or nil
    if not count then
        return news, true, false
    end
    local complete = true
    for index = 1, count do
        Util.Cooperate(index, 25)
        local ok, info = pcall(_G.C_GuildInfo.GetGuildNewsInfo, index)
        if ok and info then
            news[#news + 1] = Util.Sanitize(info)
        else
            complete = false
        end
    end
    return news, true, complete
end

local function collectChallenges()
    local challenges = {}
    if type(_G.GetNumGuildChallenges) ~= "function" or type(_G.GetGuildChallengeInfo) ~= "function" then
        return challenges, false, false
    end
    local countOk, count = pcall(_G.GetNumGuildChallenges)
    count = countOk and Util.SafeNumber(count) or nil
    if not count then
        return challenges, true, false
    end
    local complete = true
    for index = 1, count do
        local values = { pcall(_G.GetGuildChallengeInfo, index) }
        if values[1] then
            challenges[#challenges + 1] = {
                type = values[2],
                currentCount = values[3],
                maxCount = values[4],
                currentGold = values[5],
                maxGold = values[6],
            }
        else
            complete = false
        end
    end
    return challenges, true, complete
end

local function collectEventLog()
    local events = {}
    if type(_G.GetNumGuildEvents) ~= "function" or type(_G.GetGuildEventInfo) ~= "function" then
        return events, false, false
    end
    local countOk, count = pcall(_G.GetNumGuildEvents)
    count = countOk and Util.SafeNumber(count) or nil
    if not count then
        return events, true, false
    end
    local complete = true
    for index = 1, math.min(count, 200) do
        Util.Cooperate(index, 25)
        local values = { pcall(_G.GetGuildEventInfo, index) }
        if values[1] then
            events[#events + 1] = {
                type = values[2],
                player1 = values[3],
                player2 = values[4],
                rank = values[5],
                occurred = { year = values[6], month = values[7], day = values[8], hour = values[9] },
            }
        else
            complete = false
        end
    end
    return events, true, complete
end

local function approximateOccurredAt(value, observedAt)
    if type(value) ~= "table" then
        return observedAt
    end
    local years = math.min(10, math.max(0, math.floor(Util.SafeNumber(value.year) or 0)))
    local months = math.min(12, math.max(0, math.floor(Util.SafeNumber(value.month) or 0)))
    local days = math.min(366, math.max(0, math.floor(Util.SafeNumber(value.day) or 0)))
    local hours = math.min(24, math.max(0, math.floor(Util.SafeNumber(value.hour) or 0)))
    local totalHours = (((years * 365) + (months * 30) + days) * 24) + hours
    return math.floor(math.max(0, observedAt - totalHours * 60 * 60) / 3600) * 3600
end

local function signaturePart(value)
    local text = Util.SafeString(value, true)
    if text == nil then
        local number = Util.SafeNumber(value)
        text = number and tostring(number) or ""
    end
    return tostring(#text) .. ":" .. text
end

local function guildEventSignature(event, occurredAt)
    return table.concat({
        signaturePart(event.type),
        signaturePart(event.player1),
        signaturePart(event.player2),
        signaturePart(event.rank),
        signaturePart(occurredAt),
    }, "|")
end

local function appendNewGuildEvents(events)
    if type(Database.AppendEvent) ~= "function" or type(events) ~= "table" then
        return
    end
    local export = Database:GetActiveExport(false)
    local retained = type(export) == "table" and type(export.events) == "table"
        and export.events.guild or {}
    local seen = {}
    for _, envelope in ipairs(type(retained) == "table" and retained or {}) do
        local payload = type(envelope) == "table" and envelope.payload or nil
        if type(payload) == "table" then
            local signature = guildEventSignature(
                payload,
                Util.SafeNumber(payload.occurredAt) or approximateOccurredAt(
                    payload.occurred,
                    Util.SafeNumber(envelope.capturedAt) or Util.Now()
                )
            )
            local occurrence = math.max(1, math.floor(Util.SafeNumber(payload.occurrence) or 1))
            seen[signature .. "#" .. occurrence] = true
        end
    end
    local observedAt = Util.Now()
    local occurrences = {}
    for _, event in ipairs(events) do
        if type(event) == "table" then
            local occurredAt = approximateOccurredAt(event.occurred, observedAt)
            local signature = guildEventSignature(event, occurredAt)
            occurrences[signature] = (occurrences[signature] or 0) + 1
            local occurrence = occurrences[signature]
            local key = signature .. "#" .. occurrence
            if not seen[key] then
                local payload = Util.Copy(event)
                payload.occurredAt = occurredAt
                payload.observedAt = observedAt
                payload.occurrence = occurrence
                payload.provenance = "guild_event_log"
                Database:AppendEvent("guild", payload)
                seen[key] = true
            end
        end
    end
end

local function appendPresenceSnapshot(roster, rosterCounts)
    if type(Database.AppendEvent) ~= "function"
        or type(roster) ~= "table" or type(rosterCounts) ~= "table" then
        return
    end
    local totalMembers = math.max(0, math.floor(Util.SafeNumber(rosterCounts.total) or #roster))
    local onlineCount = math.max(0, math.floor(Util.SafeNumber(rosterCounts.online) or 0))
    local onlineAndMobile = math.max(
        onlineCount,
        math.floor(Util.SafeNumber(rosterCounts.onlineAndMobile) or onlineCount)
    )
    local export = Database:GetActiveExport(false)
    local retained = type(export) == "table" and type(export.events) == "table"
        and export.events.guild_presence or nil
    local latest = type(retained) == "table" and retained[#retained] or nil
    local previous = type(latest) == "table" and latest.payload or nil
    local observedAt = Util.Now()
    local unchanged = type(previous) == "table"
        and Util.SafeNumber(previous.onlineCount) == onlineCount
        and Util.SafeNumber(previous.totalMembers) == totalMembers
        and Util.SafeNumber(previous.onlineAndMobile) == onlineAndMobile
    local previousAt = type(latest) == "table" and Util.SafeNumber(latest.capturedAt) or nil
    if unchanged and previousAt and observedAt - previousAt < 15 * 60 then
        return
    end
    Database:AppendEvent("guild_presence", {
        type = "snapshot",
        onlineCount = onlineCount,
        onlineAndMobile = onlineAndMobile,
        totalMembers = totalMembers,
        observedAt = observedAt,
        provenance = "guild_roster",
    })
end

local function collectRewards()
    if type(_G.GetGuildRewards) ~= "function" then
        return {}, false, false
    end
    local values = { pcall(_G.GetGuildRewards) }
    if not values[1] then
        return {}, true, false
    end
    table.remove(values, 1)
    return Util.Sanitize(values), true, true
end

local function collectTabard()
    if type(_G.GetGuildTabardFiles) ~= "function" then
        return nil
    end
    local values = { pcall(_G.GetGuildTabardFiles) }
    if not values[1] then
        return nil
    end
    return {
        backgroundUpper = values[2],
        backgroundLower = values[3],
        emblemUpper = values[4],
        emblemLower = values[5],
        borderUpper = values[6],
        borderLower = values[7],
    }
end

local function safePermission(name)
    if type(_G[name]) ~= "function" then
        return false
    end
    local ok, value = pcall(_G[name])
    return ok and Util.SafeBoolean(value) == true
end

local function getPreviousPayload(context)
    local export = Database:GetActiveExport(false)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets.guild or nil
    if type(envelope) ~= "table" or envelope.guildKey ~= context.guild.key
        or type(envelope.payload) ~= "table" then
        return nil
    end
    return envelope.payload
end

local function componentCoverage(supported, complete, pendingReason)
    if not supported then
        return Coverage.Unsupported(pendingReason .. "_api_unavailable")
    end
    if complete then
        return Coverage.Complete()
    end
    return Coverage.Partial(pendingReason .. "_pending")
end

local function requestGuildData()
    if type(_G.C_GuildInfo) == "table" and type(_G.C_GuildInfo.GuildRoster) == "function" then
        pcall(_G.C_GuildInfo.GuildRoster)
    end
    for _, name in ipairs({ "QueryGuildNews", "QueryGuildEventLog" }) do
        if type(_G[name]) == "function" then
            pcall(_G[name])
        end
    end
end

function Guild:HandleEvent(_, event, ...)
    self.componentSignals[event] = Util.Now()
    if event == "GUILD_MOTD" then
        local value = ...
        value = Util.SafeString(value, true)
        if value ~= nil then
            self.stagedMotd = value
            self.stagedMotdObserved = true
            self.stagedMotdObservedAt = Util.Now()
        end
    end
end

function Guild:ResetStaging()
    self.componentSignals = {}
    self.stagedMotd = nil
    self.stagedMotdObserved = false
    self.stagedMotdObservedAt = nil
end

function Guild:Collect(context)
    requestGuildData()
    local canViewOfficerNote = safePermission("CanViewOfficerNote")
    local roster, rosterSupported, rosterCounts, rosterComplete = collectRoster(canViewOfficerNote)
    local infoText
    if type(_G.C_GuildInfo) == "table" and type(_G.C_GuildInfo.GetGuildInfoText) == "function" then
        local ok, value = pcall(_G.C_GuildInfo.GetGuildInfoText)
        infoText = ok and Util.SafeString(value, true) or nil
    elseif type(_G.GetGuildInfoText) == "function" then
        local ok, value = pcall(_G.GetGuildInfoText)
        infoText = ok and Util.SafeString(value, true) or nil
    end

    local previous = getPreviousPayload(context)
    local motd, motdSupported, motdComplete
    local motdGetter = type(_G.C_GuildInfo) == "table"
        and type(_G.C_GuildInfo.GetMOTD) == "function" and _G.C_GuildInfo.GetMOTD
        or type(_G.GetGuildRosterMOTD) == "function" and _G.GetGuildRosterMOTD or nil
    if self.stagedMotdObserved then
        motdSupported = true
        motd = self.stagedMotd
        motdComplete = true
    elseif motdGetter then
        motdSupported = true
        local ok, value = pcall(motdGetter)
        motd = ok and Util.SafeString(value, true) or nil
        motdComplete = motd ~= nil and (motd ~= "" or rosterComplete)
    else
        motdSupported = false
        motdComplete = false
    end
    local motdSource = self.stagedMotdObserved and "event" or "direct"
    local motdObservedAt = self.stagedMotdObserved and self.stagedMotdObservedAt
        or motdComplete and Util.Now() or nil
    if not motdComplete and type(previous) == "table" then
        local previousMotd = Util.SafeString(previous.motd, true)
        if previousMotd ~= nil then
            motd = previousMotd
            motdSource = "last_good"
            motdObservedAt = previous.motdObservedAt
        end
    end

    local ranks, ranksSupported, ranksComplete = collectRanks()
    local news, newsSupported, newsComplete = collectNews()
    local challenges, challengesSupported, challengesComplete = collectChallenges()
    local rewards, rewardsSupported, rewardsComplete = collectRewards()
    local eventLog, eventLogSupported, eventLogComplete = collectEventLog()
    if eventLogComplete then
        appendNewGuildEvents(eventLog)
    end
    if rosterComplete then
        appendPresenceSnapshot(roster, rosterCounts)
    end
    local components = {
        roster = componentCoverage(rosterSupported, rosterComplete, "guild_roster"),
        motd = componentCoverage(motdSupported, motdComplete, "guild_motd"),
        ranks = componentCoverage(ranksSupported, ranksComplete, "guild_ranks"),
        news = componentCoverage(newsSupported, newsComplete, "guild_news"),
        challenges = componentCoverage(challengesSupported, challengesComplete, "guild_challenges"),
        rewards = componentCoverage(rewardsSupported, rewardsComplete, "guild_rewards"),
        eventLog = componentCoverage(eventLogSupported, eventLogComplete, "guild_event_log"),
    }
    if motdSource == "last_good" then
        components.motd = Coverage.Partial("guild_motd_pending", {
            retainedLastGood = true,
            lastGoodObservedAt = motdObservedAt,
        })
    end

    local payload = {
        identity = {
            key = context.guild.key,
            name = context.guild.name,
            realm = context.guild.realm,
            region = context.guild.region,
        },
        motd = motd,
        motdSource = motdSource,
        motdObservedAt = motdObservedAt,
        motdExplicitlyEmpty = motdComplete and motd == "",
        info = infoText,
        ranks = ranks,
        tabard = collectTabard(),
        roster = roster,
        rosterCounts = rosterCounts,
        news = news,
        challenges = challenges,
        rewards = rewards,
        eventLog = eventLog,
        componentCoverage = components,
        componentSignals = Util.Copy(self.componentSignals),
    }

    local permissionEvidence = {
        rankIndex = context.guild.rankIndex,
        rankName = context.guild.rankName,
        canViewOfficerNote = canViewOfficerNote,
        canEditOfficerNote = safePermission("CanEditOfficerNote"),
        canEditPublicNote = safePermission("CanEditPublicNote"),
        canGuildInvite = safePermission("CanGuildInvite"),
        canGuildPromote = safePermission("CanGuildPromote"),
    }
    local pending = {}
    for name, observation in pairs(components) do
        if observation.status ~= "complete" then
            pending[#pending + 1] = name
        end
    end
    table.sort(pending)
    local details = {
        memberCount = #roster,
        components = components,
        pendingComponents = pending,
        retainedLastGoodMotd = motdSource == "last_good",
    }
    local coverage = #pending == 0 and Coverage.Complete(details)
        or Coverage.Partial("guild_components_pending", details)
    return payload, coverage, context.guild.key, permissionEvidence, {
        -- A directly observed GMOD plus a freshly enumerated payload is
        -- independently attributable to this character even when optional
        -- guild APIs keep overall coverage partial.
        allowCrossSourceReplace = motdComplete == true,
    }
end

EmberSync.CollectorManager:Register(Guild)
