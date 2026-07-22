local _, EmberSync = ...

local Constants = EmberSync.Constants
local Util = EmberSync.Util

local GuildLock = {
    state = "verifying",
    reason = "startup",
    identity = nil,
    clubsInitialized = false,
    seenEnteringWorld = false,
    evaluationStartedAt = nil,
    callbacks = {},
    generation = 0,
}

local function getGuildForName(name)
    local normalized = Util.NormalizeGuildName(name)
    for _, guild in pairs(Constants.GUILDS) do
        if normalized == guild.normalizedName then
            return guild
        end
    end
    return nil
end

function GuildLock:Resolve(snapshot)
    snapshot = snapshot or {}
    local finalAttempt = snapshot.finalAttempt == true

    if type(snapshot.region) ~= "number" then
        return "verifying", "region_pending"
    end
    if snapshot.region ~= Constants.REGION_US then
        return "denied", "wrong_region"
    end

    if snapshot.inGuild == false and not snapshot.worldReady and not finalAttempt then
        return "verifying", "guild_info_pending"
    end
    if snapshot.inGuild == false then
        return "denied", "not_in_guild"
    end
    if not snapshot.guildName or snapshot.guildName == "" then
        if finalAttempt then
            return "denied", "verification_incomplete"
        end
        return "verifying", "guild_info_pending"
    end

    local guild = getGuildForName(snapshot.guildName)
    if not guild then
        return "denied", "wrong_guild"
    end

    local normalizedGuildRealm = Util.NormalizeRealm(snapshot.guildRealm)
    local normalizedPlayerRealm = Util.NormalizeRealm(snapshot.playerRealm)
    local realmSource = "guild"
    if not normalizedGuildRealm or normalizedGuildRealm == "" then
        if normalizedPlayerRealm == guild.normalizedRealm then
            normalizedGuildRealm = normalizedPlayerRealm
            realmSource = "same_realm_inference"
        else
            if finalAttempt then
                return "denied", "verification_incomplete"
            end
            return "verifying", "guild_realm_pending"
        end
    end
    if normalizedGuildRealm ~= guild.normalizedRealm then
        return "denied", "wrong_guild_realm"
    end

    if not snapshot.clubsInitialized then
        if finalAttempt then
            return "denied", "verification_incomplete"
        end
        return "verifying", "club_data_pending"
    end
    if snapshot.clubApiSupported == false then
        return "denied", "club_api_unavailable"
    end
    if not snapshot.clubId or not snapshot.clubInfo or not snapshot.selfMember then
        if finalAttempt then
            return "denied", "club_membership_missing"
        end
        return "verifying", "club_membership_pending"
    end

    if Util.NormalizeGuildName(snapshot.clubInfo.name) ~= guild.normalizedName then
        return "denied", "club_name_mismatch"
    end
    if snapshot.expectedGuildClubType ~= nil
        and snapshot.clubInfo.clubType ~= snapshot.expectedGuildClubType then
        return "denied", "club_type_mismatch"
    end

    local state = guild.key == "main" and "authorized_main" or "authorized_alt"
    return state, "verified", {
        key = guild.key,
        name = guild.name,
        realm = guild.realm,
        region = guild.region,
        slug = guild.slug,
        rankName = snapshot.rankName,
        rankIndex = snapshot.rankIndex,
        guildRealmSource = realmSource,
        clubId = snapshot.clubId,
        verifiedAt = Util.Now(),
    }
end

local function readRegion()
    if type(_G.C_GameAccount) == "table" and type(_G.C_GameAccount.GetCurrentRegion) == "function" then
        local ok, region = pcall(_G.C_GameAccount.GetCurrentRegion)
        if ok and type(region) == "number" then
            return region
        end
    end
    if type(_G.GetCurrentRegion) == "function" then
        local ok, region = pcall(_G.GetCurrentRegion)
        if ok and type(region) == "number" then
            return region
        end
    end
    return nil
end

