local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Util = EmberSync.Util

local AuctionHouse = {
    name = "auction_house",
    scope = "character",
    events = {
        "AUCTION_HOUSE_SHOW",
        "AUCTION_HOUSE_CLOSED",
        "AUCTION_HOUSE_OWNED_LIST_UPDATE",
        "AUCTION_HOUSE_AUCTION_CREATED",
        "OWNED_AUCTIONS_UPDATED",
    },
    isOpen = false,
    debounce = 1,
    minInterval = 3,
}

function AuctionHouse:HandleEvent(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        self.isOpen = true
    elseif event == "AUCTION_HOUSE_CLOSED" then
        self.isOpen = false
    end
end

function AuctionHouse:ResetStaging()
    self.isOpen = false
end

function AuctionHouse:Collect(context)
    local api = _G.C_AuctionHouse
    if type(api) ~= "table" or type(api.GetNumOwnedAuctions) ~= "function"
        or type(api.GetOwnedAuctionInfo) ~= "function" then
        return {}, Coverage.Unsupported("auction_house_api_unavailable"), context.sourceCharacter.id
    end
    if not self.isOpen then
        return {}, Coverage.Interaction("open_auction_house"), context.sourceCharacter.id
    end
    local auctions = {}
    local count = api.GetNumOwnedAuctions() or 0
    for index = 1, count do
        local ok, info = pcall(api.GetOwnedAuctionInfo, index)
        if ok and info then
            auctions[#auctions + 1] = Util.Sanitize(info)
        end
    end
    local complete = type(api.HasFullOwnedAuctionResults) ~= "function" or api.HasFullOwnedAuctionResults()
    local coverage = complete and Coverage.Complete({ ownedAuctionCount = #auctions })
        or Coverage.Partial("owned_auction_results_pending")
    return { ownedAuctions = auctions }, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(AuctionHouse)
