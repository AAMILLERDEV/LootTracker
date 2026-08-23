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

-- Enchanting's "Disenchant" spell has several rank IDs in TBC-era clients
-- (13262/13920/13921/13922 as learned/upgraded); GetSpellInfo returns the
-- same localized base name for all of them regardless of rank, so casts
-- are matched by name instead of enumerating every rank ID.
local DISENCHANT_SPELL_NAME = GetSpellInfo(13262)
-- A disenchant loot window's own GetLootSourceInfo GUID ("Item-<n>-0-<id>")
-- is USELESS for identifying what was disenchanted: confirmed via a live
-- repro that <n> is some internal quality/ilvl loot-bracket id, not the
-- original item's itemID (disenchant tables are shared across many items
-- of the same bracket) — so there is nothing to parse out of it. Instead,
-- the target item is captured off ITEM_LOCKED at cast time (see
-- pendingDisenchantItemID below) and carried into the loot window via
-- lastDisenchantItemID once the cast is confirmed.
-- Only treat a loot window as a disenchant result if it opens this soon
-- after the cast completes; otherwise it's a coincidental unrelated loot
-- window (e.g. a corpse) and must NOT be misattributed.
local DISENCHANT_WINDOW = 3

-- Diagnostics for the "loot sometimes goes untracked" class of report.
-- Prints only at the exact points where a loot event could vanish
-- silently, so a repro tells us which path is actually firing instead
-- of guessing. Off by default; toggle at runtime with /lt debug.
local DEBUG = false
local function Debug(msg)
    if DEBUG then
        print("|cff33ff99LootTrackerTBC debug:|r " .. msg)
    end
end

function LT.SetDebug(enabled)
    DEBUG = enabled and true or false
    print(("|cff33ff99LootTrackerTBC:|r debug logging %s"):format(DEBUG and "ON" or "OFF"))
end

function LT.IsDebug()
    return DEBUG
end

local eventFrame = CreateFrame("Frame")

-- npcID -> name, learned from combat log deaths this session
local npcNames = {}

-- Most recent out-of-combat cast target ("Copper Vein", "Khorium Vein"),
-- used to name GameObject loot sources.
local lastObjectName, lastObjectTime = nil, 0

-- GetTime() of the player's last completed Disenchant cast, and the
-- itemID it targeted. The itemID starts nil at cast-success time and is
-- filled in retroactively by the ITEM_LOCKED that follows (confirmed via
-- a live repro that the item only locks AFTER the cast succeeds, as a
-- side effect of being consumed — not picked as a target beforehand).
-- See DISENCHANT_WINDOW.
local lastDisenchantTime = 0
local lastDisenchantItemID = nil
local function IsRecentDisenchant()
    return (GetTime() - lastDisenchantTime) <= DISENCHANT_WINDOW
end

---@diagnostic disable-next-line: deprecated
local GetContainerItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID

-- Snapshot of the open loot window: slot -> { itemID, sources }. Must be
-- rebuilt on every LOOT_READY, not just the first: the game renumbers
-- remaining slots as items are cleared (slot 2 becomes slot 1, etc.) and
-- refires LOOT_READY each time, so a stale snapshot silently mismatches
-- slot indices to the wrong (or no) pending entry.
local pending = {}

-- Spawn GUIDs already credited this session, so re-opening the same
-- corpse can't bump a source's loot counter twice. Deliberately NOT
-- reset by a session split (LT.StartNewSession) — its job is just to
-- stop a still-open corpse from being double-counted, unrelated to the
-- user-facing "farming session" boundaries in LootTrackerDB.sessions.
local seenGUIDs = {}

local function InitDB()
    LootTrackerDB = LootTrackerDB or {}
    LootTrackerDB.ui = LootTrackerDB.ui or {}
    LootTrackerDB.filters = LootTrackerDB.filters or {}
    LootTrackerDB.filters.hiddenItems = LootTrackerDB.filters.hiddenItems or {}

    if not LootTrackerDB.sessions then
        -- Fresh install, or upgrading from the pre-session schema where
        -- sources/log lived at the DB root — migrate that data into the
        -- first session instead of discarding it.
        LootTrackerDB.sessions = {
            {
                name = nil,
                startTime = time(),
                sources = LootTrackerDB.sources or {},
                log = LootTrackerDB.log or {},
            },
        }
        LootTrackerDB.sources = nil
        LootTrackerDB.log = nil
    end
