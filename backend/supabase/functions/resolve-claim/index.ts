// backend/supabase/functions/resolve-claim/index.ts
//
// PUBLIC / GUEST-FACING — deliberately the one function in this backend
// that does NOT require the booth device credential. Its authorization
// capability is the high-entropy claim token itself (the same one baked
// into the QR code), not a device or a login. Called only by the static
// claim page (backend/claim-page/), never by the iPad app.
//
// Verifies a claim token against its stored hash, checks expiration, and
// mints short-lived signed download URLs for private Storage objects —
// the bucket itself is never made public, and this function returns only
// guest-safe fields (kind, mime type, a time-limited URL) — no internal
// IDs, no storage paths, no session/event identifiers.
//
// Input JSON: { claimToken: string }
// Output JSON (200): { status: "ready", expiresAt: string, media: [{ kind, mimeType, downloadURL }] }
// Output JSON (404): { status: "not_found" }
// Output JSON (410): { status: "expired" }
//
// CORS: this is the one function in this backend a browser calls
// directly, so it needs explicit CORS handling. `Access-Control-Allow-
// Origin: *` is used deliberately, not by oversight: authorization here
// comes from the bearer claim token in the request body, not from the
// caller's origin, so restricting the origin would add no real security —
// it would only break the page if hosted from an unexpected domain. If
// you'd rather pin this to the claim page's exact domain once it's
// chosen, replace "*" below with that origin.
//
// Deliberately does NOT return a SocialCTA yet — that data lives only in
// the iPad app's local EventConfiguration today and isn't synced to this
// backend. Wiring it through (e.g. an event-level table, or passing it
// into create-delivery-session to store alongside the session) is a
// follow-up, not implemented in this pass.

import { getServiceClient, sha256Hex } from "../_shared/boothAuth.ts";

const BUCKET = "booth-media";
const SIGNED_URL_TTL_SECONDS = 15 * 60; // 15 minutes — within the 10-30 min target.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  try {
    const body = await req.json();
    const { claimToken } = body ?? {};
    if (typeof claimToken !== "string" || claimToken.length === 0) {
      return new Response(JSON.stringify({ error: "Invalid request body" }), { status: 400, headers: jsonHeaders });
    }

    const supabase = getServiceClient();
    const claimTokenHash = await sha256Hex(claimToken);

    const { data: session, error: sessionError } = await supabase
      .from("delivery_sessions")
      .select("id, status, expires_at")
      .eq("claim_token_hash", claimTokenHash)
      .maybeSingle();

    if (sessionError) {
      return new Response(JSON.stringify({ error: sessionError.message }), { status: 500, headers: jsonHeaders });
    }
    if (!session || session.status !== "ready") {
      return new Response(JSON.stringify({ status: "not_found" }), { status: 404, headers: jsonHeaders });
    }
    if (new Date(session.expires_at).getTime() < Date.now()) {
      return new Response(JSON.stringify({ status: "expired" }), { status: 410, headers: jsonHeaders });
    }

    const { data: mediaRows, error: mediaError } = await supabase
      .from("delivery_media")
      .select("storage_object_path, media_kind, mime_type")
      .eq("delivery_session_id", session.id);

    if (mediaError) {
      return new Response(JSON.stringify({ error: mediaError.message }), { status: 500, headers: jsonHeaders });
    }

    const media: { kind: string; mimeType: string; downloadURL: string }[] = [];
    for (const row of mediaRows ?? []) {
      const { data: signed, error: signError } = await supabase.storage
        .from(BUCKET)
        .createSignedUrl(row.storage_object_path, SIGNED_URL_TTL_SECONDS);
      if (signError || !signed) {
        return new Response(
          JSON.stringify({ error: signError?.message ?? "Could not create download URL" }),
          { status: 500, headers: jsonHeaders },
        );
      }
      // Guest-safe fields only — no storage path, no session/event id.
      media.push({ kind: row.media_kind, mimeType: row.mime_type, downloadURL: signed.signedUrl });
    }

    return new Response(
      JSON.stringify({ status: "ready", expiresAt: session.expires_at, media }),
      { status: 200, headers: jsonHeaders },
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: jsonHeaders });
  }
});
