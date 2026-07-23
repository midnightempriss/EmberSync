# Changelog

All notable EmberSync changes are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## 0.1.5 - 2026-07-23

### Fixed

- Excluded character-personal calendar entries and invitations from collection,
  retained last-good state, projections, and website APIs. EmberSync calendar
  observations are limited to explicitly guild-scoped events.
- Added explicit, secret-safe Guild Bank item and icon identifiers so the
  website can resolve official Blizzard item artwork without trusting arbitrary
  image URLs or preserving WoW chat-atlas markup in item names.

## 0.1.4 - 2026-07-23

### Added

- Added one canonical state/event registry across the addon, protocol, desktop,
  and website, including passive `world_quests` collection and the previously
  unregistered guild, bank, presence, and neighborhood event streams.
- Added component-level guild readiness, durable collector health, coverage-only
  synchronization, passive calendar initialization, and a persistent
  multi-subdivision housing catalog with direct versus derived provenance.
- Added a leader-only website synchronization-health view and protected member
  calendar/world-quest projections without exposing raw payload contents.
- Added a one-time state reconciliation epoch so existing encrypted 0.1.3 data
  is re-sent once and can be rebuilt by the corrected website projections.

### Fixed

- Guarded secret WoW values before string, number, copy, comparison, and size
  operations so temporarily protected guild data fails closed instead of
  repeatedly interrupting collection.
- Projected G.M.O.D. from the real `guild.motd` field and normalized the actual
  roster, note, presence, Guild Bank item, transaction, calendar, and housing
  payload shapes.
- Prevented missing or not-yet-loaded metrics from being displayed as genuine
  zeroes, retained same-guild last-good G.M.O.D. values, and distinguished
  explicit empty messages from unavailable data.
- Batched contiguous event ranges, isolated unsupported data, tightened signed
  upload redirects and commit validation, and made receipt/coalescing identity
  include dataset, scope, subject, sequence, and freshness.
- Reduced idle desktop work with SavedVariables path filtering and file
  fingerprints, and added zero-touch Battle.net installation discovery for
  custom World of Warcraft drives.

## 0.1.3 - 2026-07-22

### Added

- Added a guarded automatic desktop scan and upload every 15 minutes while the
  client is paired and its encrypted vault is unlocked.
- Added clearer in-game actions and notes for data that requires an open game
  window or is still loading.

### Fixed

- Captured short-lived Auction House, calendar, crafting, Guild Bank, bank,
  mailbox, and profession contexts promptly without bypassing frame-friendly
  debounce behavior.
- Preserved same-character last-good fields when a later observation is
  partial, while keeping source-character provenance isolated.
- Corrected readiness reporting for collections and progression so an empty or
  failed API response is not mislabeled complete.
- Serialized Guild Bank tab requests, kept closed-context coverage separate
  from the original bank-payload provenance, pruned catalogs for unlearned
  professions, and removed expensive synchronous logout recrawls.
- Accepted retained datasets and events from each eligible source character
  instead of incorrectly requiring every envelope to match the latest export
  character.
- Coalesced duplicate character coverage rows in the desktop interface.
- Persisted acknowledged envelope hashes so scheduled rescans do not re-upload
  unchanged state or retained event history.
- Resolved the mixed neighborhood identity Retail can report for Raining Embers
  Alts by binding neighborhood, Endeavor, and activity data to a strict live
  GUID consensus instead of a stale bulletin-board GUID.
- Kept rejected or cross-GUID neighborhood data out of guild exports, delayed
  initiative events until neighborhood verification succeeds, and made
  interaction guidance name the character's approved main or alt guild.

## 0.1.2 - 2026-07-22

### Fixed

- Made website revocation idempotent and reconciled devices that had already
  been revoked on the site, while retaining signature verification.
- Displayed pairing and revocation failures in Settings instead of silently
  swallowing them, and corrected server machine-error parsing.
- Protected coalesced queue rows from stale in-flight upload results and routed
  every upload entry point through one bounded queue-draining worker.
- Reduced Blizzard verification amplification by keeping the sync-start
  authorization valid through its atomic commit.
- Matched RFC 8785 canonical JSON across Rust and JavaScript so extreme numeric
  values and Unicode object keys cannot produce false integrity failures.

## 0.1.1 - 2026-07-22

### Added

- Full loaded guild-neighborhood, Endeavor progress/task/milestone, and
  Endeavor activity-log capture with interaction-aware coverage.
- Native WoW-folder browsing and normalized Retail SavedVariables discovery in
  the desktop client.
- Collector CPU and frame-slice diagnostics in the in-game interface.

### Fixed

- Time-sliced expensive addon collection, deferred bulk scans during combat,
  coalesced unchanged state, and reduced full-database scans to prevent stalls.
- Corrected the documented bulletin-board roster event payload handling.
- Stopped automatic retry storms when Battle.net re-verification is required,
  preserved encrypted queued data, and added an actionable reauthorization UI.
- Distinguished healthy local encryption from an unavailable or locked vault.

## 0.1.0 - 2026-07-22

### Added

- Retail addon locked to Raining Embers on Dalaran and Raining Embers Alts on
  Wyrmrest Accord, with fail-closed guild and Club verification.
- Privacy-aware collection, coverage reporting, bounded event history, and an
  ember-themed in-game interface.
- Tauri 2 desktop client for Windows, macOS, and Linux with safe SavedVariables
  parsing, encrypted local queueing, site pairing, tray mode, and opt-in
  start-at-login.
- Versioned canonical protocol with Ed25519 request signing and strict guild
  identity validation.
- Website device management, fresh membership enforcement, atomic ingestion,
  encrypted raw storage, provenance, and EmberSync-first resolution for
  existing data consumers.
- Native release automation, addon packaging, checksums, and signed Tauri
  updater artifacts.
