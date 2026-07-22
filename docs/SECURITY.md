# Security policy

## Reporting a vulnerability

Do not post credentials, private guild data, SavedVariables, or proof-of-concept
payloads in a public issue. Contact the Raining Embers site administrators
through <https://rainingembers.org> and include only the minimum information
needed to arrange a private report.

## Security invariants

- The allowed guild identities are hard-coded in the addon, desktop, protocol,
  and site configuration.
- Every upload is bound to a revocable Ed25519 device key and a freshly verified
  Raining Embers member account.
- A claimed source character must be Battle.net-owned by that account and
  currently appear in the claimed Blizzard guild roster.
- Client-provided rank, guild, membership, and permission claims are never
  authorization inputs.
- Upload membership verification fails closed and does not inherit the normal
  website membership grace period.
- Lua SavedVariables are parsed using a bounded literal grammar and are never
  evaluated.
- Queued payloads have no plaintext fallback when secure key storage is absent.
- Nonmember, wrong-guild, revoked, replayed, stale, oversized, and malformed
  uploads are rejected before durable ingestion.

## Supported versions

Security fixes are provided for the latest tagged EmberSync release.
