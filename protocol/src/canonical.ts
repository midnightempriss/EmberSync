import type { JsonValue, Sha256Hex } from "./types.js";

const encoder = new TextEncoder();

function isPlainObject(value: object): value is Record<string, unknown> {
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

/**
 * Produces deterministic JSON using lexicographically sorted object keys.
 * Non-JSON values, sparse arrays, custom prototypes, and cycles are rejected.
 */
export function canonicalJson(value: JsonValue): string {
  const active = new WeakSet<object>();

  const encode = (current: unknown): string => {
    if (current === null) return "null";

    switch (typeof current) {
      case "boolean":
        return current ? "true" : "false";
      case "string":
        return JSON.stringify(current);
      case "number":
        if (!Number.isFinite(current)) {
          throw new TypeError("Canonical JSON cannot contain NaN or Infinity");
        }
        return JSON.stringify(current);
      case "object":
        break;
      default:
        throw new TypeError(`Canonical JSON cannot contain ${typeof current}`);
    }

    if (active.has(current)) {
      throw new TypeError("Canonical JSON cannot contain cycles");
    }
    active.add(current);

    try {
      if (Array.isArray(current)) {
        const values: string[] = [];
        for (let index = 0; index < current.length; index += 1) {
          if (!Object.hasOwn(current, index)) {
            throw new TypeError("Canonical JSON cannot contain sparse arrays");
          }
          values.push(encode(current[index]));
        }
        return `[${values.join(",")}]`;
      }

      if (!isPlainObject(current)) {
        throw new TypeError("Canonical JSON objects must have a plain or null prototype");
      }
      if (Object.getOwnPropertySymbols(current).length > 0) {
        throw new TypeError("Canonical JSON objects cannot have symbol keys");
      }

      const members = Object.keys(current)
        .sort()
        .map((key) => `${JSON.stringify(key)}:${encode(current[key])}`);
      return `{${members.join(",")}}`;
    } finally {
      active.delete(current);
    }
  };

  return encode(value);
}

export function canonicalJsonBytes(value: JsonValue): Uint8Array {
  return encoder.encode(canonicalJson(value));
}

export async function sha256HexBytes(
  input: Uint8Array | ArrayBuffer,
): Promise<Sha256Hex> {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  // Copy into an ArrayBuffer-backed view so browser and Node BufferSource typings agree.
  const stableBytes = new Uint8Array(bytes.byteLength);
  stableBytes.set(bytes);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", stableBytes.buffer);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function sha256HexUtf8(input: string): Promise<Sha256Hex> {
  return sha256HexBytes(encoder.encode(input));
}

export async function canonicalJsonSha256(value: JsonValue): Promise<Sha256Hex> {
  return sha256HexBytes(canonicalJsonBytes(value));
}

export function isSha256Hex(value: unknown): value is Sha256Hex {
  return typeof value === "string" && /^[0-9a-f]{64}$/u.test(value);
}
