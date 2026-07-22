export const GUILD_KEYS = ["main", "alt"] as const;
export type GuildKey = (typeof GUILD_KEYS)[number];

export type Region = "US";

export interface CanonicalGuildIdentity {
  readonly key: GuildKey;
  readonly name: string;
  readonly slug: string;
  readonly foundingRealm: string;
  readonly realmSlug: string;
  readonly region: Region;
  readonly profileUrl: string;
}

export const ALLOWED_GUILDS = Object.freeze({
  main: Object.freeze({
    key: "main",
    name: "Raining Embers",
    slug: "raining-embers",
    foundingRealm: "Dalaran",
    realmSlug: "dalaran",
    region: "US",
    profileUrl:
      "https://worldofwarcraft.blizzard.com/en-us/guild/us/dalaran/raining-embers",
  }),
  alt: Object.freeze({
    key: "alt",
    name: "Raining Embers Alts",
    slug: "raining-embers-alts",
    foundingRealm: "Wyrmrest Accord",
    realmSlug: "wyrmrest-accord",
    region: "US",
    profileUrl:
      "https://worldofwarcraft.blizzard.com/en-us/guild/us/wyrmrest-accord/raining-embers-alts",
  }),
} satisfies Readonly<Record<GuildKey, CanonicalGuildIdentity>>);

export const SITE_GUILD_CONFIGURATION_KEYS = Object.freeze({
  main: "main",
  alt: "alts",
} satisfies Readonly<Record<GuildKey, "main" | "alts">>);

const APOSTROPHES = /['\u2018\u2019\u02BC]/gu;
const REALM_SEPARATORS = /[\s\-]/gu;

export function normalizeGuildName(value: string): string {
  return value.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleLowerCase("en-US");
}

export function normalizeRealm(value: string): string {
  return value
    .normalize("NFKC")
    .trim()
    .toLocaleLowerCase("en-US")
    .replace(APOSTROPHES, "")
    .replace(REALM_SEPARATORS, "");
}

export function normalizeRegion(value: string): string {
  return value.normalize("NFKC").trim().toLocaleUpperCase("en-US");
}

export function isGuildKey(value: unknown): value is GuildKey {
  return value === "main" || value === "alt";
}

export function getAllowedGuild(key: GuildKey): CanonicalGuildIdentity {
  return ALLOWED_GUILDS[key];
}

export interface GuildLookup {
  readonly name: string;
  /** The guild's founding realm. Never pass the cross-realm player's realm here. */
  readonly foundingRealm: string;
  readonly region: string;
}

export function resolveAllowedGuild(lookup: GuildLookup): CanonicalGuildIdentity | undefined {
  const name = normalizeGuildName(lookup.name);
  const realm = normalizeRealm(lookup.foundingRealm);
  const region = normalizeRegion(lookup.region);

  return GUILD_KEYS.map((key) => ALLOWED_GUILDS[key]).find(
    (guild) =>
      normalizeGuildName(guild.name) === name &&
      normalizeRealm(guild.foundingRealm) === realm &&
      guild.region === region,
  );
}

export interface GuildClaim extends GuildLookup {
  readonly key: unknown;
  readonly slug: unknown;
  readonly realmSlug: unknown;
  readonly profileUrl: unknown;
}

/**
 * Requires both the allowlisted tuple and all canonical identifiers to agree.
 * This is intentionally stricter than name-only membership checks.
 */
export function isCanonicalGuildClaim(claim: GuildClaim): claim is CanonicalGuildIdentity {
  if (!isGuildKey(claim.key)) return false;
  const canonical = ALLOWED_GUILDS[claim.key];
  const resolved = resolveAllowedGuild(claim);

  return (
    resolved?.key === canonical.key &&
    claim.name === canonical.name &&
    claim.foundingRealm === canonical.foundingRealm &&
    claim.region === canonical.region &&
    claim.slug === canonical.slug &&
    claim.realmSlug === canonical.realmSlug &&
    claim.profileUrl === canonical.profileUrl
  );
}
