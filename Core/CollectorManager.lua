local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Constants = EmberSync.Constants
local Database = EmberSync.Database
local GuildLock = EmberSync.GuildLock
local Util = EmberSync.Util

local CollectorManager = {
    collectors = {},
    byEvent = {},
    running = false,
    generation = 0,
    pending = {},
    jobs = {},
    deferred = {},
    lastRunAt = {},
    stats = {},
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

local function isInCombat()
    if type(_G.InCombatLockdown) ~= "function" then
        return false
    end
    local ok, value = pcall(_G.InCombatLockdown)
    return ok and value == true
end

function CollectorManager:RecordJob(job, status)
    local stats = self.stats[job.name] or { runs = 0, unchanged = 0, errors = 0, maxCpuMs = 0 }
    stats.runs = stats.runs + 1
    stats.lastCpuMs = job.cpuMs or 0
    stats.maxCpuMs = math.max(stats.maxCpuMs or 0, stats.lastCpuMs)
    stats.lastTrigger = job.trigger
    stats.lastCompletedAt = Util.Now()
    stats.lastYieldCount = job.yields or 0
    if status == "unchanged" then
        stats.unchanged = (stats.unchanged or 0) + 1
    elseif status == "error" then
        stats.errors = (stats.errors or 0) + 1
    end
    self.stats[job.name] = stats
end

function CollectorManager:ResumeJob(name, job, synchronous)
    if self.jobs[name] ~= job then
        return false
    end
    if job.generation ~= self.generation or not self.running or not GuildLock:IsAuthorized() then
        self.jobs[name] = nil
        return false
    end

    local startedAt = Util.ProfileMilliseconds()
    local results = { _G.coroutine.resume(job.thread) }
    job.cpuMs = (job.cpuMs or 0) + math.max(0, Util.ProfileMilliseconds() - startedAt)
    if not results[1] then
        self.jobs[name] = nil
        self.lastRunAt[name] = Util.MonotonicTime()
        self:RecordJob(job, "error")
        EmberSync:Log("%s collector failed: %s", name, tostring(results[2]))
        return false
    end

    if _G.coroutine.status(job.thread) == "dead" then
        self.jobs[name] = nil
        self.lastRunAt[name] = Util.MonotonicTime()
        self:RecordJob(job, results[4] == "unchanged" and "unchanged" or "complete")
        if job.rerunTrigger and self.running and GuildLock:IsAuthorized() then
            self:Schedule(name, job.rerunTrigger, job.collector.debounce or 0.5)
        end
        return results[2] ~= false
    end

    job.yields = (job.yields or 0) + 1
    if synchronous or type(_G.C_Timer) ~= "table" or type(_G.C_Timer.After) ~= "function" then
        return self:ResumeJob(name, job, true)
    end
    _G.C_Timer.After(0.01, function()
        self:ResumeJob(name, job, false)
    end)
    return true
end

function CollectorManager:Run(name, trigger, synchronous)
    local collector = self.collectors[name]
    if not collector or not self.running or not GuildLock:IsAuthorized() then
        return false
    end
    if not Database:IsCategoryEnabled(name) then
        return false
    end

    local activeJob = self.jobs[name]
    if activeJob then
        activeJob.rerunTrigger = trigger or activeJob.rerunTrigger
        return true
    end

    if not synchronous and collector.allowInCombat ~= true and isInCombat() then
        self.deferred[name] = trigger or self.deferred[name] or "combat_deferred"
        return false
    end

    local hasTimer = type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function"
    local minInterval = tonumber(collector.minInterval) or 0
    local lastRunAt = self.lastRunAt[name]
    local elapsed = lastRunAt and (Util.MonotonicTime() - lastRunAt) or math.huge
    if not synchronous and hasTimer and minInterval > 0 and elapsed >= 0 and elapsed < minInterval then
        self:Schedule(name, trigger, math.max(0.1, minInterval - elapsed))
        return false
    end

    local context = self:BuildContext(collector)
    if not context then
        return false
    end
    local generation = self.generation
    local job = {
        name = name,
        collector = collector,
        generation = generation,
        trigger = trigger or "unspecified",
        cpuMs = 0,
        yields = 0,
    }
    job.thread = _G.coroutine.create(function()
        local payload, coverage, subjectId, permissionEvidence = collector:Collect(context, trigger)
        if generation ~= self.generation or not GuildLock:IsAuthorized() then
            return false, "authorization_changed"
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
        return Database:CommitDataset(name, scope, subjectId, payload or {}, coverage, permissionEvidence, {
            force = trigger == "authorized_login",
        })
    end)
    self.jobs[name] = job
    return self:ResumeJob(name, job, synchronous == true)
end

function CollectorManager:Schedule(name, trigger, delay)
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    if self.pending[name] then
        self.pending[name].trigger = trigger or self.pending[name].trigger
        return
    end
    if self.jobs[name] then
        self.jobs[name].rerunTrigger = trigger or self.jobs[name].rerunTrigger
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
    local names = {}
    for name, collector in pairs(self.collectors) do
        if type(collector.Collect) == "function" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for index, name in ipairs(names) do
        local collector = self.collectors[name]
        local expensiveDelay = collector.expensive and 2 or 0
        self:Schedule(name, trigger or "full", math.min(8, index * 0.35 + expensiveDelay))
    end
end

function CollectorManager:Finalize()
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    self.pending = {}
    self.jobs = {}
    for name, collector in pairs(self.collectors) do
        if type(collector.Collect) == "function" then
            self:Run(name, "player_logout", true)
        end
    end
end

function CollectorManager:HandleEvent(event, ...)
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        local deferred = self.deferred
        self.deferred = {}
        for name, trigger in pairs(deferred) do
            self:Schedule(name, trigger or "combat_ended", self.collectors[name].debounce or 0.5)
        end
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
        self.ticker = _G.C_Timer.NewTicker(Constants.COLLECTOR_HEARTBEAT_SECONDS, function()
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
    self.jobs = {}
    self.deferred = {}
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

function CollectorManager:GetPerformanceStats()
    return self.stats
end

GuildLock:OnChanged(function(state)
    if state == "authorized_main" or state == "authorized_alt" then
        CollectorManager:Start()
    else
        CollectorManager:Stop()
    end
end)

EmberSync:RegisterModule("CollectorManager", CollectorManager)
