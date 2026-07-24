local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local GuildBank = {
    name = "guild_bank",
    scope = "guild",
    events = {
        "GUILDBANKFRAME_OPENED",
        "GUILDBANKFRAME_CLOSED",
        "GUILDBANKBAGSLOTS_CHANGED",
        "GUILDBANK_UPDATE_TABS",
        "GUILDBANK_UPDATE_TEXT",
        "GUILDBANK_UPDATE_MONEY",
        "GUILDBANKLOG_UPDATE",
    },
    priorityEvents = {
        GUILDBANKFRAME_OPENED = true,
        GUILDBANKBAGSLOTS_CHANGED = true,
        GUILDBANK_UPDATE_TABS = true,
        GUILDBANKLOG_UPDATE = true,
        GUILDBANK_UPDATE_TEXT = true,
    },
    isOpen = false,
    loadedTabs = {},
    loadedLogs = {},
    loadedText = {},
    moneyLogLoaded = false,
    moneyLogRequestedAt = nil,
    requestedTabs = {},
    activeRequest = nil,
    debounce = 0.75,
    minInterval = 3,
    expensive = true,
}

local function requestFinished(request)
    return type(request) == "table"
        and request.itemsPending ~= true
        and request.logPending ~= true
        and request.textPending ~= true
end

function GuildBank:HandleEvent(_, event, ...)
    if event == "GUILDBANKFRAME_OPENED" then
        self.isOpen = true
        self.loadedTabs = {}
        self.loadedLogs = {}
        self.loadedText = {}
        self.moneyLogLoaded = false
        self.moneyLogRequestedAt = nil
        self.requestedTabs = {}
        self.activeRequest = nil
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self.isOpen = false
        self.activeRequest = nil
        return false
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        -- Some current clients do not reliably fire GUILDBANKFRAME_OPENED.
        -- The first bank-slot payload is authoritative evidence that this
        -- character has an active guild-bank context.
        self.isOpen = true
        local request = self.activeRequest
        local tabIndex = type(request) == "table" and request.itemsPending and request.tabIndex or nil
        if not tabIndex and type(_G.GetCurrentGuildBankTab) == "function" then
            local ok, current = pcall(_G.GetCurrentGuildBankTab)
            tabIndex = ok and current or nil
        end
        if type(tabIndex) == "number" then
            self.loadedTabs[tabIndex] = true
        end
        if type(request) == "table" and request.tabIndex == tabIndex then
            request.itemsPending = false
        end
    elseif event == "GUILDBANKLOG_UPDATE" then
        local request = self.activeRequest
        if type(request) == "table" and request.logPending then
            if request.kind == "money" then
                self.moneyLogLoaded = true
                request.logPending = false
            else
                local tabIndex = request.tabIndex
                if type(tabIndex) == "number" then
                    self.loadedLogs[tabIndex] = true
                    request.logPending = false
                end
            end
        end
    elseif event == "GUILDBANK_UPDATE_TEXT" then
        local tabIndex = ...
        local request = self.activeRequest
        if type(tabIndex) ~= "number" and type(request) == "table" and request.textPending then
            tabIndex = request.tabIndex
        end
        if type(tabIndex) == "number" then
            self.loadedText[tabIndex] = true
        end
        if type(request) == "table" and request.tabIndex == tabIndex then
            request.textPending = false
        end
    end
    if requestFinished(self.activeRequest) then
        self.activeRequest = nil
    end
end

function GuildBank:ResetStaging()
    self.isOpen = false
    self.loadedTabs = {}
    self.loadedLogs = {}
    self.loadedText = {}
    self.moneyLogLoaded = false
    self.moneyLogRequestedAt = nil
    self.requestedTabs = {}
    self.activeRequest = nil
end

local function collectTransactions(tabIndex)
    local events = {}
    if type(_G.GetNumGuildBankTransactions) ~= "function" or type(_G.GetGuildBankTransaction) ~= "function" then
        return events
    end
    local countOk, rawCount = pcall(_G.GetNumGuildBankTransactions, tabIndex)
    local count = countOk and math.max(0, math.floor(Util.SafeNumber(rawCount) or 0)) or 0
    for index = 1, math.min(count, 200) do
        Util.Cooperate(index, 25)
        local result = { pcall(_G.GetGuildBankTransaction, tabIndex, index) }
        if result[1] then
            events[#events + 1] = {
                type = Util.SafeString(result[2], true),
                actor = Util.SafeString(result[3], true),
                itemLink = Util.SafeString(result[4], false),
                countOrMoney = Util.SafeNumber(result[5]),
                sourceTab = Util.SafeNumber(result[6]),
                destinationTab = Util.SafeNumber(result[7]),
                occurred = {
                    year = Util.SafeNumber(result[8]),
                    month = Util.SafeNumber(result[9]),
                    day = Util.SafeNumber(result[10]),
                    hour = Util.SafeNumber(result[11]),
                },
            }
        end
    end
    return events
