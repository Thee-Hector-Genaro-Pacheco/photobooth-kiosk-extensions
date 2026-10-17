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
import { isValidEngagementAction, isValidSocialCTAPlatform, sha256Hex } from "./boothAuth.ts";

const KNOWN_TEST_TOKEN = "known-test-token-do-not-use-in-production";
// Computed once via: printf '%s' "$KNOWN_TEST_TOKEN" | shasum -a 256
const EXPECTED_SHA256_HEX = "90c2be4a841f5003c1b1bb136ccf8a7a688d7591e67bbebc19e31d1fdf08feaf";

Deno.test("sha256Hex(KNOWN_TEST_TOKEN) matches the shared fixture hash", async () => {
  const hash = await sha256Hex(KNOWN_TEST_TOKEN);
  assertEquals(hash, EXPECTED_SHA256_HEX);
});

// --- Social Claim Funnel v1 validators ------------------------------------
//
// These are the same allowlist checks create-delivery-session and
// record-engagement gate on. Regression-guarding them here means a future
// typo (e.g. adding "instagram_followed" as if it were a real action) fails
// a fast local test instead of silently shipping a false "verified follow."

Deno.test("isValidSocialCTAPlatform accepts every known platform", () => {
  for (const platform of ["instagram", "tiktok", "facebook", "x", "other", "google"]) {
    assertEquals(isValidSocialCTAPlatform(platform), true);
  }
});

Deno.test("isValidSocialCTAPlatform rejects unknown or non-string values", () => {
  assertEquals(isValidSocialCTAPlatform("snapchat"), false);
  assertEquals(isValidSocialCTAPlatform(""), false);
  assertEquals(isValidSocialCTAPlatform(null), false);
  assertEquals(isValidSocialCTAPlatform(undefined), false);
  assertEquals(isValidSocialCTAPlatform(42), false);
});

Deno.test("isValidEngagementAction accepts exactly the three funnel actions", () => {
  for (const action of ["claim_viewed", "social_cta_clicked", "download_clicked"]) {
    assertEquals(isValidEngagementAction(action), true);
  }
});

Deno.test("isValidEngagementAction rejects anything implying a confirmed follow", () => {
  // A social CTA click must never be conflated with a real, API-confirmed
  // follow — these must all be rejected, not just "unrecognized."
  assertEquals(isValidEngagementAction("instagram_followed"), false);
  assertEquals(isValidEngagementAction("verified_follow"), false);
  assertEquals(isValidEngagementAction("instagram_liked"), false);
  assertEquals(isValidEngagementAction("download_completed"), false);
  assertEquals(isValidEngagementAction(""), false);
  assertEquals(isValidEngagementAction(null), false);
});
