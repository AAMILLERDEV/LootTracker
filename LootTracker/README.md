# LootTracker

A lightweight World of Warcraft addon for **TBC Anniversary (2.5.6, interface 20505/20506)** that tracks the loot *you* collect — from NPC kills and gathering nodes — grouped by source, with vendor values.

## Features

- **Per-NPC loot grouping** — every item you loot is credited to the NPC (by NPC ID) or gathering node (by object ID) it came from, with quantities stacked across kills.
- **Coin tracking** — money looted from NPCs appears as a **Currency** line inside each group and counts toward all totals.
- **Vendor values** — each item line shows its vendor (sell-to-merchant) value, each group header shows the summed value for that source, and the window footer shows the grand total. No auction-house pricing.
- **Only your loot** — items are recorded when *you* take them from *your* loot window. Party members' loot is never counted.
- **Gathering nodes** — mining veins, herbs, and other world objects are tracked and tagged `(node)`. Crafting, disenchanting, and container openings are deliberately excluded.
- **Interactive window** — movable, resizable (240×240 minimum, ~half the screen maximum), collapsible groups, Collapse All/Expand All, item icons, quality-colored names, and a Reset button with confirmation.
- **Bag-icon launcher** — a draggable floating button that toggles the window. Right-click it for options: pin the window (ignore Esc), reset window size, reset window position.
- **Persistent state** — loot data, window position/size, launcher position, collapsed groups, and the pin setting are saved per character.

## Usage

| Action | How |
| --- | --- |
| Toggle the window | Click the bag icon, or `/lt` / `/loottracker` |
| Collapse/expand one NPC | Click its header row |
| Collapse/expand everything | "Collapse All" / "Expand All" button (top left) |
| Reset all tracked data | "Reset" button (bottom left) or `/lt reset` |
| Move the window / launcher | Drag with left mouse button |
| Resize the window | Drag the grip in the bottom-right corner |
| Options (pin, reset size/position) | Right-click the bag icon |

## Installation

Copy (or symlink/junction) the `LootTracker` folder into your AddOns directory:

```
World of Warcraft\_anniversary_\Interface\AddOns\LootTracker\
```

For development, a directory junction keeps the game loading straight from your working copy:

```powershell
New-Item -ItemType Junction `
    -Path "C:\...\World of Warcraft\_anniversary_\Interface\AddOns\LootTracker" `
    -Target "C:\...\repos\WowTBCAddons\LootTracker"
```

After editing files, `/reload` in-game picks up changes — no build step.

## How it works

The addon is two files loaded by [LootTracker.toc](LootTracker.toc):

### Core.lua — tracking engine

- **Snapshot on loot open.** When your loot window opens (`LOOT_READY` / `LOOT_OPENED`), every slot is snapshotted: the item link (or parsed coin amount for money slots) plus the loot *sources* from `GetLootSourceInfo`, which returns the GUID and quantity per corpse — a single slot can span several corpses with area loot.
- **Record on take.** `LOOT_SLOT_CLEARED` fires only when a slot in *your* window is looted, so recording there guarantees only loot entering your bags is counted.
- **Source classification by GUID.** A GUID like `Creature-0-…-npcID-spawn` is grouped as an NPC; `GameObject-0-…-objectID-spawn` as a node. Every other GUID type (`Item` for disenchant/containers, `Player`, …) is ignored — this is what excludes crafting and similar non-drop loot. Each spawn GUID is only counted once per session toward a source's "looted" counter.
- **Names.** NPC names are learned from `UNIT_DIED` combat-log events (killing something records its name before you loot it). Node names come from the last out-of-combat `UNIT_SPELLCAST_SENT` target — when you gather, the cast target is the node name (e.g. "Copper Vein") — trusted only within a short time window. Unnamed sources display as `NPC #id` / `Object #id` until seen again.
- **Coins.** The loot API exposes coin slots only as localized text ("1 Silver, 23 Copper"), so the amount is parsed using the client's own `GOLD_AMOUNT`/`SILVER_AMOUNT`/`COPPER_AMOUNT` format strings, keeping it locale-safe.

Data is stored per character in the `LootTrackerDB` saved variable:

```lua
LootTrackerDB = {
    sources = {
        ["npc:3102"] = {        -- kind:id
            kind = "npc",       -- "npc" or "node"
            id = 3102,
            name = "Kobold Miner",
            loots = 4,          -- distinct corpses/nodes looted
            copper = 152,       -- coins looted (money slots)
            items = { [2589] = 5, ... },  -- itemID -> quantity
            collapsed = true,   -- UI collapse state
        },
    },
    ui = { ... },               -- window/launcher layout, pin setting
}
```

### UI.lua — window and launcher

- The window is a `BackdropTemplate` frame with a `UIPanelScrollFrameTemplate` scroll area. Rows are a reusable pool of Buttons: group headers carry their DB record and toggle `record.collapsed` on click; item rows have mouse input disabled.
- Each refresh rebuilds a display list from the DB — groups sorted by total vendor value, items likewise — and renders icons inline with `|T…|t` texture escapes.
- Vendor prices come from `GetItemInfo`, which is asynchronous for uncached items; `GET_ITEM_INFO_RECEIVED` triggers a debounced re-render as data arrives.
- Sizing is bounded (`SetResizeBounds`) between 240×240 and roughly half the screen, and an `OnUpdate` watcher guarantees resize mode ends when the mouse button is released, wherever that happens.
- Esc-close is implemented by the game via `UISpecialFrames`; the pin option simply removes/re-adds the frame name in that list.
- Modern-vs-classic API differences are bridged with fallbacks (`C_Item.GetItemInfo`, `C_CurrencyInfo.GetCoinTextureString`, `MenuUtil` → `EasyMenu`).

## Known limitations

- Items won through **group loot rolls** arrive without a loot window and are not attributed.
- If another player in a free-for-all group loots a slot while your window is open on the same corpse, it may be miscounted (rare).
- **Pickpocketing** opens a normal loot window on a creature, so it counts as NPC loot.
- Fishing catches are attributed to the bobber object and may show an approximate name.

## Development

- Lint config: [`../.luacheckrc`](../.luacheckrc) (luacheck, Lua 5.1 + WoW globals) and `../.vscode/settings.json` (sumneko Lua + [Ketho's WoW API](https://marketplace.visualstudio.com/items?itemName=ketho.wow-api) annotations).
- In-game debugging: `/console scriptErrors 1`, BugSack + BugGrabber, `/etrace`, `/fstack`, `/dump LootTrackerDB`.
