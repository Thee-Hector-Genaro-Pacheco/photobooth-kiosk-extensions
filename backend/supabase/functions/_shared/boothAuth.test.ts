// backend/supabase/functions/_shared/boothAuth.test.ts
//
// Regression guard for the client/server hashing boundary. This is NOT a
// production credential — just a fixed known string both this test and
// the Swift-side BoothAuthHashSelfTest hash independently and compare
// against the same hardcoded expected value, so a future change to either
// implementation that breaks agreement fails loudly instead of silently
// producing 403s again.
//
// Run with: deno test backend/supabase/functions/_shared/boothAuth.test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { sha256Hex } from "./boothAuth.ts";

const KNOWN_TEST_TOKEN = "known-test-token-do-not-use-in-production";
// Computed once via: printf '%s' "$KNOWN_TEST_TOKEN" | shasum -a 256
const EXPECTED_SHA256_HEX = "90c2be4a841f5003c1b1bb136ccf8a7a688d7591e67bbebc19e31d1fdf08feaf";

Deno.test("sha256Hex(KNOWN_TEST_TOKEN) matches the shared fixture hash", async () => {
  const hash = await sha256Hex(KNOWN_TEST_TOKEN);
  assertEquals(hash, EXPECTED_SHA256_HEX);
});
