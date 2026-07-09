local _, LT = ...

-- Modern-namespace versions with fallbacks for older classic clients
---@diagnostic disable-next-line: deprecated
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
---@diagnostic disable-next-line: deprecated
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
---@diagnostic disable-next-line: deprecated
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
---@diagnostic disable-next-line: deprecated
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded

local AH_COLOR = "|cff80c0ff"

local FALLBACK_ICON = 134400 -- INV_Misc_QuestionMark

local ROW_HEIGHT = 16
local FRAME_WIDTH, FRAME_HEIGHT = 420, 500
local MIN_WIDTH, MIN_HEIGHT = 260, 270

local SaveLayout          -- defined below; captured by drag/resize handlers
local Refresh             -- defined below; needed by row/button click handlers
local collapseAllButton   -- created below; label is updated inside Refresh
local viewToggleButton    -- created below; label is updated inside Refresh
local viewMode = "grouped" -- "grouped" or "timeline"; persisted in ui.viewMode
local showVendor = true    -- persisted in ui.showVendor
local showAH = true        -- persisted in ui.showAH
local showDateTime = true  -- persisted in ui.showDateTime; timeline view only

-- Grand-total breakdown from the last Refresh(), read by totalHitbox's
-- tooltip (built lazily on hover instead of recomputed every refresh).
local lastVendorTotal, lastAhTotal, lastItemCount, lastAhShown = 0, 0, 0, false

local frame = CreateFrame("Frame", "LootTrackerFrame", UIParent, "BackdropTemplate")
frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
frame:SetMovable(true)
frame:SetResizable(true)

-- Cap the window at roughly half the screen (60% x 80% ≈ half the area).
-- Computed fresh wherever it's needed (ApplyLayout, the manual resize
-- drag below) instead of cached via SetResizeBounds, so it's always
-- current with no separate refresh-on-event bookkeeping required.
local function MaxFrameSize()
    return UIParent:GetWidth() * 0.6, UIParent:GetHeight() * 0.8
end

local function Clamp(value, lo, hi)
    return math.min(math.max(value, lo), hi)
end

frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveLayout()
end)
frame:SetClampedToScreen(true)
frame:SetFrameStrata("MEDIUM")
frame:Hide()

tinsert(UISpecialFrames, "LootTrackerFrame")

-- Shares the top row with the close button, above the Collapse All /
-- view toggle row.
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -16)
title:SetText("LootTrackerTBC")

local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -6, -6)

-- Mirrors the close button on the opposite corner; opens the same menu
-- as right-clicking the launcher icon (see OpenOptionsMenu below).
local optionsButton = CreateFrame("Button", nil, frame)
optionsButton:SetSize(20, 20)
optionsButton:SetPoint("TOPLEFT", 14, -14)
optionsButton:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
optionsButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
optionsButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("LootTrackerTBC Options")
    GameTooltip:Show()
end)
optionsButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local sizeGrip = CreateFrame("Button", nil, frame)
sizeGrip:SetSize(16, 16)
sizeGrip:SetPoint("BOTTOMRIGHT", -8, 8)
sizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
sizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
sizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

-- Resized by hand — tracking raw cursor movement and calling SetSize
-- directly — instead of Frame:StartSizing/StopMovingOrSizing. That native
-- API tracks the cursor independently of the mouse button and needs the
-- frame corner-anchored to behave predictably; on this window (anchored
-- via SetPoint("CENTER")) it kept producing a visible size jump,
-- specifically after other UI interactions (e.g. the options menu) moved
-- the cursor before a later resize drag, that survived multiple attempts
-- to patch around it. Doing it ourselves removes that opaque state
-- entirely: the only state involved is the plain Lua locals below.
local CLICK_DRAG_THRESHOLD = 3 -- screen pixels
local resizeScale, resizeStartCursorX, resizeStartCursorY, resizeStartWidth, resizeStartHeight
local sizing = false

