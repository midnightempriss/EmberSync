const INSTALLATION_ID_PATTERN = /^[A-Za-z0-9_-]{16}$/u;
const BASE64URL_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

function hashLegacyInstallationId(seed: string, initial: number): number {
  let hash = initial >>> 0;
  const bytes = new TextEncoder().encode(seed);
  for (let index = 0; index < bytes.length; index += 1) {
    hash = (Math.imul(hash, 33) + bytes[index]! + index + 1) >>> 0;
  }
  return hash;
}

/**
 * Deterministically upgrades a legacy v1 identifier to the 0.1.4 transport
 * shape. Lua and Rust use the same three seeded 32-bit hashes and big-endian
 * base64url encoding.
 */
export function normalizeInstallationIdV1(value: string): string {
  if (INSTALLATION_ID_PATTERN.test(value)) return value;
  if (value.length < 1 || value.length > 128) {
    throw new TypeError("Legacy installationId must contain 1-128 characters");
  }
  const bytes = new Uint8Array(12);
  [5_381, 52_711, 1_315_423_911].forEach((initial, hashIndex) => {
    const hash = hashLegacyInstallationId(value, initial);
    const offset = hashIndex * 4;
    bytes[offset] = hash >>> 24;
    bytes[offset + 1] = hash >>> 16;
    bytes[offset + 2] = hash >>> 8;
    bytes[offset + 3] = hash;
  });
  let output = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const block = (bytes[index]! << 16) | (bytes[index + 1]! << 8) | bytes[index + 2]!;
    output += BASE64URL_ALPHABET[(block >>> 18) & 63];
    output += BASE64URL_ALPHABET[(block >>> 12) & 63];
    output += BASE64URL_ALPHABET[(block >>> 6) & 63];
    output += BASE64URL_ALPHABET[block & 63];
  }
  return output;
}
