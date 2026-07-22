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

## Dataset semantics

Every segment has a stable dataset name, guild scope, source character,
sequence, capture time, payload hash, and coverage status. Coverage is one of
`complete`, `partial`, `forbidden`, `interaction_required`, `unavailable`, or
`unsupported`.

Omission is never a deletion unless the source completed a full enumeration.
State segments coalesce to the latest sequence; append-only ranges retain their
event identities and deduplicate at the server.

## Storage

- Addon: latest state and bounded event windows in account SavedVariables.
- Desktop: SQLite index plus XChaCha20-Poly1305 encrypted payload blobs.
- Website: D1 device/session/provenance/projection metadata and R2 raw chunks.

Latest normalized state is retained indefinitely, raw state snapshots for 90
days, and append-only guild events for one year.
