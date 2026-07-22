local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local Calendar = {
    name = "calendar",
    scope = "guild",
    events = {
        "CALENDAR_UPDATE_EVENT_LIST",
        "CALENDAR_UPDATE_EVENT",
        "CALENDAR_UPDATE_INVITE_LIST",
        "CALENDAR_NEW_EVENT",
        "CALENDAR_OPEN_EVENT",
        "CALENDAR_CLOSE_EVENT",
    },
    debounce = 1,
    minInterval = 30,
    expensive = true,
    openedEvent = nil,
}

function Calendar:HandleEvent(_, event)
    if event == "CALENDAR_OPEN_EVENT" or event == "CALENDAR_UPDATE_EVENT"
        or event == "CALENDAR_UPDATE_INVITE_LIST" then
        local api = _G.C_Calendar
        if type(api) == "table" and type(api.GetEventInfo) == "function" then
            local ok, info = pcall(api.GetEventInfo)
            if ok and info then
                local opened = { info = Util.Sanitize(info), invites = {}, observedAt = Util.Now() }
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
            end
        end
    end
end

function Calendar:ResetStaging()
    self.openedEvent = nil
end

function Calendar:Collect(context)
    local api = _G.C_Calendar
    if type(api) ~= "table" or type(api.GetMonthInfo) ~= "function"
        or type(api.GetNumDayEvents) ~= "function" or type(api.GetDayEvent) ~= "function" then
        return {}, Coverage.Unsupported("calendar_api_unavailable"), context.guild.key
    end

    local events = {}
    local months = {}
    local workItems = 0
    for monthOffset = -1, 12 do
        local ok, monthInfo = pcall(api.GetMonthInfo, monthOffset)
        if ok and type(monthInfo) == "table" then
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
                            events[#events + 1] = {
                                monthOffset = monthOffset,
                                day = day,
                                index = eventIndex,
                                info = Util.Sanitize(event),
                            }
                        end
                    end
                end
            end
        end
    end

    local payload = { months = months, events = events, lastOpenedEvent = self.openedEvent }
    return payload, Coverage.Partial("event_details_require_calendar_context", {
        eventCount = #events,
        windowStartMonthOffset = -1,
        windowEndMonthOffset = 12,
    }), context.guild.key
end

EmberSync.CollectorManager:Register(Calendar)
