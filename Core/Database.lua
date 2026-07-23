local _, EmberSync = ...

local Constants = EmberSync.Constants
local Coverage = EmberSync.Coverage
local GuildLock = EmberSync.GuildLock
local Util = EmberSync.Util

local Database = {}

local function migrateInstallationId(db)
    local previous = type(db) == "table" and db.installationId or nil
    local installationId, migrated = Util.NormalizeInstallationId(previous)
    db.installationId = installationId
    db.meta = type(db.meta) == "table" and db.meta or {}
    db.meta.installationIdFormatVersion = Constants.INSTALLATION_ID_FORMAT_VERSION
    if migrated then
        db.meta.installationIdMigratedAt = db.meta.installationIdMigratedAt or Util.Now()
    end
    for _, export in pairs(type(db.exports) == "table" and db.exports or {}) do
        if type(export) == "table" then
            export.installationId = installationId
            for _, envelope in pairs(type(export.datasets) == "table" and export.datasets or {}) do
                if type(envelope) == "table" then
                    envelope.installationId = installationId
                end
            end
        end
    end
    return installationId
end

local function newDatabase()
    return {
        schemaVersion = Constants.SCHEMA_VERSION,
        installationId = Util.MakeInstallationId(),
        createdAt = Util.Now(),
        updatedAt = Util.Now(),
        persistedAt = Util.Now(),
        meta = {
            addon = "EmberSync",
            addonVersion = EmberSync.version,
            interfaceVersion = Constants.INTERFACE_VERSION,
            installationIdFormatVersion = Constants.INSTALLATION_ID_FORMAT_VERSION,
        },
        settings = {
            categories = {},
            minimap = { angle = 225, hidden = false },
            privacy = { collectAllPermitted = true },
        },
        exports = {},
    }
end

function Database:Ensure()
    if not GuildLock:IsAuthorized() then
        return nil, "not_authorized"
    end

    if type(_G.EmberSyncDB) ~= "table" then
        _G.EmberSyncDB = newDatabase()
    elseif _G.EmberSyncDB.schemaVersion ~= Constants.SCHEMA_VERSION then
        -- Version 1 is the first public schema. Unknown data is deliberately
        -- not copied into the export: only the two canonical guild keys may be
        -- serialized by EmberSync.
        _G.EmberSyncDB = newDatabase()
    end

    local db = _G.EmberSyncDB
    migrateInstallationId(db)
    db.persistedAt = Util.SafeNumber(db.persistedAt)
        or Util.SafeNumber(db.updatedAt) or Util.Now()
    local existingExports = type(db.exports) == "table" and db.exports or {}
    db.exports = {
        main = type(existingExports.main) == "table" and existingExports.main or nil,
        alt = type(existingExports.alt) == "table" and existingExports.alt or nil,
    }
    for _, export in pairs(db.exports) do
        if type(export) == "table" then
            export.schemaVersion = Constants.SCHEMA_VERSION
            export.installationId = db.installationId
            export.sequence = Util.SafeNumber(export.sequence) or 0
            export.persistedAt = Util.SafeNumber(export.persistedAt)
                or Util.SafeNumber(db.persistedAt) or Util.SafeNumber(export.capturedAt) or Util.Now()
            export.datasets = type(export.datasets) == "table" and export.datasets or {}
            export.events = type(export.events) == "table" and export.events or {}
            export.coverage = type(export.coverage) == "table" and export.coverage or {}
            export.collectorHealth = type(export.collectorHealth) == "table"
                and export.collectorHealth or {}
        end
    end
    db.settings = type(db.settings) == "table" and db.settings
        or { categories = {}, minimap = { angle = 225, hidden = false } }
    db.settings.categories = type(db.settings.categories) == "table" and db.settings.categories or {}
    db.settings.minimap = type(db.settings.minimap) == "table" and db.settings.minimap
        or { angle = 225, hidden = false }
    db.meta = type(db.meta) == "table" and db.meta or {}
    db.meta.addon = "EmberSync"
    db.meta.addonVersion = EmberSync.version
    db.meta.interfaceVersion = Constants.INTERFACE_VERSION
    db.meta.installationIdFormatVersion = Constants.INSTALLATION_ID_FORMAT_VERSION
    return db
