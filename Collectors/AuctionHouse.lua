local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local AuctionHouse = {
    name = "auction_house",
    scope = "character",
    events = {
        "AUCTION_HOUSE_SHOW",
        "AUCTION_HOUSE_CLOSED",
        "AUCTION_HOUSE_AUCTION_CREATED",
        "OWNED_AUCTIONS_UPDATED",
    },
    priorityEvents = {
        AUCTION_HOUSE_SHOW = true,
        OWNED_AUCTIONS_UPDATED = true,
    },
    isOpen = false,
    ownedResultsUpdated = false,
    debounce = 1,
    minInterval = 3,
}

function AuctionHouse:HandleEvent(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        self.isOpen = true
        self.ownedResultsUpdated = false
    elseif event == "AUCTION_HOUSE_CLOSED" then
        self.isOpen = false
        return false
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        self.ownedResultsUpdated = true
    end
end

function AuctionHouse:ResetStaging()
    self.isOpen = false
    self.ownedResultsUpdated = false
end

function AuctionHouse:Collect(context)
    local api = _G.C_AuctionHouse
    if type(api) ~= "table" or type(api.GetNumOwnedAuctions) ~= "function"
        or type(api.GetOwnedAuctionInfo) ~= "function" then
        return {}, Coverage.Unsupported("auction_house_api_unavailable"), context.sourceCharacter.id
    end
    if not self.isOpen then
        return {}, Coverage.Interaction("open_auction_house", {
            opportunity = "Open the Auction House and wait for your owned-auctions list to finish loading.",
        }), context.sourceCharacter.id
    end
    local auctions = {}
    local countOk, count = pcall(api.GetNumOwnedAuctions)
    if not countOk or type(count) ~= "number" then
        return {}, Coverage.Partial("owned_auction_results_pending", {
            opportunity = "Keep the Auction House open until the owned-auctions list finishes loading.",
        }), context.sourceCharacter.id
    end
    local enumerationReady = true
    for index = 1, count do
        local ok, info = pcall(api.GetOwnedAuctionInfo, index)
        if ok and info then
            auctions[#auctions + 1] = Util.Sanitize(info)
        else
            enumerationReady = false
        end
    end
    local complete = self.ownedResultsUpdated and enumerationReady
    if type(api.HasFullOwnedAuctionResults) == "function" then
        local ok, value = pcall(api.HasFullOwnedAuctionResults)
        complete = enumerationReady and ok and value == true
    end
    local coverage = complete and Coverage.Complete({ ownedAuctionCount = #auctions })
        or Coverage.Partial("owned_auction_results_pending", {
            ownedAuctionCount = #auctions,
            opportunity = "Keep the Auction House open until the owned-auctions list finishes loading.",
        })
    return { ownedAuctions = auctions }, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(AuctionHouse)
