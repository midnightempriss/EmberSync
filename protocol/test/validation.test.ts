import assert from "node:assert/strict";
import test from "node:test";

import {
  createDatasetEnvelopeV1,
  EVENT_DATASET_NAMES_V1,
  normalizeInstallationIdV1,
  validateDatasetEnvelopeV1,
  validateEmberSyncSavedVariablesV1,
  validateSyncManifestV1,
  verifyDatasetEnvelopePayloadHashV1,
  type AddonDatasetEnvelopeV1,
} from "../src/index.js";

const guild = {
  key: "main",
  name: "Raining Embers",
  realm: "Dalaran",
  region: 1,
} as const;

const sourceCharacter = {
  id: "Player-3683-0ABCDEF0",
  name: "Ember",
  realm: "Stormrage",
  rankIndex: 2,
} as const;

const coverage = {
  status: "complete",
  observedAt: 1_753_187_696,
  recordCount: 1,
} as const;

const addonEnvelope: AddonDatasetEnvelopeV1 = {
  schemaVersion: 1,
  dataset: "guild",
  scope: "guild",
  subjectId: "main",
  guildKey: "main",
  guild,
  sourceCharacter,
  installationId: "AbCdEf0123_-xYz9",
  sequence: 7,
  capturedAt: 1_753_187_696,
  coverage,
  permissionEvidence: {
    rankIndex: 2,
    rankName: "Officer",
  },
  payload: { name: "Raining Embers", memberCount: 125 },
};

function savedVariables(overrides: Record<string, unknown> = {}): unknown {
  return {
    schemaVersion: 1,
    installationId: "AbCdEf0123_-xYz9",
    createdAt: 1_753_187_690,
    updatedAt: 1_753_187_697,
    futureRootField: "accepted for additive compatibility",
    exports: {
      main: {
        schemaVersion: 1,
        guild,
        sourceCharacter,
        installationId: "AbCdEf0123_-xYz9",
        sequence: 8,
        capturedAt: 1_753_187_696,
        persistedAt: 1_753_187_697,
        datasets: { guild: addonEnvelope },
        events: {
          guild_chat: [
            {
              sequence: 8,
              capturedAt: 1_753_187_697,
              guildKey: "main",
              sourceCharacter,
              payload: { type: "guild", message: "For the Embers!" },
            },
          ],
        },
        coverage: { guild: coverage },
        ...overrides,
      },
    },
  };
}

test("accepts the coordinated EmberSyncDB exports.main shape", () => {
  const result = validateEmberSyncSavedVariablesV1(savedVariables());
  assert.equal(result.ok, true, result.ok ? undefined : JSON.stringify(result.issues));
});

test("rejects lookalike guilds and mismatched export keys", () => {
  const wrongRealm = validateEmberSyncSavedVariablesV1(
    savedVariables({ guild: { ...guild, realm: "Stormrage" } }),
  );
  assert.equal(wrongRealm.ok, false);
  assert.ok(!wrongRealm.ok && wrongRealm.issues.some((entry) => entry.code === "invalid_guild"));

  const mismatched = validateEmberSyncSavedVariablesV1({
    schemaVersion: 1,
    exports: { alt: (savedVariables() as { exports: { main: unknown } }).exports.main },
  });
  assert.equal(mismatched.ok, false);
  assert.ok(!mismatched.ok && mismatched.issues.some((entry) => entry.code === "guild_key_mismatch"));
});

test("desktop conversion adds canonical identity and a verified payload hash", async () => {
  const envelope = await createDatasetEnvelopeV1(addonEnvelope, "state");
  const validation = validateDatasetEnvelopeV1(envelope);
  assert.equal(validation.ok, true, validation.ok ? undefined : JSON.stringify(validation.issues));
  assert.equal(envelope.guild.realmSlug, "dalaran");
  assert.equal(envelope.sourceCharacter.guid, sourceCharacter.id);
  assert.equal(envelope.scope, "guild");
  assert.equal(envelope.subjectId, "main");
  assert.equal(envelope.persistedAt, addonEnvelope.capturedAt);
  assert.equal(await verifyDatasetEnvelopePayloadHashV1(envelope), true);

  const altered = { ...envelope, payload: { changed: true } };
  assert.equal(await verifyDatasetEnvelopePayloadHashV1(altered), false);
});