end

function Database:GetActiveExport(create)
    local identity = GuildLock:GetIdentity()
    if not identity then
        return nil, "not_authorized"
    end
    local db = create and self:Ensure() or _G.EmberSyncDB
    if type(db) ~= "table" or type(db.exports) ~= "table" then
        return nil, "not_initialized"
    end

    local export = db.exports[identity.key]
    if not export and create then
        export = {
            schemaVersion = Constants.SCHEMA_VERSION,
            guild = {
                key = identity.key,
                name = identity.name,
                realm = identity.realm,
                region = identity.region,
            },
            installationId = db.installationId,
            sequence = 0,
            capturedAt = Util.Now(),
            persistedAt = Util.SafeNumber(db.persistedAt) or Util.Now(),
            sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex),
            datasets = {},
            events = {},
            coverage = {},
            collectorHealth = {},
        }
        db.exports[identity.key] = export
    else
        export.schemaVersion = Constants.SCHEMA_VERSION
        export.guild = {
            key = identity.key,
            name = identity.name,
            realm = identity.realm,
            region = identity.region,
        }
        export.installationId = db.installationId
        export.sequence = type(export.sequence) == "number" and export.sequence or 0
        export.persistedAt = Util.SafeNumber(export.persistedAt)
            or Util.SafeNumber(db.persistedAt) or Util.SafeNumber(export.capturedAt) or Util.Now()
        export.datasets = type(export.datasets) == "table" and export.datasets or {}
        export.events = type(export.events) == "table" and export.events or {}
        export.coverage = type(export.coverage) == "table" and export.coverage or {}
        export.collectorHealth = type(export.collectorHealth) == "table" and export.collectorHealth or {}
    end
    return export
end

local function datasetStorageKey(dataset, scope, subjectId)
    if scope == "guild" or scope == "account" then
        return dataset
    end
    return dataset .. ":" .. tostring(subjectId or "unknown")
end