local function StopSizing()
    if sizing then
        SaveLayout()
    end
    sizing = false
    sizeGrip:SetScript("OnUpdate", nil)
    resizeStartCursorX, resizeStartCursorY = nil, nil
end

sizeGrip:SetScript("OnMouseDown", function(self)
    resizeScale = frame:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    resizeStartCursorX, resizeStartCursorY = cursorX / resizeScale, cursorY / resizeScale
    resizeStartWidth, resizeStartHeight = frame:GetWidth(), frame:GetHeight()
    sizing = false
    -- Sizing must end when the mouse button does, even if the release
    -- lands off the grip (easy after overshooting a size bound) — this
    -- poll catches that regardless of where the cursor ends up.
    self:SetScript("OnUpdate", function()
        if not IsMouseButtonDown("LeftButton") then
            StopSizing()
            return
        end
        local cursorX2, cursorY2 = GetCursorPosition()
        cursorX2, cursorY2 = cursorX2 / resizeScale, cursorY2 / resizeScale
        local dx = cursorX2 - resizeStartCursorX
        local dy = resizeStartCursorY - cursorY2 -- screen Y grows upward; height grows as the cursor moves down
        if not sizing then
            -- Wait for real drag intent before touching the frame at
            -- all, so a plain click never moves the window, not even
            -- momentarily.
            if abs(dx) <= CLICK_DRAG_THRESHOLD and abs(dy) <= CLICK_DRAG_THRESHOLD then
                return
            end
            sizing = true
            -- Re-anchor to the current TOPLEFT corner so the growth
            -- below expands away from it, matching "drag the
            -- bottom-right grip" regardless of the window's actual
            -- anchor point.
            local left, top = frame:GetLeft(), frame:GetTop()
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
        local maxW, maxH = MaxFrameSize()
        frame:SetSize(
            Clamp(resizeStartWidth + dx, MIN_WIDTH, maxW),
            Clamp(resizeStartHeight + dy, MIN_HEIGHT, maxH))
    end)
end)
sizeGrip:SetScript("OnMouseUp", StopSizing)
-- If the window closes mid-resize (Esc, toggling it off, etc.) with the
-- mouse still down, sizeGrip's OnUpdate stops firing along with it (a
-- hidden frame's OnUpdate doesn't run), so StopSizing would otherwise
-- never get called and the drag stays "armed" for next time.
frame:HookScript("OnHide", StopSizing)

-- Just "Total: X" at a glance; the vendor/AH breakdown (when those
-- toggles are on) lives in a tooltip instead of inline, so this stays
-- short regardless of window width. See totalHitbox below.
local totalText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
totalText:SetPoint("BOTTOM", 0, 18)

local totalHitbox = CreateFrame("Frame", nil, frame)
totalHitbox:SetAllPoints(totalText)
totalHitbox:EnableMouse(true)
totalHitbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Session Total")
    local addedLine = false
    if showVendor then
        GameTooltip:AddDoubleLine("Vendor value", GetCoinTextureString(lastVendorTotal), 1, 1, 1, 1, 1, 1)
        addedLine = true
    end
    if lastAhShown then
        local known = lastItemCount == 0 or lastAhTotal > 0
        GameTooltip:AddDoubleLine("AH value", known and GetCoinTextureString(lastAhTotal) or "—", 1, 1, 1, 1, 1, 1)
        addedLine = true
    end
    if not addedLine then
        GameTooltip:AddLine("Enable vendor/AH value in Options for a breakdown.", 0.5, 0.5, 0.5, true)
    end
    GameTooltip:Show()
end)
totalHitbox:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local scrollFrame = CreateFrame("ScrollFrame", "LootTrackerScrollFrame", frame, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 16, -66)
scrollFrame:SetPoint("BOTTOMRIGHT", -36, 44)

local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(FRAME_WIDTH - 52, 1)
scrollFrame:SetScrollChild(content)
scrollFrame:SetScript("OnSizeChanged", function(_, width)
    content:SetWidth(width)
end)

