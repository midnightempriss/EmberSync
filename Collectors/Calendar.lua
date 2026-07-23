local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local Calendar = {
    name = "calendar",
    scope = "guild",
    events = {
        "PLAYER_ENTERING_WORLD",
        "CALENDAR_UPDATE_EVENT_LIST",
        "CALENDAR_UPDATE_GUILD_EVENTS",
        "CALENDAR_UPDATE_EVENT",
        "CALENDAR_UPDATE_INVITE_LIST",
        "CALENDAR_UPDATE_PENDING_INVITES",
        "CALENDAR_NEW_EVENT",
        "CALENDAR_OPEN_EVENT",
        "CALENDAR_CLOSE_EVENT",
    },
    priorityEvents = {
        CALENDAR_OPEN_EVENT = true,
        CALENDAR_UPDATE_EVENT = true,
        CALENDAR_UPDATE_INVITE_LIST = true,
    },
    debounce = 1,
    minInterval = 30,
    expensive = true,
    openedEvent = nil,
    openedEvents = {},
    lastOpenRequestAt = nil,
    lastOpenRequestSucceeded = nil,
    calendarReadyAt = nil,
}

local function calendarPrivacyClass(info)
    local calendarType = not Util.IsSecret(info) and type(info) == "table"
        and Util.SafeString(info.calendarType, true) or nil
    if calendarType == "GUILD_EVENT" or calendarType == "GUILD_ANNOUNCEMENT" then
        return "guild"
    end
    if calendarType == "HOLIDAY" or calendarType == "RAID_RESET"
        or calendarType == "RAID_LOCKOUT" or calendarType == "SYSTEM" then
        return "global"
    end
    -- Unknown and community/player invitations fail closed into the
    -- character-personal partition rather than a guild-visible projection.
    return "personal"
end

local function requestCalendarOpen(self, force)
    local api = _G.C_Calendar
    if type(api) ~= "table" or type(api.OpenCalendar) ~= "function" then
        return false, false
    end
    local now = Util.MonotonicTime()
    if not force and self.lastOpenRequestAt and now - self.lastOpenRequestAt < 60 then
        return true, self.lastOpenRequestSucceeded == true
    end
    self.lastOpenRequestAt = now
    local ok = pcall(api.OpenCalendar)
    self.lastOpenRequestSucceeded = ok
    return true, ok
end

local function openedEventKey(info)
    local readableInfo = not Util.IsSecret(info) and type(info) == "table" and info or nil
    local start = readableInfo and not Util.IsSecret(readableInfo.startTime)
        and type(readableInfo.startTime) == "table" and readableInfo.startTime or nil
    local function part(value)
        return Util.SafeString(value, true)
            or (Util.SafeNumber(value) and tostring(Util.SafeNumber(value))) or ""
    end
    local identityPart = part(readableInfo
        and (readableInfo.eventID or readableInfo.uid or readableInfo.calendarType))
    if identityPart == "" then
        identityPart = "event"
    end
    return table.concat({
        identityPart,
        part(readableInfo and readableInfo.title),
        part(start and start.year),
        part(start and start.month),
        part(start and start.monthDay),
        part(start and start.hour),
        part(start and start.minute),
    }, ":")
end

