# EmberSync 2.0 roster preview

Fresh addon and Python/Tk desktop preview for Raining Embers. This separate branch retains the legacy commit as its parent for history; its source tree is intentionally fresh. Default branch, old release workflow, and production website are untouched.

Automatic site synchronization remains disabled. The GUI reads addon SavedVariables locally and never creates or sends credentials. Website publication is blocked separately; device enrollment cannot proceed until approved code is live and verified. Native package builds do not enable sync.

The addon collects consented minimal roster/activity evidence only. Baselines are not historical joins, partial observations cannot remove members, invitations remain distinct from confirmed joins, unknown inviters remain unknown, and collector/reset epochs are not combined. Exact live WoW 12.1/API validation remains required; the addon currently pauses outside source-reference interface120100/build69587.

The new artifact-only workflow runs on this exact preview branch and manual dispatch. It uses standard free runners in this public repository: Windows2022 x64, macOS15 ARM64/Intel, and Ubuntu24.04 x64. It runs source tests, builds native executables, creates Windows setup/macOS DMG/Linux deb packages, and checks bundled self-tests/Tk creation. There is no GitHub release/deployment/signing credential step. Artifacts expire after3 days; real interactive installer and end-user integration QA remain required.

Windows setup is user-level, refuses to overwrite an executable, and creates no startup entry or credentials. macOS DMGs contain an ad-hoc-signed, unnotarized app for the recorded native architecture; no trusted Developer ID signature is claimed. Linux deb requires Ubuntu24.04/glibc2.39 or compatible runtime, not every Linux distribution. Installers are not executed in CI. NATIVE-BUILD.json records actual platform/architecture/hash/smoke results.

Build dependencies: desktop/requirements-build.txt. Source test command: `python -m unittest discover -s tests -v`. Native package script: scripts/package_native.py. GUI smoke only creates/destroys a temporary Tk window and does not open a game/export/account or create local evidence.
