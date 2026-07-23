import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import process from "node:process";
import luaparse from "luaparse";

const FIXTURE_INSTANT = 1_784_764_800;
const FIXTURE_INSTALLATION_ID = "FixtureSync_0001";
const MAX_GENERIC_ARRAY = 3;
const MAX_DYNAMIC_OBJECT = 4;

const PUBLIC_GUILD_IDENTITIES = Object.freeze({
  main: { key: "main", name: "Raining Embers", realm: "Dalaran", region: 1 },
  alt: {
    key: "alt",
    name: "Raining Embers Alts",
    realm: "Wyrmrest Accord",
    region: 1,
  },
});

const PUBLIC_CONTRACT_STRINGS = new Set([
  "Raining Embers",
  "Raining Embers Alts",
  "Dalaran",
  "Wyrmrest Accord",
  "US",
  "main",
  "alt",
  "guild",
  "account",
  "character",
  "house",
  "neighborhood",
  "session",
  "complete",
  "partial",
  "forbidden",
  "interaction_required",
  "unavailable",
  "unsupported",
  "direct",
  "derived",
  "roster-derived/shared-layout",
  "last_good",
  "event",
  "state",
  "events",
]);

const CONTRACT_VALUE_KEYS = new Set([
  "calendarType",
  "dataset",
  "eventType",
  "faction",
  "factionName",
  "guildKey",
  "inviteStatus",
  "key",
  "kind",
  "modStatus",
  "motdSource",
  "privacyClass",
  "provenance",
  "region",
  "scope",
  "sequenceType",
  "status",
  "type",
  "verificationStatus",
]);

const DYNAMIC_MAP_KEYS = new Set([
  "bags",
  "banks",
  "equipment",
  "items",
  "mapsById",
  "neighborhoodsByGuid",
  "recipeCatalogs",
  "recipes",
]);

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (!name.startsWith("--") || index + 1 >= argv.length) {
      throw new Error(`Expected --name value, received ${name}`);
    }
    options[name.slice(2)] = argv[index + 1];
    index += 1;
  }
  for (const required of ["source", "lua-output", "json-output"]) {
    if (!options[required]) throw new Error(`Missing --${required}`);
  }
  return options;
}

function decodeLuaString(raw) {
  const body = raw.slice(1, -1);
  let output = "";
  for (let index = 0; index < body.length; index += 1) {
    const current = body[index];
    if (current !== "\\") {
      output += current;
      continue;
    }
    const escaped = body[index += 1];
    const simple = {
      a: "\x07",
      b: "\b",
      f: "\f",
      n: "\n",
      r: "\r",
      t: "\t",
      v: "\v",
      "\\": "\\",
      "\"": "\"",
      "'": "'",
    };
    if (Object.hasOwn(simple, escaped)) {
      output += simple[escaped];
      continue;
    }
    if (/[0-9]/u.test(escaped)) {
      let decimal = escaped;
      while (decimal.length < 3 && /[0-9]/u.test(body[index + 1] ?? "")) {
        decimal += body[index += 1];
      }
      output += String.fromCharCode(Number(decimal));
      continue;
    }
    output += escaped;
  }
  return output;
}

function evaluateLiteral(node, sourceStrings) {
  if (node.type === "StringLiteral") {
    const value = decodeLuaString(node.raw);
    sourceStrings.add(value);
    return value;
  }
  if (node.type === "NumericLiteral" || node.type === "BooleanLiteral") return node.value;
  if (node.type === "NilLiteral") return null;
  if (
    node.type === "UnaryExpression"
    && node.operator === "-"
    && node.argument.type === "NumericLiteral"
  ) {
    return -node.argument.value;
  }
  if (node.type !== "TableConstructorExpression") {
    throw new Error(`Executable or unsupported Lua expression: ${node.type}`);
  }

  const output = {};
  let nextArrayIndex = 1;
  for (const field of node.fields) {
    let key;
    if (field.type === "TableKeyString") {
      key = field.key.name;
    } else if (field.type === "TableKey") {
      key = String(evaluateLiteral(field.key, new Set()));
    } else if (field.type === "TableValue") {
      key = String(nextArrayIndex);
      nextArrayIndex += 1;
    } else {
      throw new Error(`Unsupported Lua table field: ${field.type}`);
    }
    if (Object.hasOwn(output, key)) throw new Error(`Duplicate Lua table key: ${key}`);
    output[key] = evaluateLiteral(field.value, sourceStrings);
  }

  const keys = Object.keys(output);
  const dense = keys.length > 0
    && keys.every((key) => /^[1-9][0-9]*$/u.test(key))
    && keys.every((_, index) => Object.hasOwn(output, String(index + 1)));
  return dense ? keys.map((_, index) => output[String(index + 1)]) : output;
}

