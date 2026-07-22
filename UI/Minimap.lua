local _, EmberSync = ...

local Database = EmberSync.Database
local GuildLock = EmberSync.GuildLock

local MinimapButton = { button = nil }

local function setPosition(button, angle)
    local radians = math.rad(angle or 225)
    button:ClearAllPoints()
    button:SetPoint("CENTER", _G.Minimap, "CENTER", math.cos(radians) * 80, math.sin(radians) * 80)
end

function MinimapButton:Create()
    if self.button or type(_G.CreateFrame) ~= "function" or not _G.Minimap then
        return
    end
    local button = _G.CreateFrame("Button", "EmberSyncMinimapButton", _G.Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(24, 24)
    background:SetPoint("CENTER")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Elemental_Primal_Fire")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button:SetScript("OnClick", function()
        EmberSync.MainWindow:Toggle()
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(dragged)
            local mapX, mapY = _G.Minimap:GetCenter()
            local cursorX, cursorY = _G.GetCursorPosition()
            local scale = _G.UIParent:GetEffectiveScale()
            cursorX, cursorY = cursorX / scale, cursorY / scale
            local angle = math.deg(math.atan2(cursorY - mapY, cursorX - mapX))
            setPosition(dragged, angle)
            dragged.emberAngle = angle
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if GuildLock:IsAuthorized() then
            Database:SetSetting("minimap.angle", self.emberAngle or 225)
        end
    end)
    button:SetScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        _G.GameTooltip:AddLine("EmberSync", 0.941, 0.353, 0.122)
        _G.GameTooltip:AddLine("Open guild sync status", 1, 1, 1)
        _G.GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        _G.GameTooltip:Hide()
    end)
    setPosition(button, 225)
    self.button = button
end

function MinimapButton:Refresh()
    if not self.button then
        return
    end
    local angle = 225
    if GuildLock:IsAuthorized() and type(_G.EmberSyncDB) == "table"
        and _G.EmberSyncDB.settings and _G.EmberSyncDB.settings.minimap then
        angle = _G.EmberSyncDB.settings.minimap.angle or angle
        self.button:SetShown(not _G.EmberSyncDB.settings.minimap.hidden)
    else
        self.button:Show()
    end
    setPosition(self.button, angle)
end

function MinimapButton:Initialize()
    self:Create()
    GuildLock:OnChanged(function()
        self:Refresh()
    end)
end

EmberSync:RegisterModule("MinimapButton", MinimapButton)
