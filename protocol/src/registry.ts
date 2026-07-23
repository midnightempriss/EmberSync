/**
 * Protocol v1 dataset catalog.
 *
 * Keep this catalog in lockstep with fixtures/dataset-registry-v1.json. The
 * protocol and Rust test suites both assert parity with that fixture so a
 * dataset cannot be added to only one transport layer.
 */
export const STATE_DATASET_NAMES_V1 = [
  "auction_house",
  "calendar",
  "character",
  "collections",
  "crafting",
  "damage_meter",
  "guild",
  "guild_bank",
  "housing",
  "inventory",
  "mail_metadata",
  "mythic_plus",
  "professions",
  "progression",
  "pvp",
  "world_quests",
] as const;

export const EVENT_DATASET_NAMES_V1 = [
  "events.guild_chat",
  "events.officer_chat",
  "events.guild",
  "events.guild_bank",
  "events.guild_presence",
  "events.neighborhood_initiative",
] as const;

export const DATASET_NAMES_V1 = [
  ...STATE_DATASET_NAMES_V1,
  ...EVENT_DATASET_NAMES_V1,
] as const;

export type StateDatasetNameV1 = (typeof STATE_DATASET_NAMES_V1)[number];
export type EventDatasetNameV1 = (typeof EVENT_DATASET_NAMES_V1)[number];
export type DatasetNameV1 = StateDatasetNameV1 | EventDatasetNameV1;

export const DATASET_SCOPES_V1 = {
  auction_house: ["character"],
  calendar: ["guild"],
  character: ["character"],
  collections: ["account"],
  crafting: ["character"],
  damage_meter: ["character"],
  guild: ["guild"],
  guild_bank: ["guild"],
  housing: ["character"],
  inventory: ["character"],
  mail_metadata: ["character"],
  mythic_plus: ["character"],
  professions: ["character"],
  progression: ["character"],
  pvp: ["character"],
  world_quests: ["character"],
  "events.guild_chat": ["guild"],
  "events.officer_chat": ["guild"],
  "events.guild": ["guild"],
  "events.guild_bank": ["guild"],
  "events.guild_presence": ["guild"],
  "events.neighborhood_initiative": ["guild"],
} as const satisfies Record<DatasetNameV1, readonly DatasetScopeNameV1[]>;

export type DatasetScopeNameV1 =
  | "guild"
  | "character"
  | "account"
  | "house"
  | "neighborhood"
  | "session";

const STATE_DATASET_SET = new Set<string>(STATE_DATASET_NAMES_V1);
const EVENT_DATASET_SET = new Set<string>(EVENT_DATASET_NAMES_V1);
const DATASET_SET = new Set<string>(DATASET_NAMES_V1);
const RAW_STATE_NAME_PATTERN = /^[a-z][a-z0-9_]{0,63}$/u;
const RAW_EVENT_NAME_PATTERN = /^events\.[a-z][a-z0-9_]{0,63}$/u;

export function isDatasetNameV1(value: unknown): value is DatasetNameV1 {
  return typeof value === "string" && DATASET_SET.has(value);
}

export function isStateDatasetNameV1(value: unknown): value is StateDatasetNameV1 {
  return typeof value === "string" && STATE_DATASET_SET.has(value);
}

export function isEventDatasetNameV1(value: unknown): value is EventDatasetNameV1 {
  return typeof value === "string" && EVENT_DATASET_SET.has(value);
}

/** A bounded future state name is uploadable only as encrypted raw-retained data. */
export function isBoundedRawStateDatasetNameV1(value: unknown): value is string {
  return typeof value === "string" && RAW_STATE_NAME_PATTERN.test(value);
}

/** Addon event maps omit the `events.` transport prefix. */
export function isBoundedRawEventStreamNameV1(value: unknown): value is string {
  return typeof value === "string" && RAW_EVENT_NAME_PATTERN.test(`events.${value}`);
}

/** Transport event names include `events.` and remain opaque until registered. */
export function isBoundedRawEventDatasetNameV1(value: unknown): value is string {
  return typeof value === "string" && RAW_EVENT_NAME_PATTERN.test(value);
}

export function datasetAllowsScopeV1(
  dataset: DatasetNameV1,
  scope: DatasetScopeNameV1,
): boolean {
  return (DATASET_SCOPES_V1[dataset] as readonly DatasetScopeNameV1[]).includes(scope);
}
