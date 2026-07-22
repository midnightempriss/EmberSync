# Installation

## Addon

1. Close World of Warcraft.
2. Extract the addon archive so the final path is
   `World of Warcraft/_retail_/Interface/AddOns/EmberSync/EmberSync.toc`.
3. Start Retail and enable **EmberSync** on the AddOns screen.
4. Log into a character in Raining Embers or Raining Embers Alts. Use
   `/embersync` to open the interface.

Characters outside the two approved guilds see the locked membership screen
and no data is collected or committed by EmberSync.

## Desktop client

Download the native installer for the operating system from the matching
release or the local `installer/` folder:

- Windows x64: NSIS `.exe`
- macOS Intel and Apple Silicon: universal `.dmg`
- Linux x86_64: `.deb`, `.rpm`, or `.AppImage`

Initial operating-system installers are unsigned and may show the platform's
standard unknown-publisher warning. Tauri updater payloads are independently
signed and verified by the app.

Open EmberSync, select the discovered World of Warcraft accounts, and pair the
device from the Members settings page at <https://rainingembers.org>. Startup
launch is opt-in. When enabled, EmberSync launches with `--background` into the
system tray and does not keep a terminal window open.

## Checksums

Compare downloaded artifacts against `SHA256SUMS.txt` from the same release.
Do not install a file whose checksum differs.