local function pruneOpenedEvents(events, limit)
    local values = {}
    for key, value in pairs(events) do
        values[#values + 1] = { key = key, value = value }
    end
    table.sort(values, function(left, right)
        return (left.value.observedAt or 0) > (right.value.observedAt or 0)
    end)
    for index = limit + 1, #values do
        events[values[index].key] = nil
    end
end

local function getPreviousEnvelope(context)
    local export = Database:GetActiveExport(false)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets.calendar or nil
    if type(envelope) ~= "table" or type(envelope.sourceCharacter) ~= "table"
        or envelope.sourceCharacter.id ~= context.sourceCharacter.id
        or type(envelope.payload) ~= "table" then
        return nil
    end
    return envelope
end

local function restorePreviousOpenedEvents(context, target)
    local envelope = getPreviousEnvelope(context)
    local previous = envelope and envelope.payload.openedEventDetails or nil
    if type(previous) ~= "table" then
        return
    end
    for key, value in pairs(previous) do
        if target[key] == nil and type(value) == "table" then
            target[key] = Util.Copy(value)
        end
    end
    pruneOpenedEvents(target, 200)
end

function Calendar:HandleEvent(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        requestCalendarOpen(self, true)
        return false
    end
    if event == "CALENDAR_CLOSE_EVENT" then
        return false
    end
    if event == "CALENDAR_UPDATE_EVENT_LIST" or event == "CALENDAR_UPDATE_GUILD_EVENTS" then
        self.calendarReadyAt = Util.Now()
    end
    if event == "CALENDAR_OPEN_EVENT" or event == "CALENDAR_UPDATE_EVENT"
        or event == "CALENDAR_UPDATE_INVITE_LIST" then
        local api = _G.C_Calendar
        if type(api) == "table" and type(api.GetEventInfo) == "function" then
            local ok, info = pcall(api.GetEventInfo)
            if ok and info then
                local opened = {
                    info = Util.Sanitize(info),
                    invites = {},
                    observedAt = Util.Now(),
                    privacyClass = calendarPrivacyClass(info),
                }
                if type(api.GetNumInvites) == "function" and type(api.GetInviteInfo) == "function" then
                    local countOk, count = pcall(api.GetNumInvites)
                    if countOk then
                        for index = 1, math.min(tonumber(count) or 0, 100) do
                            local inviteOk, invite = pcall(api.GetInviteInfo, index)
                            if inviteOk and invite then
                                opened.invites[#opened.invites + 1] = Util.Sanitize(invite)
                            end
                        end
                    end
                end
                self.openedEvent = opened
                self.openedEvents[openedEventKey(info)] = opened
                pruneOpenedEvents(self.openedEvents, 200)
            end
        end
    end
end

function Calendar:ResetStaging()
    self.openedEvent = nil
    self.openedEvents = {}
    self.lastOpenRequestAt = nil
    self.lastOpenRequestSucceeded = nil
    self.calendarReadyAt = nil
end

function Calendar:Collect(context)
    local api = _G.C_Calendar
    if type(api) ~= "table" or type(api.GetMonthInfo) ~= "function"
        or type(api.GetNumDayEvents) ~= "function" or type(api.GetDayEvent) ~= "function" then
        return {}, Coverage.Unsupported("calendar_api_unavailable"), context.guild.key
    end

    local openSupported, openRequested = requestCalendarOpen(self, false)
    restorePreviousOpenedEvents(context, self.openedEvents)
    local events = {}
    local guildEvents = {}
    local globalEvents = {}
    local personalEvents = {}
    local months = {}
    local workItems = 0
    for monthOffset = -1, 12 do
        local ok, monthInfo = pcall(api.GetMonthInfo, monthOffset)
        if ok and not Util.IsSecret(monthInfo) and type(monthInfo) == "table" then
            months[#months + 1] = Util.Sanitize(monthInfo)
            local numberOfDays = math.min(31, tonumber(monthInfo.numDays) or 31)
            for day = 1, numberOfDays do
                workItems = workItems + 1
                Util.Cooperate(workItems, 20)
                local countOk, count = pcall(api.GetNumDayEvents, monthOffset, day)
                if countOk then
                    for eventIndex = 1, math.min(tonumber(count) or 0, 100) do
                        workItems = workItems + 1
                        Util.Cooperate(workItems, 20)
                        local eventOk, event = pcall(api.GetDayEvent, monthOffset, day, eventIndex)
                        if eventOk and event then
                            local record = {
                                monthOffset = monthOffset,
                                day = day,
                                index = eventIndex,
                                info = Util.Sanitize(event),
                                privacyClass = calendarPrivacyClass(event),
                            }
                            events[#events + 1] = record
                            if record.privacyClass == "guild" then
                                guildEvents[#guildEvents + 1] = Util.Copy(record)
                            elseif record.privacyClass == "global" then
                                globalEvents[#globalEvents + 1] = Util.Copy(record)
                            else
                                personalEvents[#personalEvents + 1] = Util.Copy(record)
                            end
                        end
                    end
                end
            end
        end
    end

    if #months == 0 then
        local previousEnvelope = getPreviousEnvelope(context)
        if previousEnvelope then
            local retained = Util.Copy(previousEnvelope.payload)
            retained.initialization = {
                openSupported = openSupported,
                openRequested = openRequested,
                retainedLastGood = true,
                lastGoodCapturedAt = previousEnvelope.capturedAt,
            }
            return retained, Coverage.Partial("calendar_initialization_pending", {
                openSupported = openSupported,
                openRequested = openRequested,
                retainedLastGood = true,
                lastGoodCapturedAt = previousEnvelope.capturedAt,
            }), context.guild.key
        end
    end

    local payload = {
        months = months,
        events = events,
        guildEvents = guildEvents,
        globalEvents = globalEvents,
        personalEvents = personalEvents,
        lastOpenedEvent = Util.Copy(self.openedEvent),
        openedEventDetails = Util.Copy(self.openedEvents),
        initialization = {
            openSupported = openSupported,
            openRequested = openRequested,
            readyAt = self.calendarReadyAt,
        },
    }
    return payload, Coverage.Partial("event_details_require_calendar_context", {
        eventCount = #events,
        guildEventCount = #guildEvents,
        globalEventCount = #globalEvents,
        personalEventCount = #personalEvents,
        openedEventDetailCount = Util.TableCount(self.openedEvents),
        windowStartMonthOffset = -1,
        windowEndMonthOffset = 12,
        openSupported = openSupported,
        openRequested = openRequested,
        opportunity = "Open individual guild calendar events to capture their full details and invite lists.",
    }), context.guild.key
end

EmberSync.CollectorManager:Register(Calendar)
