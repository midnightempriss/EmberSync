# EmberSync architecture

## Trust boundaries

EmberSync deliberately uses three independent gates:

1. The addon verifies the logged-in character's guild name, founding realm,
   region, and guild Club membership before any collector can commit data.
2. The desktop validates the canonical guild identity and parses SavedVariables
   as data rather than executing Lua.
3. The website verifies the paired Battle.net account owns the source character
   and that the character is currently present in one of the two canonical
   Blizzard guild rosters.

Only the third gate is an authorization boundary. Addon files and local queues
are controlled by the user and can never grant site access.

## Data flow

```text
WoW APIs -> in-memory staging -> EmberSyncDB -> stable file read
         -> canonical segments -> encrypted local queue -> signed upload
         -> D1 metadata/projections + encrypted R2 raw chunks
         -> existing site consumers with provider fallback
```

WoW serializes SavedVariables only on reload, logout, disconnect, or exit.
Consequently the UI records separate capture, persistence, and upload times.
The desktop reacts immediately to stable file changes and also runs a guarded
15-minute scan/upload cycle. The periodic cycle skips unpaired or locked
clients, makes no website request for an empty queue, and never overlaps the
single queue-draining worker. Successfully committed content hashes are
retained locally as acknowledgements so an unchanged state envelope or
retained event cannot be queued again on the next scan.

## Dataset semantics

Every segment has a bounded dataset name, guild scope, source character,
sequence, capture time, payload hash, envelope hash, and coverage status.
Registered names and their allowed scopes come from one catalog asserted by
the addon, protocol, desktop, and website test suites. Coverage is one of
`complete`, `partial`, `forbidden`, `interaction_required`, `unavailable`, or
`unsupported`.

Omission is never a deletion unless the source completed a full enumeration.
State segments coalesce by dataset, scope, and subject while rejecting stale
sequences. A newer coverage-only observation may retain the same payload and
sequence but receives its own envelope hash. Append-only events upload as
bounded contiguous ranges and retain their identities for server deduplication.

Version 0.1.4 advances the local state-receipt epoch once. Existing state
receipts are revalidated and current state is uploaded one time so new server
projections can be backfilled; event receipts remain idempotent and unchanged
state does not enter a re-upload loop.

## Storage

- Addon: latest state and bounded event windows in account SavedVariables.
- Desktop: SQLite index plus XChaCha20-Poly1305 encrypted payload blobs.
- Website: D1 device/session/provenance/projection metadata and R2 raw chunks.

Latest normalized state is retained indefinitely, raw state snapshots for 90
days, and append-only guild events for one year.
