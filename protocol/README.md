# EmberSync protocol

This package is the versioned contract between the EmberSync WoW addon, desktop
client, and Raining Embers website. Version 1 is deliberately locked to these
guild identities:

- `main`: Raining Embers, Dalaran, US
- `alt`: Raining Embers Alts, Wyrmrest Accord, US

Name-only matches are never sufficient. The addon check is a privacy and user
experience guard; the website must independently verify Battle.net character
ownership and fresh Blizzard roster membership before pairing or accepting an
upload.

## SavedVariables boundary

The Lua file contains one account-level value with this shape:

```text
EmberSyncDB = {
  schemaVersion = 1,
  exports = {
    main = { guild, sourceCharacter, installationId, sequence, capturedAt,
             persistedAt?, datasets, events, coverage },
    alt  = { guild, sourceCharacter, installationId, sequence, capturedAt,
             persistedAt?, datasets, events, coverage }
  }
}
```

Each value in `datasets` is an `AddonDatasetEnvelopeV1`. Each value in `events`
is an ordered array of `AddonEventV1` records. Addon timestamps are Unix epoch
seconds because the WoW API exposes `GetServerTime`; the desktop converts them
to RFC 3339 UTC strings on the HTTP boundary. The addon does not implement
SHA-256. After strict guild validation, the desktop converts a dataset entry to
`DatasetEnvelopeV1`, canonicalizes the payload, and adds `payloadHash`. Event
arrays are packaged into event envelopes by the desktop without changing their
ordered sequence numbers. Upload envelopes and manifest segments retain
`scope` plus `subjectId`; consumers must use both when coalescing so one
character, house, or neighborhood cannot overwrite another.
Append-only event subjects are bound to the installation, source character,
and first event sequence as
`{installationId}:{sourceCharacterGuid}:{firstSequence}`. Runtime validation
requires an exact match, preventing event-range collisions after a reinstall.

Schema v1 keeps state and event identifiers as separate bounded sets. Current
event identifiers are `events.guild_chat` and `events.officer_chat`; arbitrary
`events.*` strings fail validation.

Unknown fields are tolerated for additive compatibility, but version numbers,
dataset names, and the guild tuple are strict. Unknown guild export keys are
always rejected.

## Canonical JSON and hashes

`canonicalJson` accepts only ordinary JSON data, rejects sparse arrays and
non-finite numbers, and sorts object keys lexicographically. `payloadHash` is
lowercase SHA-256 hex of the UTF-8 canonical payload. `envelopeHash` is the same
operation over the full upload envelope. Hashes address the expanded canonical
content; gzip representation differences do not change their identity.

## Request signatures

An authenticated request signs this exact UTF-8 string with Ed25519:

```text
EMBERSYNC-SIGN-V1
METHOD
/origin-form/path?query
RFC3339_UTC_TIMESTAMP
BASE64URL_NONCE
LOWERCASE_BODY_SHA256
```

The body hash covers the exact transmitted bytes. The server must independently
validate device revocation, timestamp freshness, nonce replay, upload scope,
character ownership, and current roster membership.

## Limits

- One compressed segment: 1 MiB
- One expanded segment: 8 MiB
- One sync session: 64 MiB compressed
- One manifest: 128 segments

JSON Schemas under `schema/` mirror the TypeScript contracts for Rust and server
implementations. Runtime validators add cross-field checks that JSON Schema
cannot express conveniently, including outer export key/guild agreement.
