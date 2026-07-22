import {
  ALLOWED_GUILDS,
  isCanonicalGuildClaim,
  isGuildKey,
  type CanonicalGuildIdentity,
} from "./guilds.js";
import { isSha256Hex } from "./canonical.js";
import {
  COVERAGE_STATUSES,
  DATASET_NAMES_V1,
  EVENT_DATASET_NAMES_V1,
  STATE_DATASET_NAMES_V1,
  type AddonDatasetEnvelopeV1,
  type AddonCoverageV1,
  type AddonEventV1,
  type AddonGuildIdentityV1,
  type AddonSourceCharacterV1,
  type CoverageV1,
  type DatasetEnvelopeV1,
  type DatasetNameV1,
  type EmberSyncSavedVariablesV1,
  type JsonValue,
  type PermissionEvidenceV1,
  type SavedVariablesGuildExportV1,
  type StateDatasetNameV1,
  type EventDatasetNameV1,
  type SourceCharacterV1,
  type SyncManifestV1,
} from "./types.js";
import { PROTOCOL_VERSION, SCHEMA_VERSION } from "./version.js";

export interface ValidationIssue {
  readonly path: string;
  readonly code: string;
  readonly message: string;
}

export type ValidationResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly issues: readonly ValidationIssue[] };

const DATASET_SET = new Set<string>(DATASET_NAMES_V1);
const STATE_DATASET_SET = new Set<string>(STATE_DATASET_NAMES_V1);
const EVENT_DATASET_SET = new Set<string>(EVENT_DATASET_NAMES_V1);
const COVERAGE_SET = new Set<string>(COVERAGE_STATUSES);
const INSTALLATION_ID_PATTERN = /^[A-Za-z0-9_-]{16,128}$/u;
const CHARACTER_GUID_PATTERN = /^Player-[0-9]+-[0-9A-Fa-f]+$/u;
const SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const UTC_INSTANT_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u;

function isRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function issue(
  issues: ValidationIssue[],
  path: string,
  code: string,
  message: string,
): void {
  issues.push({ path, code, message });
}

function exactKeys(
  record: Record<string, unknown>,
  allowed: readonly string[],
  required: readonly string[],
  path: string,
  issues: ValidationIssue[],
): void {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(record)) {
    if (!allowedSet.has(key)) issue(issues, `${path}.${key}`, "unknown_property", "Unknown property");
  }
  for (const key of required) {
    if (!Object.hasOwn(record, key)) issue(issues, `${path}.${key}`, "required", "Required property is missing");
  }
}

function requiredKeys(
  record: Record<string, unknown>,
  required: readonly string[],
  path: string,
  issues: ValidationIssue[],
): void {
  for (const key of required) {
    if (!Object.hasOwn(record, key)) issue(issues, `${path}.${key}`, "required", "Required property is missing");
  }
}

function isNonEmptyString(value: unknown, maxLength = 256): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength;
}

function isSafeNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function isUtcInstant(value: unknown): value is string {
  return (
    typeof value === "string" &&
    UTC_INSTANT_PATTERN.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

export interface JsonValueLimits {
  readonly maxDepth?: number;
  readonly maxNodes?: number;
  readonly maxStringLength?: number;
}

export function isJsonValue(
  value: unknown,
  limits: JsonValueLimits = {},
): value is JsonValue {
  const maxDepth = limits.maxDepth ?? 64;
  const maxNodes = limits.maxNodes ?? 1_000_000;
  const maxStringLength = limits.maxStringLength ?? 2 * 1024 * 1024;
  const active = new WeakSet<object>();
  let nodes = 0;

  const visit = (current: unknown, depth: number): boolean => {
    nodes += 1;
    if (nodes > maxNodes || depth > maxDepth) return false;
    if (current === null || typeof current === "boolean") return true;
    if (typeof current === "string") return current.length <= maxStringLength;
    if (typeof current === "number") return Number.isFinite(current);
    if (typeof current !== "object" || active.has(current)) return false;

    active.add(current);
    try {
      if (Array.isArray(current)) {
        for (let index = 0; index < current.length; index += 1) {
          if (!Object.hasOwn(current, index) || !visit(current[index], depth + 1)) return false;
        }
        return true;
      }
      if (!isRecord(current) || Object.getOwnPropertySymbols(current).length > 0) return false;
      return Object.values(current).every((entry) => visit(entry, depth + 1));
    } finally {
      active.delete(current);
    }
  };

  return visit(value, 0);
}

function validateGuild(
  value: unknown,
  expectedKey: unknown,
  path: string,
  issues: ValidationIssue[],
): value is CanonicalGuildIdentity {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Guild must be an object");
    return false;
  }
  exactKeys(
    value,
    ["key", "name", "slug", "foundingRealm", "realmSlug", "region", "profileUrl"],
    ["key", "name", "slug", "foundingRealm", "realmSlug", "region", "profileUrl"],
    path,
    issues,
  );

  const fieldsAreStrings =
    typeof value["name"] === "string" &&
    typeof value["foundingRealm"] === "string" &&
    typeof value["region"] === "string";
  const claim = fieldsAreStrings
    ? {
        key: value["key"],
        name: value["name"] as string,
        slug: value["slug"],
        foundingRealm: value["foundingRealm"] as string,
        realmSlug: value["realmSlug"],
        region: value["region"] as string,
        profileUrl: value["profileUrl"],
      }
    : undefined;

  if (!claim || !isCanonicalGuildClaim(claim)) {
    issue(issues, path, "invalid_guild", "Guild identity is not an exact allowlisted Raining Embers identity");
    return false;
  }
  if (claim.key !== expectedKey) {
    issue(issues, path, "guild_key_mismatch", "guildKey and guild.key must agree");
    return false;
  }
  return true;
}

function validateAddonGuild(
  value: unknown,
  expectedKey: unknown,
  path: string,
  issues: ValidationIssue[],
): value is AddonGuildIdentityV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Addon guild must be an object");
    return false;
  }
  requiredKeys(value, ["key", "name", "realm", "region"], path, issues);
  if (!isGuildKey(value["key"]) || value["key"] !== expectedKey) {
    issue(issues, `${path}.key`, "guild_key_mismatch", "Addon guild key must match its export scope");
    return false;
  }
  const canonical = ALLOWED_GUILDS[value["key"]];
  if (
    value["name"] !== canonical.name ||
    value["realm"] !== canonical.foundingRealm ||
    value["region"] !== 1
  ) {
    issue(issues, path, "invalid_guild", "Addon guild is not an exact hard-coded Raining Embers tuple");
    return false;
  }
  return true;
}

function validateAddonSourceCharacter(
  value: unknown,
  path: string,
  issues: ValidationIssue[],
): value is AddonSourceCharacterV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Addon source character must be an object");
    return false;
  }
  requiredKeys(value, ["id", "name", "realm", "rankIndex"], path, issues);
  let valid = true;
  if (typeof value["id"] !== "string" || !CHARACTER_GUID_PATTERN.test(value["id"])) {
    issue(issues, `${path}.id`, "format", "Expected a Player-* character GUID");
    valid = false;
  }
  if (!isNonEmptyString(value["name"], 64)) {
    issue(issues, `${path}.name`, "format", "Character name must be 1-64 characters");
    valid = false;
  }
  if (!isNonEmptyString(value["realm"], 128)) {
    issue(issues, `${path}.realm`, "format", "Character realm must be 1-128 characters");
    valid = false;
  }
  if (!Number.isInteger(value["rankIndex"]) || (value["rankIndex"] as number) < 0 || (value["rankIndex"] as number) > 9) {
    issue(issues, `${path}.rankIndex`, "format", "rankIndex must be an integer from 0 through 9");
    valid = false;
  }
  return valid;
}

function validateSourceCharacter(
  value: unknown,
  path: string,
  issues: ValidationIssue[],
): value is SourceCharacterV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Source character must be an object");
    return false;
  }
  exactKeys(value, ["guid", "name", "realm", "realmSlug"], ["guid", "name", "realm", "realmSlug"], path, issues);
  let valid = true;
  if (typeof value["guid"] !== "string" || !CHARACTER_GUID_PATTERN.test(value["guid"])) {
    issue(issues, `${path}.guid`, "format", "Expected a Player-* character GUID");
    valid = false;
  }
  if (!isNonEmptyString(value["name"], 64)) {
    issue(issues, `${path}.name`, "format", "Character name must be 1-64 characters");
    valid = false;
  }
  if (!isNonEmptyString(value["realm"], 128)) {
    issue(issues, `${path}.realm`, "format", "Character realm must be 1-128 characters");
    valid = false;
  }
  if (typeof value["realmSlug"] !== "string" || !SLUG_PATTERN.test(value["realmSlug"])) {
    issue(issues, `${path}.realmSlug`, "format", "Character realmSlug must be a lowercase slug");
    valid = false;
  }
  return valid;
}

