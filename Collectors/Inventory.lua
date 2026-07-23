local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local Inventory = {
    name = "inventory",
    scope = "character",
    events = {
        "BAG_UPDATE_DELAYED",
        "PLAYERBANKSLOTS_CHANGED",
        "PLAYERBANKBAGSLOTS_CHANGED",
        "BANKFRAME_OPENED",
        "BANKFRAME_CLOSED",
        "ACCOUNT_MONEY",
        "PLAYERREAGENTBANKSLOTS_CHANGED",
        "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED",
        "BANK_TABS_CHANGED",
        "BANK_TAB_SETTINGS_UPDATED",
        "BANK_BAG_SLOT_FLAGS_UPDATED",
    },
    priorityEvents = {
        BANKFRAME_OPENED = true,
        PLAYERBANKSLOTS_CHANGED = true,
        PLAYERBANKBAGSLOTS_CHANGED = true,
        PLAYERREAGENTBANKSLOTS_CHANGED = true,
        PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED = true,
        BANK_TABS_CHANGED = true,
    },
    bankOpen = false,
    bankSnapshots = {},
    observedBankTypes = {},
    sessionObservedBankTypes = {},
    debounce = 0.75,
    minInterval = 5,
}

function Inventory:HandleEvent(_, event)
    if event == "BANKFRAME_OPENED" then
        self.bankOpen = true
    elseif event == "BANKFRAME_CLOSED" then
        self.bankOpen = false
        return false
    end
end

function Inventory:ResetStaging()
    self.bankOpen = false
    self.bankSnapshots = {}
    self.observedBankTypes = {}
    self.sessionObservedBankTypes = {}
end

local function collectBag(bagIndex)
    local api = _G.C_Container
    if type(api) ~= "table" or type(api.GetContainerNumSlots) ~= "function"
        or type(api.GetContainerItemInfo) ~= "function" then
        return nil
    end
    local slots = api.GetContainerNumSlots(bagIndex) or 0
    local bag = { index = bagIndex, slots = slots, items = {} }
    for slot = 1, slots do
        Util.Cooperate(slot, 25)
        local info = api.GetContainerItemInfo(bagIndex, slot)
        if info then
            bag.items[slot] = Util.Sanitize(info)
        end
    end
    return bag
end

local function restorePreviousBanks(context, snapshots, observedTypes)
    local export = Database:GetActiveExport(false)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets["inventory:" .. tostring(context.sourceCharacter.id)] or nil
    if type(envelope) ~= "table" or type(envelope.sourceCharacter) ~= "table"
        or envelope.sourceCharacter.id ~= context.sourceCharacter.id
        or type(envelope.payload) ~= "table" then
        return
    end
    local restored = 0
    for _, bag in ipairs(type(envelope.payload.banks) == "table" and envelope.payload.banks or {}) do
        local index = type(bag) == "table" and bag.index or nil
        if type(index) == "number" and index >= -10 and index <= 100 and snapshots[index] == nil
            and restored < 32 then
            snapshots[index] = Util.Copy(bag)
            restored = restored + 1
        end
    end
    for _, bankType in ipairs(type(envelope.payload.bankTypes) == "table"
        and envelope.payload.bankTypes or {}) do
        if type(bankType) == "number" and bankType >= 0 and bankType <= 10 then
            observedTypes[bankType] = true
        end
    end
end

function Inventory:Collect(context)
    if type(_G.C_Container) ~= "table" then
        return {}, Coverage.Unsupported("container_api_unavailable"), context.sourceCharacter.id
    end
    restorePreviousBanks(context, self.bankSnapshots, self.observedBankTypes)
    local payload = { bags = {}, banks = {}, bankObserved = self.bankOpen, bankTypes = {} }
    for bagIndex = 0, 5 do
        payload.bags[#payload.bags + 1] = collectBag(bagIndex)
    end
    if self.bankOpen then
        local bankIndices = { -1, 6, 7, 8, 9, 10, 11, 12, 13 }
        local bankApi = _G.C_Bank
        if type(bankApi) == "table" and type(bankApi.FetchViewableBankTypes) == "function" then
            local ok, bankTypes = pcall(bankApi.FetchViewableBankTypes)
            if ok and type(bankTypes) == "table" then
                for _, bankType in ipairs(bankTypes) do
                    if type(bankType) == "number" then
                        if type(bankApi.FetchPurchasedBankTabData) == "function" then
                            local dataOk, tabs = pcall(bankApi.FetchPurchasedBankTabData, bankType)
                            if dataOk and type(tabs) == "table" then
                                self.observedBankTypes[bankType] = true
                                self.sessionObservedBankTypes[bankType] = true
                                for _, tab in ipairs(tabs) do
                                    if type(tab) == "table" and type(tab.ID) == "number" then
                                        bankIndices[#bankIndices + 1] = tab.ID
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if type(_G.Enum) == "table" and type(_G.Enum.BagIndex) == "table" then
            local enum = _G.Enum.BagIndex
            local candidates = { enum.Bank, enum.Reagentbank, enum.AccountBankTab_1, enum.AccountBankTab_2,
                enum.AccountBankTab_3, enum.AccountBankTab_4, enum.AccountBankTab_5 }
            for _, value in ipairs(candidates) do
                if type(value) == "number" then
                    bankIndices[#bankIndices + 1] = value
                end
            end
        end
        local seen = {}
        for _, bagIndex in ipairs(bankIndices) do
            if not seen[bagIndex] then
                seen[bagIndex] = true
                local bag = collectBag(bagIndex)
                if bag and bag.slots > 0 then
                    self.bankSnapshots[bagIndex] = bag
                end
            end
        end
    end
    local snapshotIndices = {}
    for bagIndex in pairs(self.bankSnapshots) do
        snapshotIndices[#snapshotIndices + 1] = bagIndex
    end
    table.sort(snapshotIndices)
    for _, bagIndex in ipairs(snapshotIndices) do
        payload.banks[#payload.banks + 1] = Util.Copy(self.bankSnapshots[bagIndex])
    end
    for bankType in pairs(self.observedBankTypes) do
        payload.bankTypes[#payload.bankTypes + 1] = bankType
    end
    table.sort(payload.bankTypes)

    local characterBankType = type(_G.Enum) == "table" and type(_G.Enum.BankType) == "table"
        and _G.Enum.BankType.Character or 0
    local accountBankType = type(_G.Enum) == "table" and type(_G.Enum.BankType) == "table"
        and _G.Enum.BankType.Account or 2
    local observedBothThisSession = self.sessionObservedBankTypes[characterBankType]
        and self.sessionObservedBankTypes[accountBankType]
    local coverage = self.bankOpen and observedBothThisSession and Coverage.Complete({
        bankContainerCount = #payload.banks,
        observedBankTypes = Util.Copy(payload.bankTypes),
    }) or Coverage.Partial("open_personal_or_warband_bank", {
            bankContainerCount = #payload.banks,
            personalBankObservedThisSession = self.sessionObservedBankTypes[characterBankType] == true,
            warbandBankObservedThisSession = self.sessionObservedBankTypes[accountBankType] == true,
            opportunity = "Open each personal and Warband bank to capture accessible bank tabs.",
        })
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Inventory)
