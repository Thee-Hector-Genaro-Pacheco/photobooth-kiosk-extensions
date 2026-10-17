// backend/supabase/functions/submit-feedback/handler.test.ts
//
// Validation, claim checks, and the one-per-session rule for guest feedback.
// Uses an in-memory store, so no Supabase project is needed.
//
// Run with: deno test backend/supabase/functions/submit-feedback/

import { assertEquals } from "jsr:@std/assert@1";
import { FEEDBACK_CATEGORIES, MAX_COMMENT_LENGTH, parseFeedbackSubmission } from "../_shared/feedback.ts";
import { type FeedbackRow, type FeedbackSession, type FeedbackStore, handleSubmitFeedback } from "./handler.ts";

const NOW = Date.parse("2026-10-16T12:00:00.000Z");
const VALID_TOKEN = "valid-claim-token";
const EXPIRED_TOKEN = "expired-claim-token";
const PREPARING_TOKEN = "preparing-claim-token";

class MemoryStore implements FeedbackStore {
  rows: FeedbackRow[] = [];
  sessions: Record<string, FeedbackSession> = {
    [VALID_TOKEN]: { id: "session-1", eventId: "event-1", status: "ready", expiresAt: "2026-10-30T12:00:00.000Z" },
    [EXPIRED_TOKEN]: { id: "session-2", eventId: "event-1", status: "ready", expiresAt: "2026-10-01T12:00:00.000Z" },
    [PREPARING_TOKEN]: { id: "session-3", eventId: "event-1", status: "preparing", expiresAt: "2026-10-30T12:00:00.000Z" },
  };

  findSessionByClaimToken(claimToken: string) {
    return Promise.resolve(this.sessions[claimToken] ?? null);
  }

  // Mirrors the unique index on feedback_submissions.delivery_session_id.
  insertFeedback(row: FeedbackRow) {
    if (this.rows.some((existing) => existing.delivery_session_id === row.delivery_session_id)) {
      return Promise.resolve({ ok: false as const, duplicate: true, message: "duplicate key" });
    }
    this.rows.push(row);
    return Promise.resolve({ ok: true as const });
  }
}

function post(body: unknown): Request {
  return new Request("http://localhost/submit-feedback", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function submit(store: MemoryStore, body: unknown) {
  const response = await handleSubmitFeedback(post(body), store, () => NOW);
  return { status: response.status, body: await response.json() };
}

const valid = { claimToken: VALID_TOKEN, rating: 4, categories: ["photo_quality", "qr_delivery"], comment: "Loved it" };

Deno.test("rating below 1 is rejected", async () => {
  const store = new MemoryStore();
  for (const rating of [0, -1]) {
    assertEquals((await submit(store, { ...valid, rating })).status, 400);
  }
  assertEquals(store.rows.length, 0);
});

Deno.test("rating above 5 is rejected", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, { ...valid, rating: 6 })).status, 400);
  assertEquals(store.rows.length, 0);
});

Deno.test("non-integer or missing rating is rejected", () => {
  for (const rating of [4.5, "5", null, undefined, Number.NaN]) {
    assertEquals(parseFeedbackSubmission({ ...valid, rating }).ok, false);
  }
});

Deno.test("invalid category is rejected", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, { ...valid, categories: ["photo_quality", "free_prints"] })).status, 400);
  assertEquals((await submit(store, { ...valid, categories: "photo_quality" })).status, 400);
  assertEquals(store.rows.length, 0);
});

Deno.test("the full valid category set is accepted", async () => {
  const store = new MemoryStore();
  const categories = [
    "photo_quality",
    "ai_effects",
    "qr_delivery",
    "print_experience",
    "ease_of_use",
    "something_went_wrong",
  ];
  assertEquals([...FEEDBACK_CATEGORIES], categories);
  assertEquals((await submit(store, { ...valid, categories })).status, 201);
  assertEquals(store.rows[0].categories, categories);
});

Deno.test("an unknown public field is rejected", async () => {
  const store = new MemoryStore();
  for (const key of ["email", "name", "phone", "extra"]) {
    assertEquals((await submit(store, { ...valid, [key]: "x" })).status, 400, `field ${key}`);
  }
  assertEquals(store.rows.length, 0);
});

Deno.test("a client-supplied session or event id is rejected, never used", async () => {
  const store = new MemoryStore();
  for (const key of ["deliverySessionId", "delivery_session_id", "sessionId", "eventId", "event_id"]) {
    assertEquals((await submit(store, { ...valid, [key]: "session-3" })).status, 400, `field ${key}`);
  }
  assertEquals(store.rows.length, 0);
});

