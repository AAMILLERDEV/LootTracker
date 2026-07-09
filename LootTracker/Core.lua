local ADDON_NAME, LT = ...

local LOOT_TYPE_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1
local LOOT_TYPE_MONEY = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or 2

-- Convert a Blizzard localized format string into a Lua match pattern:
-- escape pattern magic characters, then map each %s / %d token — plain
-- or positional ("%1$s", used by e.g. German and French clients) — to
-- the caller's replacement.
local function FormatToPattern(fmt, sToken, dToken, anchored)
    local pattern = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub("%%%%%d%%%$s", sToken)
    pattern = pattern:gsub("%%%%%d%%%$d", dToken)
    pattern = pattern:gsub("%%%%s", sToken)
    pattern = pattern:gsub("%%%%d", dToken)
    if anchored then
        pattern = "^" .. pattern .. "$"
    end
    return pattern
end

-- Coin loot slots and money chat messages expose amounts only as
-- localized text ("1 Silver, 23 Copper").
local GOLD_PATTERN = GOLD_AMOUNT and FormatToPattern(GOLD_AMOUNT, "(.+)", "(%%d+)") or "(%d+) Gold"
local SILVER_PATTERN = SILVER_AMOUNT and FormatToPattern(SILVER_AMOUNT, "(.+)", "(%%d+)") or "(%d+) Silver"
local COPPER_PATTERN = COPPER_AMOUNT and FormatToPattern(COPPER_AMOUNT, "(.+)", "(%%d+)") or "(%d+) Copper"

local function CoinTextToCopper(text)
    if not text then return 0 end
    local gold = tonumber(text:match(GOLD_PATTERN)) or 0
    local silver = tonumber(text:match(SILVER_PATTERN)) or 0
    local copper = tonumber(text:match(COPPER_PATTERN)) or 0
    return gold * 10000 + silver * 100 + copper
end

