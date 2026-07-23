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

interface CalendarFixtureRecord {
  privacyClass?: unknown;
  info?: {
    calendarType?: unknown;
  };
}

function assertGuildCalendarRecord(record: unknown): asserts record is CalendarFixtureRecord {
  assert.ok(record && typeof record === "object" && !Array.isArray(record));
  const calendarRecord = record as CalendarFixtureRecord;
  assert.equal(calendarRecord.privacyClass, "guild");
  assert.ok(
    calendarRecord.info?.calendarType === "GUILD_EVENT"
      || calendarRecord.info?.calendarType === "GUILD_ANNOUNCEMENT",
    `fixture retained non-guild calendar type ${String(calendarRecord.info?.calendarType)}`,
  );
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
  let mainCalendarEventCount = 0;
  for (const [guildKey, guildExport] of Object.entries(fixture.exports)) {
    const calendar = Object.values(guildExport.datasets)
      .find(({ dataset }) => dataset === "calendar");
    assert.ok(calendar, `${guildKey} fixture is missing calendar`);
    const payload = calendar.payload;
    assert.equal("personalEvents" in payload, false);
    assert.equal("globalEvents" in payload, false);
    assert.ok(payload["initialization"] && typeof payload["initialization"] === "object");
    assert.ok(payload["openedEventDetails"] && typeof payload["openedEventDetails"] === "object");

    const events = payload["events"];
    const guildEvents = payload["guildEvents"];
    assert.ok(Array.isArray(events) && events.length > 0);
    assert.ok(Array.isArray(guildEvents));
    assert.deepEqual(guildEvents, events);
    if (guildKey === "main") mainCalendarEventCount = events.length;
    events.forEach(assertGuildCalendarRecord);
    Object.values(payload["openedEventDetails"] as Record<string, unknown>)
      .forEach(assertGuildCalendarRecord);
    if (payload["lastOpenedEvent"] !== undefined) {
      assertGuildCalendarRecord(payload["lastOpenedEvent"]);
    }
  }
  assert.equal(main.events["guild_chat"]?.length, 3);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.rosterMembers > 100);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.bankItems > 100);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.bankTransactions > 10);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.calendarEvents > 0);
  assert.equal(fixture.fixtureMeta.sourceCounts.main.calendarEvents, mainCalendarEventCount);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.housingRoster > 10);
  assert.ok(fixture.fixtureMeta.sourceCounts.main.eventRecords > 10);
  assert.deepEqual(fixture.fixtureMeta.unavailableAtCapture, ["world_quests"]);
});
