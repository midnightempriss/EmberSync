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

local function isPriorityTrigger(collector, trigger)
    return type(collector.priorityEvents) == "table" and collector.priorityEvents[trigger] == true
end

local function preferRerunTrigger(collector, current, candidate)
    if not candidate then
        return current
    end
    if current and isPriorityTrigger(collector, current) and not isPriorityTrigger(collector, candidate) then
        return current
    end
    return candidate
end

function CollectorManager:Register(collector)
    assert(type(collector) == "table" and type(collector.name) == "string", "invalid collector")
    assert(type(collector.Collect) == "function" or type(collector.HandleEvent) == "function", "collector needs Collect or HandleEvent")
    if type(collector.Collect) == "function" then
        assert(Constants.STATE_DATASETS[collector.name] == true,
            "collector dataset is missing from the canonical registry: " .. collector.name)
    end
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
        local errorMessage = Util.SafeString(results[2], true) or "protected_or_unreadable_error"
        if type(Database.RecordCollectorResult) == "function" then
            Database:RecordCollectorResult(name, false, {
                error = errorMessage,
                cpuMs = job.cpuMs,
                yields = job.yields,
                coverage = job.coverage,
            })
        end
        EmberSync:Log("%s collector failed: %s", name, errorMessage)
        return false
    end

    if _G.coroutine.status(job.thread) == "dead" then
        self.jobs[name] = nil
        self.lastRunAt[name] = Util.MonotonicTime()
        local succeeded = results[2] ~= false
        local outcome = results[4] or (succeeded and "committed" or results[3])
        local status = not succeeded and "error"
            or outcome == "unchanged" and "unchanged" or "complete"
        self:RecordJob(job, status)
        if type(Database.RecordCollectorResult) == "function" then
            Database:RecordCollectorResult(name, succeeded, {
                error = not succeeded and (Util.SafeString(results[3], true) or "collector_failed") or nil,
                outcome = Util.SafeString(outcome, true),
                cpuMs = job.cpuMs,
                yields = job.yields,
                coverage = job.coverage,
            })
        end
        if job.rerunTrigger and self.running and GuildLock:IsAuthorized() then
            self:Schedule(name, job.rerunTrigger, job.collector.debounce or 0.5)
        end
        return succeeded
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
        activeJob.rerunTrigger = preferRerunTrigger(collector, activeJob.rerunTrigger, trigger)
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
    if not synchronous and hasTimer and not isPriorityTrigger(collector, trigger)
        and minInterval > 0 and elapsed >= 0 and elapsed < minInterval then
        self:Schedule(name, trigger, math.max(0.1, minInterval - elapsed))
        return false
    end

    local context = self:BuildContext(collector)
    if not context then
        return false
    end
    if not Util.IsPlayerGUID(context.sourceCharacter.id) then
        -- Without a readable Player GUID there is no valid source subject to
        -- sign or persist. Fail closed without creating an unattributable
        -- export; a later normal heartbeat retries automatically.
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
    if type(Database.RecordCollectorAttempt) == "function" then
        Database:RecordCollectorAttempt(name, job.trigger)
    end
    job.thread = _G.coroutine.create(function()
        local payload, coverage, subjectId, permissionEvidence, commitOptions = collector:Collect(context, trigger)
        if generation ~= self.generation or not GuildLock:IsAuthorized() then
            return false, "authorization_changed"
        end
        coverage = type(coverage) == "table" and coverage or Coverage.Unavailable("collector_missing_coverage")
        job.coverage = Util.Copy(coverage)
        local scope = collector.scope or "character"
        if scope == "character" and not subjectId then
            subjectId = context.sourceCharacter.id
        elseif scope == "guild" and not subjectId then
            subjectId = context.guild.key
        elseif scope == "account" and not subjectId then
            subjectId = "account"
        end
        if not Util.SafeString(subjectId, false) then
            return false, "subject_identity_unreadable"
        end
        commitOptions = type(commitOptions) == "table" and Util.Copy(commitOptions) or {}
        commitOptions.force = commitOptions.force == true or trigger == "authorized_login"
        return Database:CommitDataset(
            name,
            scope,
            subjectId,
            payload or {},
            coverage,
            permissionEvidence,
            commitOptions
        )
    end)
    self.jobs[name] = job
    return self:ResumeJob(name, job, synchronous == true)
end

function CollectorManager:Schedule(name, trigger, delay)
    if not self.running or not GuildLock:IsAuthorized() then
        return
    end
    local priority = isPriorityTrigger(self.collectors[name] or {}, trigger)
    if self.pending[name] then
        if self.pending[name].priority and not priority then
            -- Do not let a lower-priority follow-up event turn a user-open
            -- capture back into a min-interval-limited heartbeat run.
            return
        end
        if not priority or self.pending[name].priority then
            self.pending[name].trigger = trigger or self.pending[name].trigger
            return
        end
        -- A user just opened a short-lived data context while a slower
        -- heartbeat run was pending. Replace the token so the old timer becomes
        -- a no-op and inspect the newly available context after the collector's
        -- normal debounce window.
        self.pending[name] = nil
    end
    if self.jobs[name] then
        self.jobs[name].rerunTrigger = preferRerunTrigger(
            self.collectors[name] or {},
            self.jobs[name].rerunTrigger,
            trigger
        )
        return
    end
    local token = { generation = self.generation, trigger = trigger, priority = priority }
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
        -- Priority bypasses only the long minimum interval. Keeping the normal
        -- debounce coalesces bursty *_UPDATE events and avoids repeated crawls
        -- during one UI refresh.
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
        -- SavedVariables already contains the last completed event/heartbeat
        -- observations. Re-running catalog, achievement, bank, or calendar
        -- crawls synchronously during logout/reload can freeze the final frame
        -- and cannot yield safely. Collectors may opt in only when their work
        -- is explicitly bounded and logout-safe.
        if type(collector.Finalize) == "function" then
            local context = self:BuildContext(collector)
            local ok, err = pcall(collector.Finalize, collector, context)
            if not ok then
                EmberSync:Log("%s finalizer failed: %s", name,
                    Util.SafeString(err, true) or "protected_or_unreadable_error")
            end
        elseif collector.finalizeSynchronous == true and type(collector.Collect) == "function" then
            self:Run(name, "player_logout", true)
        end
    end
    if type(Database.FinalizeActiveExport) == "function" then
        Database:FinalizeActiveExport()
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
        local shouldCollect = true
        if type(collector.HandleEvent) == "function" then
            local context = self:BuildContext(collector)
            local ok, result = pcall(collector.HandleEvent, collector, context, event, ...)
            if not ok then
                EmberSync:Log("%s event handler failed: %s", collector.name, tostring(result))
            elseif result == false then
                shouldCollect = false
            end
        end
        if shouldCollect and type(collector.Collect) == "function" then
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
