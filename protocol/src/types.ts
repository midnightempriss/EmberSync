import type {
  CanonicalGuildIdentity,
  GuildKey,
  Region,
} from "./guilds.js";
import type { ProtocolVersion, SchemaVersion } from "./version.js";

export type JsonPrimitive = null | boolean | number | string;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };

export const COVERAGE_STATUSES = [
  "complete",
  "partial",
  "forbidden",
  "interaction_required",
  "unavailable",
  "unsupported",
] as const;
export type CoverageStatus = (typeof COVERAGE_STATUSES)[number];

export const STATE_DATASET_NAMES_V1 = [
  "auction_house",
  "calendar",
  "character",
  "guild_chat",
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
] as const;
export type StateDatasetNameV1 = (typeof STATE_DATASET_NAMES_V1)[number];

export const EVENT_DATASET_NAMES_V1 = [
  "events.guild_chat",
  "events.officer_chat",
] as const;
export type EventDatasetNameV1 = (typeof EVENT_DATASET_NAMES_V1)[number];

export const DATASET_NAMES_V1 = [
  ...STATE_DATASET_NAMES_V1,
  ...EVENT_DATASET_NAMES_V1,
] as const;
export type DatasetNameV1 = StateDatasetNameV1 | EventDatasetNameV1;

export type DatasetKind = "state" | "events";
export type DatasetScopeV1 =
  | "guild"
  | "character"
  | "account"
  | "house"
  | "neighborhood"
  | "session";

export interface CoverageV1 {
  readonly status: CoverageStatus;
  readonly observedAt: string;
  readonly reasonCode?: string;
  /** Safe diagnostic text. It must not include credentials or private message bodies. */
  readonly detail?: string;
  readonly recordCount?: number;
  readonly evictedBefore?: string;
  readonly metadata?: Readonly<Record<string, JsonValue>>;
}

export interface GuildBankTabPermissionEvidenceV1 {
  readonly tabId: number;
  readonly canView: boolean;
  readonly canDeposit?: boolean;
  readonly remainingWithdrawals?: number;
}

/** Observational metadata only. Servers must never authorize from these fields. */
export interface PermissionEvidenceV1 {
  readonly observedAt: string;
  readonly guildRankIndex: number;
  readonly guildRankName?: string;
  readonly canViewOfficerNote?: boolean;
  readonly canUseOfficerChat?: boolean;
  readonly guildBankTabs?: readonly GuildBankTabPermissionEvidenceV1[];
  /** Additional addon observations; never an authorization source. */
  readonly metadata?: Readonly<Record<string, JsonValue>>;
}

export interface SourceCharacterV1 {
  readonly guid: string;
  readonly name: string;
  readonly realm: string;
  readonly realmSlug: string;
}

/** Compact identity written by the addon. `realm` is always the guild's founding realm. */
export interface AddonGuildIdentityV1 {
  readonly key: GuildKey;
  readonly name: string;
  readonly realm: string;
  /** WoW region enum. US is 1. */
  readonly region: 1;
}

export interface AddonSourceCharacterV1 {
  /** Stable WoW Player-* GUID. */
  readonly id: string;
  readonly name: string;
  readonly realm: string;
  readonly rankIndex: number;
}

export interface AddonDatasetEnvelopeV1 {
  readonly schemaVersion: SchemaVersion;
  readonly dataset: StateDatasetNameV1;
  readonly scope: DatasetScopeV1;
  readonly subjectId: string;
  readonly guildKey: GuildKey;
  readonly guild: AddonGuildIdentityV1;
  readonly sourceCharacter: AddonSourceCharacterV1;
  readonly installationId: string;
  readonly sequence: number;
  /** Unix epoch seconds from GetServerTime/time. */
  readonly capturedAt: number;
  readonly coverage: AddonCoverageV1;
  readonly permissionEvidence?: Readonly<Record<string, JsonValue>>;
  readonly payload: JsonValue;
}

export interface AddonCoverageV1 {
  readonly status: CoverageStatus;
  readonly observedAt: number;
  readonly reason?: string;
  readonly [key: string]: JsonValue | undefined;
}

export interface AddonEventV1 {
  readonly sequence: number;
  readonly capturedAt: number;
  readonly guildKey: GuildKey;
  readonly sourceCharacter: AddonSourceCharacterV1;
  readonly payload: JsonValue;
}

export interface SavedVariablesGuildExportV1 {
  readonly schemaVersion: SchemaVersion;
  readonly guild: AddonGuildIdentityV1;
  readonly sourceCharacter: AddonSourceCharacterV1;
  readonly installationId: string;
  readonly sequence: number;
  readonly capturedAt: number;
  readonly persistedAt?: string;
  readonly datasets: Readonly<Record<string, AddonDatasetEnvelopeV1>>;
  readonly events: Readonly<Record<string, readonly AddonEventV1[]>>;
  readonly coverage: Readonly<Record<string, AddonCoverageV1>>;
}

/** The complete account-level Lua SavedVariables value: `EmberSyncDB`. */
export interface EmberSyncSavedVariablesV1 {
  readonly schemaVersion: SchemaVersion;
  readonly exports: Partial<Record<GuildKey, SavedVariablesGuildExportV1>>;
}

/** @deprecated Prefer EmberSyncSavedVariablesV1 for the parsed addon file. */
export type SavedVariablesExportV1 = SavedVariablesGuildExportV1;

export type Sha256Hex = string;