-- Rows are buttons so group headers can be clicked to collapse/expand.
-- A header row carries its DB record in row.record; item rows leave it
-- nil and have mouse input disabled.
local rows = {}
local function AcquireRow(index)
    local row = rows[index]
    if not row then
        row = CreateFrame("Button", nil, content)
        row:SetHeight(ROW_HEIGHT)
        local offsetY = -(index - 1) * ROW_HEIGHT
        row:SetPoint("TOPLEFT", 0, offsetY)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, offsetY)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetAllPoints()
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if self.record then
                self.record.collapsed = not self.record.collapsed
                Refresh()
            end
        end)
        rows[index] = row
    end
    row.record = nil
    row:EnableMouse(false)
    row.text:SetJustifyH("LEFT")
    row:Show()
    return row
end

local function ColoredItemName(itemID)
    local name, _, quality = GetItemInfo(itemID)
    if not name then
        return "item:" .. itemID -- uncached; a refresh fires once the server responds
    end
    local color = ITEM_QUALITY_COLORS[quality or 1]
    return (color and color.hex or "|cffffffff") .. name .. "|r"
end

local function ItemSellPrice(itemID)
    local sellPrice = select(11, GetItemInfo(itemID))
    return sellPrice or 0
end

-- nil means "Auctionator has no price for this item", not zero.
local function ItemAuctionValue(itemID, count)
    local unitPrice = LT.GetAuctionValue and LT.GetAuctionValue(itemID)
    return unitPrice and (unitPrice * count) or nil
end

