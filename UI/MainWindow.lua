local _, EmberSync = ...

local Constants = EmberSync.Constants
local Database = EmberSync.Database
local GuildLock = EmberSync.GuildLock
local L = EmberSync.L
local Util = EmberSync.Util

local MainWindow = {
    activeTab = "overview",
    frame = nil,
    tabs = {},
}

local TAB_DEFINITIONS = {
    { key = "overview", label = L.OVERVIEW },
    { key = "coverage", label = L.COVERAGE },
    { key = "sync", label = L.SYNC },
    { key = "privacy", label = L.PRIVACY },
    { key = "diagnostics", label = L.DIAGNOSTICS },
}

local function color(text, hex)
    return "|c" .. hex .. tostring(text or "") .. "|r"
end

local function statusLabel(status)
    local colors = {
        complete = "ff52d273",
        partial = "ffffc857",
        forbidden = "ffff6b6b",
        interaction_required = "ff00b4ff",
        unavailable = "ff9aa4b2",
        unsupported = "ff9aa4b2",
    }
    return color(status or "unknown", colors[status] or "ffffffff")
end

function MainWindow:Create()
    if self.frame or type(_G.CreateFrame) ~= "function" then
        return
    end
    local frame = _G.CreateFrame("Frame", "EmberSyncFrame", _G.UIParent, "BackdropTemplate")
    frame:SetSize(720, 510)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    frame:SetBackdropColor(0.035, 0.025, 0.025, 0.98)
    frame:Hide()

    local accent = frame:CreateTexture(nil, "ARTWORK")
    accent:SetColorTexture(0.941, 0.353, 0.122, 1)
    accent:SetPoint("TOPLEFT", 14, -14)
    accent:SetPoint("TOPRIGHT", -14, -14)
    accent:SetHeight(3)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 24, -28)
    title:SetText(color(L.TITLE, "fff05a1f"))

    local stateText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stateText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    stateText:SetPoint("RIGHT", frame, "RIGHT", -70, 0)
    stateText:SetJustifyH("LEFT")
    self.stateText = stateText

    local close = _G.CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    local tabAnchor
    for index, definition in ipairs(TAB_DEFINITIONS) do
        local button = _G.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(index == 2 and 130 or 105, 24)
        if not tabAnchor then
            button:SetPoint("TOPLEFT", 22, -78)
        else
            button:SetPoint("LEFT", tabAnchor, "RIGHT", 5, 0)
        end
        button:SetText(definition.label)
        button:SetScript("OnClick", function()
            self.activeTab = definition.key
            self:Refresh()
        end)
        self.tabs[definition.key] = button
        tabAnchor = button
    end

    local scroll = _G.CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 24, -115)
    scroll:SetPoint("BOTTOMRIGHT", -44, 28)
    local content = _G.CreateFrame("Frame", nil, scroll)
    content:SetSize(635, 1)
    scroll:SetScrollChild(content)
    local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT")
    body:SetWidth(625)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(4)
    self.scroll = scroll
    self.scrollContent = content
    self.body = body

    local denied = _G.CreateFrame("Frame", nil, frame)
    denied:SetPoint("TOPLEFT", 30, -120)
    denied:SetPoint("BOTTOMRIGHT", -30, 30)
    local deniedMessage = denied:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    deniedMessage:SetPoint("TOPLEFT")
    deniedMessage:SetPoint("TOPRIGHT")
    deniedMessage:SetJustifyH("LEFT")
    deniedMessage:SetJustifyV("TOP")
    deniedMessage:SetTextColor(1, 0.88, 0.8)
    deniedMessage:SetText(Constants.NONMEMBER_MESSAGE)
    self.deniedMessage = deniedMessage

    local urlLabel = denied:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    urlLabel:SetPoint("TOPLEFT", deniedMessage, "BOTTOMLEFT", 0, -30)
    urlLabel:SetText("Raining Embers website")
    self.urlLabel = urlLabel
    local urlBox = _G.CreateFrame("EditBox", nil, denied, "InputBoxTemplate")
    urlBox:SetSize(330, 30)
    urlBox:SetPoint("TOPLEFT", urlLabel, "BOTTOMLEFT", 4, -8)
    urlBox:SetAutoFocus(false)
    urlBox:SetText(Constants.WEBSITE_URL)
    urlBox:SetTextColor(0, 0.706, 1)
    urlBox:SetCursorPosition(0)
    urlBox:SetScript("OnEscapePressed", urlBox.ClearFocus)
    urlBox:SetScript("OnEditFocusGained", function(box)
        box:HighlightText()
    end)
    urlBox:SetScript("OnTextChanged", function(box)
        if box:GetText() ~= Constants.WEBSITE_URL then
            box:SetText(Constants.WEBSITE_URL)
            box:HighlightText()
        end
    end)
    self.urlBox = urlBox

    local copyButton = _G.CreateFrame("Button", nil, denied, "UIPanelButtonTemplate")
    copyButton:SetSize(165, 28)
    copyButton:SetPoint("TOPLEFT", urlBox, "BOTTOMLEFT", -4, -10)
    copyButton:SetText(L.COPY_URL)
    copyButton:SetScript("OnClick", function()
        urlBox:SetFocus()
        urlBox:HighlightText()
        self.copyHint:SetText(L.COPY_HINT)
    end)
    local copyHint = denied:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyHint:SetPoint("LEFT", copyButton, "RIGHT", 10, 0)
    copyHint:SetText("")
    self.copyHint = copyHint
    self.copyButton = copyButton
    self.denied = denied

    self.frame = frame
    if type(_G.UISpecialFrames) == "table" then
        table.insert(_G.UISpecialFrames, "EmberSyncFrame")
    end
