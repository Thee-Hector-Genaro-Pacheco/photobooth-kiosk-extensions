// backend/supabase/functions/create-delivery-session/expiry.test.ts
//
// Guards the server-side cap on client-requested session expiry.
//
// Run with: deno test backend/supabase/functions/create-delivery-session/expiry.test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { DEFAULT_RETENTION_DAYS, MAX_RETENTION_DAYS, resolveExpiresAt } from "./expiry.ts";

const NOW = new Date("2026-10-14T12:00:00.000Z");
const DAY_MS = 24 * 60 * 60 * 1000;
const daysFromNow = (days: number) => new Date(NOW.getTime() + days * DAY_MS).toISOString();
const DEFAULT = daysFromNow(DEFAULT_RETENTION_DAYS);

Deno.test("past date falls back to the default retention", () => {
  assertEquals(resolveExpiresAt(daysFromNow(-1), NOW), DEFAULT);
});

Deno.test("a date equal to now falls back to the default retention", () => {
  assertEquals(resolveExpiresAt(NOW.toISOString(), NOW), DEFAULT);
});

Deno.test("far-future date falls back to the default retention", () => {
  assertEquals(resolveExpiresAt(daysFromNow(365), NOW), DEFAULT);
  assertEquals(resolveExpiresAt("9999-12-31T23:59:59Z", NOW), DEFAULT);
});

Deno.test("one millisecond past the maximum falls back to the default", () => {
  const justOver = new Date(NOW.getTime() + MAX_RETENTION_DAYS * DAY_MS + 1).toISOString();
  assertEquals(resolveExpiresAt(justOver, NOW), DEFAULT);
});

Deno.test("missing or malformed date falls back to the default retention", () => {
  for (const value of [undefined, null, "", "not a date", 1767225600000, {}]) {
    assertEquals(resolveExpiresAt(value, NOW), DEFAULT);
  }
});

Deno.test("valid in-range date is kept", () => {
  assertEquals(resolveExpiresAt(daysFromNow(1), NOW), daysFromNow(1));
  assertEquals(resolveExpiresAt(daysFromNow(MAX_RETENTION_DAYS), NOW), daysFromNow(MAX_RETENTION_DAYS));
});

Deno.test("in-range date with a time zone offset is normalized to UTC", () => {
  assertEquals(resolveExpiresAt("2026-10-20T05:00:00-07:00", NOW), "2026-10-20T12:00:00.000Z");
});