end

-- The session currently being written to by live loot tracking — always
-- the last entry in LootTrackerDB.sessions. Distinct from whichever
-- session the UI happens to be *viewing* (see UI.lua's viewedSessionIndex),
-- so looking at a past session doesn't interrupt live tracking.
local function GetActiveSession()
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    return sessions and sessions[#sessions]
end

-- Chronological loot log, capped so a long session can't grow it forever.
-- Names aren't stored here — the timeline view resolves them live from
-- the session's sources, so a name learned later (see CacheNpcName)
-- automatically applies to earlier log entries too.
local MAX_LOG_ENTRIES = 500

local function LogEvent(kind, id, itemID, count, copper)
    local session = GetActiveSession()
    if not session then return end
    local log = session.log
    log[#log + 1] = {
        time = time(),
        kind = kind,
        id = id,
        itemID = itemID,
        count = count,
        copper = copper,
    }
    if #log > MAX_LOG_ENTRIES then
        tremove(log, 1)
    end
end

-- Real GUID layout: Type-0-server-instance-zone-ID-spawn. Creatures group
-- as NPCs, GameObjects as gathering nodes; every other real type (Item —
-- see the DISENCHANT_WINDOW comment on why that one's useless, Player,
-- etc.) is deliberately untracked. "Disenchant-<itemID>" is NOT a real
-- WoW GUID — it's a sentinel CollectSlotSources synthesizes for disenchant
-- loot windows once the target item is known by other means, recognized
-- here so the rest of the crediting pipeline (RecordEntry, GetSourceRecord)
-- can treat it exactly like any other source without special-casing it.
local function ParseGUID(guid)
    if not guid then return end
    local disenchantItemID = guid:match("^Disenchant%-(%d+)$")
    if disenchantItemID then
        return "disenchant", tonumber(disenchantItemID)
    end
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
    local session = GetActiveSession()
    if not session then return end
    local key = kind .. ":" .. id
    local record = session.sources[key]
    if not record then
        record = { kind = kind, id = id, loots = 0, items = {} }
        session.sources[key] = record
    end
    if not record.name then
        record.name = ResolveName(kind, id)
    end
    return record
end

local function CacheNpcName(id, name)
    if not id or not name or name == "" or npcNames[id] then return end
    npcNames[id] = name
    -- Retroactively name a record created before the name was known, in
    -- every session (not just the active one) — a name learned now could
    -- just as easily belong to a record from an earlier, closed session.
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    if not sessions then return end
    local changed = false
    for _, session in ipairs(sessions) do
        local record = session.sources["npc:" .. id]
        if record and not record.name then
            record.name = name
            changed = true
        end
    end
    if changed and LT.RefreshUI then
        LT.RefreshUI()
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
    if DEBUG and #info == 0 then
        Debug(("slot %d: GetLootSourceInfo returned nothing at all"):format(slot))
    end
    -- Disenchant loot windows are sourced from an "Item-..." GUID (or
    -- sometimes nothing at all) that can't identify the disenchanted item
    -- (see the DISENCHANT_WINDOW comment) — attribute the whole slot
    -- directly to the item captured off ITEM_LOCKED instead. Gated on the
    -- raw source ALSO looking like "Item-..." or being empty (not just the
    -- time window) so a genuine Creature/GameObject loot window that opens
    -- while the disenchant timer happens to still be running is never
    -- misattributed.
    if IsRecentDisenchant() and lastDisenchantItemID
        and (info[1] == nil or info[1]:match("^Item%-")) then
        Debug(("slot %d: recent confirmed Disenchant (itemID=%d), attributing loot directly"):format(
            slot, lastDisenchantItemID))
        return { { guid = "Disenchant-" .. lastDisenchantItemID, quantity = fallbackQuantity } }
    end
    for i = 1, #info, 2 do
        local kind = ParseGUID(info[i])
        Debug(("slot %d: raw source guid=%s qty=%s parsedKind=%s"):format(
            slot, tostring(info[i]), tostring(info[i + 1]), tostring(kind)))
        if kind then
            local quantity = info[i + 1] or 0
            quantitySum = quantitySum + quantity
            sources[#sources + 1] = { guid = info[i], quantity = quantity }
        end
    end
    -- GetLootSourceInfo's per-source quantities can under- or over-report
    -- versus the slot's actual quantity (observed: a x2 stack reported
    -- with a source sum of only 1). GetLootSlotInfo's fallbackQuantity is
    -- authoritative, so reconcile against it whenever they disagree —
    -- not just when the source sum came back zero — rather than silently
    -- short-counting.
    if #sources == 1 then
        if sources[1].quantity ~= fallbackQuantity then
            Debug(("slot %d: source quantity %d != actual %d, correcting"):format(
                slot, sources[1].quantity, fallbackQuantity))
            sources[1].quantity = fallbackQuantity
        end
    elseif #sources > 1 and quantitySum ~= fallbackQuantity then
        Debug(("slot %d: source quantity sum %d != actual %d, rescaling %d sources"):format(
            slot, quantitySum, fallbackQuantity, #sources))
        local idealSum, creditedSum = 0, 0
        for _, source in ipairs(sources) do
            local share = quantitySum > 0 and (source.quantity / quantitySum) or (1 / #sources)
            idealSum = idealSum + fallbackQuantity * share
            local credit = floor(idealSum + 0.5) - creditedSum
            creditedSum = creditedSum + credit
            source.quantity = credit
        end
    end
    -- GetLootSourceInfo occasionally returns nothing usable (seen under
    -- back-to-back kills), which would otherwise drop the item entirely
    -- with no error. A loot window is almost always opened on its
    -- corpse as your current target, so fall back to that GUID.
    if #sources == 0 then
        local targetGUID = UnitGUID("target")
        if targetGUID and ParseGUID(targetGUID) then
            sources[1] = { guid = targetGUID, quantity = fallbackQuantity }
            Debug(("slot %d: GetLootSourceInfo empty, used target GUID fallback"):format(slot))
        else
            Debug(("slot %d: GetLootSourceInfo empty AND no usable target — source lost"):format(slot))
        end
    end
    return sources
end

local function SnapshotLoot()
    if next(pending) then
        local target = UnitGUID("target") or "no target"
        local count = 0
        for _ in pairs(pending) do count = count + 1 end
        Debug(("SnapshotLoot: wiping %d unconsumed pending entr%s (current target %s)")
            :format(count, count == 1 and "y" or "ies", target))
    end
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
                else
                    Debug(("slot %d: item %d dropped, no sources resolved"):format(slot, itemID))
                end
            end
        elseif slotType == LOOT_TYPE_MONEY then
            local _, coinText = GetLootSlotInfo(slot)
            local copper = CoinTextToCopper(coinText)
            if copper > 0 then
                local sources = CollectSlotSources(slot, copper)
                if #sources > 0 then
                    pending[slot] = { money = true, sources = sources }
                else
                    Debug(("slot %d: %d copper dropped, no sources resolved"):format(slot, copper))
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
        local record = kind and GetSourceRecord(kind, id)
        if record then
            if entry.money then
                idealSum = idealSum + source.quantity * scale
                local credit = floor(idealSum + 0.5) - creditedSum
                creditedSum = creditedSum + credit
                record.copper = (record.copper or 0) + credit
                if credit > 0 then
                    LogEvent(kind, id, nil, nil, credit)
                end
            else
                record.items[entry.itemID] = (record.items[entry.itemID] or 0) + source.quantity
                if source.quantity > 0 then
                    LogEvent(kind, id, entry.itemID, source.quantity)
                end
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
    if not entry then
        Debug(("QueueSlot: slot %d cleared but no pending entry — loot lost"):format(slot))
        return
    end
    pending[slot] = nil
    Debug(("QueueSlot: slot %d recording %s"):format(
        slot, entry.money and (entry.copper or "money") or ("item " .. tostring(entry.itemID))))
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

---@diagnostic disable-next-line: deprecated
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
---@diagnostic disable-next-line: deprecated
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

-- "loaded" (AH values available), "disabled" (installed but unchecked in
-- the AddOns list — GetAddOnMetadata still finds it on disk even though
-- it never ran, unlike IsAddOnLoaded), or "missing" (not installed at all).
function LT.AuctionatorStatus()
    if IsAddOnLoaded("Auctionator") then return "loaded" end
    if GetAddOnMetadata and GetAddOnMetadata("Auctionator", "Version") then
        return "disabled"
    end
    return "missing"
end

-- Reads the current buyout price from Auctionator via its published API
-- (Auctionator/Source/API/v1/GetAuctionPrice.lua) instead of its internal
-- AUCTIONATOR_PRICE_DATABASE saved-variable table, so this keeps working
-- even if Auctionator's internal storage format changes. Returns nil
-- whenever Auctionator isn't installed/loaded, or has no data for
-- itemID — callers must treat nil as "unknown", not zero.
function LT.GetAuctionValue(itemID)
    if not itemID or not IsAddOnLoaded("Auctionator") then return nil end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not api or not api.GetAuctionPriceByItemID then return nil end
    local ok, price = pcall(api.GetAuctionPriceByItemID, ADDON_NAME, itemID)
    if ok and type(price) == "number" then
        return price
    end
    return nil
end

-- index defaults to the active (currently-tracked) session; pass a
-- specific index to read a past session's data instead.
function LT.GetSources(index)
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    local session = sessions and sessions[index or #sessions]
    return session and session.sources
end

function LT.GetLog(index)
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    local session = sessions and sessions[index or #sessions]
    return session and session.log
end

function LT.GetSessions()
    return LootTrackerDB and LootTrackerDB.sessions
end

function LT.GetActiveSessionIndex()
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    return sessions and #sessions or 0
end

-- Closes out the active session (stamping endTime) and starts a fresh
-- one, WITHOUT deleting the old one — the "manual split" the user asked
-- for instead of having to Reset (wipe) everything just to compare runs.
-- Returns the new session's index.
function LT.StartNewSession(name)
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    if not sessions then return end
    local current = sessions[#sessions]
    if current then
        current.endTime = time()
    end
    sessions[#sessions + 1] = {
        name = (name and name ~= "") and name or nil,
        startTime = time(),
        sources = {},
        log = {},
    }
    if LT.RefreshUI then
        LT.RefreshUI()
    end
    return #sessions
end

-- Resetting the active session wipes it in place (tracking continues in
-- the same slot); resetting a past session deletes it outright — there's
-- nothing live left to preserve once it's closed. Always leaves at least
-- one session behind, since GetActiveSession() must never come up empty.
function LT.ResetSession(index)
    local sessions = LootTrackerDB and LootTrackerDB.sessions
    local session = sessions and sessions[index]
    if not session then return end
    if index == #sessions then
        wipe(session.sources)
        wipe(session.log)
        session.startTime = time()
        session.endTime = nil
        wipe(seenGUIDs)
    else
        tremove(sessions, index)
    end
    if LT.RefreshUI then
        LT.RefreshUI()
    end
end

function LT.IsItemHidden(itemID)
    local hidden = LootTrackerDB and LootTrackerDB.filters and LootTrackerDB.filters.hiddenItems
    return (hidden and itemID and hidden[itemID]) or false
end

-- hidden stores true/nil rather than true/false so an unhidden entry
-- doesn't linger in the saved table forever.
function LT.SetItemHidden(itemID, hidden)
    local filters = LootTrackerDB and LootTrackerDB.filters
    if not (filters and itemID) then return end
    filters.hiddenItems[itemID] = hidden or nil
    if LT.RefreshUI then
        LT.RefreshUI()
    end
end

function LT.GetHiddenItems()
    return LootTrackerDB and LootTrackerDB.filters and LootTrackerDB.filters.hiddenItems
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
eventFrame:RegisterEvent("ITEM_LOCKED")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        Debug(event .. " target=" .. tostring(UnitGUID("target")) .. " items=" .. tostring(GetNumLootItems()))
        SnapshotLoot()
    elseif event == "LOOT_SLOT_CLEARED" then
        Debug("LOOT_SLOT_CLEARED slot=" .. tostring(...))
        QueueSlot(...)
    elseif event == "LOOT_CLOSED" then
        Debug("LOOT_CLOSED")
        -- Some loot flows (seen with single-item auto-loot) close the
        -- window without ever firing LOOT_SLOT_CLEARED; the confirming
        -- "You receive loot" chat message still arrives a moment later.
        -- Queue anything still pending for that confirmation instead of
        -- discarding it outright.
        for slot, entry in pairs(pending) do
            entry.time = GetTime()
            unconfirmed[#unconfirmed + 1] = entry
            Debug(("LOOT_CLOSED: slot %d never cleared, queued for chat confirmation"):format(slot))
        end
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
        local _, subevent, _, sourceGUID, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
        if subevent == "UNIT_DIED" then
            ---@diagnostic disable-next-line: need-check-nil
            CacheGUIDName(destGUID, destName)
        elseif DEBUG and subevent == "SPELL_CAST_SUCCESS" and sourceGUID == UnitGUID("player") then
            -- Fallback data point in case ITEM_LOCKED doesn't pan out either:
            -- this fires for the Disenchant cast too, with destGUID/destName
            -- describing whatever it was cast on.
            Debug(("SPELL_CAST_SUCCESS by player: destGUID=%s destName=%s"):format(
                tostring(destGUID), tostring(destName)))
        end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CacheUnitName("mouseover")
    elseif event == "PLAYER_TARGET_CHANGED" then
        CacheUnitName("target")
    elseif event == "UNIT_SPELLCAST_SENT" then
        local a1, target, a3, a4 = ...
        Debug(("UNIT_SPELLCAST_SENT args: %s | %s | %s | %s"):format(
            tostring(a1), tostring(target), tostring(a3), tostring(a4)))
        -- Gathering only happens out of combat; the guard keeps hostile
        -- cast targets from being mistaken for node names.
        if target and target ~= "" and not UnitAffectingCombat("player") then
            lastObjectName, lastObjectTime = target, GetTime()
        end
    elseif event == "ITEM_LOCKED" then
        -- Confirmed via a live repro: the lock on the disenchanted item
        -- fires AFTER UNIT_SPELLCAST_SUCCEEDED (the item being locked is
        -- a side effect of it being consumed, not a target picked before
        -- casting), so this fills in lastDisenchantItemID retroactively
        -- for a Disenchant that JUST succeeded, rather than the reverse.
        local bag, slot = ...
        local itemID = bag and slot and GetContainerItemID and GetContainerItemID(bag, slot)
        Debug(("ITEM_LOCKED bag=%s slot=%s itemID=%s"):format(tostring(bag), tostring(slot), tostring(itemID)))
        if itemID and itemID > 0 and IsRecentDisenchant() then
            lastDisenchantItemID = itemID
            Debug(("ITEM_LOCKED matched a recent Disenchant cast — target itemID=%d"):format(itemID))
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        local castName = GetSpellInfo(spellID)
        Debug(("UNIT_SPELLCAST_SUCCEEDED spellID=%s name=%s (disenchant name is %s)"):format(
            tostring(spellID), tostring(castName), tostring(DISENCHANT_SPELL_NAME)))
        if DISENCHANT_SPELL_NAME and castName == DISENCHANT_SPELL_NAME then
            lastDisenchantTime = GetTime()
            lastDisenchantItemID = nil -- filled in by the ITEM_LOCKED that follows
            Debug("Disenchant cast recognized, arming disenchant window (item id pending)")
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