function validateCoverage(
  value: unknown,
  path: string,
  issues: ValidationIssue[],
): value is CoverageV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Coverage must be an object");
    return false;
  }
  exactKeys(
    value,
    ["status", "observedAt", "reasonCode", "detail", "recordCount", "evictedBefore", "metadata"],
    ["status", "observedAt"],
    path,
    issues,
  );
  let valid = true;
  if (typeof value["status"] !== "string" || !COVERAGE_SET.has(value["status"])) {
    issue(issues, `${path}.status`, "enum", "Unknown coverage status");
    valid = false;
  }
  if (!isUtcInstant(value["observedAt"])) {
    issue(issues, `${path}.observedAt`, "format", "Expected an RFC 3339 UTC instant");
    valid = false;
  }
  if (value["reasonCode"] !== undefined && !isNonEmptyString(value["reasonCode"], 128)) {
    issue(issues, `${path}.reasonCode`, "format", "reasonCode must be 1-128 characters");
    valid = false;
  }
  if (value["detail"] !== undefined && !isNonEmptyString(value["detail"], 1024)) {
    issue(issues, `${path}.detail`, "format", "detail must be 1-1024 characters");
    valid = false;
  }
  if (value["recordCount"] !== undefined && !isSafeNonNegativeInteger(value["recordCount"])) {
    issue(issues, `${path}.recordCount`, "format", "recordCount must be a non-negative safe integer");
    valid = false;
  }
  if (value["evictedBefore"] !== undefined && !isUtcInstant(value["evictedBefore"])) {
    issue(issues, `${path}.evictedBefore`, "format", "Expected an RFC 3339 UTC instant");
    valid = false;
  }
  if (value["metadata"] !== undefined && (!isRecord(value["metadata"]) || !isJsonValue(value["metadata"]))) {
    issue(issues, `${path}.metadata`, "json_value", "metadata must be a bounded JSON object");
    valid = false;
  }
  return valid;
}

function isAddonTimestamp(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) > 0;
}

function validateAddonCoverage(
  value: unknown,
  path: string,
  issues: ValidationIssue[],
): value is AddonCoverageV1 {
  if (!isRecord(value) || !isJsonValue(value)) {
    issue(issues, path, "type", "Addon coverage must be a bounded JSON object");
    return false;
  }
  requiredKeys(value, ["status", "observedAt"], path, issues);
  let valid = true;
  if (typeof value["status"] !== "string" || !COVERAGE_SET.has(value["status"])) {
    issue(issues, `${path}.status`, "enum", "Unknown coverage status");
    valid = false;
  }
  if (!isAddonTimestamp(value["observedAt"])) {
    issue(issues, `${path}.observedAt`, "format", "Addon observedAt must be positive Unix epoch seconds");
    valid = false;
  }
  if (value["reason"] !== undefined && !isNonEmptyString(value["reason"], 128)) {
    issue(issues, `${path}.reason`, "format", "reason must be 1-128 characters");
    valid = false;
  }
  return valid;
}

function validatePermissionEvidence(
  value: unknown,
  path: string,
  issues: ValidationIssue[],
): value is PermissionEvidenceV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Permission evidence must be an object");
    return false;
  }
  exactKeys(
    value,
    ["observedAt", "guildRankIndex", "guildRankName", "canViewOfficerNote", "canUseOfficerChat", "guildBankTabs", "metadata"],
    ["observedAt", "guildRankIndex"],
    path,
    issues,
  );
  let valid = true;
  if (!isUtcInstant(value["observedAt"])) {
    issue(issues, `${path}.observedAt`, "format", "Expected an RFC 3339 UTC instant");
    valid = false;
  }
  if (!isSafeNonNegativeInteger(value["guildRankIndex"]) || (value["guildRankIndex"] as number) > 9) {
    issue(issues, `${path}.guildRankIndex`, "format", "Guild rank index must be an integer from 0 through 9");
    valid = false;
  }
  if (value["guildRankName"] !== undefined && !isNonEmptyString(value["guildRankName"], 128)) {
    issue(issues, `${path}.guildRankName`, "format", "Guild rank name must be 1-128 characters");
    valid = false;
  }
  for (const key of ["canViewOfficerNote", "canUseOfficerChat"] as const) {
    if (value[key] !== undefined && typeof value[key] !== "boolean") {
      issue(issues, `${path}.${key}`, "type", `${key} must be boolean`);
      valid = false;
    }
  }
  if (value["guildBankTabs"] !== undefined) {
    if (!Array.isArray(value["guildBankTabs"]) || value["guildBankTabs"].length > 8) {
      issue(issues, `${path}.guildBankTabs`, "format", "guildBankTabs must contain at most 8 entries");
      valid = false;
    } else {
      const seen = new Set<number>();
      value["guildBankTabs"].forEach((tab, index) => {
        const tabPath = `${path}.guildBankTabs[${index}]`;
        if (!isRecord(tab)) {
          issue(issues, tabPath, "type", "Bank-tab evidence must be an object");
          valid = false;
          return;
        }
        exactKeys(tab, ["tabId", "canView", "canDeposit", "remainingWithdrawals"], ["tabId", "canView"], tabPath, issues);
        if (!Number.isInteger(tab["tabId"]) || (tab["tabId"] as number) < 1 || (tab["tabId"] as number) > 8) {
          issue(issues, `${tabPath}.tabId`, "format", "tabId must be 1 through 8");
          valid = false;
        } else if (seen.has(tab["tabId"] as number)) {
          issue(issues, `${tabPath}.tabId`, "duplicate", "Duplicate bank tab");
          valid = false;
        } else {
          seen.add(tab["tabId"] as number);
        }
        if (typeof tab["canView"] !== "boolean") {
          issue(issues, `${tabPath}.canView`, "type", "canView must be boolean");
          valid = false;
        }
        if (tab["canDeposit"] !== undefined && typeof tab["canDeposit"] !== "boolean") {
          issue(issues, `${tabPath}.canDeposit`, "type", "canDeposit must be boolean");
          valid = false;
        }
        if (tab["remainingWithdrawals"] !== undefined && !isSafeNonNegativeInteger(tab["remainingWithdrawals"])) {
          issue(issues, `${tabPath}.remainingWithdrawals`, "format", "remainingWithdrawals must be non-negative");
          valid = false;
        }
      });
    }
  }
  if (value["metadata"] !== undefined && (!isRecord(value["metadata"]) || !isJsonValue(value["metadata"]))) {
    issue(issues, `${path}.metadata`, "json_value", "metadata must be a bounded JSON object");
    valid = false;
  }
  return valid;
}