test("accepts bounded event dataset names and enforces event kind", async () => {
  assert.deepEqual(EVENT_DATASET_NAMES_V1, [
    "events.guild_chat",
    "events.officer_chat",
    "events.guild",
    "events.guild_bank",
    "events.guild_presence",
    "events.neighborhood_initiative",
  ]);
  const stateEnvelope = await createDatasetEnvelopeV1(addonEnvelope, "state");
  const eventEnvelope = {
    ...stateEnvelope,
    dataset: "events.guild_chat",
    kind: "events",
    scope: "guild",
    subjectId: `AbCdEf0123_-xYz9:${sourceCharacter.id}:8`,
    exportSequence: 8,
    eventRange: { firstSequence: 8, lastSequence: 8 },
    capturedAt: new Date(coverage.observedAt * 1000).toISOString(),
    payload: {
      events: [{
        sequence: 8,
        capturedAt: coverage.observedAt,
        payload: { message: "sanitized" },
      }],
    },
  };
  assert.equal(validateDatasetEnvelopeV1(eventEnvelope).ok, true);
  assert.equal(
    validateDatasetEnvelopeV1({ ...eventEnvelope, subjectId: `${sourceCharacter.id}:8` }).ok,
    false,
  );
  assert.equal(validateDatasetEnvelopeV1({ ...eventEnvelope, kind: "state" }).ok, false);
  assert.equal(validateDatasetEnvelopeV1({ ...eventEnvelope, eventRange: undefined }).ok, false);
  assert.equal(
    validateDatasetEnvelopeV1({
      ...eventEnvelope,
      subjectId: `AbCdEf0123_-xYz9:${sourceCharacter.id}:7`,
      eventRange: { firstSequence: 7, lastSequence: 8 },
      payload: {
        events: [
          {
            sequence: 7,
            capturedAt: coverage.observedAt - 1,
            payload: { message: "sanitized-1" },
          },
          {
            sequence: 8,
            capturedAt: coverage.observedAt,
            payload: { message: "sanitized-2" },
          },
        ],
      },
    }).ok,
    true,
  );
  assert.equal(
    validateDatasetEnvelopeV1({
      ...eventEnvelope,
      eventRange: { firstSequence: 7, lastSequence: 9 },
    }).ok,
    false,
  );
  assert.equal(validateDatasetEnvelopeV1({ ...eventEnvelope, dataset: "events.arbitrary" }).ok, true);
  assert.equal(validateDatasetEnvelopeV1({ ...eventEnvelope, dataset: "events.Bad-Name" }).ok, false);
  assert.equal(
    validateDatasetEnvelopeV1({
      ...eventEnvelope,
      payload: {
        events: [{
          sequence: 9,
          capturedAt: coverage.observedAt,
          payload: {},
        }],
      },
    }).ok,
    false,
  );
});

