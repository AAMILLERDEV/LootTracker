local ADDON_NAME, LT = ...

local LOOT_TYPE_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

-- Only trust the last gathering cast target as a node name for this long.
local OBJECT_NAME_WINDOW = 15

local eventFrame = CreateFrame("Frame")

-- npcID -> name, learned from combat log deaths this session
local npcNames = {}

-- Most recent out-of-combat cast target ("Copper Vein", "Khorium Vein"),
-- used to name GameObject loot sources.
local lastObjectName, lastObjectTime = nil, 0

-- Snapshot of the open loot window: slot -> { itemID, sources }
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
    local unitType, _, _, _, _, id = strsplit("-", guid)
    id = tonumber(id)
    if not id then return end
    if unitType == "Creature" or unitType == "Vehicle" then
        return "npc", id
    elseif unitType == "GameObject" then
        return "node", id
    end
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

local function SnapshotLoot()
    wipe(pending)
    for slot = 1, GetNumLootItems() do
        if GetLootSlotType(slot) == LOOT_TYPE_ITEM then
            local link = GetLootSlotLink(slot)
            local itemID = link and tonumber(link:match("item:(%d+)"))
            local _, _, quantity = GetLootSlotInfo(slot)
            if itemID and quantity and quantity > 0 then
                local sources = {}
                -- Returns guid1, qty1, guid2, qty2, ... — with area loot a
                -- single slot can come from several corpses.
                local info = { GetLootSourceInfo(slot) }
                for i = 1, #info, 2 do
                    if ParseGUID(info[i]) then
                        sources[#sources + 1] = {
                            guid = info[i],
                            quantity = info[i + 1] or quantity,
                        }
                    end
                end
                if #sources > 0 then
                    pending[slot] = { itemID = itemID, sources = sources }
                end
            end
        end
    end
end

-- LOOT_SLOT_CLEARED only fires for the player's own loot window, so this
-- records exactly what entered our bags — never party members' loot.
local function RecordSlot(slot)
    local entry = pending[slot]
    if not entry then return end
    pending[slot] = nil

    local changed = false
    for _, source in ipairs(entry.sources) do
        local kind, id = ParseGUID(source.guid)
        if kind then
            local record = GetSourceRecord(kind, id)
            record.items[entry.itemID] = (record.items[entry.itemID] or 0) + source.quantity
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
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        SnapshotLoot()
    elseif event == "LOOT_SLOT_CLEARED" then
        RecordSlot(...)
    elseif event == "LOOT_CLOSED" then
        wipe(pending)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subevent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
        if subevent == "UNIT_DIED" and destName then
            local kind, id = ParseGUID(destGUID)
            if kind == "npc" and not npcNames[id] then
                npcNames[id] = destName
            end
        end
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
