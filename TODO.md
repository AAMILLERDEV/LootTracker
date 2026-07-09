# TODO

Planned features for LootTrackerTBC. Not in any particular order.

- [ ] **Session Management** — start/stop/name discrete farming sessions instead of one ever-growing log, so separate runs (e.g. "Zangarmarsh mining" vs. "Blade's Edge herbing") can be tracked and compared independently instead of all blending into the same totals. Likely needs a session boundary in `LootTrackerDB` plus UI to switch between the current session and past ones.

- [ ] **Gold/hr Breakdown** — track elapsed time per session and surface gold/hour alongside the existing totals. Needs a defined start point (session start, or time of last Reset) and a decision on how logged-out/idle time is handled so the rate isn't skewed by wall-clock time you weren't actually playing.

- [ ] **Item Summary View** — a third view that aggregates by *item* across all sources instead of by source, e.g. "every Chunk of Boar Meat looted this session, total count, total value" as one row — complementing the existing Grouped and Timeline views.

- [ ] **Classic Era Support** — extend interface version support and the vendor/AH logic to work on Classic Era realms; currently targets TBC Anniversary specifically (see README). Would need to re-verify Auctionator's Classic-era API paths and check for any loot-window API differences between TBC and Classic Era.