end

function MainWindow:GetOverviewText(export)
    local identity = GuildLock:GetIdentity()
    local source = export and export.sourceCharacter or Util.GetPlayerIdentity(identity.rankIndex)
    local lines = {
        color(identity.name, "fff05a1f") .. " — " .. identity.realm .. " (US)",
        "Verified character: " .. tostring(source.name or "Unknown") .. "-" .. tostring(source.realm or "Unknown"),
        "Guild rank: " .. tostring(identity.rankName or "Unknown") .. " (" .. tostring(identity.rankIndex or "?") .. ")",
        "",
        "EmberSync captures every permitted dataset exposed to this character. Interaction-gated data updates when you open the relevant game window.",
        "",
        color("Useful data opportunities", "ff00b4ff"),
        "• Open the Guild Bank and each visible tab.",
        "• Visit your house, neighborhood, and neighborhood bulletin board.",
        "• Open every profession, personal/Warband bank, Auction House, mailbox, and Crafting Orders window.",
        "• Log in to each eligible Raining Embers character to capture character-specific data.",
    }
    return table.concat(lines, "\n")
end

function MainWindow:GetCoverageText(export)
    local lines = { "Each row reports what the game actually exposed. Partial or unavailable data never deletes a complete prior observation.", "" }
    local entries = {}
    for key, coverage in pairs(export and export.coverage or {}) do
        entries[#entries + 1] = { key = key, coverage = coverage }
    end
    table.sort(entries, function(a, b) return a.key < b.key end)
    if #entries == 0 then
        lines[#lines + 1] = "No collection pass has completed yet."
    end
    for _, entry in ipairs(entries) do
        local coverage = entry.coverage or {}
        local reason = coverage.reason and (" — " .. tostring(coverage.reason):gsub("_", " ")) or ""
        lines[#lines + 1] = color(entry.key, "ffffffff") .. ": " .. statusLabel(coverage.status) .. reason
    end
    return table.concat(lines, "\n")
end

function MainWindow:GetSyncText(export)
    return table.concat({
        color("Captured in game", "fff05a1f") .. ": " .. tostring(export and export.capturedAt or "waiting"),
        color("Persisted by WoW", "ff00b4ff") .. ": SavedVariables are written only on /reload, logout, disconnect, or client exit.",
        color("Uploaded", "ff52d273") .. ": Shown by the EmberSync desktop client after the website accepts the export.",
        "",
        "The addon cannot force a SavedVariables disk write and will never force /reload just to sync.",
        "Current export sequence: " .. tostring(export and export.sequence or 0),
    }, "\n")
end

function MainWindow:GetPrivacyText()
    return table.concat({
        color("Private by default", "fff05a1f"),
        "EmberSync collects all data this eligible character can legitimately inspect. The website applies current Battle.net membership and guild-rank checks before accepting or displaying it.",
        "",
        color("Never collected", "ff00b4ff"),
        "• Whispers, Battle.net contacts or messages, party/raid chat",
        "• Mail bodies, authentication data, Battle.net account identifiers",
        "• Raw combat-log event streams or protected/automated actions",
        "",
        "Guild and officer messages are collected only when visible to the current character. Mail collection is limited to loaded header and transaction metadata.",
    }, "\n")
end

function MainWindow:GetDiagnosticsText(export)
    local db = _G.EmberSyncDB
    return table.concat({
        "Addon version: " .. EmberSync.version,
        "Interface target: " .. Constants.INTERFACE_VERSION,
        "Schema version: " .. Constants.SCHEMA_VERSION,
        "Membership state: " .. GuildLock.state,
        "Verification reason: " .. tostring(GuildLock.reason),
        "Guild-realm source: " .. tostring(GuildLock.identity and GuildLock.identity.guildRealmSource),
        "Installation ID: " .. tostring(db and db.installationId or "not initialized"),
        "Export datasets: " .. tostring(Util.TableCount(export and export.datasets)),
        "Export event streams: " .. tostring(Util.TableCount(export and export.events)),
        "Estimated account data size: " .. tostring(db and Util.EstimateSize(db) or 0) .. " bytes",
    }, "\n")
end

function MainWindow:Refresh()
    if not self.frame then
        return
    end
    local authorized = GuildLock:IsAuthorized()
    self.denied:SetShown(not authorized)
    self.scroll:SetShown(authorized)
    for _, button in pairs(self.tabs) do
        button:SetShown(authorized)
    end

    if not authorized then
        if GuildLock.state == "verifying" then
            self.stateText:SetText(color(Constants.VERIFYING_MESSAGE, "ff00b4ff"))
            self.deniedMessage:SetText(Constants.VERIFYING_MESSAGE)
            self.urlBox:Hide()
            self.urlLabel:Hide()
            self.copyButton:Hide()
            self.copyHint:Hide()
        elseif GuildLock.reason == "verification_incomplete" or GuildLock.reason == "club_api_unavailable"
            or GuildLock.reason == "club_membership_missing" then
            self.stateText:SetText(color(Constants.UNVERIFIED_MESSAGE, "ffffc857"))
            self.deniedMessage:SetText(Constants.UNVERIFIED_MESSAGE)
            self.urlBox:Show()
            self.urlLabel:Show()
            self.copyButton:Show()
            self.copyHint:Show()
        else
            self.stateText:SetText(color("Not an approved Raining Embers member", "ffff6b6b"))
            self.deniedMessage:SetText(Constants.NONMEMBER_MESSAGE)
            self.urlBox:Show()
            self.urlLabel:Show()
            self.copyButton:Show()
            self.copyHint:Show()
        end
        return
    end

    self.stateText:SetText(color(GuildLock.state == "authorized_main" and L.AUTHORIZED_MAIN or L.AUTHORIZED_ALT, "ff52d273"))
    local export = Database:GetActiveExport(false)
    local text
    if self.activeTab == "coverage" then
        text = self:GetCoverageText(export)
    elseif self.activeTab == "sync" then
        text = self:GetSyncText(export)
    elseif self.activeTab == "privacy" then
        text = self:GetPrivacyText()
    elseif self.activeTab == "diagnostics" then
        text = self:GetDiagnosticsText(export)
    else
        text = self:GetOverviewText(export)
    end
    self.body:SetText(text)
    self.scrollContent:SetHeight(math.max(360, self.body:GetStringHeight() + 20))
    for key, button in pairs(self.tabs) do
        button:SetEnabled(key ~= self.activeTab)
    end
end

function MainWindow:Show()
    self:Create()
    if self.frame then
        self:Refresh()
        self.frame:Show()
    end
end

function MainWindow:Toggle()
    self:Create()
    if not self.frame then
        return
    end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Show()
    end
end

function MainWindow:Initialize()
    self:Create()
    GuildLock:OnChanged(function()
        self:Refresh()
    end)
    EmberSync:On("DATABASE_UPDATED", function()
        if self.frame and self.frame:IsShown() then
            self:Refresh()
        end
    end)
end

EmberSync:RegisterModule("MainWindow", MainWindow)
