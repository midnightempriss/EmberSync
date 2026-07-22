local _, EmberSync = ...

local Constants = EmberSync.Constants
local Coverage = EmberSync.Coverage
local GuildLock = EmberSync.GuildLock
local Util = EmberSync.Util

local Database = {}

local function newDatabase()
    return {
        schemaVersion = Constants.SCHEMA_VERSION,
        installationId = Util.MakeInstallationId(),
        createdAt = Util.Now(),
        updatedAt = Util.Now(),
        meta = {
            addon = "EmberSync",
            addonVersion = EmberSync.version,
            interfaceVersion = Constants.INTERFACE_VERSION,
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
    if type(db.installationId) ~= "string" or db.installationId == "" then
        db.installationId = Util.MakeInstallationId()
    end
    local existingExports = type(db.exports) == "table" and db.exports or {}
    db.exports = {
        main = type(existingExports.main) == "table" and existingExports.main or nil,
        alt = type(existingExports.alt) == "table" and existingExports.alt or nil,
    }
    db.settings = type(db.settings) == "table" and db.settings
        or { categories = {}, minimap = { angle = 225, hidden = false } }
    db.settings.categories = type(db.settings.categories) == "table" and db.settings.categories or {}
    db.settings.minimap = type(db.settings.minimap) == "table" and db.settings.minimap
        or { angle = 225, hidden = false }
    db.meta = type(db.meta) == "table" and db.meta or {}
    db.meta.addon = "EmberSync"
    db.meta.addonVersion = EmberSync.version
    db.meta.interfaceVersion = Constants.INTERFACE_VERSION
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
            sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex),
            datasets = {},
            events = {},
            coverage = {},
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
        export.datasets = type(export.datasets) == "table" and export.datasets or {}
        export.events = type(export.events) == "table" and export.events or {}
        export.coverage = type(export.coverage) == "table" and export.coverage or {}
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
    if sanitizeState.truncated and coverage.status == Constants.COVERAGE.COMPLETE then
        coverage.status = Constants.COVERAGE.PARTIAL
        coverage.reason = "payload_safety_limit"
        coverage.truncated = true
    end
    coverage.observedAt = coverage.observedAt or Util.Now()

    options = type(options) == "table" and options or {}
    local key = datasetStorageKey(dataset, scope, subjectId)
    local sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex)
    local existing = export.datasets[key]
    local heartbeatSeconds = options.heartbeatSeconds or Constants.COLLECTOR_HEARTBEAT_SECONDS
    local existingAge = type(existing) == "table" and Util.Now() - (existing.capturedAt or 0) or math.huge
    local coverageMatches = type(existing) == "table" and type(existing.coverage) == "table"
        and existing.coverage.status == coverage.status and existing.coverage.reason == coverage.reason
    local sourceMatches = type(existing) == "table" and type(existing.sourceCharacter) == "table"
        and existing.sourceCharacter.id == sourceCharacter.id
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
    local export, err = self:GetActiveExport(true)
    if not export then
        return false, err
    end
    local sanitized = Util.Sanitize(payload, { maxDepth = 6, maxEntries = 500 })
    if not GuildLock:IsAuthorized() or GuildLock:GetIdentity().key ~= identity.key then
        return false, "authorization_changed"
    end

    local events = export.events[stream]
    if type(events) ~= "table" then
        events = {}
        export.events[stream] = events
    end
    export.sequence = (export.sequence or 0) + 1
    local event = {
        sequence = export.sequence,
        capturedAt = capturedAt or Util.Now(),
        guildKey = identity.key,
        sourceCharacter = Util.GetPlayerIdentity(identity.rankIndex),
        payload = sanitized or {},
    }
    table.insert(events, event)
    self:PruneEventStream(export, stream)
    if #events % 100 == 0 then
        self:EnforceSizeCap()
    end
    export.capturedAt = event.capturedAt
    export.sourceCharacter = Util.Copy(event.sourceCharacter)
    _G.EmberSyncDB.updatedAt = event.capturedAt
    EmberSync:Emit("DATABASE_UPDATED", identity.key, "events." .. stream, event)
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
        and (#events > Constants.MAX_EVENTS_PER_STREAM or (events[1].capturedAt or 0) < cutoff) do
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
