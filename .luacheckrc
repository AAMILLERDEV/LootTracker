-- Luacheck config for WoW TBC Classic (2.5.x) addon development
std = "lua51"
max_line_length = false
codes = true
self = false

-- Don't lint bundled third-party libraries
exclude_files = {
    "**/Libs/**",
    ".luacheckrc",
}

ignore = {
    "211/_.*",  -- unused variables prefixed with _
    "212/_.*",  -- unused arguments prefixed with _
}

-- Globals the addon is allowed to WRITE (saved variables, slash command
-- registration, FrameXML tables addons add fields to).
globals = {
    "LootTrackerDB",
    "SLASH_LOOTTRACKER1", "SLASH_LOOTTRACKER2",
    "SlashCmdList", "StaticPopupDialogs", "UISpecialFrames",
}

-- WoW API and Lua extensions the addon may READ. This is a working core
-- set for TBC Classic; add functions as luacheck flags them.
read_globals = {
    -- Lua library extensions provided by WoW
    "bit", "format", "gsub", "strbyte", "strchar", "strfind", "strjoin",
    "strlen", "strlower", "strmatch", "strrep", "strsplit", "strsub",
    "strtrim", "strupper", "tinsert", "tremove", "wipe", "tContains",
    "tInvert", "sort", "floor", "ceil", "abs", "min", "max", "mod",
    "random", "time", "date", "debugstack", "debugprofilestop",

    -- Core / utility
    "hooksecurefunc", "issecurevariable", "securecall", "geterrorhandler",
    "seterrorhandler", "GetTime", "GetLocale", "GetBuildInfo",
    "GetAddOnMetadata", "IsAddOnLoaded", "LoadAddOn", "InterfaceOptions_AddCategory",
    "ReloadUI", "PlaySound", "PlaySoundFile", "GetCursorPosition",
    "InCombatLockdown", "IsLoggedIn", "IsShiftKeyDown", "IsControlKeyDown",
    "IsAltKeyDown", "IsModifierKeyDown",

    -- Frames / UI
    "CreateFrame", "UIParent", "WorldFrame", "GameTooltip", "GameFontNormal",
    "GameFontHighlight", "GameFontNormalLarge",
    "StaticPopup_Show", "UIDropDownMenu_Initialize",
    "UIDropDownMenu_AddButton", "UIDropDownMenu_SetWidth",
    "UIDropDownMenu_SetText", "UIDropDownMenu_SetSelectedValue",
    "ToggleDropDownMenu", "CloseDropDownMenus", "EasyMenu",
    "GameTooltip_Hide", "SetPortraitTexture",

    -- Chat
    "DEFAULT_CHAT_FRAME", "ChatFrame1",
    "SendChatMessage", "ChatFrame_AddMessageEventFilter",
    "ChatFrame_RemoveMessageEventFilter",

    -- Loot
    "GetNumLootItems", "GetLootSlotType", "GetLootSlotInfo",
    "GetLootSlotLink", "GetLootSourceInfo",

    -- Unit info
    "UnitName", "UnitClass", "UnitRace", "UnitLevel", "UnitHealth",
    "UnitHealthMax", "UnitPower", "UnitPowerMax", "UnitPowerType",
    "UnitExists", "UnitIsPlayer", "UnitIsUnit", "UnitIsDead",
    "UnitIsGhost", "UnitIsConnected", "UnitAffectingCombat", "UnitGUID",
    "UnitFactionGroup", "UnitReaction", "UnitInParty", "UnitInRaid",
    "UnitIsFriend", "UnitIsEnemy", "UnitCanAttack", "UnitCastingInfo",
    "UnitChannelInfo", "UnitAura", "UnitBuff", "UnitDebuff",
    "GetUnitName", "TargetUnit",

    -- Player info
    "GetMoney", "GetXPExhaustion", "UnitXP", "UnitXPMax",
    "GetZoneText", "GetSubZoneText", "GetRealZoneText", "GetMinimapZoneText",
    "GetRealmName", "IsInInstance", "IsResting",

    -- Spells / combat
    "GetSpellInfo", "GetSpellCooldown", "GetSpellTexture", "IsSpellKnown",
    "IsUsableSpell", "CastSpellByName", "GetSpellBookItemName",
    "CombatLogGetCurrentEventInfo", "GetShapeshiftForm", "GetTalentInfo",

    -- Items / inventory
    "GetItemInfo", "GetItemCount", "GetItemIcon", "GetInventoryItemLink",
    "GetInventoryItemID", "GetContainerNumSlots", "GetContainerItemInfo",
    "GetContainerItemLink", "UseContainerItem", "PickupContainerItem",
    "GetItemQualityColor", "GetCoinTextureString",

    -- Group / raid
    "GetNumGroupMembers", "GetNumSubgroupMembers", "IsInGroup", "IsInRaid",
    "GetRaidRosterInfo", "UnitIsGroupLeader", "UnitIsGroupAssistant",

    -- Quests / gossip
    "GetNumQuestLogEntries", "GetQuestLogTitle", "GetQuestLogSelection",

    -- Constants / mixins / namespaces
    "C_Timer", "C_Map", "C_QuestLog", "C_ChatInfo", "C_CreatureInfo",
    "C_Item", "C_CurrencyInfo", "YES", "NO",
    "Enum", "CreateColor", "Mixin", "CopyTable",
    "RAID_CLASS_COLORS", "CUSTOM_CLASS_COLORS", "FACTION_BAR_COLORS",
    "ITEM_QUALITY_COLORS", "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR",
    "RED_FONT_COLOR", "GREEN_FONT_COLOR", "ERR_NOT_IN_COMBAT",
    "WOW_PROJECT_ID", "WOW_PROJECT_BURNING_CRUSADE_CLASSIC",
    "WOW_PROJECT_MAINLINE", "WOW_PROJECT_CLASSIC",

    -- Libraries (uncomment if you add Ace3/LibStub)
    -- "LibStub",
}