export interface DatasetEnvelopeV1 {
  readonly schemaVersion: SchemaVersion;
  readonly protocolVersion: ProtocolVersion;
  readonly dataset: DatasetNameV1;
  readonly kind: DatasetKind;
  readonly scope: DatasetScopeV1;
  /** Stable identifier inside scope (for example a Player-* GUID or house ID). */
  readonly subjectId: string;
  readonly guildKey: GuildKey;
  readonly guild: CanonicalGuildIdentity;
  readonly sourceCharacter: SourceCharacterV1;
  readonly installationId: string;
  readonly exportSequence: number;
  readonly capturedAt: string;
  readonly coverage: CoverageV1;
  readonly permissionEvidence?: PermissionEvidenceV1;
  /** SHA-256 of canonical JSON for payload alone. */
  readonly payloadHash: Sha256Hex;
  readonly payload: JsonValue;
}

export type DevicePlatform = "windows" | "macos" | "linux";

export interface PairingStartRequestV1 {
  readonly protocolVersion: ProtocolVersion;
  readonly publicKeyAlgorithm: "Ed25519";
  /** Base64url without padding, containing a 32-byte raw Ed25519 public key. */
  readonly devicePublicKey: string;
  readonly deviceName: string;
  readonly platform: DevicePlatform;
  readonly clientVersion: string;
}

export interface PairingStartResponseV1 {
  readonly deviceCode: string;
  readonly verificationCode: string;
  readonly verificationUri: string;
  readonly expiresAt: string;
  readonly pollIntervalSeconds: number;
}

export interface PairingPollRequestV1 {
  readonly protocolVersion: ProtocolVersion;
  readonly deviceCode: string;
}

export type PairingPollResponseV1 =
  | { readonly status: "pending"; readonly expiresAt: string }
  | { readonly status: "denied" | "expired" }
  | {
      readonly status: "approved";
      readonly deviceId: string;
      readonly uploadScopes: readonly GuildKey[];
      readonly serverTime: string;
    };

export interface DeviceSummaryV1 {
  readonly deviceId: string;
  readonly deviceName: string;
  readonly platform: DevicePlatform;
  readonly uploadScopes: readonly GuildKey[];
  readonly createdAt: string;
  readonly lastSeenAt?: string;
  readonly revokedAt?: string;
}

export interface DeviceListResponseV1 {
  readonly devices: readonly DeviceSummaryV1[];
}

export interface DeviceRevokeRequestV1 {
  readonly deviceId: string;
}

export interface EventRangeV1 {
  readonly firstSequence: number;
  readonly lastSequence: number;
}

export interface SegmentManifestEntryV1 {
  readonly dataset: DatasetNameV1;
  readonly kind: DatasetKind;
  readonly scope: DatasetScopeV1;
  readonly subjectId: string;
  readonly coverage: CoverageV1;
  readonly payloadHash: Sha256Hex;
  /** SHA-256 of canonical JSON for the complete DatasetEnvelopeV1. */
  readonly envelopeHash: Sha256Hex;
  readonly compressedBytes: number;
  readonly expandedBytes: number;
  readonly eventRange?: EventRangeV1;
}

export interface SyncManifestV1 {
  readonly schemaVersion: SchemaVersion;
  readonly protocolVersion: ProtocolVersion;
  readonly guildKey: GuildKey;
  readonly guild: CanonicalGuildIdentity;
  readonly sourceCharacter: SourceCharacterV1;
  readonly installationId: string;
  readonly exportSequence: number;
  readonly capturedAt: string;
  readonly segments: readonly SegmentManifestEntryV1[];
}

export interface SyncStartRequestV1 {
  readonly manifest: SyncManifestV1;
  /** SHA-256 of canonical JSON for manifest. */
  readonly manifestHash: Sha256Hex;
}

export interface SyncStartResponseV1 {
  readonly sessionId: string;
  readonly expiresAt: string;
  readonly missingEnvelopeHashes: readonly Sha256Hex[];
  readonly maxCompressedChunkBytes: 1048576;
  readonly maxExpandedChunkBytes: 8388608;
  readonly remainingCompressedSessionBytes: number;
}

export interface SyncCommitRequestV1 {
  readonly manifestHash: Sha256Hex;
}

export interface SyncCommitResponseV1 {
  readonly status: "committed" | "already_committed";
  readonly committedAt: string;
  readonly acceptedSequence: number;
}

export interface ProtocolErrorV1 {
  readonly error:
    | "invalid_request"
    | "invalid_guild"
    | "not_a_member"
    | "character_not_owned"
    | "character_not_rostered"
    | "device_revoked"
    | "authorization_expired"
    | "signature_invalid"
    | "replay_detected"
    | "schema_unsupported"
    | "hash_mismatch"
    | "payload_too_large"
    | "rate_limited"
    | "provider_unavailable";
  readonly message: string;
  readonly retryAfterSeconds?: number;
}

export interface RequestSigningInputV1 {
  readonly method: string;
  /** Origin-form path including its query string, if any. */
  readonly requestTarget: string;
  /** RFC 3339 UTC instant supplied in X-EmberSync-Timestamp. */
  readonly timestamp: string;
  /** Base64url nonce supplied in X-EmberSync-Nonce. */
  readonly nonce: string;
  /** Lowercase SHA-256 hex of the exact HTTP body bytes. */
  readonly bodyHash: Sha256Hex;
}

export interface SignedRequestHeadersV1 {
  readonly "x-embersync-device-id": string;
  readonly "x-embersync-timestamp": string;
  readonly "x-embersync-nonce": string;
  readonly "x-embersync-content-sha256": Sha256Hex;
  readonly "x-embersync-signature": string;
}

export interface CanonicalGuildIdentityJson extends CanonicalGuildIdentity {
  readonly region: Region;
}