test("manifest enforces event ranges and byte limits", async () => {
  const envelope = await createDatasetEnvelopeV1(addonEnvelope, "state");
  const manifest = {
    schemaVersion: 1,
    protocolVersion: "1.0",
    guildKey: "main",
    guild: envelope.guild,
    sourceCharacter: envelope.sourceCharacter,
    installationId: envelope.installationId,
    exportSequence: envelope.exportSequence,
    capturedAt: envelope.capturedAt,
    persistedAt: envelope.persistedAt,
    queuedAt: envelope.persistedAt + 1,
    segments: [
      {
        dataset: envelope.dataset,
        kind: "state",
        scope: envelope.scope,
        subjectId: envelope.subjectId,
        coverage: envelope.coverage,
        payloadHash: envelope.payloadHash,
        envelopeHash: "1".repeat(64),
        compressedBytes: 512,
        expandedBytes: 1024,
      },
    ],
  };
  assert.equal(validateSyncManifestV1(manifest).ok, true);
  assert.equal(validateSyncManifestV1({ ...manifest, queuedAt: 0 }).ok, false);

  const secondSubject = structuredClone(manifest);
  secondSubject.segments.push({
    ...secondSubject.segments[0]!,
    dataset: "character",
    scope: "character",
    subjectId: sourceCharacter.id,
    envelopeHash: "2".repeat(64),
  });
  assert.equal(validateSyncManifestV1(secondSubject).ok, true);

  const eventManifest = {
    ...manifest,
    exportSequence: 8,
    segments: [{
      ...manifest.segments[0]!,
      dataset: "events.guild_chat",
      kind: "events",
      subjectId: `AbCdEf0123_-xYz9:${sourceCharacter.id}:8`,
      eventRange: { firstSequence: 8, lastSequence: 8 },
    }],
  };
  assert.equal(validateSyncManifestV1(eventManifest).ok, true);
  assert.equal(
    validateSyncManifestV1({
      ...eventManifest,
      segments: [{ ...eventManifest.segments[0]!, subjectId: `${sourceCharacter.id}:8` }],
    }).ok,
    false,
  );
  assert.equal(
    validateSyncManifestV1({
      ...eventManifest,
      segments: [{
        ...eventManifest.segments[0]!,
        dataset: "events.future_stream",
      }],
    }).ok,
    true,
  );
  assert.equal(
    validateSyncManifestV1({
      ...eventManifest,
      exportSequence: 9,
    }).ok,
    false,
  );

  const tooLarge = structuredClone(manifest);
  tooLarge.segments[0]!.compressedBytes = 1_048_577;
  assert.equal(validateSyncManifestV1(tooLarge).ok, false);
});

test("normalizes legacy installation ids exactly like Lua and preserves v0.1.4 ids", () => {
  assert.equal(normalizeInstallationIdV1("AbCdEf0123_-xYz9"), "AbCdEf0123_-xYz9");
  assert.equal(normalizeInstallationIdV1("es-123456789-987654321"), "wbnFbgsqo9A0EqyQ");
  assert.equal(normalizeInstallationIdV1("es-legacy-install"), "m4T9HLOW1j5cZmb-");
  assert.match(normalizeInstallationIdV1("legacy-install"), /^[A-Za-z0-9_-]{16}$/u);
});

test("accepts bounded future SavedVariables names for opaque raw-retained upload", async () => {
  const future = structuredClone(savedVariables()) as {
    exports: { main: { datasets: Record<string, unknown>; events: Record<string, unknown> } };
  };
  future.exports.main.datasets[`future_metric:${sourceCharacter.id}`] = {
    ...addonEnvelope,
    dataset: "future_metric",
    scope: "character",
    subjectId: sourceCharacter.id,
  };
  future.exports.main.events["future_event"] = [];
  assert.equal(validateEmberSyncSavedVariablesV1(future).ok, true);

  const ahead = structuredClone(future) as {
    exports: {
      main: {
        sequence: number;
        datasets: Record<string, { sequence: number }>;
        events: Record<string, Array<{ sequence: number }>>;
      };
    };
  };
  ahead.exports.main.datasets["guild"]!.sequence = ahead.exports.main.sequence + 1;
  assert.equal(validateEmberSyncSavedVariablesV1(ahead).ok, false);

  const wrongSubject = structuredClone(future) as {
    exports: { main: { datasets: Record<string, { subjectId: string }> } };
  };
  wrongSubject.exports.main.datasets[`future_metric:${sourceCharacter.id}`]!.subjectId =
    "Player-3683-0BADCAFE";
  assert.equal(validateEmberSyncSavedVariablesV1(wrongSubject).ok, false);

  const registeredEnvelope = await createDatasetEnvelopeV1(addonEnvelope, "state");
  assert.equal(
    validateDatasetEnvelopeV1({
      ...registeredEnvelope,
      dataset: "future_metric",
      scope: "character",
      subjectId: sourceCharacter.id,
    }).ok,
    true,
  );
  assert.equal(
    validateDatasetEnvelopeV1({
      ...registeredEnvelope,
      dataset: "Future-Metric",
      scope: "character",
      subjectId: sourceCharacter.id,
    }).ok,
    false,
  );
  assert.equal(
    validateDatasetEnvelopeV1({
      ...registeredEnvelope,
      persistedAt: 0,
    }).ok,
    false,
  );
});
