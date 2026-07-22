local _, EmberSync = ...

local Coverage = EmberSync.Coverage

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
    isOpen = false,
    debounce = 0.75,
}

function GuildBank:HandleEvent(_, event)
    if event == "GUILDBANKFRAME_OPENED" then
        self.isOpen = true
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self.isOpen = false
    end
end

function GuildBank:ResetStaging()
    self.isOpen = false
end

local function collectTransactions(tabIndex)
    local events = {}
    if type(_G.GetNumGuildBankTransactions) ~= "function" or type(_G.GetGuildBankTransaction) ~= "function" then
        return events
    end
    local count = _G.GetNumGuildBankTransactions(tabIndex) or 0
    for index = 1, math.min(count, 200) do
        local transactionType, name, itemLink, countOrMoney, tab1, tab2, year, month, day, hour =
            _G.GetGuildBankTransaction(tabIndex, index)
        events[#events + 1] = {
            type = transactionType,
            actor = name,
            itemLink = itemLink,
            countOrMoney = countOrMoney,
            sourceTab = tab1,
            destinationTab = tab2,
            occurred = { year = year, month = month, day = day, hour = hour },
        }
    end
    return events
end

function GuildBank:Collect(context)
    if not self.isOpen then
        return {}, Coverage.Interaction("open_guild_bank"), context.guild.key
    end
    if type(_G.GetNumGuildBankTabs) ~= "function" then
        return {}, Coverage.Unsupported("guild_bank_api_unavailable"), context.guild.key
    end

    local tabs = {}
    local permissionTabs = {}
    local visibleTabs = 0
    local tabCount = _G.GetNumGuildBankTabs() or 0
    for tabIndex = 1, tabCount do
        local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals
        if type(_G.GetGuildBankTabInfo) == "function" then
            name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals = _G.GetGuildBankTabInfo(tabIndex)
        end
        permissionTabs[tabIndex] = {
            isViewable = isViewable == true,
            canDeposit = canDeposit == true,
            numWithdrawals = numWithdrawals,
            remainingWithdrawals = remainingWithdrawals,
        }
        local tab = {
            index = tabIndex,
            name = name,
            icon = icon,
            isViewable = isViewable == true,
            canDeposit = canDeposit == true,
            numWithdrawals = numWithdrawals,
            remainingWithdrawals = remainingWithdrawals,
        }
        if isViewable then
            visibleTabs = visibleTabs + 1
            tab.text = type(_G.GetGuildBankText) == "function" and _G.GetGuildBankText(tabIndex) or nil
            tab.items = {}
            for slot = 1, 98 do
                local texture, itemCount, isLocked, isFiltered, quality
                if type(_G.GetGuildBankItemInfo) == "function" then
                    texture, itemCount, isLocked, isFiltered, quality = _G.GetGuildBankItemInfo(tabIndex, slot)
                end
                local itemLink = type(_G.GetGuildBankItemLink) == "function" and _G.GetGuildBankItemLink(tabIndex, slot) or nil
                if itemLink or texture then
                    tab.items[slot] = {
                        itemLink = itemLink,
                        texture = texture,
                        count = itemCount,
                        isLocked = isLocked,
                        isFiltered = isFiltered,
                        quality = quality,
                    }
                end
            end
            tab.transactions = collectTransactions(tabIndex)
        end
        tabs[tabIndex] = tab
    end

    local payload = {
        money = type(_G.GetGuildBankMoney) == "function" and _G.GetGuildBankMoney() or nil,
        withdrawableMoney = type(_G.GetGuildBankWithdrawMoney) == "function" and _G.GetGuildBankWithdrawMoney() or nil,
        tabs = tabs,
    }
    local coverage = visibleTabs == tabCount and Coverage.Complete({ tabCount = tabCount, visibleTabs = visibleTabs })
        or Coverage.Partial("rank_restricted_bank_tabs", { tabCount = tabCount, visibleTabs = visibleTabs })
    local permissionEvidence = {
        rankIndex = context.guild.rankIndex,
        rankName = context.guild.rankName,
        tabs = permissionTabs,
    }
    return payload, coverage, context.guild.key, permissionEvidence
end

EmberSync.CollectorManager:Register(GuildBank)
