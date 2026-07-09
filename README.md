# LootTracker

Ever wanted a clean view of all the loot you collected during your gold farming sessions? **LootTracker** keeps a running tally of everything you loot — organized by the NPC or gathering node it came from — and shows you what it's all worth at a vendor.

For **World of Warcraft: TBC Anniversary (2.5.6)**.

## What it does

- **Groups your loot by source.** Every mob you kill and loot gets its own entry, with all its drops stacked together — kill 40 kobolds and you'll see one "Kobold Miner" group with everything they dropped, how many times you've looted them, and its own item icons.
- **Tracks gathering too.** Mining veins, herbs, and chests get their own `(node)` entries, so you can see what that hour of ore farming actually produced.
- **Shows coin drops.** Money looted from mobs appears as a **Currency** line inside each group.
- **Adds it all up.** Every item shows its vendor sell value, every group shows its combined worth, and the bottom of the window shows the grand total for your session.
- **Auction house values, if you have Auctionator.** With [Auctionator](https://www.curseforge.com/wow/addons/auctionator) installed, every item, group, and the grand total also shows what it's worth on the AH, right alongside the vendor price. No Auctionator? LootTracker works exactly the same, just without that column.
- **Two ways to browse.** Switch between a **grouped** view (loot stacked by source) and a **timeline** view (a chronological, newest-first log of every pickup) with one click.
- **Counts only *your* loot.** If a party member picks something up, it doesn't get counted. Only what actually enters your bags is tracked.
- **Resize and reposition freely.** The window and the launcher button both remember where you left them, per character.
- Your data is saved **per character** and survives logging out.

## Getting started

1. Copy the `LootTracker` folder into:
   ```
   World of Warcraft\_anniversary_\Interface\AddOns\
   ```
2. Enable **LootTracker** in the AddOns list on the character select screen.

## How to use it

| I want to... | Do this |
| --- | --- |
| Open or close the tracker | Click the bag icon, or type `/lt` |
| See what one mob dropped | Click its name to expand or collapse it |
| Collapse or expand the whole list | Click **Collapse All** / **Expand All** at the top |
| See loot in the order you picked it up | Click **Timeline View** at the top |
| Go back to loot grouped by source | Click **Grouped View** at the top |
| Start fresh | Click **Reset** (bottom left) or type `/lt reset` |
| Open the options menu | Click the gear icon (top left), or right-click the bag icon |
| Move the window or bag icon | Drag it anywhere with the left mouse button |
| Make the window bigger or smaller | Drag the grip in the bottom-right corner |

The list sorts itself by value, so your most profitable targets are always at the top.

### Options

Click the gear icon in the top-left of the window, or right-click the bag icon — both open the same menu:

- **Pin window (ignore Esc)** — normally the Esc key closes the tracker like any other window. Pin it and it stays open (handy while farming).
- **Reset window size** — snaps the window back to its original size.
- **Reset window position** — brings the window back to the center of the screen, in case it wanders off somewhere unhelpful.
- **Show vendor value** — toggle the vendor sell-price column off if you only care about AH values (or vice versa).
- **Show AH value** — toggle the Auctionator column off if you'd rather not see it.
- **Show date/time** — toggle the timestamp shown on each entry in Timeline View.

## Good to know

- Items you win from **group loot rolls** aren't attributed — the tracker records loot you take directly from a loot window.
- **Pickpocketed** loot counts (it comes from an NPC, after all).
- **Crafting doesn't count.** Only drops and gathering — creating items at a forge won't inflate your numbers.
- A mob may briefly appear as `NPC #1234` if its name isn't known yet; it fills in as you keep playing.
- Newly seen items may take a moment to show their name and price while the game fetches item data.

Please feel free to provide as much feedback as possible. Whether it's bug fixes, concerns, likes or dislikes! I'm happy to discuss possible improvements as well, as I'm always looking to improve my work. 
