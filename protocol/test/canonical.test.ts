import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

import {
  canonicalJson,
  canonicalJsonSha256,
  sha256HexUtf8,
} from "../src/index.js";

test("canonical envelope hash matches the cross-language fixture", async () => {
  const fixtureUrl = new URL("../../fixtures/canonical-envelope-v1.json", import.meta.url);
  const expectedUrl = new URL("../../fixtures/canonical-envelope-v1.sha256", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8"));
  const expected = (await readFile(expectedUrl, "utf8")).trim();
  assert.equal(await canonicalJsonSha256(fixture), expected);
});

test("canonical JSON recursively sorts object keys", () => {
  assert.equal(
    canonicalJson({ z: [3, { y: true, x: null }], a: "ember" }),
    '{"a":"ember","z":[3,{"x":null,"y":true}]}',
  );
});

test("canonical hashing is stable", async () => {
  const expected = "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777";
  assert.equal(await canonicalJsonSha256({ b: 2, a: 1 }), expected);
  assert.equal(await sha256HexUtf8('{"a":1,"b":2}'), expected);
});

test("canonical JSON follows JCS number formatting and UTF-16 key ordering", () => {
  assert.equal(
    canonicalJson({
      "\ufffd": "replacement",
      "\ud83d\ude00": "astral",
      numbers: [
        -0,
        1e-7,
        1e-6,
        1e15,
        1e16,
        1e20,
        1e21,
        0.03921568766236305,
        83.33333587646484,
        280.0625,
      ],
    }),
    '{"numbers":[0,1e-7,0.000001,1000000000000000,10000000000000000,100000000000000000000,1e+21,0.03921568766236305,83.33333587646484,280.0625],"😀":"astral","�":"replacement"}',
  );
});

test("canonical JSON rejects non-JSON and ambiguous structures", () => {
  assert.throws(() => canonicalJson({ bad: Number.NaN }), /NaN/u);
  const sparse: unknown[] = [];
  sparse.length = 1;
  assert.throws(() => canonicalJson(sparse as never), /sparse/u);
  assert.throws(
    () => canonicalJson({ createdAt: new Date() } as never),
    /plain or null prototype/u,
  );
});
