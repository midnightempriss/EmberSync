local _, EmberSync = ...

local Coverage = EmberSync.Coverage
local Database = EmberSync.Database
local Util = EmberSync.Util

local Crafting = {
    name = "crafting",
    scope = "character",
    events = {
        "CRAFTINGORDERS_SHOW_CUSTOMER",
        "CRAFTINGORDERS_SHOW_CRAFTER",
        "CRAFTINGORDERS_HIDE_CUSTOMER",
        "CRAFTINGORDERS_HIDE_CRAFTER",
        "CRAFTINGORDERS_UPDATE_ORDER_COUNT",
        "CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS",
        "CRAFTINGORDERS_CLAIMED_ORDER_ADDED",
        "CRAFTINGORDERS_CLAIMED_ORDER_REMOVED",
        "CRAFTINGORDERS_CLAIMED_ORDER_UPDATED",
        "CRAFTINGORDERS_CLAIM_ORDER_RESPONSE",
        "CRAFTINGORDERS_ORDER_PLACEMENT_RESPONSE",
    },
    priorityEvents = {
        CRAFTINGORDERS_SHOW_CUSTOMER = true,
        CRAFTINGORDERS_SHOW_CRAFTER = true,
        CRAFTINGORDERS_UPDATE_ORDER_COUNT = true,
        CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS = true,
    },
    ordersOpen = false,
    activeContext = nil,
    observations = {},
    debounce = 1,
    minInterval = 5,
}

function Crafting:HandleEvent(_, event)
    if event == "CRAFTINGORDERS_SHOW_CUSTOMER" or event == "CRAFTINGORDERS_SHOW_CRAFTER" then
        self.ordersOpen = true
        self.activeContext = event == "CRAFTINGORDERS_SHOW_CUSTOMER" and "customer" or "crafter"
    elseif event == "CRAFTINGORDERS_HIDE_CUSTOMER" or event == "CRAFTINGORDERS_HIDE_CRAFTER" then
        self.ordersOpen = false
        self.activeContext = nil
        return false
    end
end

function Crafting:ResetStaging()
    self.ordersOpen = false
    self.activeContext = nil
    self.observations = {}
end

local function collectMethod(api, method, ...)
    if type(api) ~= "table" or type(api[method]) ~= "function" then
        return nil, false, false
    end
    local values = { pcall(api[method], ...) }
    if not values[1] then
        return nil, true, false
    end
    table.remove(values, 1)
    return Util.Sanitize(#values == 1 and values[1] or values), true, true
end

local function restorePreviousContexts(context, target)
    local export = Database:GetActiveExport(false)
    local envelope = type(export) == "table" and type(export.datasets) == "table"
        and export.datasets["crafting:" .. tostring(context.sourceCharacter.id)] or nil
    local previous = type(envelope) == "table" and type(envelope.sourceCharacter) == "table"
        and envelope.sourceCharacter.id == context.sourceCharacter.id and type(envelope.payload) == "table"
        and envelope.payload.contexts or nil
    if type(previous) ~= "table" then
        return
    end
    for key, value in pairs(previous) do
        if target[key] == nil and type(value) == "table" then
            target[key] = Util.Copy(value)
        end
    end
end

function Crafting:Collect(context)
    restorePreviousContexts(context, self.observations)
    local api = _G.C_CraftingOrders
    if type(api) ~= "table" then
        return {}, Coverage.Unsupported("crafting_orders_api_unavailable"), context.sourceCharacter.id
    end
    if not self.ordersOpen then
        return { contexts = Util.Copy(self.observations) }, Coverage.Interaction("open_crafting_orders", {
            opportunity = "Open both the Customer and Crafter Crafting Orders views; EmberSync records only data each view actually loads.",
        }), context.sourceCharacter.id
    end
    local mode = self.activeContext or "unknown"
    local observation = { observedAt = Util.Now(), supported = {}, loaded = {} }
    local methods = mode == "customer"
        and { "GetCustomerOrders", "GetMyOrders", "GetCustomerCategories", "GetPersonalOrdersInfo" }
        or { "GetCrafterOrders", "GetCrafterBuckets", "GetPersonalOrdersInfo", "GetClaimedOrder" }
    for _, method in ipairs(methods) do
        observation[method], observation.supported[method], observation.loaded[method] =
            collectMethod(api, method)
    end
    observation.craftingOrderTime, observation.supported.GetCraftingOrderTime,
        observation.loaded.GetCraftingOrderTime = collectMethod(api, "GetCraftingOrderTime")
    observation.orderNotesDisabled, observation.supported.AreOrderNotesDisabled,
        observation.loaded.AreOrderNotesDisabled = collectMethod(api, "AreOrderNotesDisabled")
    self.observations[mode] = observation

    local payload = {
        activeContext = mode,
        contexts = Util.Copy(self.observations),
    }
    local coverage = Coverage.Partial("crafting_orders_context_and_permissions", {
        customerContextObserved = self.observations.customer ~= nil,
        crafterContextObserved = self.observations.crafter ~= nil,
        opportunity = "Open both Crafting Orders views and wait for their order-count updates. Some order lists remain profession- and permission-specific.",
    })
    return payload, coverage, context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Crafting)
