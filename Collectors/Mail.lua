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
    isOpen = false,
    debounce = 1,
}

function Mail:HandleEvent(_, event)
    if event == "MAIL_SHOW" then
        self.isOpen = true
    elseif event == "MAIL_CLOSED" then
        self.isOpen = false
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
        return {}, Coverage.Interaction("open_mailbox"), context.sourceCharacter.id
    end
    local numberOfItems, totalItems = _G.GetInboxNumItems()
    local messages = {}
    for index = 1, (numberOfItems or 0) do
        local packageIcon, stationeryIcon, sender, subject, money, codAmount, daysLeft,
            itemCount, wasRead, wasReturned, textCreated, canReply, isGM = _G.GetInboxHeaderInfo(index)
        messages[#messages + 1] = {
            index = index,
            packageIcon = packageIcon,
            stationeryIcon = stationeryIcon,
            sender = sender,
            subject = subject,
            money = money,
            codAmount = codAmount,
            daysLeft = daysLeft,
            itemCount = itemCount,
            wasRead = wasRead,
            wasReturned = wasReturned,
            textCreated = textCreated,
            canReply = canReply,
            isGM = isGM,
        }
    end
    -- Mail bodies and invoice text are deliberately never requested.
    return { loadedCount = numberOfItems, totalCount = totalItems, headers = messages },
        Coverage.Complete({ messageCount = #messages }), context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Mail)
