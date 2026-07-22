import assert from "node:assert/strict";
import test from "node:test";

import {
  ALLOWED_GUILDS,
  isCanonicalGuildClaim,
  normalizeGuildName,
  normalizeRealm,
  resolveAllowedGuild,
} from "../src/index.js";

test("normalizes display variations without widening the allowlist", () => {
  assert.equal(normalizeGuildName("  RAINING   EMBERS  "), "raining embers");
  assert.equal(normalizeRealm("Wyrmrest- Accord"), "wyrmrestaccord");
  assert.equal(
    resolveAllowedGuild({
      name: "raining embers alts",
      foundingRealm: "Wyrmrest Accord",
      region: "us",
    })?.key,
    "alt",
  );
});

test("same-name guild on another founding realm is rejected", () => {
  assert.equal(
    resolveAllowedGuild({
      name: "Raining Embers",
      foundingRealm: "Stormrage",
      region: "US",
    }),
    undefined,
  );
});

test("canonical claim requires every hard-coded identifier", () => {
  assert.equal(isCanonicalGuildClaim(ALLOWED_GUILDS.main), true);
  assert.equal(
    isCanonicalGuildClaim({
      ...ALLOWED_GUILDS.main,
      profileUrl: "https://example.invalid/lookalike",
    }),
    false,
  );
  assert.equal(
    isCanonicalGuildClaim({ ...ALLOWED_GUILDS.main, key: "alt" }),
    false,
  );
});
