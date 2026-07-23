local _, EmberSync = ...

local Coverage = EmberSync.Coverage

local Mail = {
    name = "mail_metadata",
    scope = "character",
    events = {
        "MAIL_SHOW",
        "MAIL_CLOSED",
        "MAIL_INBOX_UPDATE",
        "MAIL_SUCCESS",
        "UPDATE_PENDING_MAIL",
    },
    priorityEvents = {
        MAIL_SHOW = true,
        MAIL_INBOX_UPDATE = true,
        MAIL_SUCCESS = true,
    },
    isOpen = false,
    debounce = 1,
    minInterval = 5,
}

function Mail:HandleEvent(_, event)
    if event == "MAIL_SHOW" then
        self.isOpen = true
    elseif event == "MAIL_CLOSED" then
        self.isOpen = false
        return false
    end
end

function Mail:ResetStaging()
    self.isOpen = false
end

function Mail:Collect(context)
    if type(_G.GetInboxNumItems) ~= "function" or type(_G.GetInboxHeaderInfo) ~= "function" then
        return {}, Coverage.Unsupported("mail_api_unavailable"), context.sourceCharacter.id
    end
    if not self.isOpen then
        return {}, Coverage.Interaction("open_mailbox", {
            opportunity = "Open a mailbox and wait for the inbox headers to finish loading.",
        }), context.sourceCharacter.id
    end
    local countOk, numberOfItems, totalItems = pcall(_G.GetInboxNumItems)
    if not countOk or type(numberOfItems) ~= "number" or type(totalItems) ~= "number" then
        return {}, Coverage.Partial("mail_headers_loading", {
            opportunity = "Keep the mailbox open while the inbox header count loads.",
        }), context.sourceCharacter.id
    end
    local messages = {}
    local headersReady = true
    for index = 1, (numberOfItems or 0) do
        local values = { pcall(_G.GetInboxHeaderInfo, index) }
        if not values[1] or values[4] == nil then
            headersReady = false
        else
            messages[#messages + 1] = {
                index = index,
                packageIcon = values[2],
                stationeryIcon = values[3],
                sender = values[4],
                subject = values[5],
                money = values[6],
                codAmount = values[7],
                daysLeft = values[8],
                itemCount = values[9],
                wasRead = values[10],
                wasReturned = values[11],
                textCreated = values[12],
                canReply = values[13],
                isGM = values[14],
            }
        end
    end
    -- Mail bodies and invoice text are deliberately never requested.
    local payload = { loadedCount = numberOfItems, totalCount = totalItems, headers = messages }
    if numberOfItems < totalItems or not headersReady or #messages < numberOfItems then
        return payload, Coverage.Partial("mail_headers_partially_loaded", {
            loadedCount = #messages,
            totalCount = totalItems,
            opportunity = "Keep the mailbox open while the remaining inbox headers load.",
        }), context.sourceCharacter.id
    end
    return payload, Coverage.Complete({ messageCount = #messages, totalCount = totalItems }),
        context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Mail)
