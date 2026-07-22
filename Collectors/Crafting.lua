local _, EmberSync = ...

local Coverage = EmberSync.Coverage
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
        "CRAFTINGORDERS_CLAIM_ORDER_RESPONSE",
        "CRAFTINGORDERS_ORDER_PLACEMENT_RESPONSE",
        "TRADE_SKILL_LIST_UPDATE",
    },
    ordersOpen = false,
    debounce = 1,
}

function Crafting:HandleEvent(_, event)
    if event == "CRAFTINGORDERS_SHOW_CUSTOMER" or event == "CRAFTINGORDERS_SHOW_CRAFTER" then
        self.ordersOpen = true
    elseif event == "CRAFTINGORDERS_HIDE_CUSTOMER" or event == "CRAFTINGORDERS_HIDE_CRAFTER" then
        self.ordersOpen = false
    end
end

function Crafting:ResetStaging()
    self.ordersOpen = false
end

local function collectMethod(api, method, ...)
    if type(api) ~= "table" or type(api[method]) ~= "function" then
        return nil, false
    end
    local values = { pcall(api[method], ...) }
    if not values[1] then
        return nil, true
    end
    table.remove(values, 1)
    return Util.Sanitize(#values == 1 and values[1] or values), true
end

function Crafting:Collect(context)
    local api = _G.C_CraftingOrders
    if type(api) ~= "table" then
        return {}, Coverage.Unsupported("crafting_orders_api_unavailable"), context.sourceCharacter.id
    end
    if not self.ordersOpen then
        return {}, Coverage.Interaction("open_crafting_orders"), context.sourceCharacter.id
    end
    local payload, supported = {}, {}
    payload.crafterOrders, supported.crafterOrders = collectMethod(api, "GetCrafterOrders")
    payload.personalOrders, supported.personalOrders = collectMethod(api, "GetPersonalOrdersInfo")
    payload.customerOptions, supported.customerOptions = collectMethod(api, "GetCustomerOptions")
    payload.orderCounts, supported.orderCounts = collectMethod(api, "GetOrderCounts")
    payload.supported = supported
    return payload, Coverage.Partial("crafting_orders_context_and_permissions"), context.sourceCharacter.id
end

EmberSync.CollectorManager:Register(Crafting)
