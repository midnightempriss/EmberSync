import type {
  RequestSigningInputV1,
  Sha256Hex,
  SignedRequestHeadersV1,
} from "./types.js";
import { isSha256Hex } from "./canonical.js";

export const SIGNING_CONTEXT_V1 = "EMBERSYNC-SIGN-V1" as const;

export const SIGNED_HEADER_NAMES_V1 = Object.freeze({
  deviceId: "x-embersync-device-id",
  timestamp: "x-embersync-timestamp",
  nonce: "x-embersync-nonce",
  contentSha256: "x-embersync-content-sha256",
  signature: "x-embersync-signature",
} as const);

function assertSingleLine(label: string, value: string): void {
  if (value.length === 0 || /[\r\n]/u.test(value)) {
    throw new TypeError(`${label} must be a non-empty single line`);
  }
}

export function requestSigningStringV1(input: RequestSigningInputV1): string {
  const method = input.method.toLocaleUpperCase("en-US");
  if (!/^[A-Z]+$/u.test(method)) {
    throw new TypeError("HTTP method must contain ASCII letters only");
  }
  assertSingleLine("Request target", input.requestTarget);
  if (!input.requestTarget.startsWith("/") || input.requestTarget.startsWith("//")) {
    throw new TypeError("Request target must be an origin-form path");
  }
  assertSingleLine("Timestamp", input.timestamp);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u.test(input.timestamp)) {
    throw new TypeError("Timestamp must be an RFC 3339 UTC instant");
  }
  assertSingleLine("Nonce", input.nonce);
  if (!/^[A-Za-z0-9_-]{16,128}$/u.test(input.nonce)) {
    throw new TypeError("Nonce must be 16-128 base64url characters without padding");
  }
  if (!isSha256Hex(input.bodyHash)) {
    throw new TypeError("Body hash must be lowercase SHA-256 hex");
  }

  return [
    SIGNING_CONTEXT_V1,
    method,
    input.requestTarget,
    input.timestamp,
    input.nonce,
    input.bodyHash,
  ].join("\n");
}

export function signedRequestHeadersV1(input: {
  readonly deviceId: string;
  readonly timestamp: string;
  readonly nonce: string;
  readonly bodyHash: Sha256Hex;
  /** Base64url Ed25519 signature without padding. */
  readonly signature: string;
}): SignedRequestHeadersV1 {
  assertSingleLine("Device ID", input.deviceId);
  assertSingleLine("Signature", input.signature);
  // Reuse all timestamp/nonce/hash checks with a harmless request target.
  requestSigningStringV1({
    method: "POST",
    requestTarget: "/",
    timestamp: input.timestamp,
    nonce: input.nonce,
    bodyHash: input.bodyHash,
  });
  if (!/^[A-Za-z0-9_-]{64,128}$/u.test(input.signature)) {
    throw new TypeError("Signature must be base64url without padding");
  }

  return {
    "x-embersync-device-id": input.deviceId,
    "x-embersync-timestamp": input.timestamp,
    "x-embersync-nonce": input.nonce,
    "x-embersync-content-sha256": input.bodyHash,
    "x-embersync-signature": input.signature,
  };
}
