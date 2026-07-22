local _, EmberSync = ...

local Coverage = EmberSync.Coverage
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
    },
    bankOpen = false,
    debounce = 0.75,
}

function Inventory:HandleEvent(_, event)
    if event == "BANKFRAME_OPENED" then
        self.bankOpen = true
    elseif event == "BANKFRAME_CLOSED" then
        self.bankOpen = false
    end
end

function Inventory:ResetStaging()
    self.bankOpen = false
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
        local info = api.GetContainerItemInfo(bagIndex, slot)
        if info then
            bag.items[slot] = Util.Sanitize(info)
        end
    end
    return bag
end

function Inventory:Collect(context)
    if type(_G.C_Container) ~= "table" then
        return {}, Coverage.Unsupported("container_api_unavailable"), context.sourceCharacter.id
    end
    local payload = { bags = {}, banks = {}, bankObserved = self.bankOpen }
    for bagIndex = 0, 5 do
        payload.bags[#payload.bags + 1] = collectBag(bagIndex)
    end
    if self.bankOpen then
        local bankIndices = { -1, 6, 7, 8, 9, 10, 11, 12, 13 }
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
                    payload.banks[#payload.banks + 1] = bag
                end
            end
        end
    end
    local coverage = self.bankOpen and Coverage.Complete()
        or Coverage.Partial("open_personal_or_warband_bank", {
            opportunity = "Open each personal and Warband bank to capture accessible bank tabs.",
        })
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Inventory)