end

local function collectMoneyTransactions()
    local events = {}
    if type(_G.GetNumGuildBankMoneyTransactions) ~= "function"
        or type(_G.GetGuildBankMoneyTransaction) ~= "function" then
        return events
    end
    local countOk, rawCount = pcall(_G.GetNumGuildBankMoneyTransactions)
    local count = countOk and math.max(0, math.floor(Util.SafeNumber(rawCount) or 0)) or 0
    for index = 1, math.min(count, 200) do
        Util.Cooperate(index, 25)
        local result = { pcall(_G.GetGuildBankMoneyTransaction, index) }
        if result[1] then
            local amount = Util.SafeNumber(result[4])
            events[#events + 1] = {
                type = Util.SafeString(result[2], true),
                actor = Util.SafeString(result[3], true),
                amountCopper = amount,
                countOrMoney = amount,
                occurred = {
                    year = Util.SafeNumber(result[5]),
                    month = Util.SafeNumber(result[6]),
                    day = Util.SafeNumber(result[7]),
                    hour = Util.SafeNumber(result[8]),
                },
            }
        end
    end
    return events
end

local function approximateOccurredAt(value, observedAt)
    if type(value) ~= "table" then
        return observedAt
    end
    local years = math.min(10, math.max(0, math.floor(Util.SafeNumber(value.year) or 0)))
    local months = math.min(12, math.max(0, math.floor(Util.SafeNumber(value.month) or 0)))
    local days = math.min(366, math.max(0, math.floor(Util.SafeNumber(value.day) or 0)))
    local hours = math.min(24, math.max(0, math.floor(Util.SafeNumber(value.hour) or 0)))
    local totalHours = (((years * 365) + (months * 30) + days) * 24) + hours
    return math.floor(math.max(0, observedAt - totalHours * 60 * 60) / 3600) * 3600
end