function validateAddonDatasetEnvelope(
  value: unknown,
  expectedGuildKey: "main" | "alt",
  expectedInstallationId: string | undefined,
  path: string,
  issues: ValidationIssue[],
): value is AddonDatasetEnvelopeV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Addon dataset envelope must be an object");
    return false;
  }
  requiredKeys(
    value,
    ["schemaVersion", "dataset", "scope", "subjectId", "guildKey", "guild", "sourceCharacter", "installationId", "sequence", "capturedAt", "coverage", "payload"],
    path,
    issues,
  );
  let valid = true;
  if (value["schemaVersion"] !== SCHEMA_VERSION) {
    issue(issues, `${path}.schemaVersion`, "schema_unsupported", `Expected schema version ${SCHEMA_VERSION}`);
    valid = false;
  }
  if (typeof value["dataset"] !== "string" || !STATE_DATASET_SET.has(value["dataset"])) {
    issue(issues, `${path}.dataset`, "unknown_dataset", "Addon state dataset is not supported by schema v1");
    valid = false;
  }
  if (!["guild", "character", "account", "house", "neighborhood", "session"].includes(String(value["scope"]))) {
    issue(issues, `${path}.scope`, "enum", "Unknown dataset scope");
    valid = false;
  }
  if (!isNonEmptyString(value["subjectId"], 256)) {
    issue(issues, `${path}.subjectId`, "format", "subjectId must be 1-256 characters");
    valid = false;
  }
  if (value["guildKey"] !== expectedGuildKey) {
    issue(issues, `${path}.guildKey`, "guild_key_mismatch", "Dataset guildKey must match its export");
    valid = false;
  }
  if (!validateAddonGuild(value["guild"], expectedGuildKey, `${path}.guild`, issues)) valid = false;
  if (!validateAddonSourceCharacter(value["sourceCharacter"], `${path}.sourceCharacter`, issues)) valid = false;
  if (typeof value["installationId"] !== "string" || !INSTALLATION_ID_PATTERN.test(value["installationId"])) {
    issue(issues, `${path}.installationId`, "format", "installationId must be 16-128 base64url characters");
    valid = false;
  } else if (expectedInstallationId !== undefined && value["installationId"] !== expectedInstallationId) {
    issue(issues, `${path}.installationId`, "installation_mismatch", "Dataset installationId must match its export");
    valid = false;
  }
  if (!isSafeNonNegativeInteger(value["sequence"])) {
    issue(issues, `${path}.sequence`, "format", "sequence must be a non-negative safe integer");
    valid = false;
  }
  if (!isAddonTimestamp(value["capturedAt"])) {
    issue(issues, `${path}.capturedAt`, "format", "Addon capturedAt must be positive Unix epoch seconds");
    valid = false;
  }
  if (!validateAddonCoverage(value["coverage"], `${path}.coverage`, issues)) valid = false;
  if (value["permissionEvidence"] !== undefined && (!isRecord(value["permissionEvidence"]) || !isJsonValue(value["permissionEvidence"]))) {
    issue(issues, `${path}.permissionEvidence`, "json_value", "Addon permission evidence must be a bounded JSON object");
    valid = false;
  }
  if (!isJsonValue(value["payload"])) {
    issue(issues, `${path}.payload`, "json_value", "payload must be bounded JSON data");
    valid = false;
  }
  return valid;
}