-- Anchored patterns for the player's own loot-window chat messages
-- ("You receive loot: %s."). The PUSHED variants ("You receive item:")
-- are deliberately excluded: they also fire for quest rewards, mail,
-- and crafting, which must never confirm a queued loot slot.
local lootSelfPatterns = {}
local function AddLootPattern(fmt)
    if fmt then
        lootSelfPatterns[#lootSelfPatterns + 1] = FormatToPattern(fmt, "(.+)", "%%d+", true)
    end
end
AddLootPattern(LOOT_ITEM_SELF_MULTIPLE)
AddLootPattern(LOOT_ITEM_SELF)

-- Only trust the last gathering cast target as a node name for this long.
local OBJECT_NAME_WINDOW = 15

local eventFrame = CreateFrame("Frame")

-- npcID -> name, learned from combat log deaths this session
local npcNames = {}

-- Most recent out-of-combat cast target ("Copper Vein", "Khorium Vein"),
-- used to name GameObject loot sources.
local lastObjectName, lastObjectTime = nil, 0

-- Snapshot of the open loot window: slot -> { itemID, sources }. Must be
-- rebuilt on every LOOT_READY, not just the first: the game renumbers
-- remaining slots as items are cleared (slot 2 becomes slot 1, etc.) and
-- refires LOOT_READY each time, so a stale snapshot silently mismatches
-- slot indices to the wrong (or no) pending entry.
local pending = {}

-- Spawn GUIDs already credited this session, so re-opening the same
-- corpse can't bump a source's loot counter twice.
local seenGUIDs = {}

local function InitDB()
    LootTrackerDB = LootTrackerDB or {}
    LootTrackerDB.sources = LootTrackerDB.sources or {}
    LootTrackerDB.ui = LootTrackerDB.ui or {}
end

-- GUID layout: Type-0-server-instance-zone-ID-spawn. Creatures group as
-- NPCs, GameObjects as gathering nodes; every other type (Item GUIDs from
-- disenchanting/containers, Player, etc.) is deliberately untracked.
local function ParseGUID(guid)
    if not guid then return end
    local unitType, _, _, _, _, idText = strsplit("-", guid)
    local id = tonumber(idText)
    if not id then return end
    if unitType == "Creature" or unitType == "Vehicle" then
        return "npc", id
    elseif unitType == "GameObject" then
        return "node", id
    end
end

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function ResolveName(kind, id)
    if kind == "npc" then
        return npcNames[id]
    elseif kind == "node" and (GetTime() - lastObjectTime) <= OBJECT_NAME_WINDOW then
        return lastObjectName
    end
end

local function GetSourceRecord(kind, id)
    local key = kind .. ":" .. id
    local record = LootTrackerDB.sources[key]
    if not record then
        record = { kind = kind, id = id, loots = 0, items = {} }
        LootTrackerDB.sources[key] = record
    end
    if not record.name then
        record.name = ResolveName(kind, id)
    end
    return record
end

local function CacheNpcName(id, name)
    if not id or not name or name == "" or npcNames[id] then return end
    npcNames[id] = name
    -- Retroactively name a record created before the name was known.
    local sources = LootTrackerDB and LootTrackerDB.sources
    local record = sources and sources["npc:" .. id]
    if record and not record.name then
        record.name = name
        if LT.RefreshUI then
            LT.RefreshUI()
        end
    end
end

local function CacheGUIDName(guid, name)
    if not guid or not name then return end
    local kind, id = ParseGUID(guid)
    if kind == "npc" then
        CacheNpcName(id, name)
    end
end

local function CacheUnitName(unit)
    if UnitExists(unit) and not UnitIsPlayer(unit) then
        CacheGUIDName(UnitGUID(unit), UnitName(unit))
    end
end

-- Returns guid1, qty1, guid2, qty2, ... — with area loot a single slot
-- can come from several corpses. For money slots the quantities are
-- copper amounts.
local function CollectSlotSources(slot, fallbackQuantity)
    local sources, quantitySum = {}, 0
    local info = { GetLootSourceInfo(slot) }
    for i = 1, #info, 2 do
        if ParseGUID(info[i]) then
            local quantity = info[i + 1] or 0
            quantitySum = quantitySum + quantity
            sources[#sources + 1] = { guid = info[i], quantity = quantity }
        end
    end
    -- If the API reported no per-source quantities, credit the whole
    -- amount to the first source rather than losing it.
    if quantitySum == 0 and sources[1] then
        sources[1].quantity = fallbackQuantity
    end
    return sources
end

local function SnapshotLoot()
    wipe(pending)
    for slot = 1, GetNumLootItems() do
        local slotType = GetLootSlotType(slot)
        if slotType == LOOT_TYPE_ITEM then
            local itemID = ItemIDFromLink(GetLootSlotLink(slot))
            local _, _, quantity = GetLootSlotInfo(slot)
            if itemID and quantity and quantity > 0 then
                local sources = CollectSlotSources(slot, quantity)
                if #sources > 0 then
                    pending[slot] = { itemID = itemID, sources = sources }
                end
            end
        elseif slotType == LOOT_TYPE_MONEY then
            local _, coinText = GetLootSlotInfo(slot)
            local copper = CoinTextToCopper(coinText)
            if copper > 0 then
                local sources = CollectSlotSources(slot, copper)
                if #sources > 0 then
                    pending[slot] = { money = true, sources = sources }
                end
            end
        end
    end
end

-- With group/raid loot, LOOT_SLOT_CLEARED also fires when someone ELSE
-- takes an item out of the shared window, so a cleared slot alone does
-- not prove the loot reached our bags. Cleared slots wait here until a
-- self-loot chat message confirms them; unconfirmed entries expire.
local unconfirmed = {}
local CONFIRM_WINDOW = 5 -- seconds

local function PurgeUnconfirmed()
    local now = GetTime()
    for i = #unconfirmed, 1, -1 do
        if now - unconfirmed[i].time > CONFIRM_WINDOW then
            tremove(unconfirmed, i)
        end
    end
end

-- For money entries, copperReceived is the amount the chat message said
-- we received (group loot splits coins); nil means the full slot amount.
-- Credits are distributed across source corpses with cumulative rounding
-- so the recorded sum always equals the received amount exactly.
local function RecordEntry(entry, copperReceived)
    local scale = 1
    if entry.money and copperReceived then
        local total = 0
        for _, source in ipairs(entry.sources) do
            total = total + source.quantity
        end
        scale = total > 0 and copperReceived / total or 0
    end

    local changed = false
    local idealSum, creditedSum = 0, 0
    for _, source in ipairs(entry.sources) do
        local kind, id = ParseGUID(source.guid)
        if kind then
            local record = GetSourceRecord(kind, id)
            if entry.money then
                idealSum = idealSum + source.quantity * scale
                local credit = floor(idealSum + 0.5) - creditedSum
                creditedSum = creditedSum + credit
                record.copper = (record.copper or 0) + credit
            else
                record.items[entry.itemID] = (record.items[entry.itemID] or 0) + source.quantity
            end
            if not seenGUIDs[source.guid] then
                seenGUIDs[source.guid] = true
                record.loots = record.loots + 1
            end
            changed = true
        end
    end
    if changed and LT.RefreshUI then
        LT.RefreshUI()
    end
end

local function QueueSlot(slot)
    local entry = pending[slot]
    if not entry then return end
    pending[slot] = nil
    -- Solo, nobody else can take slots out of our loot window, so the
    -- cleared slot alone proves the loot reached our bags. Only group
    -- loot needs the chat-message confirmation step.
    if not IsInGroup() then
        RecordEntry(entry)
        return
    end
    entry.time = GetTime()
    unconfirmed[#unconfirmed + 1] = entry
    PurgeUnconfirmed()
end

-- Newest match first: our own confirmation arrives within a frame or
-- two of the slot clearing, while an older matching entry is more
-- likely a party member's never-confirmed pickup.
local function Confirm(match, copper)
    PurgeUnconfirmed()
    for i = #unconfirmed, 1, -1 do
        local entry = unconfirmed[i]
        if match(entry) then
            tremove(unconfirmed, i)
            RecordEntry(entry, copper)
            return
        end
    end
end

local function ConfirmItem(itemID)
    Confirm(function(entry)
        return not entry.money and entry.itemID == itemID
    end)
end

local function ConfirmMoney(copper)
    Confirm(function(entry)
        return entry.money
    end, copper)
end

local function OnLootMessage(message)
    for _, pattern in ipairs(lootSelfPatterns) do
        local link = message:match(pattern)
        if link then
            local itemID = ItemIDFromLink(link)
            if itemID then
                ConfirmItem(itemID)
            end
            return
        end
    end
end

function LT.GetSources()
    return LootTrackerDB and LootTrackerDB.sources
end

function LT.ResetData()
    if LootTrackerDB then
        wipe(LootTrackerDB.sources)
    end
    wipe(seenGUIDs)
    if LT.RefreshUI then
        LT.RefreshUI()
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_READY")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("CHAT_MSG_MONEY")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        SnapshotLoot()
    elseif event == "LOOT_SLOT_CLEARED" then
        QueueSlot(...)
    elseif event == "LOOT_CLOSED" then
        wipe(pending)
    elseif event == "CHAT_MSG_LOOT" then
        OnLootMessage(...)
    elseif event == "CHAT_MSG_MONEY" then
        local copper = CoinTextToCopper(...)
        if copper > 0 then
            ConfirmMoney(copper)
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Cheap one-compare bail for the vast majority of combat-log
        -- traffic; mouseover/target caching covers names of living mobs.
        local _, subevent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
        if subevent == "UNIT_DIED" then
            ---@diagnostic disable-next-line: need-check-nil
            CacheGUIDName(destGUID, destName)
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CacheUnitName("mouseover")
    elseif event == "PLAYER_TARGET_CHANGED" then
        CacheUnitName("target")
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, target = ...
        -- Gathering only happens out of combat; the guard keeps hostile
        -- cast targets from being mistaken for node names.
        if target and target ~= "" and not UnitAffectingCombat("player") then
            lastObjectName, lastObjectTime = target, GetTime()
        end
    elseif event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            InitDB()
            if LT.ApplyLayout then
                LT.ApplyLayout()
            end
            eventFrame:UnregisterEvent("ADDON_LOADED")
        end
    end
end)
