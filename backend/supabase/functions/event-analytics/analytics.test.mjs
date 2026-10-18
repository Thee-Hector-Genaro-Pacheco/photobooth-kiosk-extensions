// backend/supabase/functions/event-analytics/analytics.test.mjs
//
// Test suite for the Pacific Rising Ops read-only event analytics layer.
//
// Run with:
// node --experimental-strip-types --test backend/supabase/functions/event-analytics/analytics.test.mjs

import test from "node:test";
import assert from "node:assert/strict";

import {
  computeCompareEvents,
  computeDeliveryHealth,
  computeEventSummary,
  computeFeedbackSummary,
  timingSafeEqualString,
  verifyReportingAuth,
} from "./analytics.ts";
import { handleEventAnalytics } from "./handler.ts";

const VALID_KEY = "test-reporting-agent-key-secret-987654";
const EVENT_A = "11111111-1111-4111-8111-111111111111";
const EVENT_B = "22222222-2222-4222-8222-222222222222";
const SESSION_1 = "aaaa0001-0000-4000-8000-000000000001";
const SESSION_2 = "aaaa0002-0000-4000-8000-000000000002";
const SESSION_3 = "aaaa0003-0000-4000-8000-000000000003";

class MockAnalyticsProvider {
  constructor(initialData = {}) {
    this.latestEvent = initialData.latestEvent || {
      operation: "latest_event",
      eventId: EVENT_A,
      lastActivityAt: "2026-10-17T12:00:00.000Z",
      sessionCount: 5,
    };
    this.eventsData = initialData.eventsData || {};
  }

  async getLatestEvent() {
    return this.latestEvent;
  }

  async getEventData(eventId) {
    return (
      this.eventsData[eventId] || {
        sessions: [],
        engagementEvents: [],
        feedbackSubmissions: [],
        mediaItems: [],
        triageRows: [],
      }
    );
  }
}