local function signaturePart(value)
    local text = Util.SafeString(value, true)
    if text == nil then
        local number = Util.SafeNumber(value)
        text = number and tostring(number) or ""
    end
    return tostring(#text) .. ":" .. text
end

local function bankEventSignature(event, occurredAt, tabIndex)
    return table.concat({
        signaturePart(event.type),
        signaturePart(event.actor),
        signaturePart(event.itemLink),
        signaturePart(event.countOrMoney),
        signaturePart(event.amountCopper),
        signaturePart(event.sourceTab),
        signaturePart(event.destinationTab),
        signaturePart(tabIndex),
        signaturePart(occurredAt),
    }, "|")
end

local function appendNewBankEvents(tabs, moneyTransactions, moneyTransactionsPreserved, moneyLogIndex)
    if type(Database.AppendEvent) ~= "function" or type(tabs) ~= "table" then
        return
    end
    local export = Database:GetActiveExport(false)
    local retained = type(export) == "table" and type(export.events) == "table"
        and export.events.guild_bank or {}
    local seen = {}
    for _, envelope in ipairs(type(retained) == "table" and retained or {}) do
        local payload = type(envelope) == "table" and envelope.payload or nil
        if type(payload) == "table" then
            local signature = bankEventSignature(
                payload,
                Util.SafeNumber(payload.occurredAt) or approximateOccurredAt(
                    payload.occurred,
                    Util.SafeNumber(envelope.capturedAt) or Util.Now()
                ),
                Util.SafeNumber(payload.tabIndex)
            )
            local occurrence = math.max(1, math.floor(Util.SafeNumber(payload.occurrence) or 1))
            seen[signature .. "#" .. occurrence] = true
        end
    end
    local observedAt = Util.Now()
    local occurrences = {}
    local function appendEvent(event, tabIndex, tabName, provenance)
        if type(event) ~= "table" then
            return
        end
        local occurredAt = approximateOccurredAt(event.occurred, observedAt)
        local signature = bankEventSignature(event, occurredAt, tabIndex)
        occurrences[signature] = (occurrences[signature] or 0) + 1
        local occurrence = occurrences[signature]
        local key = signature .. "#" .. occurrence
        if not seen[key] then
            local payload = Util.Copy(event)
            payload.tabIndex = tabIndex
            payload.tabName = tabName
            payload.occurredAt = occurredAt
            payload.observedAt = observedAt
            payload.occurrence = occurrence
            payload.provenance = provenance
            Database:AppendEvent("guild_bank", payload)
            seen[key] = true
        end
    end
    for tabIndex, tab in pairs(tabs) do
        if type(tab) == "table" and tab.transactionsPreserved ~= true
            and type(tab.transactions) == "table" then
            for _, event in ipairs(tab.transactions) do
                appendEvent(event, tabIndex, tab.name, "guild_bank_log")
            end
        end
    end
    if moneyTransactionsPreserved ~= true and type(moneyTransactions) == "table" then
        for _, event in ipairs(moneyTransactions) do
            appendEvent(event, moneyLogIndex, "Gold", "guild_bank_money_log")
        end
    end
end

local function requestVisibleTab(tabIndex)
    local request = {
        kind = "tab",
        tabIndex = tabIndex,
        startedAt = Util.MonotonicTime(),
        itemsPending = false,
        logPending = false,
        textPending = false,
    }
    if type(_G.QueryGuildBankTab) == "function" then
        request.itemsPending = pcall(_G.QueryGuildBankTab, tabIndex)
    end
    if type(_G.QueryGuildBankLog) == "function" then
        request.logPending = pcall(_G.QueryGuildBankLog, tabIndex)
    end
    if type(_G.QueryGuildBankText) == "function" then
        request.textPending = pcall(_G.QueryGuildBankText, tabIndex)
    end
    return requestFinished(request) and nil or request
end

local function requestMoneyLog(tabIndex)
    local request = {
        kind = "money",
        tabIndex = tabIndex,
        startedAt = Util.MonotonicTime(),
        itemsPending = false,
        logPending = false,
        textPending = false,
    }
    if type(_G.QueryGuildBankLog) == "function" then
        request.logPending = pcall(_G.QueryGuildBankLog, tabIndex)
    end
    return requestFinished(request) and nil or request
end

local function safeApiNumber(callback, ...)
    if type(callback) ~= "function" then
        return nil
    end
    local ok, value = pcall(callback, ...)
    return ok and Util.SafeNumber(value) or nil
end

local function previousPayloadForSource(context)
    local export = Database:GetActiveExport(false)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets.guild_bank or nil
    if type(envelope) ~= "table" or type(envelope.sourceCharacter) ~= "table"
        or envelope.sourceCharacter.id ~= context.sourceCharacter.id
        or type(envelope.payload) ~= "table" then
        return nil
    end
    return envelope.payload
end

local function preserveLoadedFields(tab, previous)
    if type(previous) ~= "table" then
        return
    end
    if tab.items == nil and type(previous.items) == "table" then
        tab.items = Util.Copy(previous.items)
        tab.itemsPreserved = true
    end
    if tab.transactions == nil and type(previous.transactions) == "table" then
        tab.transactions = Util.Copy(previous.transactions)
        tab.transactionsPreserved = true
    end
    if tab.text == nil and previous.text ~= nil then
        tab.text = previous.text
        tab.textPreserved = true
    end
end

function GuildBank:Collect(context)
    if not self.isOpen then
        return {}, Coverage.Interaction("open_guild_bank", {
            opportunity = "Open the Guild Bank and keep it open while EmberSync requests each viewable tab.",
        }), context.guild.key, nil, { coverageOnly = true }
    end
    if type(_G.GetNumGuildBankTabs) ~= "function" then
        return {}, Coverage.Unsupported("guild_bank_api_unavailable"), context.guild.key
    end

    local previousPayload = previousPayloadForSource(context)
    local tabs = {}
    local permissionTabs = {}
    local visibleTabs = 0
    local fullyLoadedTabs = 0
    local knownTabs = 0
    local nextTabToRequest = nil
    local now = Util.MonotonicTime()
    if type(self.activeRequest) == "table"
        and now - (self.activeRequest.startedAt or now) >= 5 then
        self.activeRequest = nil
    end
    local tabCount = math.max(0, math.floor(safeApiNumber(_G.GetNumGuildBankTabs) or 0))
    local moneyLogIndex = math.floor(Util.SafeNumber(_G.MAX_GUILDBANK_TABS) or tabCount) + 1
    local moneyLogSupported = type(_G.QueryGuildBankLog) == "function"
        and type(_G.GetNumGuildBankMoneyTransactions) == "function"
        and type(_G.GetGuildBankMoneyTransaction) == "function"
    for tabIndex = 1, tabCount do
        local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals
        if type(_G.GetGuildBankTabInfo) == "function" then
            local info = { pcall(_G.GetGuildBankTabInfo, tabIndex) }
            if info[1] then
                name = Util.SafeString(info[2], true)
                icon = Util.SafeNumber(info[3])
                isViewable = Util.SafeBoolean(info[4])
                canDeposit = Util.SafeBoolean(info[5])
                numWithdrawals = Util.SafeNumber(info[6])
                remainingWithdrawals = Util.SafeNumber(info[7])
            end
        end
        if type(isViewable) == "boolean" then
            knownTabs = knownTabs + 1
        end
        permissionTabs[tabIndex] = {
            isViewable = isViewable,
            canDeposit = canDeposit,
            numWithdrawals = numWithdrawals,
            remainingWithdrawals = remainingWithdrawals,
        }
        local tab = {
            index = tabIndex,
            name = name,
            icon = icon,
            isViewable = isViewable,
            canDeposit = canDeposit,
            numWithdrawals = numWithdrawals,
            remainingWithdrawals = remainingWithdrawals,
        }
        if isViewable then
            visibleTabs = visibleTabs + 1
            tab.itemsLoaded = self.loadedTabs[tabIndex] == true
            tab.logLoaded = type(_G.QueryGuildBankLog) ~= "function" or self.loadedLogs[tabIndex] == true
            tab.textLoaded = type(_G.QueryGuildBankText) ~= "function" or self.loadedText[tabIndex] == true
            if tab.itemsLoaded then
                tab.items = {}
                for slot = 1, 98 do
                    Util.Cooperate(((tabIndex - 1) * 98) + slot, 25)
                    local texture, itemCount, isLocked, isFiltered, quality
                    if type(_G.GetGuildBankItemInfo) == "function" then
                        local info = { pcall(_G.GetGuildBankItemInfo, tabIndex, slot) }
                        if info[1] then
                            texture, itemCount, isLocked, isFiltered, quality =
                                info[2], info[3], info[4], info[5], info[6]
                        end
                    end
                    local itemLink
                    if type(_G.GetGuildBankItemLink) == "function" then
                        local linkOk, link = pcall(_G.GetGuildBankItemLink, tabIndex, slot)
                        itemLink = linkOk and link or nil
                    end
                    local safeItemLink = Util.SafeString(itemLink, false)
                    local safeTexture = Util.SafeNumber(texture)
                    local itemID = safeItemLink
                        and tonumber(string.match(safeItemLink, "|Hitem:(%d+)")) or nil
                    if safeItemLink or safeTexture then
                        tab.items[slot] = {
                            itemID = itemID,
                            itemLink = safeItemLink,
                            iconFileID = safeTexture,
                            texture = safeTexture,
                            count = Util.SafeNumber(itemCount),
                            isLocked = Util.SafeBoolean(isLocked),
                            isFiltered = Util.SafeBoolean(isFiltered),
                            quality = Util.SafeNumber(quality),
                        }
                    end
                end
            end
            if tab.logLoaded then
                tab.transactions = collectTransactions(tabIndex)
            end
            if tab.textLoaded and type(_G.GetGuildBankText) == "function" then
                local ok, value = pcall(_G.GetGuildBankText, tabIndex)
                tab.text = ok and Util.SafeString(value, true) or nil
            end
            preserveLoadedFields(tab, type(previousPayload) == "table"
                and type(previousPayload.tabs) == "table" and previousPayload.tabs[tabIndex] or nil)
            if tab.itemsLoaded and tab.logLoaded and tab.textLoaded then
                fullyLoadedTabs = fullyLoadedTabs + 1
            elseif self.activeRequest == nil and not nextTabToRequest then
                local lastRequestedAt = self.requestedTabs[tabIndex]
                if not lastRequestedAt or now - lastRequestedAt >= 5 then
                    nextTabToRequest = tabIndex
                end
            end
        elseif isViewable == nil and self.activeRequest == nil and not nextTabToRequest then
            local lastRequestedAt = self.requestedTabs[tabIndex]
            if not lastRequestedAt or now - lastRequestedAt >= 5 then
                nextTabToRequest = tabIndex
            end
        end
        tabs[tabIndex] = tab
    end

    if self.activeRequest == nil then
        if nextTabToRequest then
            self.activeRequest = requestVisibleTab(nextTabToRequest)
            if self.activeRequest then
                self.requestedTabs[nextTabToRequest] = now
            end
        elseif moneyLogSupported and self.moneyLogLoaded ~= true
            and (not self.moneyLogRequestedAt or now - self.moneyLogRequestedAt >= 5) then
            self.activeRequest = requestMoneyLog(moneyLogIndex)
            if self.activeRequest then
                self.moneyLogRequestedAt = now
            end
        end
    end

    local moneyTransactions = nil
    local moneyTransactionsPreserved = false
    if moneyLogSupported and self.moneyLogLoaded == true then
        moneyTransactions = collectMoneyTransactions()
    elseif type(previousPayload) == "table"
        and type(previousPayload.moneyTransactions) == "table" then
        moneyTransactions = Util.Copy(previousPayload.moneyTransactions)
        moneyTransactionsPreserved = true
    end
    local payload = {
        money = safeApiNumber(_G.GetGuildBankMoney),
        withdrawableMoney = safeApiNumber(_G.GetGuildBankWithdrawMoney),
        moneyTransactions = moneyTransactions,
        tabs = tabs,
    }
    appendNewBankEvents(tabs, moneyTransactions, moneyTransactionsPreserved, moneyLogIndex)
    local coverage
    local requestedTab = type(self.activeRequest) == "table" and self.activeRequest.tabIndex or nextTabToRequest
    if tabCount == 0 or knownTabs < tabCount then
        coverage = Coverage.Partial("guild_bank_permissions_pending", {
            tabCount = tabCount,
            knownTabs = knownTabs,
            visibleTabs = visibleTabs,
            requestedTab = requestedTab,
            opportunity = "Keep the Guild Bank open while EmberSync loads its tab permissions and viewable contents.",
        })
    elseif visibleTabs == 0 then
        coverage = Coverage.Forbidden("rank_cannot_view_guild_bank_tabs", {
            tabCount = tabCount,
            visibleTabs = visibleTabs,
            actionNeeded = false,
            opportunity = "This character's current guild rank cannot view any Guild Bank tabs.",
        })
    elseif fullyLoadedTabs < visibleTabs then
        coverage = Coverage.Partial("guild_bank_tabs_loading", {
            tabCount = tabCount,
            visibleTabs = visibleTabs,
            fullyLoadedTabs = fullyLoadedTabs,
            requestedTab = requestedTab,
            opportunity = "Keep the Guild Bank open while EmberSync loads each viewable tab, tab text, and transaction log.",
        })
    elseif moneyLogSupported and self.moneyLogLoaded ~= true then
        coverage = Coverage.Partial("guild_bank_money_log_loading", {
            tabCount = tabCount,
            visibleTabs = visibleTabs,
            fullyLoadedTabs = fullyLoadedTabs,
            moneyLogIndex = moneyLogIndex,
            opportunity = "Keep the Guild Bank open while EmberSync loads the separate gold transaction log.",
        })
    elseif visibleTabs < tabCount then
        coverage = Coverage.Partial("rank_restricted_bank_tabs", {
            tabCount = tabCount,
            visibleTabs = visibleTabs,
            fullyLoadedTabs = fullyLoadedTabs,
            actionNeeded = false,
            opportunity = "All tabs visible to this rank were captured; other tabs are rank-restricted.",
        })
    else
        coverage = Coverage.Complete({
            tabCount = tabCount,
            visibleTabs = visibleTabs,
            fullyLoadedTabs = fullyLoadedTabs,
            moneyLogLoaded = not moneyLogSupported or self.moneyLogLoaded == true,
        })
    end
    local permissionEvidence = {
        rankIndex = context.guild.rankIndex,
        rankName = context.guild.rankName,
        tabs = permissionTabs,
    }
    return payload, coverage, context.guild.key, permissionEvidence
end

EmberSync.CollectorManager:Register(GuildBank)
