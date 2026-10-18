// backend/supabase/functions/event-analytics/analytics.ts
//
// Pure aggregation and deterministic analytics calculations for Pacific Rising Ops.
// Completely isolated from network and database I/O so it can be tested
// deterministically without a live Supabase instance or Docker.

export interface DeliverySessionRow {
  id: string;
  event_id: string;
  status: "preparing" | "ready" | "expired" | string;
  created_at: string;
  expires_at: string;
}

export interface EngagementEventRow {
  id: string;
  delivery_session_id: string;
  action: "claim_viewed" | "social_cta_clicked" | "download_clicked" | string;
  platform: "instagram" | "tiktok" | "facebook" | "x" | "other" | "google" | string | null;
  created_at: string;
}

export interface FeedbackSubmissionRow {
  id: string;
  delivery_session_id: string | null;
  event_id: string;
  rating: number;
  categories: string[];
  consent_to_anonymous_testimonial: boolean;
  created_at: string;
}

export interface FeedbackTriageRow {
  feedback_id?: string;
  status: "new" | "triaged" | "planned" | "implemented" | "verified" | string;
  classification?: string | null;
  actionable?: boolean | null;
  product_area?: string | null;
  severity?: string | null;
}

export interface DeliveryMediaRow {
  id: string;
  delivery_session_id: string;
  media_kind: "photo" | "loopVideo" | string;
  created_at: string;
}

export interface EventSummary {
  operation: "event_summary";
  eventId: string;
  startedAt: string | null;
  lastActivityAt: string | null;
  sessions: {
    total: number;
    ready: number;
    preparing: number;
    expired: number;
  };
  claims: {
    views: number;
    uniqueSessionsViewed: number;
  };
  downloads: {
    total: number;
    uniqueSessionsDownloaded: number;
  };
  social: {
    instagramClicks: number;
    instagramUniqueSessions: number;
    tiktokClicks: number;
    tiktokUniqueSessions: number;
    googleReviewClicks: number;
    googleReviewUniqueSessions: number;
  };
  feedback: {
    submissions: number;
    averageRating: number | null;
    ratings: {
      "1": number;
      "2": number;
      "3": number;
      "4": number;
      "5": number;
    };
  };
  delivery: {
    totalSessions: number;
    readySessions: number;
    unfinalizedSessions: number;
    expiredSessions: number;
    mediaItemsCount: number;
  };
}

export interface FeedbackSummary {
  operation: "feedback_summary";
  eventId: string;
  submissions: number;
  averageRating: number | null;
  ratings: {
    "1": number;
    "2": number;
    "3": number;
    "4": number;
    "5": number;
  };
  categories: {
    photo_quality: number;
    ai_effects: number;
    qr_delivery: number;
    print_experience: number;
    ease_of_use: number;
    something_went_wrong: number;
  };
  consentedTestimonialsCount: number;
  triage: {
    total: number;
    new: number;
    triaged: number;
    planned: number;
    implemented: number;
    verified: number;
    actionable: number;
  };
}

export interface DeliveryHealth {
  operation: "delivery_health";
  eventId: string;
  sessionsCreated: number;
  sessionsReady: number;
  sessionsPreparing: number;
  sessionsExpired: number;
  totalMediaItems: number;
  mediaBreakdown: {
    photo: number;
    loopVideo: number;
  };
  completionRate: number | null;
  hasUnfinalizedSessions: boolean;
}

export interface EventComparisonDeltas {
  sessionsTotalDelta: number;
  readySessionsDelta: number;
  claimViewsDelta: number;
  uniqueSessionsViewedDelta: number;
  downloadsDelta: number;
  uniqueSessionsDownloadedDelta: number;
  instagramClicksDelta: number;
  tiktokClicksDelta: number;
  googleReviewClicksDelta: number;
  feedbackSubmissionsDelta: number;
  averageRatingDelta: number | null;
}

