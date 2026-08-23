# Changelog

All notable changes to LootTrackerTBC are documented here. Versions before 1.0 predate this file and are reconstructed from commit history, so their entries are terser than newer ones.

## 1.1 — 2026-08-23

### Added
- **Disenchant tracking** — items you disenchant now show up as their own "Disenchanted: `<item>`" group, right alongside NPC and node loot.
- **Item Summary View** — a third view (cycle it with the view button) that aggregates loot by item across every source instead of by source.
- **Item filter** — right-click any item to hide it everywhere, lists and totals both. Options > **Manage Hidden Items** now shows the hidden list in place of the loot view, with a one-click unhide per item, instead of opening a separate menu.
- **"Show disenchants only"** — an Options toggle that scopes whichever view you're on down to just disenchant results.
- **Multiple sessions** — start a new session at any time without losing the last one (session picker button, or `/lt session`), then switch between past sessions to compare runs side by side. Reset now wipes only the session you're viewing if it's the active one, or deletes it outright if it's a past one.
- **Gold/hr** — shown next to the vendor/AH breakdown when you hover **Total**, computed from however long the session you're viewing has been running.
- **Auctionator-disabled notice** — if Auctionator is installed but disabled, a note now explains that instead of AH values just silently not appearing.
- `/lt debug` toggles verbose debug logging at runtime, for troubleshooting reports without needing a code edit.

### Changed
- The Reset menu entry now reads "Reset current session" or "Delete this session" depending on whether you're viewing the live session or a past one.

## 1.0 — 2026-07-09

### Added
- Auction house values via [Auctionator](https://www.curseforge.com/wow/addons/auctionator) (optional dependency) — shown per item and folded into a blended session total.
- Options menu (gear icon on the window, or right-click the bag icon): pin window, reset window size/position, toggle vendor/AH/date-time visibility, reset all data.
- Hover tooltip on the session total showing the raw vendor/AH breakdown.

### Changed
- Renamed the addon from **LootTracker** to **LootTrackerTBC**.
- The session total is now a blended "best value" estimate — AH price where Auctionator knows one, vendor price as the fallback, plus currency — instead of a plain vendor-only total. This also now drives sort order.
- Timeline view: each entry's source and timestamp now sit on their own line above the item instead of a trailing "from X", so rows no longer run wide.
- The Reset button moved from a standalone footer button into the options menu.

### Fixed
- The window resize grip could jump/snap the window size — on a plain click, and specifically after using the options menu. Replaced Blizzard's native `StartSizing`/`StopMovingOrSizing` with a fully manual resize implementation to eliminate the opaque native state causing it.
- Per-item AH tags no longer show `AH: —` for items Auctionator has no price for; they're simply omitted instead of cluttering the row.

## 0.7.4-debug — 2026-07-08
- Multi-item tracking fixes; button layout/size improvements.

## 0.7.3-debug — 2026-07-08
- Fixes for items looted in quick succession.

## 0.6.1 — 2026-07-08
- Bug fixes related to loot positioning when looting multiple items.

## 0.6.0 — 2026-07-08
- Locale pattern fixes, solo/group loot fixes, a source-matching fix, and cleanup of false loot confirmations.

## 0.5.0 — 2026-07-08
- Added the "Pin window" option (ignore Esc) and proper coin/currency tracking.

## 0.4.0 — 2026-07-08
- Added dropdown options for resetting window position and size.

## 0.3.1 — 2026-07-08
- Added a max window size; fixed a window-expansion issue when click-dragging the launcher icon.

## 0.3.0 — 2026-07-08
- Added item icons, collapsible loot grouped by NPC name, and an expand/collapse-all button.

## 0.2.0 — 2026-07-08
- Initial working version.