function parseSavedVariables(source) {
  const ast = luaparse.parse(source, { luaVersion: "5.1" });
  const assignment = ast.body.find((node) =>
    node.type === "AssignmentStatement"
    && node.variables[0]?.type === "Identifier"
    && node.variables[0].name === "EmberSyncDB");
  if (!assignment || assignment.init.length !== 1) {
    throw new Error("Expected one literal EmberSyncDB assignment");
  }
  const sourceStrings = new Set();
  const database = evaluateLiteral(assignment.init[0], sourceStrings);
  return { database, sourceStrings };
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function uniqueSelections(values, predicates, limit) {
  const selected = [];
  const seen = new Set();
  const add = (value) => {
    const index = values.indexOf(value);
    if (index >= 0 && !seen.has(index) && selected.length < limit) {
      seen.add(index);
      selected.push(value);
    }
  };
  for (const predicate of predicates) add(values.find(predicate));
  for (const value of values) add(value);
  return selected;
}

function boundedArray(values, path) {
  const leaf = path.at(-1) ?? "";
  if (path.includes("housing") && ["mapData", "plots", "roster"].includes(leaf)) {
    return values.slice(0, 80);
  }
  if (leaf === "roster") {
    return uniqueSelections(
      values,
      [
        (value) => isRecord(value) && typeof value.note === "string" && value.note.length > 0,
        (value) => isRecord(value) && typeof value.officerNote === "string" && value.officerNote.length > 0,
        (value) => isRecord(value) && value.isOnline === true,
        (value) => isRecord(value) && value.isOnline === false,
      ],
      6,
    );
  }
  if (leaf === "events" && path.includes("calendar")) {
    return uniqueSelections(
      values,
      [
        ...new Set(values.map((value) =>
          isRecord(value) && isRecord(value.info) ? value.info.calendarType : undefined)),
      ].filter((value) => value !== undefined).map((calendarType) =>
        (value) => isRecord(value)
          && isRecord(value.info)
          && value.info.calendarType === calendarType),
      6,
    );
  }
  if (["eventLog", "mapData"].includes(leaf)) return values.slice(0, 8);
  if (leaf === "transactions") return values.slice(0, 3);
  if (leaf === "tabs") {
    return uniqueSelections(
      values,
      [
        (value) => isRecord(value) && Object.keys(value.items ?? {}).length > 0,
        (value) => isRecord(value) && Array.isArray(value.transactions) && value.transactions.length > 0,
      ],
      2,
    );
  }
  return values.slice(0, MAX_GENERIC_ARRAY);
}

function sourceCounts(database) {
  const exports = {};
  for (const guildKey of ["main", "alt"]) {
    const guildExport = database.exports?.[guildKey];
    if (!isRecord(guildExport)) continue;
    const datasets = isRecord(guildExport.datasets) ? guildExport.datasets : {};
    const guild = isRecord(datasets.guild?.payload) ? datasets.guild.payload : {};
    const bank = isRecord(datasets.guild_bank?.payload) ? datasets.guild_bank.payload : {};
    const calendar = isRecord(datasets.calendar?.payload) ? datasets.calendar.payload : {};
    const housingEnvelope = Object.values(datasets).find((value) =>
      isRecord(value) && value.dataset === "housing");
    const housing = isRecord(housingEnvelope?.payload) ? housingEnvelope.payload : {};
    const bankTabs = Array.isArray(bank.tabs) ? bank.tabs : Object.values(bank.tabs ?? {});
    exports[guildKey] = {
      datasets: Object.keys(datasets).length,
      rosterMembers: Array.isArray(guild.roster) ? guild.roster.length : 0,
      guildLogRecords: Array.isArray(guild.eventLog) ? guild.eventLog.length : 0,
      bankTabs: bankTabs.length,
      bankItems: bankTabs.reduce((count, tab) =>
        count + (isRecord(tab)
          ? Array.isArray(tab.items) ? tab.items.length : Object.keys(tab.items ?? {}).length
          : 0), 0),
      bankTransactions: bankTabs.reduce((count, tab) =>
        count + (isRecord(tab) && Array.isArray(tab.transactions) ? tab.transactions.length : 0), 0),
      calendarEvents: Array.isArray(calendar.events) ? calendar.events.length : 0,
      housingRoster: Array.isArray(housing.neighborhood?.roster)
        ? housing.neighborhood.roster.length
        : 0,
      housingMapPlots: Array.isArray(housing.neighborhood?.mapData)
        ? housing.neighborhood.mapData.length
        : 0,
      eventRecords: Object.values(guildExport.events ?? {}).reduce((count, records) =>
        count + (Array.isArray(records) ? records.length : 0), 0),
    };
  }
  return exports;
}

function createSanitizer(referenceCapturedAt) {
  const stringMappings = new Map();
  const guidMappings = new Map();
  let nextString = 1;
  let nextGuid = 1;
  const shiftSeconds = FIXTURE_INSTANT - referenceCapturedAt;

  function syntheticGuid(value) {
    if (!guidMappings.has(value)) {
      const suffix = `F${String(nextGuid).padStart(7, "0")}`;
      nextGuid += 1;
      const prefix = value.split("-")[0];
      const replacement = prefix === "Player"
        ? `Player-9999-${suffix}`
        : prefix === "Guild"
          ? `Guild-9999-${suffix}`
          : prefix === "Housing"
            ? `Housing-9-1-9999-${suffix}`
            : `Fixture-${suffix}`;
      guidMappings.set(value, replacement);
    }
    return guidMappings.get(value);
  }

  function syntheticText(value, key) {
    const mappingKey = `${key}:${value}`;
    if (!stringMappings.has(mappingKey)) {
      const ordinal = String(nextString).padStart(3, "0");
      nextString += 1;
      let replacement = `Fixture text ${ordinal}`;
      if (/motd|message/iu.test(key)) replacement = `Fixture guild message ${ordinal}`;
      else if (/officer.*note/iu.test(key)) replacement = `Fixture officer note ${ordinal}`;
      else if (/note/iu.test(key)) replacement = `Fixture public note ${ordinal}`;
      else if (/name|sender|target|creator|owner/iu.test(key)) replacement = `Fixture Name ${ordinal}`;
      else if (/title/iu.test(key)) replacement = `Fixture Title ${ordinal}`;
      else if (/description|objective|label/iu.test(key)) replacement = `Fixture description ${ordinal}`;
      else if (/url|uri/iu.test(key)) replacement = "https://example.invalid/fixture";
      else if (/itemLink/iu.test(key)) {
        replacement = "|Hitem:19019::::::::|h[Fixture Item]|h";
      }
      stringMappings.set(mappingKey, replacement);
    }
    return stringMappings.get(mappingKey);
  }

  function sanitizeString(value, key, path) {
    if (key === "installationId") return FIXTURE_INSTALLATION_ID;
    if (/^(?:Player|Guild|Housing)-/u.test(value)) return syntheticGuid(value);
    if (PUBLIC_CONTRACT_STRINGS.has(value)) return value;
    if (key === "name" && path.includes("roster")) {
      const placeholder = syntheticText(value, key);
      const ordinal = placeholder.match(/[0-9]+/u)?.[0] ?? "000";
      const realm = path.includes("alt") ? "WyrmrestAccord" : "Dalaran";
      return `Fixture${ordinal}-${realm}`;
    }
    if (
      CONTRACT_VALUE_KEYS.has(key)
      && /^[A-Za-z0-9_.:/ -]{1,96}$/u.test(value)
    ) {
      return value;
    }
    if (key === "reason" || key === "opportunity" || key === "actionNeeded") {
      return "fixture_reason";
    }
    return syntheticText(value, key);
  }

  function sanitizeNumber(value, key, path) {
    if (value >= 946_684_800_000 && value <= 4_102_444_800_000) {
      return value + shiftSeconds * 1_000;
    }
    if (value >= 946_684_800 && value <= 4_102_444_800) {
      return value + shiftSeconds;
    }
    if (path.includes("calendar") && key === "year") return 2026;
    if (path.includes("calendar") && key === "month") return 7;
    if (path.includes("calendar") && key === "monthDay") return 24;
    return value;
  }

  function sanitizeKey(key) {
    if (/^(?:Player|Guild|Housing)-/u.test(key)) return syntheticGuid(key);
    const guidSuffix = key.match(/^(.*:)((?:Player|Guild|Housing)-.+)$/u);
    if (guidSuffix) return `${guidSuffix[1]}${syntheticGuid(guidSuffix[2])}`;
    return key;
  }

  function sanitizeValue(value, path = []) {
    const key = path.at(-1) ?? "";
    if (typeof value === "string") return sanitizeString(value, key, path);
    if (typeof value === "number") return sanitizeNumber(value, key, path);
    if (value === null || typeof value === "boolean") return value;
    if (Array.isArray(value)) {
      return boundedArray(value, path).map((entry, index) =>
        sanitizeValue(entry, [...path, String(index)]));
    }
    if (!isRecord(value)) return null;

    let entries = Object.entries(value);
    if (
      DYNAMIC_MAP_KEYS.has(key)
      || (entries.length > 20
        && entries.filter(([entryKey]) =>
          /^[0-9]+$/u.test(entryKey) || /^(?:Player|Guild|Housing)-/u.test(entryKey)).length
          > entries.length / 2)
    ) {
      entries = entries.slice(0, MAX_DYNAMIC_OBJECT);
    }
    return Object.fromEntries(entries.map(([entryKey, entryValue]) => {
      const safeKey = sanitizeKey(entryKey);
      return [safeKey, sanitizeValue(entryValue, [...path, safeKey])];
    }));
  }

  return { sanitizeValue, syntheticGuid };
}

function normalizeCalendarPayload(payload, coverage) {
  if (!isRecord(payload)) return;
  const sourceEvents = Array.isArray(payload.events)
    ? payload.events
    : Array.isArray(payload.guildEvents)
      ? payload.guildEvents
      : [];
  const guildEvents = sourceEvents.filter((event) =>
    isRecord(event)
      && isRecord(event.info)
      && ["GUILD_EVENT", "GUILD_ANNOUNCEMENT"].includes(event.info.calendarType));
  guildEvents.forEach((event, index) => {
    if (!isRecord(event) || !isRecord(event.info)) return;
    event.privacyClass = "guild";
    const startTime = isRecord(event.info.startTime) ? event.info.startTime : null;
    const endTime = isRecord(event.info.endTime) ? event.info.endTime : null;
    const day = 24 + index;
    if (startTime) {
      Object.assign(startTime, { year: 2026, month: 7, monthDay: day, hour: 18, minute: 0 });
    }
    if (endTime) {
      Object.assign(endTime, { year: 2026, month: 7, monthDay: day, hour: 19, minute: 0 });
    }
    event.day = day;
    event.monthOffset = 0;
  });
  payload.events = guildEvents;
  payload.guildEvents = structuredClone(guildEvents);
  delete payload.personalEvents;
  delete payload.globalEvents;

  if (!isRecord(payload.lastOpenedEvent)
    || !isRecord(payload.lastOpenedEvent.info)
    || !["GUILD_EVENT", "GUILD_ANNOUNCEMENT"].includes(
      payload.lastOpenedEvent.info.calendarType,
    )) {
    delete payload.lastOpenedEvent;
  } else {
    payload.lastOpenedEvent.privacyClass = "guild";
  }

  const openedEventDetails = isRecord(payload.openedEventDetails)
    ? payload.openedEventDetails
    : {};
  payload.openedEventDetails = Object.fromEntries(
    Object.entries(openedEventDetails)
      .filter(([, detail]) =>
        isRecord(detail)
          && isRecord(detail.info)
          && ["GUILD_EVENT", "GUILD_ANNOUNCEMENT"].includes(
            detail.info.calendarType,
          ))
      .map(([key, detail]) => [key, { ...detail, privacyClass: "guild" }]),
  );
  payload.initialization = isRecord(payload.initialization)
    ? payload.initialization
    : {
        openSupported: true,
        openRequested: true,
        readyAt: FIXTURE_INSTANT,
      };

  if (isRecord(coverage)) {
    coverage.eventCount = guildEvents.length;
    coverage.guildEventCount = guildEvents.length;
    coverage.openedEventDetailCount = Object.keys(payload.openedEventDetails).length;
    delete coverage.excludedNonGuildEventCount;
    delete coverage.personalEventCount;
    delete coverage.globalEventCount;
  }
}

function normalizeExport(database, guildKey, sanitizer) {
  const rawExport = database.exports?.[guildKey];
  if (!isRecord(rawExport)) return null;
  const identity = PUBLIC_GUILD_IDENTITIES[guildKey];
  const exportSequence = guildKey === "main" ? 1_000 : 2_000;
  const sourceGuid = sanitizer.syntheticGuid(rawExport.sourceCharacter?.id ?? `Player-${guildKey}`);
  const sourceCharacter = {
    id: sourceGuid,
    name: guildKey === "main" ? "Fixturemain" : "Fixturealt",
    realm: identity.realm,
    rankIndex: Math.min(Number(rawExport.sourceCharacter?.rankIndex ?? 0), 9),
  };
  const output = {
    schemaVersion: 1,
    guild: identity,
    sourceCharacter,
    installationId: FIXTURE_INSTALLATION_ID,
    sequence: exportSequence,
    capturedAt: FIXTURE_INSTANT,
    persistedAt: FIXTURE_INSTANT + 5,
    datasets: {},
    events: {},
    coverage: {},
    collectorHealth: {},
  };

  let datasetSequence = guildKey === "main" ? 100 : 200;
  for (const rawEnvelope of Object.values(rawExport.datasets ?? {})) {
    if (!isRecord(rawEnvelope) || typeof rawEnvelope.dataset !== "string") continue;
    const dataset = rawEnvelope.dataset;
    const scope = rawEnvelope.scope;
    const subjectId = scope === "guild"
      ? guildKey
      : scope === "account"
        ? "account"
        : scope === "character"
          ? sourceGuid
          : sanitizer.sanitizeValue(rawEnvelope.subjectId, ["subjectId"]);
    const envelope = sanitizer.sanitizeValue(rawEnvelope, [
      "exports",
      guildKey,
      "datasets",
      dataset,
    ]);
    Object.assign(envelope, {
      schemaVersion: 1,
      dataset,
      scope,
      subjectId,
      guildKey,
      guild: identity,
      sourceCharacter,
      installationId: FIXTURE_INSTALLATION_ID,
      sequence: datasetSequence,
      capturedAt: FIXTURE_INSTANT + datasetSequence,
    });
    if (isRecord(envelope.coverage)) {
      envelope.coverage.observedAt = envelope.capturedAt;
    }
    if (dataset === "calendar") normalizeCalendarPayload(envelope.payload, envelope.coverage);
    const storageKey = scope === "guild" || scope === "account"
      ? dataset
      : `${dataset}:${subjectId}`;
    output.datasets[storageKey] = envelope;
    output.coverage[storageKey] = envelope.coverage;
    output.collectorHealth[dataset] = {
      lastAttemptAt: envelope.capturedAt,
      lastSuccessAt: envelope.capturedAt,
      consecutiveFailures: 0,
      freshness: "fresh",
      truncation: false,
      interactionRequired: envelope.coverage?.status === "interaction_required",
    };
    datasetSequence += 1;
  }

  for (const [stream, rawEvents] of Object.entries(rawExport.events ?? {})) {
    if (!Array.isArray(rawEvents) || rawEvents.length === 0) continue;
    const selected = rawEvents.slice(0, 3);
    const firstSequence = exportSequence - selected.length + 1;
    output.events[stream] = selected.map((rawEvent, index) => {
      const event = sanitizer.sanitizeValue(rawEvent, [
        "exports",
        guildKey,
        "events",
        stream,
        String(index),
      ]);
      return {
        ...event,
        sequence: firstSequence + index,
        capturedAt: FIXTURE_INSTANT + index,
        guildKey,
        sourceCharacter,
      };
    });
    output.coverage[`events.${stream}`] = {
      status: "partial",
      observedAt: FIXTURE_INSTANT + selected.length - 1,
      reason: "fixture_bounded_event_stream",
      sourceRecordCount: rawEvents.length,
      retainedRecordCount: selected.length,
      truncated: rawEvents.length > selected.length,
    };
  }
  return output;
}

function buildFixture(database) {
  const referenceCapturedAt = Number(database.exports?.main?.capturedAt ?? database.updatedAt);
  if (!Number.isSafeInteger(referenceCapturedAt) || referenceCapturedAt <= 0) {
    throw new Error("Source does not contain a valid reference capture time");
  }
  const counts = sourceCounts(database);
  const sanitizer = createSanitizer(referenceCapturedAt);
  const exports = {};
  for (const guildKey of ["main", "alt"]) {
    const guildExport = normalizeExport(database, guildKey, sanitizer);
    if (guildExport) {
      exports[guildKey] = guildExport;
      const calendar = Object.values(guildExport.datasets)
        .find((envelope) => envelope.dataset === "calendar");
      if (calendar && counts[guildKey]) {
        counts[guildKey].calendarEvents = Array.isArray(calendar.payload?.events)
          ? calendar.payload.events.length
          : 0;
      }
    }
  }
  const observedDatasets = new Set(
    Object.values(exports).flatMap((guildExport) =>
      Object.values(guildExport.datasets).map((envelope) => envelope.dataset)),
  );
  return {
    schemaVersion: 1,
    installationId: FIXTURE_INSTALLATION_ID,
    createdAt: FIXTURE_INSTANT - 86_400,
    updatedAt: FIXTURE_INSTANT,
    fixtureMeta: {
      sanitized: true,
      generatorVersion: 1,
      bounded: true,
      sourceCounts: counts,
      unavailableAtCapture: [
        ...["world_quests"].filter((dataset) => !observedDatasets.has(dataset)),
      ],
    },
    exports,
  };
}

function luaString(value) {
  return JSON.stringify(value)
    .replaceAll("\u2028", "\\n")
    .replaceAll("\u2029", "\\n");
}

function toLua(value, depth = 0) {
  const indent = "    ".repeat(depth);
  const childIndent = "    ".repeat(depth + 1);
  if (value === null) return "nil";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return luaString(value);
  const array = Array.isArray(value);
  const entries = array
    ? value.map((entry, index) => [String(index + 1), entry])
    : Object.entries(value);
  if (entries.length === 0) return "{}";
  const rows = entries.map(([key, entry]) =>
    `${childIndent}[${array ? key : luaString(key)}] = ${toLua(entry, depth + 1)},`);
  return `{\n${rows.join("\n")}\n${indent}}`;
}

function collectContractValues(value, key = "", output = new Set()) {
  if (typeof value === "string") {
    if (CONTRACT_VALUE_KEYS.has(key) || /Apis$/u.test(key)) output.add(value);
    return output;
  }
  if (Array.isArray(value)) {
    value.forEach((entry) => collectContractValues(entry, key, output));
    return output;
  }
  if (isRecord(value)) {
    Object.entries(value).forEach(([entryKey, entry]) =>
      collectContractValues(entry, entryKey, output));
  }
  return output;
}

function sensitiveSourceStrings(sourceStrings, safeSourceStrings) {
  return [...sourceStrings].filter((value) =>
    value.length >= 4
    && !PUBLIC_CONTRACT_STRINGS.has(value)
    && !safeSourceStrings.has(value)
    && !CONTRACT_VALUE_KEYS.has(value)
    && !/^(?:C_|Enum\.|Get|Can|Is|Has)[A-Za-z0-9_.]+$/u.test(value)
    && !/^[a-z][a-z0-9_.-]{0,63}$/u.test(value));
}

function assertSanitized(output, sourceStrings, safeSourceStrings) {
  for (const sourceValue of sensitiveSourceStrings(sourceStrings, safeSourceStrings)) {
    if (output.includes(JSON.stringify(sourceValue))) {
      const digest = createHash("sha256").update(sourceValue).digest("hex").slice(0, 12);
      const classification = /^(?:Player|Guild|Housing)-/u.test(sourceValue)
        ? "guid"
        : /^https?:/u.test(sourceValue)
          ? "url"
          : /^[A-Z0-9_ -]+$/u.test(sourceValue)
            ? "enum"
            : "text";
      throw new Error(
        `Sanitization retained a source value (sha256:${digest}, length:${sourceValue.length}, class:${classification})`,
      );
    }
  }
  if (output.length > 512 * 1024) {
    throw new Error(`Golden fixture exceeds 512 KiB (${output.length} bytes)`);
  }
}

const options = parseArgs(process.argv.slice(2));
const sourcePath = resolve(options.source);
const luaOutput = resolve(options["lua-output"]);
const jsonOutput = resolve(options["json-output"]);
const source = await readFile(sourcePath, "utf8");
const { database, sourceStrings } = parseSavedVariables(source);
const safeSourceStrings = collectContractValues(database);
const fixture = buildFixture(database);
const json = `${JSON.stringify(fixture, null, 2)}\n`;
const lua = `EmberSyncDB = ${toLua(fixture)}\n`;
assertSanitized(json, sourceStrings, safeSourceStrings);
assertSanitized(lua, sourceStrings, safeSourceStrings);
await writeFile(luaOutput, lua, "utf8");
await writeFile(jsonOutput, json, "utf8");
process.stdout.write(JSON.stringify({
  sanitized: true,
  luaOutput: luaOutput.slice(dirname(luaOutput).length + 1),
  jsonOutput: jsonOutput.slice(dirname(jsonOutput).length + 1),
  bytes: { lua: Buffer.byteLength(lua), json: Buffer.byteLength(json) },
  exports: Object.keys(fixture.exports),
  unavailableAtCapture: fixture.fixtureMeta.unavailableAtCapture,
}) + "\n");
