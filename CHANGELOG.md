# Changelog

All notable EmberSync changes are documented here. This project follows
[Semantic Versioning](https://semver.org/).

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