function validateAddonEvent(
  value: unknown,
  expectedGuildKey: "main" | "alt",
  path: string,
  issues: ValidationIssue[],
): value is AddonEventV1 {
  if (!isRecord(value)) {
    issue(issues, path, "type", "Addon event must be an object");
    return false;
  }
  requiredKeys(value, ["sequence", "capturedAt", "guildKey", "sourceCharacter", "payload"], path, issues);
  let valid = true;
  if (!isSafeNonNegativeInteger(value["sequence"])) {
    issue(issues, `${path}.sequence`, "format", "Event sequence must be non-negative");
    valid = false;
  }
  if (!isAddonTimestamp(value["capturedAt"])) {
    issue(issues, `${path}.capturedAt`, "format", "Event capturedAt must be positive Unix epoch seconds");
    valid = false;
  }
  if (value["guildKey"] !== expectedGuildKey) {
    issue(issues, `${path}.guildKey`, "guild_key_mismatch", "Event guildKey must match its export");
    valid = false;
  }
  if (!validateAddonSourceCharacter(value["sourceCharacter"], `${path}.sourceCharacter`, issues)) valid = false;
  if (!isJsonValue(value["payload"])) {
    issue(issues, `${path}.payload`, "json_value", "Event payload must be bounded JSON data");
    valid = false;
  }
  return valid;
}

function validateUploadHeader(
  value: Record<string, unknown>,
  path: string,
  issues: ValidationIssue[],
): boolean {
  let valid = true;
  if (value["schemaVersion"] !== SCHEMA_VERSION) {
    issue(issues, `${path}.schemaVersion`, "schema_unsupported", `Expected schema version ${SCHEMA_VERSION}`);
    valid = false;
  }
  if (value["protocolVersion"] !== PROTOCOL_VERSION) {
    issue(issues, `${path}.protocolVersion`, "protocol_unsupported", `Expected protocol ${PROTOCOL_VERSION}`);
    valid = false;
  }
  if (typeof value["installationId"] !== "string" || !INSTALLATION_ID_PATTERN.test(value["installationId"])) {
    issue(issues, `${path}.installationId`, "format", "installationId must be 16-128 base64url characters");
    valid = false;
  }
  if (!isSafeNonNegativeInteger(value["exportSequence"])) {
    issue(issues, `${path}.exportSequence`, "format", "exportSequence must be a non-negative safe integer");
    valid = false;
  }
  if (!isUtcInstant(value["capturedAt"])) {
    issue(issues, `${path}.capturedAt`, "format", "Expected an RFC 3339 UTC instant");
    valid = false;
  }
  if (!isGuildKey(value["guildKey"])) {
    issue(issues, `${path}.guildKey`, "invalid_guild", "guildKey must be main or alt");
    valid = false;
  }
  if (!validateGuild(value["guild"], value["guildKey"], `${path}.guild`, issues)) valid = false;
  if (!validateSourceCharacter(value["sourceCharacter"], `${path}.sourceCharacter`, issues)) valid = false;
  return valid;
}

