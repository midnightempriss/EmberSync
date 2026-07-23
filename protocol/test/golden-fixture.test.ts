import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { validateEmberSyncSavedVariablesV1 } from "../src/validation.js";

interface GoldenFixture {
  installationId: string;
  fixtureMeta: {
    sanitized: boolean;
    bounded: boolean;
    sourceCounts: {
      main: {
        rosterMembers: number;
        bankItems: number;
        bankTransactions: number;
        calendarEvents: number;
        housingRoster: number;
        eventRecords: number;
      };
    };
    unavailableAtCapture: string[];
  };
  exports: Record<string, {
    datasets: Record<string, {
      dataset: string;
      payload: Record<string, unknown>;
    }>;
    events: Record<string, unknown[]>;
  }>;
}

test("sanitized real-shape SavedVariables fixture satisfies the public addon contract", async () => {
  const fixtureUrl = new URL("../../fixtures/embersync-saved-variables-v1.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8")) as GoldenFixture;
  const validated = validateEmberSyncSavedVariablesV1(fixture);
  assert.equal(
    validated.ok,
    true,
    validated.ok ? undefined : JSON.stringify(validated.issues),
  );

  assert.match(fixture.installationId, /^[A-Za-z0-9_-]{16}$/u);
  assert.equal(fixture.fixtureMeta.sanitized, true);
  assert.equal(fixture.fixtureMeta.bounded, true);
  assert.deepEqual(Object.keys(fixture.exports).sort(), ["alt", "main"]);

  const main = fixture.exports["main"];
  assert.ok(main);
  const datasets = new Set(Object.values(main.datasets).map(({ dataset }) => dataset));
  for (const dataset of ["guild", "guild_bank", "calendar", "housing"]) {
    assert.ok(datasets.has(dataset), `fixture is missing ${dataset}`);
  }
  assert.equal(main.events["guild_chat"]?.length, 3);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.rosterMembers > 100);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.bankItems > 100);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.bankTransactions > 10);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.calendarEvents > 10);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.housingRoster > 10);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.eventRecords > 10);
  assert.deepEqual(fixture.fixtureMeta.unavailableAtCapture, ["world_quests"]);
});
