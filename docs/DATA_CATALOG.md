# Data catalog

EmberSync records only information exposed to the logged-in character by the
World of Warcraft addon API. Every dataset carries a coverage state so an
empty or inaccessible result cannot be mistaken for a complete enumeration.

| Dataset | Scope | Typical coverage constraints |
| --- | --- | --- |
| Guild roster and metadata | Guild | Rank and note visibility follows guild permissions. |
| Guild bank | Guild | Requires the bank to be opened; tabs and logs follow character permissions. |
| Calendar | Guild/character | Includes visible guild and character events; invite detail can require interaction. |
| Housing and neighborhoods | Guild/character | Feature-detected; unsupported fields remain explicitly unsupported. |
| Character profile and progression | Character | Captured only for the verified source character. |
| Inventory and equipment | Character | Bank, reagent-bank, and similar storage requires interaction. |
| Collections | Account | Mount, pet, toy, appearance, and achievement summaries available to the client. |
| Professions and crafting | Character | Recipe and order visibility follows the active profession UI and permissions. |
| Mythic+ and PvP | Character | Current client-visible progression and ratings. |
| World quests | Character | Passively enumerated for the current map plus the versioned Retail 12.0.7 Midnight catalog (Silvermoon City, Eversong Woods, Voidstorm, Harandar, Isle of Quel'Danas, and Zul'Aman); each map reports direct, retained, unavailable, or valid-empty coverage. |
| Auction House | Character | Requires Auction House interaction; no automation is performed. |
| Mail metadata | Character | Sender/subject/status metadata only; mail bodies are excluded. |
| Damage and healing aggregates | Character | Bounded post-combat summaries, never the raw combat-log firehose. |
| Guild/officer chat | Guild events | Only messages visible while online; whispers, party, raid, and Battle.net messages are excluded. |
| Guild log, Guild Bank log, and presence history | Guild events | Passively materialized from fresh roster/log observations; Guild Bank history remains interaction- and rank-gated. |

Coverage values are `complete`, `partial`, `forbidden`,
`interaction_required`, `unavailable`, or `unsupported`. A missing record can
delete prior normalized state only after a complete enumeration.

The registered v1 state catalog is shared by the Lua addon, TypeScript
protocol, Rust desktop client, and website ingestion tests. Bounded future
dataset names may be retained encrypted as raw-only observations, but they
cannot feed a projection until they are explicitly registered and reviewed.
Coverage changes are transport observations in their own right, so a newly
unavailable or interaction-gated collector is visible even when its last-good
payload did not change.

Several yellow rows are expected until the corresponding Blizzard interface is
opened. Auction House, mailbox, Guild Bank, personal/Warband bank, profession,
crafting-order, calendar-detail, and Endeavor views expose additional data only
while their game context is loaded. EmberSync listens for those short-lived
contexts, explains the useful action in Data Coverage, and preserves
same-character last-good fields when a later observation is incomplete.

Current state coalesces by its logical subject. Event streams are append-only
and are bounded to 90 days or 10,000 records in SavedVariables, subject to the
50 MiB account-level soft cap. Eviction creates an explicit coverage gap.