Deno.test("oversized comment is rejected", async () => {
  const store = new MemoryStore();
  const response = await submit(store, { ...valid, comment: "a".repeat(MAX_COMMENT_LENGTH + 1) });
  assertEquals(response.status, 400);
  assertEquals(store.rows.length, 0);
});

Deno.test("comment at the limit is accepted, counted in characters not UTF-16 units", () => {
  const emoji = "📸".repeat(MAX_COMMENT_LENGTH); // 2000 UTF-16 units, 1000 characters
  assertEquals(parseFeedbackSubmission({ ...valid, comment: emoji }).ok, true);
});

Deno.test("body over 8 KB is rejected before parsing", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, { ...valid, comment: "a".repeat(9000) })).status, 413);
});

Deno.test("valid feedback is accepted and stored against the token's own session", async () => {
  const store = new MemoryStore();
  const response = await submit(store, { ...valid, consentToAnonymousTestimonial: true });
  assertEquals(response, { status: 201, body: { status: "received" } });
  assertEquals(store.rows, [{
    delivery_session_id: "session-1",
    event_id: "event-1",
    rating: 4,
    categories: ["photo_quality", "qr_delivery"],
    comment: "Loved it",
    consent_to_anonymous_testimonial: true,
    source: "claim_page",
  }]);
});

Deno.test("minimal feedback (rating only) is accepted", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, { claimToken: VALID_TOKEN, rating: 1 })).status, 201);
  assertEquals(store.rows[0].categories, []);
  assertEquals(store.rows[0].comment, null);
});

Deno.test("whitespace-only comment is stored as null and duplicate categories collapse", () => {
  const result = parseFeedbackSubmission({ ...valid, comment: "   ", categories: ["ease_of_use", "ease_of_use"] });
  assertEquals(result.ok && result.value.comment, null);
  assertEquals(result.ok && result.value.categories, ["ease_of_use"]);
});

Deno.test("internal triage fields cannot be supplied by a public request", async () => {
  const store = new MemoryStore();
  const internalFields: Record<string, unknown> = {
    status: "verified",
    classification: "bug",
    actionable: true,
    actionabilityReason: "x",
    productArea: "capture",
    severity: "critical",
    linkedIssue: "#1",
    resolutionNote: "done",
    resolvedAt: "2026-10-16T00:00:00Z",
    source: "admin",
    deliverySessionId: "session-3",
    eventId: "event-2",
    id: "00000000-0000-0000-0000-000000000000",
    createdAt: "2020-01-01T00:00:00Z",
  };
  for (const [key, value] of Object.entries(internalFields)) {
    const response = await submit(store, { ...valid, [key]: value });
    assertEquals(response.status, 400, `field ${key} should be rejected`);
  }
  assertEquals(store.rows.length, 0);
});

Deno.test("invalid, unknown, not-ready, or expired claims cannot submit", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, { ...valid, claimToken: "" })).status, 400);
  assertEquals((await submit(store, { ...valid, claimToken: "x".repeat(300) })).status, 400);
  assertEquals((await submit(store, { ...valid, claimToken: "no-such-token" })).status, 404);
  assertEquals((await submit(store, { ...valid, claimToken: PREPARING_TOKEN })).status, 404);
  assertEquals((await submit(store, { ...valid, claimToken: EXPIRED_TOKEN })), { status: 410, body: { status: "expired" } });
  assertEquals(store.rows.length, 0);
});

Deno.test("one submission per claim: a second submit gets 409 and stores nothing", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, valid)).status, 201);
  assertEquals(await submit(store, { ...valid, rating: 1, comment: "again" }), {
    status: 409,
    body: { status: "already_submitted" },
  });
  assertEquals(store.rows.length, 1);
  assertEquals(store.rows[0].rating, 4);
});

Deno.test("testimonial consent defaults to false and rejects non-booleans", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, valid)).status, 201);
  assertEquals(store.rows[0].consent_to_anonymous_testimonial, false);

  for (const consent of ["true", 1, null]) {
    assertEquals(parseFeedbackSubmission({ ...valid, consentToAnonymousTestimonial: consent }).ok, false);
  }
});

Deno.test("malformed JSON and non-POST methods are rejected", async () => {
  const store = new MemoryStore();
  assertEquals((await submit(store, "{not json")).status, 400);
  assertEquals((await submit(store, [1, 2])).status, 400);
  const get = await handleSubmitFeedback(new Request("http://localhost/submit-feedback"), store, () => NOW);
  assertEquals(get.status, 405);
  const preflight = await handleSubmitFeedback(
    new Request("http://localhost/submit-feedback", { method: "OPTIONS" }),
    store,
    () => NOW,
  );
  assertEquals(preflight.status, 204);
});
