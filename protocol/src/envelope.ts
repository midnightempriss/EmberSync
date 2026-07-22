import { canonicalJsonSha256 } from "./canonical.js";
import type {
  AddonDatasetEnvelopeV1,
  AddonCoverageV1,
  CoverageV1,
  DatasetEnvelopeV1,
  DatasetKind,
  JsonValue,
  PermissionEvidenceV1,
  SyncManifestV1,
} from "./types.js";
import { ALLOWED_GUILDS } from "./guilds.js";
import { PROTOCOL_VERSION, SCHEMA_VERSION } from "./version.js";

function unixSecondsToUtc(value: number): string {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new TypeError("Addon timestamp must be positive Unix epoch seconds");
  }
  return new Date(value * 1000).toISOString();
}

export function normalizeAddonCoverageV1(coverage: AddonCoverageV1): CoverageV1 {
  const metadata: Record<string, JsonValue> = {};
  for (const [key, value] of Object.entries(coverage)) {
    if (key !== "status" && key !== "observedAt" && key !== "reason" && value !== undefined) {
      metadata[key] = value;
    }
  }
  return {
    status: coverage.status,
    observedAt: unixSecondsToUtc(coverage.observedAt),
    ...(coverage.reason ? { reasonCode: coverage.reason } : {}),
    ...(Object.keys(metadata).length > 0 ? { metadata } : {}),
  };
}

function normalizeAddonPermissionEvidenceV1(
  raw: Readonly<Record<string, JsonValue>> | undefined,
  sourceRankIndex: number,
  observedAt: string,
): PermissionEvidenceV1 {
  const rankIndex = typeof raw?.["rankIndex"] === "number"
    ? raw["rankIndex"]
    : sourceRankIndex;
  const rankName = typeof raw?.["rankName"] === "string" ? raw["rankName"] : undefined;
  const canViewOfficerNote = typeof raw?.["canViewOfficerNote"] === "boolean"
    ? raw["canViewOfficerNote"]
    : undefined;
  const canUseOfficerChat = typeof raw?.["canUseOfficerChat"] === "boolean"
    ? raw["canUseOfficerChat"]
    : undefined;
  const metadata: Record<string, JsonValue> = {};
  for (const [key, value] of Object.entries(raw ?? {})) {
    if (!["rankIndex", "rankName", "canViewOfficerNote", "canUseOfficerChat"].includes(key)) {
      metadata[key] = value;
    }
  }
  return {
    observedAt,
    guildRankIndex: rankIndex,
    ...(rankName ? { guildRankName: rankName } : {}),
    ...(canViewOfficerNote === undefined ? {} : { canViewOfficerNote }),
    ...(canUseOfficerChat === undefined ? {} : { canUseOfficerChat }),
    ...(Object.keys(metadata).length > 0 ? { metadata } : {}),
  };
}

export async function createDatasetEnvelopeV1(
  source: AddonDatasetEnvelopeV1,
  kind: DatasetKind,
): Promise<DatasetEnvelopeV1> {
  const payloadHash = await canonicalJsonSha256(source.payload);
  const guild = ALLOWED_GUILDS[source.guildKey];
  if (
    source.guild.key !== guild.key ||
    source.guild.name !== guild.name ||
    source.guild.realm !== guild.foundingRealm ||
    source.guild.region !== 1
  ) {
    throw new TypeError("Addon dataset contains a non-allowlisted guild identity");
  }
  const capturedAt = unixSecondsToUtc(source.capturedAt);
  const coverage = normalizeAddonCoverageV1(source.coverage);
  const playerRealmSlug = source.sourceCharacter.realm
    .normalize("NFKC")
    .trim()
    .toLocaleLowerCase("en-US")
    .replace(/['\u2018\u2019\u02BC]/gu, "")
    .replace(/[^a-z0-9]+/gu, "-")
    .replace(/^-|-$/gu, "");
  return {
    schemaVersion: SCHEMA_VERSION,
    protocolVersion: PROTOCOL_VERSION,
    dataset: source.dataset,
    kind,
    scope: source.scope,
    subjectId: source.subjectId,
    guildKey: source.guildKey,
    guild,
    sourceCharacter: {
      guid: source.sourceCharacter.id,
      name: source.sourceCharacter.name,
      realm: source.sourceCharacter.realm,
      realmSlug: playerRealmSlug,
    },
    installationId: source.installationId,
    exportSequence: source.sequence,
    capturedAt,
    coverage,
    permissionEvidence: normalizeAddonPermissionEvidenceV1(
      source.permissionEvidence,
      source.sourceCharacter.rankIndex,
      coverage.observedAt,
    ),
    payloadHash,
    payload: source.payload,
  };
}

export async function datasetEnvelopeHashV1(
  envelope: DatasetEnvelopeV1,
): Promise<string> {
  return canonicalJsonSha256(envelope as unknown as JsonValue);
}

export async function syncManifestHashV1(manifest: SyncManifestV1): Promise<string> {
  return canonicalJsonSha256(manifest as unknown as JsonValue);
}
