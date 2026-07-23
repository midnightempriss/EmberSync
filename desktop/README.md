# EmberSync desktop client

EmberSync is a Tauri 2 desktop application for Windows, macOS, and Linux. It
reads (and never writes) World of Warcraft `EmberSync.lua` SavedVariables,
validates the hard-coded Raining Embers guild identity, encrypts changed
segments locally, and uploads them with an Ed25519 device identity.

## Security boundary

- Only `Raining Embers / Dalaran / US` and
  `Raining Embers Alts / Wyrmrest Accord / US` are accepted.
- Lua is parsed as bounded literal data. It is never executed.
- Payloads remain in the Rust process and are never exposed to the webview.
- SQLite payloads use XChaCha20-Poly1305. The key is kept in the operating
  system credential vault or derived from an explicitly entered passphrase.
- The client fails closed: no plaintext queue fallback exists.
- Website requests are restricted to `https://rainingembers.org`, signed with
  Ed25519, and follow the contracts in `../protocol`.

## Automatic sync

The watcher scans immediately when a selected SavedVariables file changes.
It also performs a guarded scan every 15 minutes and uploads any queued changes
while the device is paired and its vault is unlocked. Empty queues do not make
an upload request, overlapping workers are coalesced, and website
authorization failures remain paused for the user instead of retrying
indefinitely. A durable local acknowledgement index prevents unchanged state
and retained event history from being re-queued by later scheduled scans.
Bounded future dataset and event names are uploaded for encrypted raw retention
but remain ineligible for typed website projections until registered. Invalid
segments and non-transient server rejections are isolated without stopping
other queued datasets.

World of Warcraft writes account SavedVariables to disk on reload, logout,
disconnect, or client exit. The desktop timer cannot force the game to persist
new in-memory addon data, so `/reload` remains the quickest way to make a
fresh in-game capture available to the desktop while staying logged in.

## Development

```powershell
npm install
npm test
npm run build
npm run tauri dev
```

Rust validation:

```powershell
cd src-tauri
cargo fmt -- --check
cargo test --all-targets
cargo check --all-targets
```

Build the local Windows NSIS installer:

```powershell
$env:TAURI_SIGNING_PRIVATE_KEY = "C:\path\to\embersync-updater.key"
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = "<matching key password>"
npx tauri build --bundles nsis
```

Release builds generate signed Tauri 2 updater artifacts because
`bundle.createUpdaterArtifacts` is enabled. The application checks the static
GitHub Releases feed at
`https://github.com/midnightempriss/EmberSync/releases/latest/download/latest.json`
and verifies every update with the public key embedded in `tauri.conf.json`.
Keep the corresponding private key outside the repository and provide it to CI
only through `TAURI_SIGNING_PRIVATE_KEY` and
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD` secrets. The release workflow must attach
the generated installers, `.sig` files, and Tauri `latest.json` metadata.

Platform-native release jobs must run on their corresponding GitHub Actions
runner. Startup is opt-in and launches the application with `--background`;
closing the window keeps the watcher in the system tray, while **Quit
EmberSync** stops it.