function validateSavedVariablesGuildExport(
  input: unknown,
  guildKey: "main" | "alt",
  path: string,
  issues: ValidationIssue[],
): input is SavedVariablesGuildExportV1 {
  if (!isRecord(input)) {
    issue(issues, path, "type", "Guild export must be an object");
    return false;
  }
  requiredKeys(input, ["schemaVersion", "guild", "sourceCharacter", "installationId", "sequence", "capturedAt", "datasets", "events", "coverage"], path, issues);
  let valid = true;
  if (input["schemaVersion"] !== SCHEMA_VERSION) {
    issue(issues, `${path}.schemaVersion`, "schema_unsupported", `Expected schema version ${SCHEMA_VERSION}`);
    valid = false;
  }
  if (!validateAddonGuild(input["guild"], guildKey, `${path}.guild`, issues)) valid = false;
  if (!validateAddonSourceCharacter(input["sourceCharacter"], `${path}.sourceCharacter`, issues)) valid = false;
  const installationId = typeof input["installationId"] === "string" ? input["installationId"] : undefined;
  if (!installationId || !INSTALLATION_ID_PATTERN.test(installationId)) {
    issue(issues, `${path}.installationId`, "format", "installationId must be 16-128 base64url characters");
    valid = false;
  }
  if (!isSafeNonNegativeInteger(input["sequence"])) {
    issue(issues, `${path}.sequence`, "format", "sequence must be a non-negative safe integer");
    valid = false;
  }
  if (!isAddonTimestamp(input["capturedAt"])) {
    issue(issues, `${path}.capturedAt`, "format", "Addon capturedAt must be positive Unix epoch seconds");
    valid = false;
  }
  if (input["persistedAt"] !== undefined && !isUtcInstant(input["persistedAt"])) {
    issue(issues, `${path}.persistedAt`, "format", "Expected an RFC 3339 UTC instant");
    valid = false;
  }
  for (const mapName of ["datasets", "events"] as const) {
    const map = input[mapName];
    if (!isRecord(map)) {
      issue(issues, `${path}.${mapName}`, "type", `${mapName} must be an object`);
      valid = false;
      continue;
    }
    if (mapName === "datasets") {
      for (const [key, envelope] of Object.entries(map)) {
        if (!validateAddonDatasetEnvelope(envelope, guildKey, installationId, `${path}.${mapName}.${key}`, issues)) valid = false;
      }
    } else {
      for (const [stream, events] of Object.entries(map)) {
        if (!Array.isArray(events)) {
          issue(issues, `${path}.events.${stream}`, "type", "Event stream must be an array");
          valid = false;
          continue;
        }
        let previousSequence = -1;
        events.forEach((event, index) => {
          if (!validateAddonEvent(event, guildKey, `${path}.events.${stream}[${index}]`, issues)) valid = false;
          if (isRecord(event) && isSafeNonNegativeInteger(event["sequence"])) {
            if (event["sequence"] as number <= previousSequence) {
              issue(issues, `${path}.events.${stream}[${index}].sequence`, "order", "Event sequences must increase");
              valid = false;
            }
            previousSequence = event["sequence"] as number;
          }
        });
      }
    }
  }
  if (!isRecord(input["coverage"])) {
    issue(issues, `${path}.coverage`, "type", "coverage must be an object");
    valid = false;
  } else {
    for (const [dataset, coverage] of Object.entries(input["coverage"])) {
      if (!isNonEmptyString(dataset, 512)) {
        issue(issues, `${path}.coverage`, "format", "Coverage keys must be non-empty");
        valid = false;
      } else if (!validateAddonCoverage(coverage, `${path}.coverage.${dataset}`, issues)) {
        valid = false;
      }
    }
  }
  return valid;
}

export function validateEmberSyncSavedVariablesV1(input: unknown): ValidationResult<EmberSyncSavedVariablesV1> {
  const issues: ValidationIssue[] = [];
  if (!isRecord(input)) {
    return { ok: false, issues: [{ path: "$", code: "type", message: "EmberSyncDB must be an object" }] };
  }
  requiredKeys(input, ["schemaVersion", "exports"], "$", issues);
  if (input["schemaVersion"] !== SCHEMA_VERSION) issue(issues, "$.schemaVersion", "schema_unsupported", `Expected schema version ${SCHEMA_VERSION}`);
  if (!isRecord(input["exports"])) {
    issue(issues, "$.exports", "type", "exports must be an object");
  } else {
    for (const key of Object.keys(input["exports"])) {
      if (!isGuildKey(key)) issue(issues, `$.exports.${key}`, "invalid_guild", "Only main and alt exports are allowed");
    }
    for (const key of ["main", "alt"] as const) {
      const guildExport = input["exports"][key];
      if (guildExport !== undefined) validateSavedVariablesGuildExport(guildExport, key, `$.exports.${key}`, issues);
    }
  }
  return issues.length === 0
    ? { ok: true, value: input as unknown as EmberSyncSavedVariablesV1 }
    : { ok: false, issues };
}

/** Compatibility alias for callers that previously validated the parsed addon file by this name. */
export const validateSavedVariablesExportV1 = validateEmberSyncSavedVariablesV1;

