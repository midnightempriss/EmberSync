local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local GuildLock = EmberSync.GuildLock
local Util = EmberSync.Util

local CollectorManager = {
    collectors = {},
    byEvent = {},
    running = false,
    generation = 0,
    pending = {},
    ticker = nil,
}

function CollectorManager:Register(collector)
    assert(type(collector) == "table" and type(collector.name) == "string", "invalid collector")
    assert(type(collector.Collect) == "function" or type(collector.HandleEvent) == "function", "collector needs Collect or HandleEvent")
    self.collectors[collector.name] = collector
    EmberSync.collectors[collector.name] = collector
    for _, event in ipairs(collector.events or {}) do
        self.byEvent[event] = self.byEvent[event] or {}
        table.insert(self.byEvent[event], collector)
    end
end

function CollectorManager:GetRegisteredEvents()
    local events = {}
    for event in pairs(self.byEvent) do
        table.insert(events, event)
    end
    table.sort(events)
    return events
end

function CollectorManager:BuildContext(collector)
    local identity = GuildLock:GetIdentity()
    if not identity then
        return nil
    end
    local sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex)
    return {
        addon = EmberSync,
        collector = collector,
        guild = Util.Copy(identity),
        sourceCharacter = sourceCharacter,
        capturedAt = Util.Now(),
        coverage = Coverage,
        util = Util,
    }
end

function CollectorManager:Run(name, trigger)
    local collector = self.collectors[name]
    if not collector or not self.running or not GuildLock:IsAuthorized() then
        return false
    end
    if not Database:IsCategoryEnabled(name) then
        return false
    end

    local context = self:BuildContext(collector)
    local generation = self.generation
    local ok, payload, coverage, subjectId, permissionEvidence = pcall(collector.Collect, collector, context, trigger)
    if not ok then
        EmberSync:Log("%s collector failed: %s", name, tostring(payload))
        payload = { error = tostring(payload) }
        coverage = Coverage.Unavailable("collector_error")
    end
    if generation ~= self.generation or not GuildLock:IsAuthorized() then
        return false
    end

    coverage = type(coverage) == "table" and coverage or Coverage.Unavailable("collector_missing_coverage")
    local scope = collector.scope or "character"
    if scope == "character" and not subjectId then
        subjectId = context.sourceCharacter.id
    elseif scope == "guild" and not subjectId then
        subjectId = context.guild.key
    elseif scope == "account" and not subjectId then
        subjectId = "account"
    end
    return Database:CommitDataset(name, scope, subjectId, payload or {}, coverage, permissionEvidence)
end

function CollectorManager:Schedule(name, trigger, delay)
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    if self.pending[name] then
        self.pending[name].trigger = trigger or self.pending[name].trigger
        return
    end
    local token = { generation = self.generation, trigger = trigger }
    self.pending[name] = token
    local function run()
        if self.pending[name] ~= token then
            return
        end
        self.pending[name] = nil
        if token.generation == self.generation then
            self:Run(name, token.trigger)
        end
    end
    if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
        _G.C_Timer.After(delay or 0.25, run)
    else
        run()
    end
end

function CollectorManager:CollectAll(trigger)
    local index = 0
    for name, collector in pairs(self.collectors) do
        if type(collector.Collect) == "function" then
            index = index + 1
            self:Schedule(name, trigger or "full", math.min(3, index * 0.08))
        end
    end
end

function CollectorManager:Finalize()
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    for name, collector in pairs(self.collectors) do
        if type(collector.Collect) == "function" then
            self:Run(name, "player_logout")
        end
    end
end

function CollectorManager:HandleEvent(event, ...)
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    local collectors = self.byEvent[event]
    if not collectors then
        return
    end
    for index = 1, #collectors do
        local collector = collectors[index]
        if type(collector.HandleEvent) == "function" then
            local context = self:BuildContext(collector)
            local ok, err = pcall(collector.HandleEvent, collector, context, event, ...)
            if not ok then
                EmberSync:Log("%s event handler failed: %s", collector.name, tostring(err))
            end
        end
        if type(collector.Collect) == "function" then
            self:Schedule(collector.name, event, collector.debounce or 0.5)
        end
    end
end

function CollectorManager:Start()
    if self.running or not GuildLock:IsAuthorized() then
        return
    end
    self.running = true
    self.generation = self.generation + 1
    Database:Ensure()
    self:CollectAll("authorized_login")
    if type(_G.C_Timer) == "table" and type(_G.C_Timer.NewTicker) == "function" then
        self.ticker = _G.C_Timer.NewTicker(300, function()
            if self.running and GuildLock:IsAuthorized() then
                self:CollectAll("periodic")
            end
        end)
    end
end

function CollectorManager:Stop()
    self.running = false
    self.generation = self.generation + 1
    self.pending = {}
    if self.ticker and type(self.ticker.Cancel) == "function" then
        self.ticker:Cancel()
    end
    self.ticker = nil
    for _, collector in pairs(self.collectors) do
        if type(collector.ResetStaging) == "function" then
            pcall(collector.ResetStaging, collector)
        end
    end
end

GuildLock:OnChanged(function(state)
    if state == "authorized_main" or state == "authorized_alt" then
        CollectorManager:Start()
    else
        CollectorManager:Stop()
    end
end)

EmberSync:RegisterModule("CollectorManager", CollectorManager)
