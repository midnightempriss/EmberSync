import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  DATASET_SCOPES_V1,
  EVENT_DATASET_NAMES_V1,
  STATE_DATASET_NAMES_V1,
  isBoundedRawEventDatasetNameV1,
  isBoundedRawStateDatasetNameV1,
} from "../src/index.js";

interface RegistryFixture {
  schemaVersion: number;
  state: Array<{ name: string; scopes: string[] }>;
  events: Array<{ name: string; scopes: string[] }>;
}

test("TypeScript dataset catalog matches the cross-language registry fixture", async () => {
  const fixtureUrl = new URL("../../fixtures/dataset-registry-v1.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8")) as RegistryFixture;
  assert.equal(fixture.schemaVersion, 1);
  assert.deepEqual(fixture.state.map(({ name }) => name), STATE_DATASET_NAMES_V1);
  assert.deepEqual(fixture.events.map(({ name }) => name), EVENT_DATASET_NAMES_V1);
  for (const entry of [...fixture.state, ...fixture.events]) {
    assert.deepEqual(entry.scopes, DATASET_SCOPES_V1[entry.name as keyof typeof DATASET_SCOPES_V1]);
  }
  const schemaUrl = new URL("../../schema/common-v1.schema.json", import.meta.url);
  const schema = JSON.parse(await readFile(schemaUrl, "utf8")) as {
    $defs: {
      stateDatasetName: { enum: string[] };
      eventDatasetName: { enum: string[] };
    };
  };
  assert.deepEqual(schema.$defs.stateDatasetName.enum, STATE_DATASET_NAMES_V1);
  assert.deepEqual(schema.$defs.eventDatasetName.enum, EVENT_DATASET_NAMES_V1);
  assert.equal(isBoundedRawStateDatasetNameV1("future_metric"), true);
  assert.equal(isBoundedRawEventDatasetNameV1("events.future_stream"), true);
  assert.equal(isBoundedRawStateDatasetNameV1("events.future_stream"), false);
  assert.equal(isBoundedRawEventDatasetNameV1("future_stream"), false);
});
