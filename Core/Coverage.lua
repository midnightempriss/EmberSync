local _, EmberSync = ...

local Constants = EmberSync.Constants
local Util = EmberSync.Util
local Coverage = {}

local valid = {}
for _, value in pairs(Constants.COVERAGE) do
    valid[value] = true
end

function Coverage.New(status, reason, details)
    if not valid[status] then
        status = Constants.COVERAGE.UNAVAILABLE
        reason = reason or "invalid_coverage_status"
    end
    local result = {
        status = status,
        reason = reason,
        observedAt = Util.Now(),
    }
    if type(details) == "table" then
        for key, value in pairs(details) do
            if result[key] == nil then
                result[key] = value
            end
        end
    end
    return result
end

function Coverage.Complete(details)
    return Coverage.New(Constants.COVERAGE.COMPLETE, nil, details)
end

function Coverage.Partial(reason, details)
    return Coverage.New(Constants.COVERAGE.PARTIAL, reason, details)
end

function Coverage.Unsupported(reason)
    return Coverage.New(Constants.COVERAGE.UNSUPPORTED, reason or "api_not_available")
end

function Coverage.Interaction(reason)
    return Coverage.New(Constants.COVERAGE.INTERACTION_REQUIRED, reason)
end

function Coverage.Forbidden(reason)
    return Coverage.New(Constants.COVERAGE.FORBIDDEN, reason)
end

function Coverage.Unavailable(reason)
    return Coverage.New(Constants.COVERAGE.UNAVAILABLE, reason)
end

EmberSync:RegisterModule("Coverage", Coverage)