-- Turn the DB into a sorted display list: sources by total value, items
-- within a source likewise. Currency is never folded into vendorTotal or
-- ahTotal (those are pure per-item sums, for the raw "Show vendor/AH
-- value" breakdowns) — it only feeds valueTotal, LootTrackerTBC's best
-- estimate of what a source is actually worth: AH price per item where
-- Auctionator has one, vendor price as the fallback, plus currency.
-- itemCount lets the renderer tell "nothing sold on the AH yet"
-- (itemCount > 0, ahTotal == 0) apart from "no items at all".
local function BuildGroups()
    local groups = {}
    local sources = LT.GetSources and LT.GetSources()
    if not sources then return groups end

    for _, record in pairs(sources) do
        local items, copper = {}, record.copper or 0
        local vendorTotal, ahTotal, valueTotal, itemCount = 0, 0, copper, 0
        for itemID, count in pairs(record.items) do
            local value = ItemSellPrice(itemID) * count
            local auctionValue = ItemAuctionValue(itemID, count)
            local bestValue = auctionValue or value
            vendorTotal = vendorTotal + value
            valueTotal = valueTotal + bestValue
            itemCount = itemCount + 1
            if auctionValue then
                ahTotal = ahTotal + auctionValue
            end
            items[#items + 1] = {
                itemID = itemID, count = count, value = value,
                auctionValue = auctionValue, bestValue = bestValue,
            }
        end
        sort(items, function(a, b)
            if a.bestValue ~= b.bestValue then return a.bestValue > b.bestValue end
            return a.itemID < b.itemID
        end)
        groups[#groups + 1] = {
            record = record, items = items, copper = copper,
            vendorTotal = vendorTotal, ahTotal = ahTotal,
            valueTotal = valueTotal, itemCount = itemCount,
        }
    end

    sort(groups, function(a, b)
        if a.valueTotal ~= b.valueTotal then return a.valueTotal > b.valueTotal end
        return (a.record.name or "") < (b.record.name or "")
    end)
    return groups
end

local function SourceLabel(record)
    local name = record.name
    if not name then
        name = (record.kind == "node" and "Object #" or "NPC #") .. record.id
    end
    if record.kind == "node" then
        name = name .. " |cff80c0ff(node)|r"
    end
    return name
end

-- Renders the "grouped by source" view; returns the row count used.
local function RenderGrouped(groups)
    local rowIndex = 0
    local anyExpanded = false
    local ahShown = showAH and IsAddOnLoaded("Auctionator")

    for _, group in ipairs(groups) do
        local record = group.record
        if not record.collapsed then
            anyExpanded = true
        end

        rowIndex = rowIndex + 1
        local header = AcquireRow(rowIndex)
        local indicator = record.collapsed
            and "|TInterface\\Buttons\\UI-PlusButton-Up:16|t"
            or "|TInterface\\Buttons\\UI-MinusButton-Up:16|t"
        local headerText = ("%s |cffffd100%s|r  x%d looted — %s"):format(
            indicator, SourceLabel(record), record.loots, GetCoinTextureString(group.valueTotal))
        if showVendor then
            headerText = headerText .. ("  |cff808080Vendor:|r %s"):format(GetCoinTextureString(group.vendorTotal))
        end
        if ahShown then
            local known = group.itemCount == 0 or group.ahTotal > 0
            headerText = headerText .. ("  %sAH: %s|r"):format(
                AH_COLOR, known and GetCoinTextureString(group.ahTotal) or "—")
        end
        header.text:SetText(headerText)
        header.record = record
        header:EnableMouse(true)

        if not record.collapsed then
            if group.copper > 0 then
                rowIndex = rowIndex + 1
                AcquireRow(rowIndex).text:SetText(
                    "    |TInterface\\Icons\\INV_Misc_Coin_01:14|t Currency — "
                    .. GetCoinTextureString(group.copper))
            end
            for _, item in ipairs(group.items) do
                rowIndex = rowIndex + 1
                local icon = GetItemIcon(item.itemID) or FALLBACK_ICON
                local itemText = ("    |T%d:14|t %s x%d"):format(
                    icon, ColoredItemName(item.itemID), item.count)
                if showVendor then
                    itemText = itemText .. " — " .. GetCoinTextureString(item.value)
                end
                if ahShown and item.auctionValue then
                    itemText = itemText .. ("  %sAH: %s|r"):format(AH_COLOR, GetCoinTextureString(item.auctionValue))
                end
                AcquireRow(rowIndex).text:SetText(itemText)
            end
        end
    end

    if collapseAllButton then
        collapseAllButton:Show()
        if #groups > 0 then
            collapseAllButton:Enable()
            collapseAllButton:SetText(anyExpanded and "Collapse All" or "Expand All")
        else
            collapseAllButton:Disable()
            collapseAllButton:SetText("Collapse All")
        end
    end
    return rowIndex
end

-- Renders the flat chronological log, newest entry first; returns the
-- row count used. Names resolve live from the current source records,
-- so a name learned after the fact (see Core's CacheNpcName) shows up
-- correctly even for older log entries.
local function RenderTimeline()
    if collapseAllButton then
        collapseAllButton:Hide()
    end

    local log = LT.GetLog and LT.GetLog()
    local sources = LT.GetSources and LT.GetSources()
    if not log then return 0 end

    local ahShown = showAH and IsAddOnLoaded("Auctionator")
    local rowIndex = 0
    for i = #log, 1, -1 do
        local entry = log[i]
        local record = sources and sources[entry.kind .. ":" .. entry.id]
        local label = SourceLabel(record or { kind = entry.kind, id = entry.id })

        -- Source name gets its own row (with the timestamp, if shown)
        -- above the item/currency row, instead of a "from X" suffix
        -- tacked onto the end — keeps the detail row from stretching
        -- wide with a long item name plus a long source name.
        rowIndex = rowIndex + 1
        local headerText = ("|cffffd100%s|r"):format(label)
        if showDateTime then
            headerText = ("|cff808080%s|r  %s"):format(date("%H:%M:%S", entry.time), headerText)
        end
        AcquireRow(rowIndex).text:SetText(headerText)

        rowIndex = rowIndex + 1
        local row = AcquireRow(rowIndex)
        if entry.copper then
            row.text:SetText(("    |TInterface\\Icons\\INV_Misc_Coin_01:14|t Currency — %s"):format(
                GetCoinTextureString(entry.copper)))
        else
            local icon = GetItemIcon(entry.itemID) or FALLBACK_ICON
            local text = ("    |T%d:14|t %s x%d"):format(icon, ColoredItemName(entry.itemID), entry.count)
            if showVendor then
                local value = ItemSellPrice(entry.itemID) * entry.count
                text = text .. " — " .. GetCoinTextureString(value)
            end
            if ahShown then
                local auctionValue = ItemAuctionValue(entry.itemID, entry.count)
                if auctionValue then
                    text = text .. ("  %sAH: %s|r"):format(AH_COLOR, GetCoinTextureString(auctionValue))
                end
            end
            row.text:SetText(text)
        end
    end
    return rowIndex
end

function Refresh()
    if viewToggleButton then
        viewToggleButton:SetText(viewMode == "timeline" and "Grouped View" or "Timeline View")
        viewToggleButton:ClearAllPoints()
        if viewMode == "timeline" then
            -- Collapse All is hidden in this view; center the toggle
            -- alone on the row instead of leaving it offset to one side.
            viewToggleButton:SetPoint("TOP", frame, "TOP", 0, -42)
        else
            viewToggleButton:SetPoint("TOPLEFT", collapseAllButton, "TOPRIGHT", 6, 0)
        end
    end

    local groups = BuildGroups()
    local grandVendorTotal, grandAhTotal, grandValueTotal, grandItemCount = 0, 0, 0, 0
    for _, group in ipairs(groups) do
        grandVendorTotal = grandVendorTotal + group.vendorTotal
        grandAhTotal = grandAhTotal + group.ahTotal
        grandValueTotal = grandValueTotal + group.valueTotal
        grandItemCount = grandItemCount + group.itemCount
    end

    local rowIndex = (viewMode == "timeline") and RenderTimeline() or RenderGrouped(groups)

    if rowIndex == 0 then
        rowIndex = 1
        local emptyRow = AcquireRow(1)
        emptyRow.text:SetJustifyH("CENTER")
        emptyRow.text:SetText(viewMode == "timeline"
            and "Nothing logged yet. Go loot something!"
            or "Nothing tracked yet. Go loot something!")
    end

    for i = rowIndex + 1, #rows do
        rows[i]:Hide()
    end

    content:SetHeight(rowIndex * ROW_HEIGHT)
    lastVendorTotal, lastAhTotal, lastItemCount = grandVendorTotal, grandAhTotal, grandItemCount
    lastAhShown = showAH and IsAddOnLoaded("Auctionator")
    totalText:SetText("Total: " .. GetCoinTextureString(grandValueTotal))
end

-- Collapse All + view toggle share their own row, centered on the frame
-- (anchored from "TOP", which is top-CENTER, so this stays centered at
-- any window width) below the close button's row so widening either
-- button never risks overlapping it.
collapseAllButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
collapseAllButton:SetSize(100, 20)
collapseAllButton:SetPoint("TOPLEFT", frame, "TOP", -118, -42)
collapseAllButton:SetText("Collapse All")
collapseAllButton:Hide()
collapseAllButton:SetScript("OnClick", function()
    local sources = LT.GetSources and LT.GetSources()
    if not sources then return end
    local collapse = false
    for _, record in pairs(sources) do
        if not record.collapsed then
            collapse = true
            break
        end
    end
    for _, record in pairs(sources) do
        record.collapsed = collapse
    end
    Refresh()
end)

viewToggleButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
viewToggleButton:SetSize(130, 20)
viewToggleButton:SetPoint("TOPLEFT", collapseAllButton, "TOPRIGHT", 6, 0)
viewToggleButton:SetScript("OnClick", function()
    viewMode = (viewMode == "timeline") and "grouped" or "timeline"
    SaveLayout()
    Refresh()
end)

local refreshQueued = false
function LT.RefreshUI()
    if refreshQueued or not frame:IsShown() then return end
    refreshQueued = true
    C_Timer.After(0.1, function()
        refreshQueued = false
        if frame:IsShown() then
            Refresh()
        end
    end)
end

frame:SetScript("OnShow", Refresh)

-- Uncached items resolve asynchronously; redraw when their data arrives.
local infoWatcher = CreateFrame("Frame")
infoWatcher:RegisterEvent("GET_ITEM_INFO_RECEIVED")
infoWatcher:SetScript("OnEvent", function()
    LT.RefreshUI()
end)

local function ToggleWindow()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

-- Floating bag-icon launcher; drag to reposition, click to toggle.
local launcher = CreateFrame("Button", "LootTrackerLauncher", UIParent)
launcher:SetSize(32, 32)
launcher:SetPoint("CENTER", UIParent, "CENTER", 0, 260)
launcher:SetMovable(true)
launcher:SetClampedToScreen(true)
launcher:SetFrameStrata("MEDIUM")
launcher:RegisterForDrag("LeftButton")

local launcherIcon = launcher:CreateTexture(nil, "ARTWORK")
launcherIcon:SetAllPoints()
launcherIcon:SetTexture("Interface\\AddOns\\LootTrackerTBC\\Media\\LootTracker-icon.png")
launcher:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

-- Pinning removes the frame from UISpecialFrames so Esc no longer
-- closes it; CloseSpecialWindows re-reads the list on every press.
local function IsPinned()
    local ui = LootTrackerDB and LootTrackerDB.ui
    return (ui and ui.pinned) or false
end

local function SetPinned(pinned)
    local ui = LootTrackerDB and LootTrackerDB.ui
    if ui then
        ui.pinned = pinned or nil
    end
    local index
    for i, name in ipairs(UISpecialFrames) do
        if name == "LootTrackerFrame" then
            index = i
            break
        end
    end
    if pinned and index then
        tremove(UISpecialFrames, index)
    elseif not pinned and not index then
        tinsert(UISpecialFrames, "LootTrackerFrame")
    end
end

local function ResetWindowSize()
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    SaveLayout()
end

local function ResetWindowPosition()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    SaveLayout()
end

-- Rendered as plain buttons (not menu checkboxes) so every entry
-- left-aligns identically; the checkmark is appended to the label instead.
local function CheckableLabel(label, checked)
    if checked then
        label = label .. " |TInterface\\Buttons\\UI-CheckBox-Check:14|t"
    end
    return label
end

local function PinnedLabel()
    return CheckableLabel("Pin window (ignore Esc)", IsPinned())
end

local function TogglePinned()
    SetPinned(not IsPinned())
end

local function ToggleShowVendor()
    showVendor = not showVendor
    SaveLayout()
    Refresh()
end

local function ToggleShowAH()
    showAH = not showAH
    SaveLayout()
    Refresh()
end

local function ToggleShowDateTime()
    showDateTime = not showDateTime
    SaveLayout()
    Refresh()
end

-- Shared by the launcher icon's right-click menu and the in-window
-- options button, so both stay in sync with a single definition.
local optionsMenu -- fallback dropdown host, created on demand
local function OpenOptionsMenu(owner)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
            rootDescription:CreateTitle("LootTrackerTBC")
            rootDescription:CreateButton(PinnedLabel(), TogglePinned)
            rootDescription:CreateButton("Reset window size", ResetWindowSize)
            rootDescription:CreateButton("Reset window position", ResetWindowPosition)
            rootDescription:CreateButton(CheckableLabel("Show vendor value", showVendor), ToggleShowVendor)
            rootDescription:CreateButton(CheckableLabel("Show AH value", showAH), ToggleShowAH)
            rootDescription:CreateButton(CheckableLabel("Show date/time", showDateTime), ToggleShowDateTime)
            rootDescription:CreateButton("Reset all data", function()
                StaticPopup_Show("LOOTTRACKER_RESET")
            end)
        end)
    elseif EasyMenu then
        if not optionsMenu then
            optionsMenu = CreateFrame("Frame", "LootTrackerOptionsMenu", UIParent, "UIDropDownMenuTemplate")
        end
        EasyMenu({
            { text = "LootTrackerTBC", isTitle = true, notCheckable = true },
            { text = PinnedLabel(), notCheckable = true, func = TogglePinned },
            { text = "Reset window size", notCheckable = true, func = ResetWindowSize },
            { text = "Reset window position", notCheckable = true, func = ResetWindowPosition },
            { text = CheckableLabel("Show vendor value", showVendor), notCheckable = true, func = ToggleShowVendor },
            { text = CheckableLabel("Show AH value", showAH), notCheckable = true, func = ToggleShowAH },
            { text = CheckableLabel("Show date/time", showDateTime), notCheckable = true, func = ToggleShowDateTime },
            { text = "Reset all data", notCheckable = true, func = function()
                StaticPopup_Show("LOOTTRACKER_RESET")
            end },
        }, optionsMenu, "cursor", 0, 0, "MENU")
    end
end

optionsButton:SetScript("OnClick", function(self)
    OpenOptionsMenu(self)
end)

launcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
launcher:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        OpenOptionsMenu(self)
    else
        ToggleWindow()
    end
end)
launcher:SetScript("OnDragStart", launcher.StartMoving)
launcher:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveLayout()
end)
launcher:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("LootTrackerTBC")
    GameTooltip:AddLine("Click to toggle the loot window.", 1, 1, 1)
    GameTooltip:AddLine("Right-click for options.", 1, 1, 1)
    GameTooltip:AddLine("Drag to move this button.", 1, 1, 1)
    GameTooltip:Show()
