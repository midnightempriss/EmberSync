# Optional addon research

Reviewed 2026-10-07 using author-maintained project pages and source. Recommendations are restricted to the current roster/joins/departures/inviter scope. More installed addons do not automatically mean more reliable or permitted data.

| Addon | Verified compatibility and purpose | EmberSync decision |
| --- | --- | --- |
| [Guild Roster Manager](https://www.curseforge.com/wow/addons/guild-roster-manager) | Retail 12.1.0, R1.99422, updated 2026-08-21. Maintains account-local join/rejoin/departure history with observed inviter fields; its log is not shared as a complete global history. | Recommended optional provider. Exact 1.99422 read-only adapter, manual install and explicit provider opt-in. |
| [GRM Group Info](https://www.curseforge.com/wow/addons/guild-roster-manager-group-info) | Retail 12.1.0, R1.65, updated 2026-08-14. Requires GRM; shows current/former guildmates in groups and other social details. | Useful GRM companion if desired, but no independent EmberSync data adapter. Group/trade-distance/ban/alt information is outside scope. |
| [FastGuildTracker](https://www.curseforge.com/wow/addons/fastguildtracker) | Author page lists Retail 12.1.0/12.1.5, 3.3 updated 2026-09-28. Displays Mythic+/raid progress using Raider.IO. | No provider recommended for these roster metrics. Progress/combat data is outside scope and does not establish actual inviters. |
| [Guildbook](https://www.curseforge.com/wow/addons/guildbook) | The reviewed project targets Classic/Cataclysm and shares character/profession/calendar information. | No Midnight Retail installation recommendation or provider. Current Retail 12.1 compatibility and an in-scope history contract were not established. |

## GRM adapter contract

The inspected author source is pinned to [commit 4c33214be3f1a730c6649f0bd9db170d61999e57](https://github.com/TheGeneticsGuy/Guild-Roster-Manager/tree/4c33214be3f1a730c6649f0bd9db170d61999e57). The source confirms the version/interface and structured log layout:

- [GRM_SaveVar_API.lua](https://github.com/TheGeneticsGuy/Guild-Roster-Manager/blob/4c33214be3f1a730c6649f0bd9db170d61999e57/GRM_SaveVar_API.lua): `GRM.GetLog(guildKey)` returns a table owned by GRM. EmberSync reads it without modifying it.
- [GRM_Log.lua](https://github.com/TheGeneticsGuy/Guild-Roster-Manager/blob/4c33214be3f1a730c6649f0bd9db170d61999e57/GRM_Log.lua): types 7/8/9 carry rejoin/join subject, an observed-log flag and inviter. Type 10 carries departure subject and kicked/left flag. Only whitelisted positions are read.
- [GRM_API.lua](https://github.com/TheGeneticsGuy/Guild-Roster-Manager/blob/4c33214be3f1a730c6649f0bd9db170d61999e57/GRM_API.lua): the advertised `GetWhoInvited` is a stub in this source; it is not treated as a working public API. Whole-member exports include unrelated private data and are deliberately unused.

Import contains at most 200 sanitized rows from the current exact guild key: event type, subject, known actual inviter and valid Gregorian `[day,month,year,hour,minute]`. Inviter attribution requires GRM's literal observed-log flag; otherwise it is omitted/unknown. Color wrappers are removed, but realm/identity is not invented. No formatted log text, private/officer/custom notes, ban details, birthdays, alt relationships, main names, levels or whole database exports are imported.

GRM dates are calendar values from its clock convention, with no supplied UTC offset. The website labels this explicitly and does not put them into precise UTC period buckets. Provider history is always partial and shown as the latest retained window from one collector, not added to overlapping windows, Blizzard invitation totals or observed roster joins. A newer record without a provider window removes an older provider view. Native Blizzard log failure can coexist with usable GRM history without being turned into a native zero.

GRM is [all rights reserved](https://github.com/TheGeneticsGuy/Guild-Roster-Manager/blob/4c33214be3f1a730c6649f0bd9db170d61999e57/License.md). EmberSync distributes its own compatibility adapter, links to the official download and does not bundle, alter or redistribute GRM. Install GRM independently, select the Retail flavor and enable only the EmberSync provider you want in `/embersync plugins`. Its other behavior remains controlled by GRM's own settings.

The checklist shows installed, missing, disabled and unsupported states with both text and color. Only GRM currently contributes data. Other adapters can later be registered after version/API/identity/time/privacy contracts and fixture tests are reviewed; installing an unrelated addon cannot enable data collection implicitly.
