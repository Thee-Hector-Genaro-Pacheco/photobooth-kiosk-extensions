// backend/supabase/functions/_shared/feedback.ts
//
// Validation for guest feedback sent from the claim page to submit-feedback.
// No imports, so it can be unit tested without Supabase or Deno.serve.
//
// The public request may carry exactly the fields in ALLOWED_FIELDS. Any
// other key (including internal triage fields like status, actionable,
// severity, or a client-chosen deliverySessionId/eventId) rejects the whole
// request instead of being silently dropped, so a client can't believe it
// set them.

// Must match the CHECK constraint in migrations/0005_guest_feedback.sql and
// FEEDBACK_CATEGORIES in claim-page/feedback.js.
export const FEEDBACK_CATEGORIES = [
  "photo_quality",
  "ai_effects",
  "qr_delivery",
  "print_experience",
  "ease_of_use",
  "something_went_wrong",
] as const;

export type FeedbackCategory = (typeof FEEDBACK_CATEGORIES)[number];

export const MAX_COMMENT_LENGTH = 1000;
/** Claim tokens are ~32 base64url chars; anything far longer isn't one. */
export const MAX_CLAIM_TOKEN_LENGTH = 256;
/** Whole request body, in bytes. A max-length comment fits with room to spare. */
export const MAX_BODY_BYTES = 8 * 1024;

const ALLOWED_FIELDS = new Set([
  "claimToken",
  "rating",
  "categories",
  "comment",
  "consentToAnonymousTestimonial",
]);

export interface FeedbackInput {
  claimToken: string;
  rating: number;
  categories: FeedbackCategory[];
  comment: string | null;
  consentToAnonymousTestimonial: boolean;
}

export type FeedbackParseResult =
  | { ok: true; value: FeedbackInput }
  | { ok: false; error: string };

function isCategory(value: unknown): value is FeedbackCategory {
  return typeof value === "string" && (FEEDBACK_CATEGORIES as readonly string[]).includes(value);
}

export function parseFeedbackSubmission(body: unknown): FeedbackParseResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "Invalid request body" };
  }
  const record = body as Record<string, unknown>;

  for (const key of Object.keys(record)) {
    if (!ALLOWED_FIELDS.has(key)) return { ok: false, error: `Unexpected field: ${key}` };
  }

  const { claimToken, rating, categories, comment, consentToAnonymousTestimonial } = record;

  if (typeof claimToken !== "string" || claimToken.length === 0 || claimToken.length > MAX_CLAIM_TOKEN_LENGTH) {
    return { ok: false, error: "Invalid claim token" };
  }

  if (typeof rating !== "number" || !Number.isInteger(rating) || rating < 1 || rating > 5) {
    return { ok: false, error: "Rating must be a whole number from 1 to 5" };
  }

  let normalizedCategories: FeedbackCategory[] = [];
  if (categories !== undefined) {
    if (!Array.isArray(categories) || categories.length > FEEDBACK_CATEGORIES.length) {
      return { ok: false, error: "Invalid categories" };
    }
    for (const category of categories) {
      if (!isCategory(category)) return { ok: false, error: "Unknown category" };
    }
    normalizedCategories = [...new Set(categories as FeedbackCategory[])];
  }

  let normalizedComment: string | null = null;
  if (comment !== undefined && comment !== null) {
    if (typeof comment !== "string") return { ok: false, error: "Invalid comment" };
    const trimmed = comment.trim();
    // Count code points, matching Postgres char_length, not UTF-16 units.
    if ([...trimmed].length > MAX_COMMENT_LENGTH) {
      return { ok: false, error: `Comment must be ${MAX_COMMENT_LENGTH} characters or fewer` };
    }
    normalizedComment = trimmed.length > 0 ? trimmed : null;
  }

  if (consentToAnonymousTestimonial !== undefined && typeof consentToAnonymousTestimonial !== "boolean") {
    return { ok: false, error: "Invalid testimonial consent" };
  }

  return {
    ok: true,
    value: {
      claimToken,
      rating,
      categories: normalizedCategories,
      comment: normalizedComment,
      // Consent is opt-in: absent means no.
      consentToAnonymousTestimonial: consentToAnonymousTestimonial === true,
    },
  };
}
