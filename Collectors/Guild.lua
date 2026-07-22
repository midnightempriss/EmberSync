local _, EmberSync = ...

local Coverage = EmberSync.Coverage
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
    debounce = 1,
}

local function collectRanks()
    local ranks = {}
    if type(_G.GuildControlGetNumRanks) ~= "function" then
        return ranks
    end
    local count = _G.GuildControlGetNumRanks() or 0
    for index = 1, count do
        local flags
        if type(_G.GuildControlGetRankFlags) == "function" then
            flags = Util.Array(_G.GuildControlGetRankFlags(index))
        end
        ranks[index] = {
            index = index - 1,
            name = type(_G.GuildControlGetRankName) == "function" and _G.GuildControlGetRankName(index) or nil,
            flags = flags,
        }
    end
    return ranks
end

local function collectRoster(canViewOfficerNote)
    local roster = {}
    if type(_G.GetNumGuildMembers) ~= "function" or type(_G.GetGuildRosterInfo) ~= "function" then
        return roster, false
    end
    local total, online, onlineAndMobile = _G.GetNumGuildMembers()
    for index = 1, (total or 0) do
        local name, rankName, rankIndex, level, className, zone, publicNote, officerNote,
            isOnline, status, classFile, achievementPoints, achievementRank, isMobile,
            canScrollOfResurrection, reputationStanding, guid = _G.GetGuildRosterInfo(index)
        roster[#roster + 1] = {
            id = guid,
            name = name,
            rankName = rankName,
            rankIndex = rankIndex,
            level = level,
            className = className,
            classFile = classFile,
            zone = zone,
            publicNote = publicNote,
            officerNote = canViewOfficerNote and officerNote or nil,
            isOnline = isOnline,
            status = status,
            achievementPoints = achievementPoints,
            achievementRank = achievementRank,
            isMobile = isMobile,
            canScrollOfResurrection = canScrollOfResurrection,
            reputationStanding = reputationStanding,
        }
    end
    return roster, true, { total = total, online = online, onlineAndMobile = onlineAndMobile }
end

local function collectNews()
    local news = {}
    if type(_G.GetNumGuildNews) ~= "function" or type(_G.C_GuildInfo) ~= "table"
        or type(_G.C_GuildInfo.GetGuildNewsInfo) ~= "function" then
        return news
    end
    for index = 1, (_G.GetNumGuildNews() or 0) do
        local ok, info = pcall(_G.C_GuildInfo.GetGuildNewsInfo, index)
        if ok and info then
            news[#news + 1] = Util.Sanitize(info)
        end
    end
    return news
end

local function collectChallenges()
    local challenges = {}
    if type(_G.GetNumGuildChallenges) == "function" and type(_G.GetGuildChallengeInfo) == "function" then
        for index = 1, (_G.GetNumGuildChallenges() or 0) do
            local challengeType, currentCount, maxCount, currentGold, maxGold = _G.GetGuildChallengeInfo(index)
            challenges[#challenges + 1] = {
                type = challengeType,
                currentCount = currentCount,
                maxCount = maxCount,
                currentGold = currentGold,
                maxGold = maxGold,
            }
        end
    end
    return challenges
end

local function collectEventLog()
    local events = {}
    if type(_G.GetNumGuildEvents) == "function" and type(_G.GetGuildEventInfo) == "function" then
        for index = 1, math.min(_G.GetNumGuildEvents() or 0, 200) do
            local eventType, player1, player2, rank, year, month, day, hour = _G.GetGuildEventInfo(index)
            events[#events + 1] = {
                type = eventType,
                player1 = player1,
                player2 = player2,
                rank = rank,
                occurred = { year = year, month = month, day = day, hour = hour },
            }
        end
    end
    return events
end

local function collectRewards()
    if type(_G.GetGuildRewards) ~= "function" then
        return {}
    end
    local values = { pcall(_G.GetGuildRewards) }
    if not values[1] then
        return {}
    end
    table.remove(values, 1)
    return Util.Sanitize(values)
end

local function collectTabard()
    if type(_G.GetGuildTabardFiles) ~= "function" then
        return nil
    end
    local backgroundUpper, backgroundLower, emblemUpper, emblemLower, borderUpper, borderLower = _G.GetGuildTabardFiles()
    return {
        backgroundUpper = backgroundUpper,
        backgroundLower = backgroundLower,
        emblemUpper = emblemUpper,
        emblemLower = emblemLower,
        borderUpper = borderUpper,
        borderLower = borderLower,
    }
end

function Guild:Collect(context)
    if type(_G.C_GuildInfo) == "table" and type(_G.C_GuildInfo.GuildRoster) == "function" then
        pcall(_G.C_GuildInfo.GuildRoster)
    end
    local canViewOfficerNote = type(_G.CanViewOfficerNote) == "function" and _G.CanViewOfficerNote() or false
    local roster, rosterSupported, rosterCounts = collectRoster(canViewOfficerNote)
    local infoText
    if type(_G.C_GuildInfo) == "table" and type(_G.C_GuildInfo.GetGuildInfoText) == "function" then
        local ok, value = pcall(_G.C_GuildInfo.GetGuildInfoText)
        infoText = ok and value or nil
    elseif type(_G.GetGuildInfoText) == "function" then
        infoText = _G.GetGuildInfoText()
    end

    local payload = {
        identity = {
            key = context.guild.key,
            name = context.guild.name,
            realm = context.guild.realm,
            region = context.guild.region,
        },
        motd = type(_G.GetGuildRosterMOTD) == "function" and _G.GetGuildRosterMOTD() or nil,
        info = infoText,
        ranks = collectRanks(),
        tabard = collectTabard(),
        roster = roster,
        rosterCounts = rosterCounts,
        news = collectNews(),
        challenges = collectChallenges(),
        rewards = collectRewards(),
        eventLog = collectEventLog(),
    }

    local permissionEvidence = {
        rankIndex = context.guild.rankIndex,
        rankName = context.guild.rankName,
        canViewOfficerNote = canViewOfficerNote,
        canEditOfficerNote = type(_G.CanEditOfficerNote) == "function" and _G.CanEditOfficerNote() or false,
        canEditPublicNote = type(_G.CanEditPublicNote) == "function" and _G.CanEditPublicNote() or false,
        canGuildInvite = type(_G.CanGuildInvite) == "function" and _G.CanGuildInvite() or false,
        canGuildPromote = type(_G.CanGuildPromote) == "function" and _G.CanGuildPromote() or false,
    }
    local coverage = rosterSupported and Coverage.Complete({ memberCount = #roster })
        or Coverage.Partial("guild_roster_pending")
    return payload, coverage, context.guild.key, permissionEvidence
end

EmberSync.CollectorManager:Register(Guild)
