# Release process

1. Update the version in `EmberSync.toc`, `desktop/package.json`,
   `desktop/src-tauri/Cargo.toml`, and `desktop/src-tauri/tauri.conf.json`.
2. Update `CHANGELOG.md` and run the full local validation matrix.
3. Package the addon with `scripts/package-addon.ps1`.
4. Push the exact commit and create a `vMAJOR.MINOR.PATCH` tag.
5. The release workflow builds native bundles on each operating system, signs
   updater artifacts, attaches the addon archive, generates
   `SHA256SUMS.txt`, and publishes the GitHub release.
6. Populate this checkout's `installer/` directory with
   `scripts/fetch-release-artifacts.ps1 -Tag vMAJOR.MINOR.PATCH` and verify the
   checksums.

The repository must define these GitHub Actions secrets:

- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`

The updater private key must never be committed. Losing it prevents future
versions from updating existing installations, so keep an encrypted offline
backup. Operating-system code-signing credentials can be added later without
changing the Tauri updater trust key.
