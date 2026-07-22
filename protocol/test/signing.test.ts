import assert from "node:assert/strict";
import test from "node:test";

import {
  requestSigningStringV1,
  signedRequestHeadersV1,
} from "../src/index.js";

const BODY_HASH = "0".repeat(64);

test("request signature input is unambiguous across languages", () => {
  assert.equal(
    requestSigningStringV1({
      method: "post",
      requestTarget: "/api/ember-sync/v1/sync/start?mode=normal",
      timestamp: "2026-07-22T12:34:56.000Z",
      nonce: "0123456789abcdef",
      bodyHash: BODY_HASH,
    }),
    [
      "EMBERSYNC-SIGN-V1",
      "POST",
      "/api/ember-sync/v1/sync/start?mode=normal",
      "2026-07-22T12:34:56.000Z",
      "0123456789abcdef",
      BODY_HASH,
    ].join("\n"),
  );
});

test("signed header helper emits fixed lower-case names", () => {
  assert.deepEqual(
    signedRequestHeadersV1({
      deviceId: "device_0123456789",
      timestamp: "2026-07-22T12:34:56Z",
      nonce: "0123456789abcdef",
      bodyHash: BODY_HASH,
      signature: "A".repeat(86),
    }),
    {
      "x-embersync-device-id": "device_0123456789",
      "x-embersync-timestamp": "2026-07-22T12:34:56Z",
      "x-embersync-nonce": "0123456789abcdef",
      "x-embersync-content-sha256": BODY_HASH,
      "x-embersync-signature": "A".repeat(86),
    },
  );
});

test("signing helper rejects CRLF and noncanonical hashes", () => {
  assert.throws(
    () =>
      requestSigningStringV1({
        method: "POST",
        requestTarget: "/safe\nX-Injected: yes",
        timestamp: "2026-07-22T12:34:56Z",
        nonce: "0123456789abcdef",
        bodyHash: BODY_HASH,
      }),
    /single line/u,
  );
  assert.throws(
    () =>
      requestSigningStringV1({
        method: "POST",
        requestTarget: "/safe",
        timestamp: "2026-07-22T12:34:56Z",
        nonce: "0123456789abcdef",
        bodyHash: "A".repeat(64),
      }),
    /lowercase/u,
  );
});