export interface CompareEventsResult {
  operation: "compare_events";
  eventIdA: string;
  eventIdB: string;
  eventA: EventSummary;
  eventB: EventSummary;
  deltas: EventComparisonDeltas;
}

export interface LatestEventResult {
  operation: "latest_event";
  eventId: string | null;
  lastActivityAt: string | null;
  sessionCount: number;
}

/**
 * Constant-time string comparison using SHA-256 pre-hashing and XOR accumulator.
 * Hashes both strings to a fixed 32-byte digest so comparisons never leak string lengths.
 */
export async function timingSafeEqualString(a: string, b: string): Promise<boolean> {
  if (typeof a !== "string" || typeof b !== "string") {
    return false;
  }
  const enc = new TextEncoder();
  const digestA = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(a)));
  const digestB = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(b)));
  let mismatch = 0;
  for (let i = 0; i < 32; i++) {
    mismatch |= digestA[i] ^ digestB[i];
  }
  return mismatch === 0;
}

/**
 * Validates the Authorization Bearer token against REPORTING_AGENT_API_KEY.
 * Fails closed if the secret is not configured or if the header is missing/mismatched.
 */
export async function verifyReportingAuth(
  authHeader: string | null,
  expectedKey: string | undefined
): Promise<boolean> {
  if (!expectedKey || typeof expectedKey !== "string" || expectedKey.trim().length === 0) {
    return false;
  }
  if (!authHeader || typeof authHeader !== "string") {
    return false;
  }

  const prefix = "Bearer ";
  if (!authHeader.startsWith(prefix)) {
    return false;
  }

  const token = authHeader.slice(prefix.length).trim();
  if (token.length === 0) {
    return false;
  }

  return await timingSafeEqualString(token, expectedKey.trim());
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isValidUUID(value: unknown): value is string {
  return typeof value === "string" && UUID_REGEX.test(value);
}

/**
 * Calculates average rating rounded to 2 decimal places, or null if empty.
 */
function roundTwoDecimals(value: number): number {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

/**
 * Aggregates EventSummary metrics.
 */
export function computeEventSummary(
  eventId: string,
  sessions: DeliverySessionRow[],
  engagementEvents: EngagementEventRow[],
  feedbackSubmissions: FeedbackSubmissionRow[],
  mediaItems: DeliveryMediaRow[]
): EventSummary {
  // Session status counts
  let readySessions = 0;
  let preparingSessions = 0;
  let expiredSessions = 0;

  const allTimestamps: number[] = [];

  for (const s of sessions) {
    if (s.created_at) {
      const t = Date.parse(s.created_at);
      if (!Number.isNaN(t)) allTimestamps.push(t);
    }
    if (s.status === "ready") {
      readySessions++;
    } else if (s.status === "preparing") {
      preparingSessions++;
    } else if (s.status === "expired") {
      expiredSessions++;
    }
  }

  // Engagement tracking
  let claimViews = 0;
  const claimViewSessions = new Set<string>();

  let downloads = 0;
  const downloadSessions = new Set<string>();

  let instagramClicks = 0;
  const instagramSessions = new Set<string>();

  let tiktokClicks = 0;
  const tiktokSessions = new Set<string>();

  let googleReviewClicks = 0;
  const googleReviewSessions = new Set<string>();

  for (const ev of engagementEvents) {
    if (ev.created_at) {
      const t = Date.parse(ev.created_at);
      if (!Number.isNaN(t)) allTimestamps.push(t);
    }

    if (ev.action === "claim_viewed") {
      claimViews++;
      if (ev.delivery_session_id) claimViewSessions.add(ev.delivery_session_id);
    } else if (ev.action === "download_clicked") {
      downloads++;
      if (ev.delivery_session_id) downloadSessions.add(ev.delivery_session_id);
    } else if (ev.action === "social_cta_clicked") {
      if (ev.platform === "instagram") {
        instagramClicks++;
        if (ev.delivery_session_id) instagramSessions.add(ev.delivery_session_id);
      } else if (ev.platform === "tiktok") {
        tiktokClicks++;
        if (ev.delivery_session_id) tiktokSessions.add(ev.delivery_session_id);
      } else if (ev.platform === "google") {
        googleReviewClicks++;
        if (ev.delivery_session_id) googleReviewSessions.add(ev.delivery_session_id);
      }
    }
  }

  // Feedback submissions
  const ratings: { "1": number; "2": number; "3": number; "4": number; "5": number } = {
    "1": 0,
    "2": 0,
    "3": 0,
    "4": 0,
    "5": 0,
  };
  let ratingSum = 0;
  let ratingCount = 0;

  for (const fb of feedbackSubmissions) {
    if (fb.created_at) {
      const t = Date.parse(fb.created_at);
      if (!Number.isNaN(t)) allTimestamps.push(t);
    }

    if (typeof fb.rating === "number" && fb.rating >= 1 && fb.rating <= 5) {
      const key = String(fb.rating) as "1" | "2" | "3" | "4" | "5";
      ratings[key] = (ratings[key] || 0) + 1;
      ratingSum += fb.rating;
      ratingCount++;
    }
  }

  const averageRating = ratingCount > 0 ? roundTwoDecimals(ratingSum / ratingCount) : null;

  // Started at & last activity timestamps
  let startedAt: string | null = null;
  let lastActivityAt: string | null = null;

  if (allTimestamps.length > 0) {
    const minTime = Math.min(...allTimestamps);
    const maxTime = Math.max(...allTimestamps);
    startedAt = new Date(minTime).toISOString();
    lastActivityAt = new Date(maxTime).toISOString();
  }

  return {
    operation: "event_summary",
    eventId,
    startedAt,
    lastActivityAt,
    sessions: {
      total: sessions.length,
      ready: readySessions,
      preparing: preparingSessions,
      expired: expiredSessions,
    },
    claims: {
      views: claimViews,
      uniqueSessionsViewed: claimViewSessions.size,
    },
    downloads: {
      total: downloads,
      uniqueSessionsDownloaded: downloadSessions.size,
    },
    social: {
      instagramClicks,
      instagramUniqueSessions: instagramSessions.size,
      tiktokClicks,
      tiktokUniqueSessions: tiktokSessions.size,
      googleReviewClicks,
      googleReviewUniqueSessions: googleReviewSessions.size,
    },
    feedback: {
      submissions: feedbackSubmissions.length,
      averageRating,
      ratings,
    },
    delivery: {
      totalSessions: sessions.length,
      readySessions,
      unfinalizedSessions: preparingSessions,
      expiredSessions,
      mediaItemsCount: mediaItems.length,
    },
  };
}

/**
 * Aggregates FeedbackSummary metrics without returning any guest comments or PII.
 */
export function computeFeedbackSummary(
  eventId: string,
  feedbackSubmissions: FeedbackSubmissionRow[],
  triageRows: FeedbackTriageRow[] = []
): FeedbackSummary {
  const ratings = { "1": 0, "2": 0, "3": 0, "4": 0, "5": 0 };
  const categories = {
    photo_quality: 0,
    ai_effects: 0,
    qr_delivery: 0,
    print_experience: 0,
    ease_of_use: 0,
    something_went_wrong: 0,
  };

  let ratingSum = 0;
  let ratingCount = 0;
  let consentedTestimonialsCount = 0;

  for (const fb of feedbackSubmissions) {
    if (typeof fb.rating === "number" && fb.rating >= 1 && fb.rating <= 5) {
      const key = String(fb.rating) as "1" | "2" | "3" | "4" | "5";
      ratings[key] = (ratings[key] || 0) + 1;
      ratingSum += fb.rating;
      ratingCount++;
    }

    if (Array.isArray(fb.categories)) {
      for (const cat of fb.categories) {
        if (cat in categories) {
          categories[cat as keyof typeof categories]++;
        }
      }
    }

    if (fb.consent_to_anonymous_testimonial === true) {
      consentedTestimonialsCount++;
    }
  }

  const averageRating = ratingCount > 0 ? roundTwoDecimals(ratingSum / ratingCount) : null;

  // Triage breakdown
  const triage = {
    total: triageRows.length,
    new: 0,
    triaged: 0,
    planned: 0,
    implemented: 0,
    verified: 0,
    actionable: 0,
  };

  for (const tr of triageRows) {
    if (tr.status === "new") triage.new++;
    else if (tr.status === "triaged") triage.triaged++;
    else if (tr.status === "planned") triage.planned++;
    else if (tr.status === "implemented") triage.implemented++;
    else if (tr.status === "verified") triage.verified++;

    if (tr.actionable === true) {
      triage.actionable++;
    }
  }

  return {
    operation: "feedback_summary",
    eventId,
    submissions: feedbackSubmissions.length,
    averageRating,
    ratings,
    categories,
    consentedTestimonialsCount,
    triage,
  };
}

/**
 * Aggregates DeliveryHealth metrics strictly provable from the existing schema.
 */
export function computeDeliveryHealth(
  eventId: string,
  sessions: DeliverySessionRow[],
  mediaItems: DeliveryMediaRow[]
): DeliveryHealth {
  let ready = 0;
  let preparing = 0;
  let expired = 0;

  for (const s of sessions) {
    if (s.status === "ready") ready++;
    else if (s.status === "preparing") preparing++;
    else if (s.status === "expired") expired++;
  }

  let photoCount = 0;
  let loopCount = 0;

  for (const m of mediaItems) {
    if (m.media_kind === "photo") photoCount++;
    else if (m.media_kind === "loopVideo") loopCount++;
  }

  const completionRate = sessions.length > 0 ? roundTwoDecimals(ready / sessions.length) : null;

  return {
    operation: "delivery_health",
    eventId,
    sessionsCreated: sessions.length,
    sessionsReady: ready,
    sessionsPreparing: preparing,
    sessionsExpired: expired,
    totalMediaItems: mediaItems.length,
    mediaBreakdown: {
      photo: photoCount,
      loopVideo: loopCount,
    },
    completionRate,
    hasUnfinalizedSessions: preparing > 0,
  };
}

/**
 * Compares two event summaries and computes numerical deltas (Event B minus Event A).
 */
export function computeCompareEvents(
  eventIdA: string,
  summaryA: EventSummary,
  eventIdB: string,
  summaryB: EventSummary
): CompareEventsResult {
  const averageRatingDelta =
    summaryA.feedback.averageRating !== null && summaryB.feedback.averageRating !== null
      ? roundTwoDecimals(summaryB.feedback.averageRating - summaryA.feedback.averageRating)
      : null;

  return {
    operation: "compare_events",
    eventIdA,
    eventIdB,
    eventA: summaryA,
    eventB: summaryB,
    deltas: {
      sessionsTotalDelta: summaryB.sessions.total - summaryA.sessions.total,
      readySessionsDelta: summaryB.delivery.readySessions - summaryA.delivery.readySessions,
      claimViewsDelta: summaryB.claims.views - summaryA.claims.views,
      uniqueSessionsViewedDelta: summaryB.claims.uniqueSessionsViewed - summaryA.claims.uniqueSessionsViewed,
      downloadsDelta: summaryB.downloads.total - summaryA.downloads.total,
      uniqueSessionsDownloadedDelta: summaryB.downloads.uniqueSessionsDownloaded - summaryA.downloads.uniqueSessionsDownloaded,
      instagramClicksDelta: summaryB.social.instagramClicks - summaryA.social.instagramClicks,
      tiktokClicksDelta: summaryB.social.tiktokClicks - summaryA.social.tiktokClicks,
      googleReviewClicksDelta: summaryB.social.googleReviewClicks - summaryA.social.googleReviewClicks,
      feedbackSubmissionsDelta: summaryB.feedback.submissions - summaryA.feedback.submissions,
      averageRatingDelta,
    },
  };
}
