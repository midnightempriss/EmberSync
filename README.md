# EmberSync desktop 2.0.0 preview.3 native builds

Fresh Lua addon and Python/Tk desktop for Raining Embers. This artifact-only preview branch preserves the legacy history and leaves the default branch/release workflow unchanged. No GitHub release is created. Website source/publication is managed separately; native builds never enable production flags or credentials.

The desktop includes browser-approved Ed25519 device pairing, a narrow owned-character/guild scope, native OS-vault adapters, signed durable scoped delivery and revocation. It starts with uploads paused. No actual account, production session or persistent credential is used by CI; fixture keys/vaults are ephemeral.

Preview.3 fixes a real production transport issue: pairing and upload requests now identify themselves honestly as EmberSync rather than using Python's default user agent, which the site edge rejects. No endpoint, signature, scope or redirect policy is relaxed. The website is published separately and allows enrollment only for the full public-key fingerprint of the specifically approved Windows PC; other devices are blocked. The unchanged addon remains preview.2.

The addon collects consented minimal roster/activity evidence and an optional read-only Guild Roster Manager 1.99422 provider. `/embersync plugins` shows installed/compatible/enabled status and explicit opt-in. GRM is not bundled. Its partial join/departure history, unknown inviters and calendar dates without verified timezone remain separate from Blizzard invitation counts and roster deltas. See `OPTIONAL-ADDONS.md` for researched sources.

The workflow runs on standard Windows2022 x64, macOS15 ARM64 and Intel, Ubuntu24.04 x64 runners. It runs native/Lua unit tests and actual Tk control tests using fake vault/server fixtures, builds the current desktop, packages Windows setup/macOS DMG/Linux deb, then verifies bundled self-tests and safe Tk creation. QA reports are bound to the source commit before packaging. Installers are not executed and real-vault/login/game/full bundled-GUI behavior remains unverified.

Windows/Linux are unsigned. macOS is ad-hoc signed and unnotarized; no signing certificate or notarization secret is available. Linux supports the declared Ubuntu24.04/glibc2.39-compatible amd64 runtime, not every distribution. Source GUI fixtures do not certify a platform's actual native vault.

Build requirements: `desktop/requirements-build.txt`, plus `lupa==2.8` for Lua fixtures. Commands: `python -m unittest discover -s tests -v`, `python scripts/desktop_ui_qa.py`, the workflow's PyInstaller commands and `python scripts/package_native.py`. Build metadata records actual commit/architecture/hashes/checks. Bounded artifact parts expire after three days and are reassembled with hash verification for local Downloads delivery.
