# EmberSync

EmberSync is the private data bridge for the Raining Embers World of Warcraft
guild sites. It combines a read-only Retail addon, a cross-platform desktop
companion, and a server-enforced upload protocol.

EmberSync is intentionally locked to two US guilds:

- **Raining Embers**, founded on **Dalaran**
- **Raining Embers Alts**, founded on **Wyrmrest Accord**

A character outside those guilds is not collected. The website independently
checks current Battle.net character ownership and the live Blizzard rosters
before it pairs a device or accepts a sync. SavedVariables are never treated as
proof of membership, rank, or permission.

## Project layout

- `EmberSync.toc`, `Core/`, `Collectors/`, `UI/`, `Locales/` — the in-game addon
- `desktop/` — the Tauri 2 desktop companion
- `protocol/` — versioned wire contracts and fixtures
- `tests/` — addon and cross-component tests
- `docs/` — architecture, privacy, security, and release notes
- `scripts/` — reproducible addon packaging and artifact helpers
- `installer/` — locally downloaded native release installers
- `.github/workflows/` — validation and native release builds

## Privacy and safety

The addon uses only Blizzard's addon APIs and never performs protected actions.
It does not send HTTP requests. The desktop reads SavedVariables without
modifying them, rejects executable Lua, encrypts queued payloads, and uploads
only after explicit site pairing.

EmberSync excludes whispers, Battle.net messages and contacts, party and raid
chat, mail bodies, raw combat-log streams, credentials, and Battle.net IDs.
Sensitive collected data is private by default.

See [Security](docs/SECURITY.md), [Privacy](docs/PRIVACY.md),
[Data catalog](docs/DATA_CATALOG.md), and
[Architecture](docs/ARCHITECTURE.md).

## Development

The addon can be installed by keeping this repository at:

`World of Warcraft/_retail_/Interface/AddOns/EmberSync`

Desktop prerequisites are Node.js 22 or newer, Rust stable, and the native
Tauri 2 platform prerequisites. From `desktop/`:

```text
npm install
npm run test
npm run tauri build
```

Release installers are produced on native GitHub Actions runners and copied
into `installer/windows`, `installer/macos`, and `installer/linux` by the
release download script. Operating-system signing hooks are present, but the
initial installers are unsigned.

Installation and release-maintainer instructions live in
[`docs/INSTALLATION.md`](docs/INSTALLATION.md) and
[`docs/RELEASE.md`](docs/RELEASE.md).

## Status

Version `0.1.0` is the initial guild-locked release.