export function validateDatasetEnvelopeV1(input: unknown): ValidationResult<DatasetEnvelopeV1> {
  const issues: ValidationIssue[] = [];
  if (!isRecord(input)) {
    return { ok: false, issues: [{ path: "$", code: "type", message: "Envelope must be an object" }] };
  }
  exactKeys(
    input,
    ["schemaVersion", "protocolVersion", "dataset", "kind", "scope", "subjectId", "guildKey", "guild", "sourceCharacter", "installationId", "exportSequence", "capturedAt", "coverage", "permissionEvidence", "payloadHash", "payload"],
    ["schemaVersion", "protocolVersion", "dataset", "kind", "scope", "subjectId", "guildKey", "guild", "sourceCharacter", "installationId", "exportSequence", "capturedAt", "coverage", "payloadHash", "payload"],
    "$",
    issues,
  );
  validateUploadHeader(input, "$", issues);
  if (typeof input["dataset"] !== "string" || !DATASET_SET.has(input["dataset"])) {
    issue(issues, "$.dataset", "unknown_dataset", "Dataset is not supported by schema v1");
  }
  if (input["kind"] !== "state" && input["kind"] !== "events") {
    issue(issues, "$.kind", "enum", "kind must be state or events");
  } else if (
    (input["kind"] === "state" && typeof input["dataset"] === "string" && EVENT_DATASET_SET.has(input["dataset"])) ||
    (input["kind"] === "events" && typeof input["dataset"] === "string" && !EVENT_DATASET_SET.has(input["dataset"]))
  ) {
    issue(issues, "$.kind", "dataset_kind_mismatch", "Event dataset names require kind events; state dataset names require kind state");
  }
  if (!["guild", "character", "account", "house", "neighborhood", "session"].includes(String(input["scope"]))) {
    issue(issues, "$.scope", "enum", "Unknown dataset scope");
  }
  if (!isNonEmptyString(input["subjectId"], 256)) {
    issue(issues, "$.subjectId", "format", "subjectId must be 1-256 characters");
  }
  if (
    input["kind"] === "events" &&
    typeof input["installationId"] === "string" &&
    isRecord(input["sourceCharacter"]) &&
    typeof input["sourceCharacter"]["guid"] === "string" &&
    isSafeNonNegativeInteger(input["exportSequence"])
  ) {
    const expectedSubject = `${input["installationId"]}:${input["sourceCharacter"]["guid"]}:${input["exportSequence"]}`;
    if (input["subjectId"] !== expectedSubject) {
      issue(issues, "$.subjectId", "event_subject_mismatch", "Event subjectId must bind installationId, source character GUID, and first sequence");
    }
  }
  validateCoverage(input["coverage"], "$.coverage", issues);
  if (input["permissionEvidence"] !== undefined) validatePermissionEvidence(input["permissionEvidence"], "$.permissionEvidence", issues);
  if (!isSha256Hex(input["payloadHash"])) issue(issues, "$.payloadHash", "format", "Expected lowercase SHA-256 hex");
  if (!isJsonValue(input["payload"])) issue(issues, "$.payload", "json_value", "payload must be bounded JSON data");

  return issues.length === 0
    ? { ok: true, value: input as unknown as DatasetEnvelopeV1 }
    : { ok: false, issues };
}