function Database:CommitDataset(dataset, scope, subjectId, payload, coverage, permissionEvidence, options)
    if not GuildLock:IsAuthorized() then
        return false, "not_authorized"
    end
    local identity = GuildLock:GetIdentity()
    dataset = Util.SafeString(dataset, false)
    scope = Util.SafeString(scope, false)
    subjectId = Util.SafeString(subjectId, false)
    if not dataset or not Constants.STATE_DATASETS[dataset] then
        return false, "unregistered_dataset"
    end
    if scope ~= "guild" and scope ~= "account" and scope ~= "character" then
        return false, "invalid_scope"
    end
    if not subjectId then
        return false, "subject_identity_unreadable"
    end
    local sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex)
    if not Util.IsPlayerGUID(sourceCharacter.id) then
        return false, "source_identity_unreadable"
    end
    if scope == "character" and subjectId ~= sourceCharacter.id then
        return false, "character_subject_mismatch"
    end
    local export, err = self:GetActiveExport(true)
    if not export then
        return false, err
    end

    local sanitized, sanitizeState = Util.Sanitize(payload)
    local estimatedSize = Util.EstimateSize(sanitized)
    if estimatedSize > Constants.MAX_DATASET_ESTIMATED_BYTES then
        sanitized, sanitizeState = Util.Sanitize(payload, {
            maxDepth = 6,
            maxEntries = 5000,
            maxStringBytes = 16384,
        })
        sanitizeState.truncated = true
        if Util.EstimateSize(sanitized) > Constants.MAX_DATASET_ESTIMATED_BYTES then
            sanitized, sanitizeState = Util.Sanitize(payload, {
                maxDepth = 5,
                maxEntries = 1000,
                maxStringBytes = 4096,
            })
            sanitizeState.truncated = true
        end
    end
    if not GuildLock:IsAuthorized() or GuildLock:GetIdentity().key ~= identity.key then
        return false, "authorization_changed"
    end

    coverage = type(coverage) == "table" and Util.Copy(coverage) or Coverage.Unavailable("collector_missing_coverage")
    if sanitizeState.truncated then
        coverage.truncated = true
        coverage.truncationReason = "payload_safety_limit"
        coverage.secretValuesOmitted = sanitizeState.secretValuesOmitted
        if coverage.status == Constants.COVERAGE.COMPLETE then
            coverage.status = Constants.COVERAGE.PARTIAL
            coverage.reason = "payload_safety_limit"
        end
    end
    coverage.observedAt = coverage.observedAt or Util.Now()

    options = type(options) == "table" and options or {}
    local key = datasetStorageKey(dataset, scope, subjectId)
    local existing = export.datasets[key]
    local heartbeatSeconds = options.heartbeatSeconds or Constants.COLLECTOR_HEARTBEAT_SECONDS
    local existingCapturedAt = type(existing) == "table" and Util.SafeNumber(existing.capturedAt) or nil
    local existingAge = existingCapturedAt and Util.Now() - existingCapturedAt or math.huge
    local sourceMatches = type(existing) == "table" and type(existing.sourceCharacter) == "table"
        and existing.sourceCharacter.id == sourceCharacter.id
    if options.coverageOnly == true and type(existing) == "table" then
        local previousCoverage = export.coverage[key]
        local previousCoverageObservedAt = type(previousCoverage) == "table"
            and Util.SafeNumber(previousCoverage.observedAt) or nil
        local previousCoverageAge = previousCoverageObservedAt
            and Util.Now() - previousCoverageObservedAt or math.huge
        local sameCoverage = type(previousCoverage) == "table"
            and previousCoverage.status == coverage.status
            and previousCoverage.reason == coverage.reason
        if not options.force and previousCoverageAge >= 0 and previousCoverageAge < heartbeatSeconds
            and sameCoverage then
            return true, key, "unchanged"
        end
        local coverageCapturedAt = math.max(
            Util.SafeNumber(coverage.observedAt) or 0,
            Util.Now(),
            (existingCapturedAt or 0) + 1
        )
        existing.coverage = Util.Copy(coverage)
        existing.capturedAt = coverageCapturedAt
        export.coverage[key] = Util.Copy(coverage)
        export.capturedAt = coverageCapturedAt
        export.sourceCharacter = sourceCharacter
        _G.EmberSyncDB.updatedAt = coverageCapturedAt
        EmberSync:Emit("DATABASE_UPDATED", identity.key, key, existing)
        return true, key, "coverage_only"
    end
    local existingWasComplete = type(existing) == "table" and type(existing.coverage) == "table"
        and existing.coverage.status == Constants.COVERAGE.COMPLETE
    if type(existing) == "table" and not sourceMatches and (scope == "guild" or scope == "account")
        and existingWasComplete and coverage.status ~= Constants.COVERAGE.COMPLETE
        and options.allowCrossSourceReplace ~= true then
        -- A shared logical dataset cannot safely combine observations from two
        -- characters inside one source-signed envelope. Keep the independently
        -- attributable complete envelope until this source produces its own
        -- complete enumeration.
        return true, key, "preserved_existing_source"
    end
    local coverageMatches = type(existing) == "table" and type(existing.coverage) == "table"
        and existing.coverage.status == coverage.status and existing.coverage.reason == coverage.reason
    if not options.force and existingAge >= 0 and existingAge < heartbeatSeconds
        and coverageMatches and sourceMatches and Util.DeepEqual(existing.payload, sanitized) then
        return true, key, "unchanged"
    end

    export.sequence = (export.sequence or 0) + 1
    export.capturedAt = Util.Now()
    export.sourceCharacter = sourceCharacter
    local envelope = {
        schemaVersion = Constants.SCHEMA_VERSION,
        dataset = dataset,
        scope = scope,
        subjectId = subjectId,
        guildKey = identity.key,
        guild = {
            key = identity.key,
            name = identity.name,
            realm = identity.realm,
            region = identity.region,
        },
        sourceCharacter = Util.Copy(export.sourceCharacter),
        installationId = export.installationId,
        sequence = export.sequence,
        capturedAt = export.capturedAt,
        coverage = coverage,
        permissionEvidence = Util.Sanitize(permissionEvidence or {
            rankIndex = identity.rankIndex,
            rankName = identity.rankName,
        }),
        payload = sanitized or {},
    }
    export.datasets[key] = envelope
    export.coverage[key] = Util.Copy(coverage)

    local db = _G.EmberSyncDB
    db.updatedAt = export.capturedAt
    if export.sequence % Constants.DATABASE_SIZE_CHECK_SEQUENCE_INTERVAL == 0 then
        self:EnforceSizeCap()
    end
    EmberSync:Emit("DATABASE_UPDATED", identity.key, key, envelope)
    return true, key