function makeRequest(body, headers = {}) {
  const reqHeaders = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${VALID_KEY}`,
    ...headers,
  };
  return new Request("http://localhost/event-analytics", {
    method: "POST",
    headers: reqHeaders,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("1. unauthorized request rejected", async () => {
  const provider = new MockAnalyticsProvider();

  // Missing Authorization header
  const reqMissing = new Request("http://localhost/event-analytics", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ operation: "latest_event" }),
  });
  const resMissing = await handleEventAnalytics(reqMissing, provider, VALID_KEY);
  assert.equal(resMissing.status, 401);
  const jsonMissing = await resMissing.json();
  assert.equal(jsonMissing.error, "Unauthorized");

  // Incorrect Bearer token
  const reqWrong = makeRequest({ operation: "latest_event" }, { Authorization: "Bearer wrong-key" });
  const resWrong = await handleEventAnalytics(reqWrong, provider, VALID_KEY);
  assert.equal(resWrong.status, 401);

  // Malformed scheme (Basic instead of Bearer)
  const reqBasic = makeRequest({ operation: "latest_event" }, { Authorization: `Basic ${VALID_KEY}` });
  const resBasic = await handleEventAnalytics(reqBasic, provider, VALID_KEY);
  assert.equal(resBasic.status, 401);

  // Unconfigured server secret fails closed
  const reqUnconfigured = makeRequest({ operation: "latest_event" });
  const resUnconfigured = await handleEventAnalytics(reqUnconfigured, provider, undefined);
  assert.equal(resUnconfigured.status, 401);
});

test("2. malformed operation rejected", async () => {
  const provider = new MockAnalyticsProvider();

  // Missing operation
  const reqNoOp = makeRequest({});
  const resNoOp = await handleEventAnalytics(reqNoOp, provider, VALID_KEY);
  assert.equal(resNoOp.status, 400);
  const jsonNoOp = await resNoOp.json();
  assert.equal(jsonNoOp.error, "Missing operation");

  // Unknown operation
  const reqUnknown = makeRequest({ operation: "destroy_data" });
  const resUnknown = await handleEventAnalytics(reqUnknown, provider, VALID_KEY);
  assert.equal(resUnknown.status, 400);
  const jsonUnknown = await resUnknown.json();
  assert.match(jsonUnknown.error, /Unknown operation/);

  // Malformed JSON body
  const reqBadJson = makeRequest("invalid json text {{{", { "Content-Type": "application/json" });
  const resBadJson = await handleEventAnalytics(reqBadJson, provider, VALID_KEY);
  assert.equal(resBadJson.status, 400);

  // Non-POST method (GET)
  const reqGet = new Request("http://localhost/event-analytics", {
    method: "GET",
    headers: { Authorization: `Bearer ${VALID_KEY}` },
  });
  const resGet = await handleEventAnalytics(reqGet, provider, VALID_KEY);
  assert.equal(resGet.status, 405);
});

test("3. missing eventId rejected where required", async () => {
  const provider = new MockAnalyticsProvider();

  for (const op of ["event_summary", "feedback_summary", "delivery_health"]) {
    // Missing eventId
    const reqMissing = makeRequest({ operation: op });
    const resMissing = await handleEventAnalytics(reqMissing, provider, VALID_KEY);
    assert.equal(resMissing.status, 400, `Expected 400 for missing eventId in ${op}`);

    // Invalid non-UUID eventId
    const reqInvalid = makeRequest({ operation: op, eventId: "not-a-uuid" });
    const resInvalid = await handleEventAnalytics(reqInvalid, provider, VALID_KEY);
    assert.equal(resInvalid.status, 400, `Expected 400 for invalid eventId in ${op}`);
  }

  // compare_events requires both eventIdA and eventIdB
  const reqCompareMissingA = makeRequest({ operation: "compare_events", eventIdB: EVENT_B });
  const resCompareMissingA = await handleEventAnalytics(reqCompareMissingA, provider, VALID_KEY);
  assert.equal(resCompareMissingA.status, 400);

  const reqCompareMissingB = makeRequest({ operation: "compare_events", eventIdA: EVENT_A });
  const resCompareMissingB = await handleEventAnalytics(reqCompareMissingB, provider, VALID_KEY);
  assert.equal(resCompareMissingB.status, 400);
});

test("4. Google Review clicks counted from: action = social_cta_clicked, platform = google", () => {
  const sessions = [
    { id: SESSION_1, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:00:00Z", expires_at: "2026-11-17T10:00:00Z" },
    { id: SESSION_2, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:05:00Z", expires_at: "2026-11-17T10:05:00Z" },
  ];
  const engagements = [
    { id: "e1", delivery_session_id: SESSION_1, action: "social_cta_clicked", platform: "google", created_at: "2026-10-17T10:01:00Z" },
    { id: "e2", delivery_session_id: SESSION_1, action: "social_cta_clicked", platform: "google", created_at: "2026-10-17T10:02:00Z" },
    { id: "e3", delivery_session_id: SESSION_2, action: "social_cta_clicked", platform: "google", created_at: "2026-10-17T10:06:00Z" },
  ];

  const summary = computeEventSummary(EVENT_A, sessions, engagements, [], []);
  assert.equal(summary.social.googleReviewClicks, 3);
  assert.equal(summary.social.googleReviewUniqueSessions, 2);
});

test("5. Instagram clicks remain correct", () => {
  const sessions = [
    { id: SESSION_1, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:00:00Z", expires_at: "2026-11-17T10:00:00Z" },
  ];
  const engagements = [
    { id: "e1", delivery_session_id: SESSION_1, action: "social_cta_clicked", platform: "instagram", created_at: "2026-10-17T10:01:00Z" },
    { id: "e2", delivery_session_id: SESSION_1, action: "social_cta_clicked", platform: "instagram", created_at: "2026-10-17T10:02:00Z" },
  ];

  const summary = computeEventSummary(EVENT_A, sessions, engagements, [], []);
  assert.equal(summary.social.instagramClicks, 2);
  assert.equal(summary.social.instagramUniqueSessions, 1);
});

test("6. TikTok clicks remain correct", () => {
  const sessions = [
    { id: SESSION_1, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:00:00Z", expires_at: "2026-11-17T10:00:00Z" },
    { id: SESSION_2, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:05:00Z", expires_at: "2026-11-17T10:05:00Z" },
  ];
  const engagements = [
    { id: "e1", delivery_session_id: SESSION_1, action: "social_cta_clicked", platform: "tiktok", created_at: "2026-10-17T10:01:00Z" },
    { id: "e2", delivery_session_id: SESSION_2, action: "social_cta_clicked", platform: "tiktok", created_at: "2026-10-17T10:06:00Z" },
  ];

  const summary = computeEventSummary(EVENT_A, sessions, engagements, [], []);
  assert.equal(summary.social.tiktokClicks, 2);
  assert.equal(summary.social.tiktokUniqueSessions, 2);
});

test("7. unique-session counts use distinct delivery_session_id", () => {
  const sessions = [
    { id: SESSION_1, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:00:00Z", expires_at: "2026-11-17T10:00:00Z" },
    { id: SESSION_2, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:05:00Z", expires_at: "2026-11-17T10:05:00Z" },
    { id: SESSION_3, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:10:00Z", expires_at: "2026-11-17T10:10:00Z" },
  ];
  const engagements = [
    // SESSION_1 viewed 3 times
    { id: "e1", delivery_session_id: SESSION_1, action: "claim_viewed", platform: null, created_at: "2026-10-17T10:01:00Z" },
    { id: "e2", delivery_session_id: SESSION_1, action: "claim_viewed", platform: null, created_at: "2026-10-17T10:02:00Z" },
    { id: "e3", delivery_session_id: SESSION_1, action: "claim_viewed", platform: null, created_at: "2026-10-17T10:03:00Z" },
    // SESSION_2 viewed once
    { id: "e4", delivery_session_id: SESSION_2, action: "claim_viewed", platform: null, created_at: "2026-10-17T10:06:00Z" },
    // SESSION_1 downloaded twice, SESSION_3 downloaded once
    { id: "e5", delivery_session_id: SESSION_1, action: "download_clicked", platform: null, created_at: "2026-10-17T10:04:00Z" },
    { id: "e6", delivery_session_id: SESSION_1, action: "download_clicked", platform: null, created_at: "2026-10-17T10:05:00Z" },
    { id: "e7", delivery_session_id: SESSION_3, action: "download_clicked", platform: null, created_at: "2026-10-17T10:12:00Z" },
  ];

  const summary = computeEventSummary(EVENT_A, sessions, engagements, [], []);
  assert.equal(summary.claims.views, 4);
  assert.equal(summary.claims.uniqueSessionsViewed, 2); // SESSION_1, SESSION_2
  assert.equal(summary.downloads.total, 3);
  assert.equal(summary.downloads.uniqueSessionsDownloaded, 2); // SESSION_1, SESSION_3
});

test("8. Google clicks are never described as completed reviews", () => {
  const sessions = [
    { id: SESSION_1, event_id: EVENT_A, status: "ready", created_at: "2026-10-17T10:00:00Z", expires_at: "2026-11-17T10:00:00Z" },
  ];
  const engagements = [
    { id: "e1", delivery_session_id: SESSION_1, action: "social_cta_clicked", platform: "google", created_at: "2026-10-17T10:01:00Z" },
  ];

  const summary = computeEventSummary(EVENT_A, sessions, engagements, [], []);
  const keys = Object.keys(summary.social);

  assert.ok(keys.includes("googleReviewClicks"), "Must include googleReviewClicks");
  assert.ok(keys.includes("googleReviewUniqueSessions"), "Must include googleReviewUniqueSessions");
  assert.ok(!keys.includes("reviews"), "Must not name click metrics 'reviews'");
  assert.ok(!keys.includes("completedReviews"), "Must not name click metrics 'completedReviews'");
  assert.ok(!keys.includes("followers"), "Must not describe clicks as followers");
  assert.ok(!keys.includes("follows"), "Must not describe clicks as follows");
});

test("9. feedback average/rating distribution calculation", () => {
  const submissions = [
    { id: "f1", delivery_session_id: SESSION_1, event_id: EVENT_A, rating: 5, categories: ["photo_quality"], consent_to_anonymous_testimonial: true, created_at: "2026-10-17T10:00:00Z" },
    { id: "f2", delivery_session_id: SESSION_2, event_id: EVENT_A, rating: 4, categories: ["photo_quality", "ease_of_use"], consent_to_anonymous_testimonial: false, created_at: "2026-10-17T10:01:00Z" },
    { id: "f3", delivery_session_id: SESSION_3, event_id: EVENT_A, rating: 4, categories: ["ease_of_use"], consent_to_anonymous_testimonial: true, created_at: "2026-10-17T10:02:00Z" },
    { id: "f4", delivery_session_id: "s4", event_id: EVENT_A, rating: 3, categories: ["something_went_wrong"], consent_to_anonymous_testimonial: false, created_at: "2026-10-17T10:03:00Z" },
    { id: "f5", delivery_session_id: "s5", event_id: EVENT_A, rating: 5, categories: [], consent_to_anonymous_testimonial: true, created_at: "2026-10-17T10:04:00Z" },
  ];

  const summary = computeEventSummary(EVENT_A, [], [], submissions, []);
  // Ratings: [5, 4, 4, 3, 5] => sum = 21, count = 5, avg = 4.2
  assert.equal(summary.feedback.submissions, 5);
  assert.equal(summary.feedback.averageRating, 4.2);
  assert.deepEqual(summary.feedback.ratings, {
    1: 0,
    2: 0,
    3: 1,
    4: 2,
    5: 2,
  });

  const fbSummary = computeFeedbackSummary(EVENT_A, submissions, [
    { feedback_id: "f1", status: "new" },
    { feedback_id: "f2", status: "triaged", actionable: true },
  ]);
  assert.equal(fbSummary.submissions, 5);
  assert.equal(fbSummary.averageRating, 4.2);
  assert.equal(fbSummary.consentedTestimonialsCount, 3);
  assert.equal(fbSummary.categories.photo_quality, 2);
  assert.equal(fbSummary.categories.ease_of_use, 2);
  assert.equal(fbSummary.categories.something_went_wrong, 1);
  assert.equal(fbSummary.categories.ai_effects, 0);
  assert.equal(fbSummary.triage.new, 1);
  assert.equal(fbSummary.triage.triaged, 1);
  assert.equal(fbSummary.triage.actionable, 1);
});

test("10. empty event returns zeros/nulls safely", () => {
  const summary = computeEventSummary(EVENT_A, [], [], [], []);
  assert.equal(summary.eventId, EVENT_A);
  assert.equal(summary.startedAt, null);
  assert.equal(summary.lastActivityAt, null);
  assert.deepEqual(summary.sessions, { total: 0, ready: 0, preparing: 0, expired: 0 });
  assert.deepEqual(summary.claims, { views: 0, uniqueSessionsViewed: 0 });
  assert.deepEqual(summary.downloads, { total: 0, uniqueSessionsDownloaded: 0 });
  assert.deepEqual(summary.social, {
    instagramClicks: 0,
    instagramUniqueSessions: 0,
    tiktokClicks: 0,
    tiktokUniqueSessions: 0,
    googleReviewClicks: 0,
    googleReviewUniqueSessions: 0,
  });
  assert.deepEqual(summary.feedback, {
    submissions: 0,
    averageRating: null,
    ratings: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 },
  });
  assert.deepEqual(summary.delivery, {
    totalSessions: 0,
    readySessions: 0,
    unfinalizedSessions: 0,
    expiredSessions: 0,
    mediaItemsCount: 0,
  });

  const fbSummary = computeFeedbackSummary(EVENT_A, [], []);
  assert.equal(fbSummary.submissions, 0);
  assert.equal(fbSummary.averageRating, null);
  assert.equal(fbSummary.consentedTestimonialsCount, 0);

  const health = computeDeliveryHealth(EVENT_A, [], []);
  assert.equal(health.sessionsCreated, 0);
  assert.equal(health.completionRate, null);
  assert.equal(health.hasUnfinalizedSessions, false);
});

test("11. compare-events deltas", () => {
  const sessionsA = [
    { id: "a1", event_id: EVENT_A, status: "ready", created_at: "2026-10-10T10:00:00Z", expires_at: "2026-11-10T10:00:00Z" },
    { id: "a2", event_id: EVENT_A, status: "ready", created_at: "2026-10-10T10:05:00Z", expires_at: "2026-11-10T10:05:00Z" },
  ];
  const engagementsA = [
    { id: "ea1", delivery_session_id: "a1", action: "claim_viewed", platform: null, created_at: "2026-10-10T10:01:00Z" },
    { id: "ea2", delivery_session_id: "a1", action: "social_cta_clicked", platform: "google", created_at: "2026-10-10T10:02:00Z" },
    { id: "ea3", delivery_session_id: "a1", action: "download_clicked", platform: null, created_at: "2026-10-10T10:03:00Z" },
  ];
  const feedbackA = [
    { id: "fa1", delivery_session_id: "a1", event_id: EVENT_A, rating: 4, categories: [], consent_to_anonymous_testimonial: false, created_at: "2026-10-10T10:04:00Z" },
  ];

  const sessionsB = [
    { id: "b1", event_id: EVENT_B, status: "ready", created_at: "2026-10-17T10:00:00Z", expires_at: "2026-11-17T10:00:00Z" },
    { id: "b2", event_id: EVENT_B, status: "ready", created_at: "2026-10-17T10:05:00Z", expires_at: "2026-11-17T10:05:00Z" },
    { id: "b3", event_id: EVENT_B, status: "ready", created_at: "2026-10-17T10:10:00Z", expires_at: "2026-11-17T10:10:00Z" },
    { id: "b4", event_id: EVENT_B, status: "preparing", created_at: "2026-10-17T10:15:00Z", expires_at: "2026-11-17T10:15:00Z" },
  ];
  const engagementsB = [
    { id: "eb1", delivery_session_id: "b1", action: "claim_viewed", platform: null, created_at: "2026-10-17T10:01:00Z" },
    { id: "eb2", delivery_session_id: "b2", action: "claim_viewed", platform: null, created_at: "2026-10-17T10:06:00Z" },
    { id: "eb3", delivery_session_id: "b1", action: "social_cta_clicked", platform: "google", created_at: "2026-10-17T10:02:00Z" },
    { id: "eb4", delivery_session_id: "b2", action: "social_cta_clicked", platform: "google", created_at: "2026-10-17T10:07:00Z" },
    { id: "eb5", delivery_session_id: "b1", action: "social_cta_clicked", platform: "instagram", created_at: "2026-10-17T10:03:00Z" },
    { id: "eb6", delivery_session_id: "b1", action: "download_clicked", platform: null, created_at: "2026-10-17T10:04:00Z" },
    { id: "eb7", delivery_session_id: "b2", action: "download_clicked", platform: null, created_at: "2026-10-17T10:08:00Z" },
    { id: "eb8", delivery_session_id: "b3", action: "download_clicked", platform: null, created_at: "2026-10-17T10:12:00Z" },
  ];
  const feedbackB = [
    { id: "fb1", delivery_session_id: "b1", event_id: EVENT_B, rating: 5, categories: [], consent_to_anonymous_testimonial: true, created_at: "2026-10-17T10:05:00Z" },
  ];

  const summaryA = computeEventSummary(EVENT_A, sessionsA, engagementsA, feedbackA, []);
  const summaryB = computeEventSummary(EVENT_B, sessionsB, engagementsB, feedbackB, []);

  const comparison = computeCompareEvents(EVENT_A, summaryA, EVENT_B, summaryB);

  assert.equal(comparison.deltas.sessionsTotalDelta, 2); // 4 - 2 = 2
  assert.equal(comparison.deltas.readySessionsDelta, 1); // 3 - 2 = 1
  assert.equal(comparison.deltas.claimViewsDelta, 1); // 2 - 1 = 1
  assert.equal(comparison.deltas.downloadsDelta, 2); // 3 - 1 = 2
  assert.equal(comparison.deltas.googleReviewClicksDelta, 1); // 2 - 1 = 1
  assert.equal(comparison.deltas.instagramClicksDelta, 1); // 1 - 0 = 1
  assert.equal(comparison.deltas.averageRatingDelta, 1.0); // 5.0 - 4.0 = 1.0
});

test("12. no claim token or sensitive secret appears in returned contract", async () => {
  const provider = new MockAnalyticsProvider({
    eventsData: {
      [EVENT_A]: {
        sessions: [
          {
            id: SESSION_1,
            event_id: EVENT_A,
            status: "ready",
            created_at: "2026-10-17T10:00:00Z",
            expires_at: "2026-11-17T10:00:00Z",
          },
        ],
        engagementEvents: [
          {
            id: "e1",
            delivery_session_id: SESSION_1,
            action: "claim_viewed",
            platform: null,
            created_at: "2026-10-17T10:01:00Z",
          },
        ],
        feedbackSubmissions: [
          {
            id: "f1",
            delivery_session_id: SESSION_1,
            event_id: EVENT_A,
            rating: 5,
            categories: ["photo_quality"],
            comment: "This is private guest text that must not leak",
            consent_to_anonymous_testimonial: false,
            created_at: "2026-10-17T10:05:00Z",
          },
        ],
        mediaItems: [
          {
            id: "m1",
            delivery_session_id: SESSION_1,
            media_kind: "photo",
            created_at: "2026-10-17T10:00:30Z",
          },
        ],
      },
    },
  });

  const endpoints = [
    { operation: "latest_event" },
    { operation: "event_summary", eventId: EVENT_A },
    { operation: "feedback_summary", eventId: EVENT_A },
    { operation: "delivery_health", eventId: EVENT_A },
    { operation: "compare_events", eventIdA: EVENT_A, eventIdB: EVENT_A },
  ];

  for (const payload of endpoints) {
    const req = makeRequest(payload);
    const res = await handleEventAnalytics(req, provider, VALID_KEY);
    assert.equal(res.status, 200);
    const text = await res.text();

    // Verify forbidden substrings never leak
    const forbidden = [
      "claim_token",
      "claim_token_hash",
      "claimToken",
      "storage_object_path",
      "booth_token",
      "token_hash",
      "service_role",
      "sb_secret",
      "SUPABASE_SERVICE_ROLE_KEY",
      VALID_KEY,
      "private guest text that must not leak",
    ];

    for (const term of forbidden) {
      assert.ok(
        !text.includes(term),
        `Response for ${payload.operation} contained forbidden sensitive string: ${term}`
      );
    }
  }
});