export function validateSyncManifestV1(input: unknown): ValidationResult<SyncManifestV1> {
  const issues: ValidationIssue[] = [];
  if (!isRecord(input)) {
    return { ok: false, issues: [{ path: "$", code: "type", message: "Manifest must be an object" }] };
  }
  exactKeys(
    input,
    ["schemaVersion", "protocolVersion", "guildKey", "guild", "sourceCharacter", "installationId", "exportSequence", "capturedAt", "segments"],
    ["schemaVersion", "protocolVersion", "guildKey", "guild", "sourceCharacter", "installationId", "exportSequence", "capturedAt", "segments"],
    "$",
    issues,
  );
  validateUploadHeader(input, "$", issues);
  let compressedTotal = 0;
  const uniqueSegments = new Set<string>();

  if (!Array.isArray(input["segments"]) || input["segments"].length === 0 || input["segments"].length > 128) {
    issue(issues, "$.segments", "format", "segments must contain 1-128 entries");
  } else {
    input["segments"].forEach((segment, index) => {
      const path = `$.segments[${index}]`;
      if (!isRecord(segment)) {
        issue(issues, path, "type", "Segment must be an object");
        return;
      }
      exactKeys(segment, ["dataset", "kind", "scope", "subjectId", "coverage", "payloadHash", "envelopeHash", "compressedBytes", "expandedBytes", "eventRange"], ["dataset", "kind", "scope", "subjectId", "coverage", "payloadHash", "envelopeHash", "compressedBytes", "expandedBytes"], path, issues);
      if (typeof segment["dataset"] !== "string" || !DATASET_SET.has(segment["dataset"])) issue(issues, `${path}.dataset`, "unknown_dataset", "Unknown dataset");
      if (segment["kind"] !== "state" && segment["kind"] !== "events") issue(issues, `${path}.kind`, "enum", "kind must be state or events");
      else if (
        (segment["kind"] === "state" && typeof segment["dataset"] === "string" && EVENT_DATASET_SET.has(segment["dataset"])) ||
        (segment["kind"] === "events" && typeof segment["dataset"] === "string" && !EVENT_DATASET_SET.has(segment["dataset"]))
      ) issue(issues, `${path}.kind`, "dataset_kind_mismatch", "Event dataset names require kind events; state dataset names require kind state");
      if (!["guild", "character", "account", "house", "neighborhood", "session"].includes(String(segment["scope"]))) issue(issues, `${path}.scope`, "enum", "Unknown dataset scope");
      if (!isNonEmptyString(segment["subjectId"], 256)) issue(issues, `${path}.subjectId`, "format", "subjectId must be 1-256 characters");
      validateCoverage(segment["coverage"], `${path}.coverage`, issues);
      if (!isSha256Hex(segment["payloadHash"])) issue(issues, `${path}.payloadHash`, "format", "Expected lowercase SHA-256 hex");
      if (!isSha256Hex(segment["envelopeHash"])) issue(issues, `${path}.envelopeHash`, "format", "Expected lowercase SHA-256 hex");
      if (!isSafeNonNegativeInteger(segment["compressedBytes"]) || (segment["compressedBytes"] as number) > 1_048_576) {
        issue(issues, `${path}.compressedBytes`, "payload_too_large", "Compressed segment exceeds 1 MiB");
      } else {
        compressedTotal += segment["compressedBytes"] as number;
      }
      if (!isSafeNonNegativeInteger(segment["expandedBytes"]) || (segment["expandedBytes"] as number) > 8_388_608) issue(issues, `${path}.expandedBytes`, "payload_too_large", "Expanded segment exceeds 8 MiB");

      const uniquenessKey = `${String(segment["dataset"])}:${String(segment["kind"])}:${String(segment["scope"])}:${String(segment["subjectId"])}`;
      if (uniqueSegments.has(uniquenessKey)) issue(issues, path, "duplicate", "Duplicate dataset/kind/scope/subject segment");
      uniqueSegments.add(uniquenessKey);

      if (segment["kind"] === "events") {
        if (!isRecord(segment["eventRange"])) {
          issue(issues, `${path}.eventRange`, "required", "Event segments require an eventRange");
        } else {
          exactKeys(segment["eventRange"], ["firstSequence", "lastSequence"], ["firstSequence", "lastSequence"], `${path}.eventRange`, issues);
          const first = segment["eventRange"]["firstSequence"];
          const last = segment["eventRange"]["lastSequence"];
          if (!isSafeNonNegativeInteger(first) || !isSafeNonNegativeInteger(last) || first > last) issue(issues, `${path}.eventRange`, "format", "Event range must contain ordered non-negative sequences");
          if (
            isSafeNonNegativeInteger(first) &&
            typeof input["installationId"] === "string" &&
            isRecord(input["sourceCharacter"]) &&
            typeof input["sourceCharacter"]["guid"] === "string"
          ) {
            const expectedSubject = `${input["installationId"]}:${input["sourceCharacter"]["guid"]}:${first}`;
            if (segment["subjectId"] !== expectedSubject) {
              issue(issues, `${path}.subjectId`, "event_subject_mismatch", "Event subjectId must bind installationId, source character GUID, and first sequence");
            }
          }
        }
      } else if (segment["eventRange"] !== undefined) {
        issue(issues, `${path}.eventRange`, "forbidden", "State segments cannot contain eventRange");
      }
    });
  }
  if (compressedTotal > 67_108_864) issue(issues, "$.segments", "payload_too_large", "Manifest exceeds the 64 MiB compressed session limit");

  return issues.length === 0
    ? { ok: true, value: input as unknown as SyncManifestV1 }
    : { ok: false, issues };
}

export async function verifyDatasetEnvelopePayloadHashV1(
  envelope: DatasetEnvelopeV1,
): Promise<boolean> {
  const { canonicalJsonSha256 } = await import("./canonical.js");
  return (await canonicalJsonSha256(envelope.payload)) === envelope.payloadHash;
}

export function allowedGuildForKey(key: "main" | "alt"): CanonicalGuildIdentity {
  return ALLOWED_GUILDS[key];
}

export function isDatasetNameV1(value: unknown): value is DatasetNameV1 {
  return typeof value === "string" && DATASET_SET.has(value);
}

export function isStateDatasetNameV1(value: unknown): value is StateDatasetNameV1 {
  return typeof value === "string" && STATE_DATASET_SET.has(value);
}

export function isEventDatasetNameV1(value: unknown): value is EventDatasetNameV1 {
  return typeof value === "string" && EVENT_DATASET_SET.has(value);
}
