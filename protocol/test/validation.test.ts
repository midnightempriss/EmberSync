import assert from "node:assert/strict";
import test from "node:test";

import {
  createDatasetEnvelopeV1,
  EVENT_DATASET_NAMES_V1,
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
  installationId: "install_0123456789",
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
    futureRootField: "accepted for additive compatibility",
    exports: {
      main: {
        schemaVersion: 1,
        guild,
        sourceCharacter,
        installationId: "install_0123456789",
        sequence: 7,
        capturedAt: 1_753_187_696,
        datasets: { identity: addonEnvelope },
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
  assert.equal(await verifyDatasetEnvelopePayloadHashV1(envelope), true);

  const altered = { ...envelope, payload: { changed: true } };
  assert.equal(await verifyDatasetEnvelopePayloadHashV1(altered), false);
});

test("accepts bounded event dataset names and enforces event kind", async () => {
  assert.deepEqual(EVENT_DATASET_NAMES_V1, ["events.guild_chat", "events.officer_chat"]);
  const stateEnvelope = await createDatasetEnvelopeV1(addonEnvelope, "state");
  const eventEnvelope = {
    ...stateEnvelope,
    dataset: "events.guild_chat",
    kind: "events",
    scope: "guild",
    subjectId: `install_0123456789:${sourceCharacter.id}:8`,
    exportSequence: 8,
  };
  assert.equal(validateDatasetEnvelopeV1(eventEnvelope).ok, true);
  assert.equal(
    validateDatasetEnvelopeV1({ ...eventEnvelope, subjectId: `${sourceCharacter.id}:8` }).ok,
    false,
  );
  assert.equal(validateDatasetEnvelopeV1({ ...eventEnvelope, kind: "state" }).ok, false);
  assert.equal(
    validateDatasetEnvelopeV1({ ...eventEnvelope, dataset: "events.arbitrary" }).ok,
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

  const secondSubject = structuredClone(manifest);
  secondSubject.segments.push({
    ...secondSubject.segments[0]!,
    scope: "character",
    subjectId: "Player-3683-0FEDCBA0",
    envelopeHash: "2".repeat(64),
  });
  assert.equal(validateSyncManifestV1(secondSubject).ok, true);

  const eventManifest = {
    ...manifest,
    segments: [{
      ...manifest.segments[0]!,
      dataset: "events.guild_chat",
      kind: "events",
      subjectId: `install_0123456789:${sourceCharacter.id}:8`,
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

  const tooLarge = structuredClone(manifest);
  tooLarge.segments[0]!.compressedBytes = 1_048_577;
  assert.equal(validateSyncManifestV1(tooLarge).ok, false);
});
