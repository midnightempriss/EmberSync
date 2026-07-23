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

local function isGuildCalendarRecord(record)
    if Util.IsSecret(record) or type(record) ~= "table" then
        return false
    end
    local info = not Util.IsSecret(record.info) and type(record.info) == "table"
        and record.info or record
    return calendarPrivacyClass(info) == "guild"
end

local function copyGuildCalendarRecords(records)
    local guildRecords = {}
    if Util.IsSecret(records) or type(records) ~= "table" then
        return guildRecords
    end
    for _, record in ipairs(records) do
        if isGuildCalendarRecord(record) then
            local guildRecord = Util.Copy(record)
            guildRecord.privacyClass = "guild"
            guildRecords[#guildRecords + 1] = guildRecord
        end
    end
    return guildRecords
end

local function copyGuildOpenedEvents(openedEvents)
    local guildOpenedEvents = {}
    if Util.IsSecret(openedEvents) or type(openedEvents) ~= "table" then
        return guildOpenedEvents
    end
    for key, opened in pairs(openedEvents) do
        if not Util.IsSecret(key) and isGuildCalendarRecord(opened) then
            local guildOpened = Util.Copy(opened)
            guildOpened.privacyClass = "guild"
            guildOpenedEvents[key] = guildOpened
        end
    end
    return guildOpenedEvents
end

local function guildOnlyPayload(payload)
    local readablePayload = not Util.IsSecret(payload) and type(payload) == "table"
        and payload or {}
    local guildEvents = copyGuildCalendarRecords(readablePayload.guildEvents)
    if #guildEvents == 0 then
        guildEvents = copyGuildCalendarRecords(readablePayload.events)
    end
    local lastOpenedEvent = readablePayload.lastOpenedEvent
    if not isGuildCalendarRecord(lastOpenedEvent) then
        lastOpenedEvent = nil
    else
        lastOpenedEvent = Util.Copy(lastOpenedEvent)
        lastOpenedEvent.privacyClass = "guild"
    end
    return {
        months = Util.Copy(readablePayload.months or {}),
        events = Util.Copy(guildEvents),
        guildEvents = guildEvents,
        lastOpenedEvent = lastOpenedEvent,
        openedEventDetails = copyGuildOpenedEvents(readablePayload.openedEventDetails),
        initialization = Util.Copy(readablePayload.initialization or {}),
    }
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
    local identityPart = part(readableInfo and readableInfo.eventID)
    if identityPart == "" then
        identityPart = part(readableInfo and readableInfo.uid)
    end
    if identityPart == "" then
        identityPart = part(readableInfo and readableInfo.calendarType)
    end
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
        return (Util.SafeNumber(left.value.observedAt) or 0)
            > (Util.SafeNumber(right.value.observedAt) or 0)
    end)
    for index = limit + 1, #values do
        events[values[index].key] = nil
    end
end

local function getPreviousEnvelope(context)
    local export = Database:GetActiveExport(false)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets.calendar or nil
    local previousSourceId = not Util.IsSecret(envelope) and type(envelope) == "table"
        and not Util.IsSecret(envelope.sourceCharacter)
        and type(envelope.sourceCharacter) == "table"
        and Util.SafeString(envelope.sourceCharacter.id, false) or nil
    local currentSourceId = not Util.IsSecret(context) and type(context) == "table"
        and not Util.IsSecret(context.sourceCharacter)
        and type(context.sourceCharacter) == "table"
        and Util.SafeString(context.sourceCharacter.id, false) or nil
    if Util.IsSecret(envelope) or type(envelope) ~= "table"
        or not previousSourceId or not currentSourceId
        or previousSourceId ~= currentSourceId
        or Util.IsSecret(envelope.payload) or type(envelope.payload) ~= "table" then
        return nil
    end
    return envelope
end