end)
launcher:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

function SaveLayout()
    local ui = LootTrackerDB and LootTrackerDB.ui
    if not ui then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    ui.point, ui.relPoint, ui.x, ui.y = point, relPoint, x, y
    ui.width, ui.height = frame:GetWidth(), frame:GetHeight()
    local bPoint, _, bRelPoint, bx, by = launcher:GetPoint()
    ui.btnPoint, ui.btnRelPoint, ui.btnX, ui.btnY = bPoint, bRelPoint, bx, by
    ui.viewMode = viewMode
    ui.showVendor = showVendor
    ui.showAH = showAH
    ui.showDateTime = showDateTime
end

-- Called from Core once saved variables are available.
function LT.ApplyLayout()
    local ui = LootTrackerDB and LootTrackerDB.ui
    if not ui then return end
    if ui.point then
        frame:ClearAllPoints()
        frame:SetPoint(ui.point, UIParent, ui.relPoint or ui.point, ui.x or 0, ui.y or 0)
    end
    if ui.width and ui.height then
        local maxW, maxH = MaxFrameSize()
        frame:SetSize(Clamp(ui.width, MIN_WIDTH, maxW), Clamp(ui.height, MIN_HEIGHT, maxH))
    end
    if ui.btnPoint then
        launcher:ClearAllPoints()
        launcher:SetPoint(ui.btnPoint, UIParent, ui.btnRelPoint or ui.btnPoint, ui.btnX or 0, ui.btnY or 0)
    end
    if ui.pinned then
        SetPinned(true)
    end
    if ui.viewMode == "timeline" or ui.viewMode == "grouped" then
        viewMode = ui.viewMode
    end
    if ui.showVendor ~= nil then showVendor = ui.showVendor end
    if ui.showAH ~= nil then showAH = ui.showAH end
    if ui.showDateTime ~= nil then showDateTime = ui.showDateTime end
end

StaticPopupDialogs["LOOTTRACKER_RESET"] = {
    text = "Reset all LootTrackerTBC data?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        LT.ResetData()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_LOOTTRACKER1 = "/loottracker"
SLASH_LOOTTRACKER2 = "/lt"
SlashCmdList.LOOTTRACKER = function(msg)
    msg = strlower(strtrim(msg or ""))
    if msg == "reset" then
        StaticPopup_Show("LOOTTRACKER_RESET")
    else
        ToggleWindow()
    end
end
