# Privacy

EmberSync is designed for voluntary contributions from verified Raining Embers
members. It does not collect anything for a character whose approved guild
membership cannot be established in game, and the website independently
rechecks Battle.net ownership and current Blizzard roster membership.

## Never collected

- Whispers, Battle.net messages, contacts, or identifiers
- Party or raid chat
- Mail bodies
- Credentials, authentication cookies, or Blizzard access tokens
- Raw combat-log firehoses
- Protected inputs or automated gameplay actions

## Local handling

The addon writes only to World of Warcraft SavedVariables. The desktop client
reads those files without modifying them, parses them as bounded literals
instead of executing Lua, and encrypts queued payloads with
XChaCha20-Poly1305. The queue key must come from the operating-system credential
vault or an explicit passphrase vault; there is no plaintext fallback.

Category controls can disable future staging. **Delete local data** removes the
desktop queue and local client state; World of Warcraft SavedVariables remain
under the player's control and can be removed separately while the game is
closed.

## Website handling

The site stores normalized provenance and current projections in isolated D1
tables. Raw chunks are compressed, encrypted, and stored under the private
`ember-sync/v1/` R2 prefix. Latest normalized state is retained indefinitely,
raw state snapshots for 90 days, and append-only guild events for one year.

Sensitive or uncorroborated guild-wide observations are private. Live Blizzard
data remains authoritative for authentication, membership, ownership,
leadership, and access decisions.
