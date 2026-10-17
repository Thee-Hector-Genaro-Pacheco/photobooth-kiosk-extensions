// backend/supabase/functions/submit-feedback/handler.ts
//
// Request handling for submit-feedback, with the database behind a small
// interface so it can be tested without Supabase. index.ts wires in the
// real implementation.

import { MAX_BODY_BYTES, parseFeedbackSubmission } from "../_shared/feedback.ts";

export interface FeedbackSession {
  id: string;
  eventId: string;
  status: string;
  expiresAt: string;
}

export interface FeedbackRow {
  delivery_session_id: string;
  event_id: string;
  rating: number;
  categories: string[];
  comment: string | null;
  consent_to_anonymous_testimonial: boolean;
  source: "claim_page";
}

export type InsertResult = { ok: true } | { ok: false; duplicate: boolean; message: string };

export interface FeedbackStore {
  /** Looks the session up by claim token (hashing is the store's job). */
  findSessionByClaimToken(claimToken: string): Promise<FeedbackSession | null>;
  insertFeedback(row: FeedbackRow): Promise<InsertResult>;
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

export async function handleSubmitFeedback(
  req: Request,
  store: FeedbackStore,
  now: () => number = Date.now,
): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: corsHeaders });

  const declaredLength = Number(req.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) return json({ error: "Request too large" }, 413);

  let body: unknown;
  try {
    const text = await req.text();
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return json({ error: "Request too large" }, 413);
    body = JSON.parse(text);
  } catch {
    return json({ error: "Invalid request body" }, 400);
  }

  const parsed = parseFeedbackSubmission(body);
  if (!parsed.ok) return json({ error: parsed.error }, 400);
  const input = parsed.value;

  try {
    // Same validity rule as resolve-claim and record-engagement: the claim
    // token must resolve to a ready, unexpired session. The session and
    // event ids come from here, never from the request.
    const session = await store.findSessionByClaimToken(input.claimToken);
    if (!session || session.status !== "ready") return json({ status: "not_found" }, 404);
    if (new Date(session.expiresAt).getTime() < now()) return json({ status: "expired" }, 410);

    const result = await store.insertFeedback({
      delivery_session_id: session.id,
      event_id: session.eventId,
      rating: input.rating,
      categories: input.categories,
      comment: input.comment,
      consent_to_anonymous_testimonial: input.consentToAnonymousTestimonial,
      source: "claim_page",
    });
    if (!result.ok) {
      if (result.duplicate) return json({ status: "already_submitted" }, 409);
      console.log(`[submit-feedback] insert failed: ${result.message}`);
      return json({ error: "Could not save feedback" }, 500);
    }

    return json({ status: "received" }, 201);
  } catch (err) {
    console.log(`[submit-feedback] error: ${String(err)}`);
    return json({ error: "Could not save feedback" }, 500);
  }
}