function GuildLock:ReadSnapshot(finalAttempt)
    local guildName, rankName, rankIndex, guildRealm
    if type(_G.GetGuildInfo) == "function" then
        local ok
        ok, guildName, rankName, rankIndex, guildRealm = pcall(_G.GetGuildInfo, "player")
        if not ok then
            guildName, rankName, rankIndex, guildRealm = nil, nil, nil, nil
        end
    end

    local playerRealm
    if type(_G.GetRealmName) == "function" then
        local ok, value = pcall(_G.GetRealmName)
        playerRealm = ok and value or nil
    end

    local inGuild
    if type(_G.IsInGuild) == "function" then
        local ok, value = pcall(_G.IsInGuild)
        inGuild = ok and value or nil
    end

    local clubId, clubInfo, selfMember
    local clubApiSupported = type(_G.C_Club) == "table"
        and type(_G.C_Club.GetGuildClubId) == "function"
        and type(_G.C_Club.GetClubInfo) == "function"
        and type(_G.C_Club.GetMemberInfoForSelf) == "function"
    if clubApiSupported then
        local ok, value = pcall(_G.C_Club.GetGuildClubId)
        if ok then
            clubId = value
            if clubId ~= nil then
                self.clubsInitialized = true
                local infoOk, info = pcall(_G.C_Club.GetClubInfo, clubId)
                clubInfo = infoOk and info or nil
                local memberOk, member = pcall(_G.C_Club.GetMemberInfoForSelf, clubId)
                selfMember = memberOk and member or nil
            end
        end
    end

    local expectedGuildClubType
    if type(_G.Enum) == "table" and type(_G.Enum.ClubType) == "table" then
        expectedGuildClubType = _G.Enum.ClubType.Guild
    end

    return {
        region = readRegion(),
        inGuild = inGuild,
        guildName = guildName,
        guildRealm = guildRealm,
        playerRealm = playerRealm,
        rankName = rankName,
        rankIndex = rankIndex,
        clubsInitialized = self.clubsInitialized,
        clubApiSupported = clubApiSupported,
        clubId = clubId,
        clubInfo = clubInfo,
        selfMember = selfMember,
        expectedGuildClubType = expectedGuildClubType,
        worldReady = self.seenEnteringWorld,
        finalAttempt = finalAttempt == true,
    }
end

function GuildLock:SetState(state, reason, identity)
    local oldState = self.state
    local oldKey = self.identity and self.identity.key or nil
    self.state = state
    self.reason = reason
    self.identity = identity

    local newKey = identity and identity.key or nil
    if oldState ~= state or oldKey ~= newKey then
        self.generation = self.generation + 1
        for index = 1, #self.callbacks do
            local ok, err = pcall(self.callbacks[index], state, reason, identity, oldState)
            if not ok then
                EmberSync:Log("Guild-lock callback failed: %s", tostring(err))
            end
        end
        EmberSync:Emit("GUILD_LOCK_CHANGED", state, reason, identity, oldState)
    end
end

function GuildLock:Evaluate(finalAttempt)
    local snapshot = self:ReadSnapshot(finalAttempt)
    local state, reason, identity = self:Resolve(snapshot)
    self:SetState(state, reason, identity)
    return state, reason, identity
end

function GuildLock:OnChanged(callback)
    if type(callback) == "function" then
        table.insert(self.callbacks, callback)
    end
end

function GuildLock:IsAuthorized()
    return self.state == "authorized_main" or self.state == "authorized_alt"
end

function GuildLock:GetIdentity()
    if not self:IsAuthorized() then
        return nil
    end
    return self.identity
end

function GuildLock:Initialize()
    self.state = "verifying"
    self.reason = "startup"
    self.identity = nil
    self.evaluationStartedAt = type(_G.GetTime) == "function" and _G.GetTime() or 0

    local generation = self.generation
    local delays = { 0, 1, 3, 8, 15 }
    for index = 1, #delays do
        local delay = delays[index]
        local finalAttempt = index == #delays
        if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
            _G.C_Timer.After(delay, function()
                if self.generation == generation or self.state == "verifying" then
                    self:Evaluate(finalAttempt)
                end
            end)
        elseif delay == 0 then
            self:Evaluate(false)
        end
    end
end

function GuildLock:HandleEvent(event)
    if event == "INITIAL_CLUBS_LOADED" then
        self.clubsInitialized = true
    elseif event == "PLAYER_ENTERING_WORLD" then
        self.seenEnteringWorld = true
    end

    if event == "PLAYER_ENTERING_WORLD"
        or event == "PLAYER_GUILD_UPDATE"
        or event == "GUILD_ROSTER_UPDATE"
        or event == "INITIAL_CLUBS_LOADED" then
        if type(_G.C_GuildInfo) == "table" and type(_G.C_GuildInfo.GuildRoster) == "function" then
            pcall(_G.C_GuildInfo.GuildRoster)
        end
        self:Evaluate(false)
    end
end

EmberSync:RegisterModule("GuildLock", GuildLock)