end

function Database:AppendEvent(stream, payload, capturedAt)
    if not GuildLock:IsAuthorized() then
        return false, "not_authorized"
    end
    local identity = GuildLock:GetIdentity()
    stream = Util.SafeString(stream, false)
    if not stream or not Constants.EVENT_STREAMS["events." .. stream] then
        return false, "unregistered_event_stream"
    end
    local sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex)
    if not Util.IsPlayerGUID(sourceCharacter.id) then
        return false, "source_identity_unreadable"
    end
    local export, err = self:GetActiveExport(true)
    if not export then
        return false, err
    end
    local sanitized, sanitizeState = Util.Sanitize(payload, { maxDepth = 6, maxEntries = 500 })
    if not GuildLock:IsAuthorized() or GuildLock:GetIdentity().key ~= identity.key then
        return false, "authorization_changed"
    end

    local events = export.events[stream]
    if type(events) ~= "table" then
        events = {}
        export.events[stream] = events
    end
    export.sequence = (export.sequence or 0) + 1
    capturedAt = Util.SafeNumber(capturedAt) or Util.Now()
    local event = {
        sequence = export.sequence,
        capturedAt = capturedAt,
        guildKey = identity.key,
        sourceCharacter = sourceCharacter,
        payload = sanitized or {},
    }
    if sanitizeState.truncated then
        event.sanitization = {
            truncated = true,
            reason = "payload_safety_limit",
            secretValuesOmitted = sanitizeState.secretValuesOmitted,
        }
    end
    table.insert(events, event)
    self:PruneEventStream(export, stream)
    local coverageKey = "events." .. stream
    local streamCoverage = export.coverage[coverageKey]
    if sanitizeState.truncated then
        export.coverage[coverageKey] = Coverage.Partial("payload_safety_limit", {
            truncated = true,
            secretValuesOmitted = sanitizeState.secretValuesOmitted,
            recordCount = #events,
            oldestRetainedAt = events[1] and events[1].capturedAt or nil,
            newestRetainedAt = events[#events] and events[#events].capturedAt or nil,
        })
    elseif type(streamCoverage) == "table"
        and (streamCoverage.reason == "retention_limit" or streamCoverage.reason == "database_soft_cap") then
        streamCoverage.observedAt = Util.Now()
        streamCoverage.recordCount = #events
        streamCoverage.oldestRetainedAt = events[1] and events[1].capturedAt or nil
        streamCoverage.newestRetainedAt = events[#events] and events[#events].capturedAt or nil
    else
        export.coverage[coverageKey] = Coverage.Complete({
            recordCount = #events,
            oldestRetainedAt = events[1] and events[1].capturedAt or nil,
            newestRetainedAt = events[#events] and events[#events].capturedAt or nil,
        })
    end
    if #events % 100 == 0 then
        self:EnforceSizeCap()
    end
    export.capturedAt = event.capturedAt
    export.sourceCharacter = Util.Copy(event.sourceCharacter)
    _G.EmberSyncDB.updatedAt = event.capturedAt
    EmberSync:Emit("DATABASE_UPDATED", identity.key, "events." .. stream, event)
    return true
end

function Database:RecordCollectorAttempt(name, trigger)
    name = Util.SafeString(name, false)
    if not name or not GuildLock:IsAuthorized() then
        return false
    end
    local export = self:GetActiveExport(true)
    if not export then
        return false
    end
    export.collectorHealth = type(export.collectorHealth) == "table" and export.collectorHealth or {}
    local health = type(export.collectorHealth[name]) == "table" and export.collectorHealth[name] or {}
    health.attempts = (tonumber(health.attempts) or 0) + 1
    health.lastAttemptAt = Util.Now()
    health.lastTrigger = Util.SafeString(trigger, true) or "unspecified"
    health.state = "running"
    export.collectorHealth[name] = health
    return true
end

function Database:RecordCollectorResult(name, succeeded, details)
    name = Util.SafeString(name, false)
    if not name or not GuildLock:IsAuthorized() then
        return false
    end
    local export = self:GetActiveExport(true)
    if not export then
        return false
    end
    export.collectorHealth = type(export.collectorHealth) == "table" and export.collectorHealth or {}
    local health = type(export.collectorHealth[name]) == "table" and export.collectorHealth[name] or {}
    local now = Util.Now()
    health.lastCompletedAt = now
    if succeeded then
        health.lastSuccessAt = now
        health.consecutiveFailures = 0
        health.lastError = nil
        health.state = "succeeded"
    else
        health.consecutiveFailures = (tonumber(health.consecutiveFailures) or 0) + 1
        health.lastFailureAt = now
        health.lastError = type(details) == "table"
            and (Util.SafeString(details.error, true) or "collector_failed") or "collector_failed"
        health.state = "failed"
    end
    if type(details) == "table" then
        health.lastOutcome = Util.SafeString(details.outcome, true)
        health.lastCpuMs = Util.SafeNumber(details.cpuMs)
        health.lastYieldCount = Util.SafeNumber(details.yields)
        if type(details.coverage) == "table" then
            health.coverage = Util.Sanitize(details.coverage, { maxDepth = 5, maxEntries = 500 })
            health.coverageObservedAt = details.coverage.observedAt or now
        end
    end
    export.collectorHealth[name] = health
    _G.EmberSyncDB.updatedAt = now
    return true
end

function Database:FinalizeActiveExport()
    if not GuildLock:IsAuthorized() then
        return false, "not_authorized"
    end
    local export, err = self:GetActiveExport(true)
    if not export then
        return false, err
    end
    for stream in pairs(export.events or {}) do
        self:PruneEventStream(export, stream)
    end
    local now = Util.Now()
    export.persistedAt = now
    export.finalizedAt = now
    local sourceCharacter = Util.GetPlayerIdentity((GuildLock:GetIdentity() or {}).rankIndex)
    if Util.IsPlayerGUID(sourceCharacter.id) then
        export.sourceCharacter = sourceCharacter
    end
    local db = _G.EmberSyncDB
    db.persistedAt = now
    db.updatedAt = math.max(tonumber(db.updatedAt) or 0, now)
    db.meta = type(db.meta) == "table" and db.meta or {}
    db.meta.lastFinalizedAt = now
    return true
end

function Database:PruneEventStream(export, stream)
    local events = export.events[stream]
    if type(events) ~= "table" then
        return
    end
    local cutoff = Util.Now() - Constants.MAX_EVENT_AGE_SECONDS
    local removed = 0
    while #events > 0
        and (#events > Constants.MAX_EVENTS_PER_STREAM
            or (Util.SafeNumber(events[1].capturedAt) or 0) < cutoff) do
        table.remove(events, 1)
        removed = removed + 1
    end
    if removed > 0 then
        export.coverage["events." .. stream] = Coverage.Partial("retention_limit", {
            evictedRecords = removed,
            oldestRetainedAt = events[1] and events[1].capturedAt or nil,
        })
    end
end

function Database:EnforceSizeCap()
    local db = _G.EmberSyncDB
    if type(db) ~= "table" then
        return
    end
    db.meta = type(db.meta) == "table" and db.meta or {}
    local estimatedBytes = Util.EstimateSize(db)
    db.meta.estimatedBytes = estimatedBytes
    db.meta.estimatedBytesAt = Util.Now()
    if estimatedBytes <= Constants.SOFT_DATABASE_BYTES then
        return
    end
    for _, export in pairs(db.exports or {}) do
        for stream in pairs(export.events or {}) do
            local events = export.events[stream]
            local target = math.max(100, math.floor(#events * 0.75))
            local removed = 0
            while #events > target do
                table.remove(events, 1)
                removed = removed + 1
            end
            if removed > 0 then
                export.coverage["events." .. stream] = Coverage.Partial("database_soft_cap", {
                    evictedRecords = removed,
                    oldestRetainedAt = events[1] and events[1].capturedAt or nil,
                })
            end
        end
    end
    estimatedBytes = Util.EstimateSize(db)
    db.meta.estimatedBytes = estimatedBytes
    db.meta.estimatedBytesAt = Util.Now()
    if estimatedBytes <= Constants.SOFT_DATABASE_BYTES then
        return
    end

    local candidates = {}
    for guildKey, export in pairs(db.exports or {}) do
        for datasetKey, envelope in pairs(export.datasets or {}) do
            candidates[#candidates + 1] = {
                guildKey = guildKey,
                datasetKey = datasetKey,
                capturedAt = type(envelope) == "table" and (envelope.capturedAt or 0) or 0,
                priority = type(envelope) == "table" and envelope.scope == "character" and 1 or 2,
            }
        end
    end
    table.sort(candidates, function(left, right)
        if left.priority ~= right.priority then
            return left.priority < right.priority
        end
        return left.capturedAt < right.capturedAt
    end)
    for _, candidate in ipairs(candidates) do
        estimatedBytes = Util.EstimateSize(db)
        if estimatedBytes <= Constants.SOFT_DATABASE_BYTES then
            break
        end
        local export = db.exports[candidate.guildKey]
        if export and export.datasets[candidate.datasetKey] then
            export.datasets[candidate.datasetKey] = nil
            export.coverage[candidate.datasetKey] = Coverage.Partial("database_soft_cap_evicted", {
                evictedAt = Util.Now(),
                previousCapturedAt = candidate.capturedAt,
            })
        end
    end
    db.meta.estimatedBytes = Util.EstimateSize(db)
    db.meta.estimatedBytesAt = Util.Now()
end

function Database:GetEstimatedSize()
    local db = _G.EmberSyncDB
    if type(db) ~= "table" or type(db.meta) ~= "table" then
        return nil
    end
    return db.meta.estimatedBytes, db.meta.estimatedBytesAt
end

function Database:SetSetting(path, value)
    if not GuildLock:IsAuthorized() then
        return false, "not_authorized"
    end
    local db, err = self:Ensure()
    if not db then
        return false, err
    end
    if path == "minimap.angle" and type(value) == "number" then
        db.settings.minimap.angle = value
    elseif path == "minimap.hidden" and type(value) == "boolean" then
        db.settings.minimap.hidden = value
    elseif type(path) == "string" and path:match("^categories%.") and type(value) == "boolean" then
        local name = path:match("^categories%.(.+)$")
        db.settings.categories[name] = value
    else
        return false, "invalid_setting"
    end
    db.updatedAt = Util.Now()
    return true
end

function Database:IsCategoryEnabled(name)
    if not GuildLock:IsAuthorized() then
        return false
    end
    local db = _G.EmberSyncDB
    if type(db) ~= "table" or type(db.settings) ~= "table" then
        return true
    end
    local value = db.settings.categories and db.settings.categories[name]
    return value ~= false
end

EmberSync:RegisterModule("Database", Database)