local function restorePreviousOpenedEvents(context, target)
    for key, value in pairs(target) do
        if not isGuildCalendarRecord(value) then
            target[key] = nil
        end
    end
    local envelope = getPreviousEnvelope(context)
    local previous = envelope and envelope.payload.openedEventDetails or nil
    if Util.IsSecret(previous) or type(previous) ~= "table" then
        return
    end
    for key, value in pairs(previous) do
        if not Util.IsSecret(key) and target[key] == nil and isGuildCalendarRecord(value) then
            local guildOpened = Util.Copy(value)
            guildOpened.privacyClass = "guild"
            target[key] = guildOpened
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
            if ok and not Util.IsSecret(info) and type(info) == "table" then
                if calendarPrivacyClass(info) == "guild" then
                    local opened = {
                        info = Util.Sanitize(info),
                        invites = {},
                        observedAt = Util.Now(),
                        privacyClass = "guild",
                    }
                    if type(api.GetNumInvites) == "function" and type(api.GetInviteInfo) == "function" then
                        local countOk, count = pcall(api.GetNumInvites)
                        if countOk then
                            for index = 1, math.min(Util.SafeNumber(count) or 0, 100) do
                                local inviteOk, invite = pcall(api.GetInviteInfo, index)
                                if inviteOk and not Util.IsSecret(invite)
                                    and type(invite) == "table" then
                                    opened.invites[#opened.invites + 1] = Util.Sanitize(invite)
                                end
                            end
                        end
                    end
                    self.openedEvent = opened
                    self.openedEvents[openedEventKey(info)] = opened
                    pruneOpenedEvents(self.openedEvents, 200)
                else
                    -- Never stage a player, community, global, or unknown event.
                    -- Clearing the single-event pointer also prevents a previously
                    -- opened guild record from being misattributed to this context.
                    self.openedEvent = nil
                end
            elseif ok then
                self.openedEvent = nil
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
    local months = {}
    local workItems = 0
    for monthOffset = -1, 12 do
        local ok, monthInfo = pcall(api.GetMonthInfo, monthOffset)
        if ok and not Util.IsSecret(monthInfo) and type(monthInfo) == "table" then
            months[#months + 1] = Util.Sanitize(monthInfo)
            local numberOfDays = math.min(31, Util.SafeNumber(monthInfo.numDays) or 31)
            for day = 1, numberOfDays do
                workItems = workItems + 1
                Util.Cooperate(workItems, 20)
                local countOk, count = pcall(api.GetNumDayEvents, monthOffset, day)
                if countOk then
                    for eventIndex = 1, math.min(Util.SafeNumber(count) or 0, 100) do
                        workItems = workItems + 1
                        Util.Cooperate(workItems, 20)
                        local eventOk, event = pcall(api.GetDayEvent, monthOffset, day, eventIndex)
                        if eventOk and not Util.IsSecret(event) and type(event) == "table" then
                            if calendarPrivacyClass(event) == "guild" then
                                local record = {
                                    monthOffset = monthOffset,
                                    day = day,
                                    index = eventIndex,
                                    info = Util.Sanitize(event),
                                    privacyClass = "guild",
                                }
                                events[#events + 1] = record
                                guildEvents[#guildEvents + 1] = Util.Copy(record)
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
            local retained = guildOnlyPayload(previousEnvelope.payload)
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
            }), context.guild.key, nil, {
                allowCrossSourceReplace = true,
            }
        end
    end

    local payload = {
        months = months,
        events = events,
        guildEvents = guildEvents,
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
        openedEventDetailCount = Util.TableCount(self.openedEvents),
        windowStartMonthOffset = -1,
        windowEndMonthOffset = 12,
        openSupported = openSupported,
        openRequested = openRequested,
        opportunity = "Open individual guild calendar events to capture their full details and invite lists.",
    }), context.guild.key, nil, {
        allowCrossSourceReplace = true,
    }
end

EmberSync.CollectorManager:Register(Calendar)
