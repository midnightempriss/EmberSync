# Native installers

Tagged releases populate this directory with checksummed artifacts downloaded
from the matching GitHub Release. Large installer binaries are intentionally
not committed to Git.

- `windows/` — x64 NSIS setup executable
- `macos/` — universal Apple Silicon and Intel DMG
- `linux/` — x86_64 DEB, RPM, and AppImage
- `updater/` — signed updater metadata and any platform-neutral signatures

The addon ZIP and `SHA256SUMS.txt` live at the root of this folder. Generate a
local addon package with `scripts/package-addon.ps1`, or download, verify, and
replace all native artifacts from a published tag with
`scripts/fetch-release-artifacts.ps1`.
