// backend/supabase/functions/submit-feedback/index.ts
//
// PUBLIC / GUEST-FACING — same authorization model as resolve-claim and
// record-engagement: no booth device credential, deployed with
// --no-verify-jwt, and the claim token is the only capability. The session
// and event are always looked up from the token here; the request can't
// name them.
//
// Stores optional post-download feedback (rating, categories, comment,
// testimonial consent) in feedback_submissions. A trigger creates the
// matching internal feedback_triage row; this function never reads or
// writes triage data and never returns any of it.
//
// One submission per delivery session (unique index in 0005). Completely
// separate from resolve-claim, so a failure here can never affect media
// delivery.
//
// Input JSON:  { claimToken, rating: 1-5, categories?: string[], comment?: string,
//                consentToAnonymousTestimonial?: boolean }
// Output JSON: 201 { status: "received" }
//              400 { error }            invalid field, unknown field, bad value
//              404 { status: "not_found" }
//              409 { status: "already_submitted" }
//              410 { status: "expired" }
//              413 { error }            body over 8 KB
//
// CORS "*" for the same reason as resolve-claim: authorization is the
// bearer claim token, not the origin.

import { getServiceClient, sha256Hex } from "../_shared/boothAuth.ts";
import { type FeedbackStore, handleSubmitFeedback } from "./handler.ts";

// Postgres unique_violation.
const UNIQUE_VIOLATION = "23505";

const store: FeedbackStore = {
  async findSessionByClaimToken(claimToken) {
    const supabase = getServiceClient();
    const { data, error } = await supabase
      .from("delivery_sessions")
      .select("id, event_id, status, expires_at")
      .eq("claim_token_hash", await sha256Hex(claimToken))
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) return null;
    return { id: data.id, eventId: data.event_id, status: data.status, expiresAt: data.expires_at };
  },

  async insertFeedback(row) {
    const supabase = getServiceClient();
    const { error } = await supabase.from("feedback_submissions").insert(row);
    if (!error) return { ok: true };
    return { ok: false, duplicate: error.code === UNIQUE_VIOLATION, message: error.message };
  },
};

Deno.serve((req) => handleSubmitFeedback(req, store));
