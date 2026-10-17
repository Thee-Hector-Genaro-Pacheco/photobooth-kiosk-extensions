// backend/supabase/functions/record-engagement/index.ts
//
// PUBLIC / GUEST-FACING — same authorization model as resolve-claim: no
// booth device credential, and deployed with --no-verify-jwt so it needs
// no Supabase key at all. The claim token is the only capability checked;
// a client-supplied delivery_session_id is never trusted or even
// accepted — the session is always looked up here from the token, exactly
// like resolve-claim, so a guest can only ever record engagement against
// their own real, still-valid claim.
//
// Records lightweight funnel analytics only (Social Claim Funnel v1):
// claim_viewed, social_cta_clicked, download_clicked. Deliberately CANNOT
// record anything stronger than a click — there is no "instagram_followed"
// or "verified_follow" action, because this backend has no approved
// Instagram API integration to actually confirm a follow. See
// isValidEngagementAction / isValidSocialCTAPlatform in _shared/boothAuth.ts
// for the exact allowlists.
//
// No biometric data, no Instagram credentials/usernames, no IP or
// user-agent fingerprinting is ever read or stored here.
//
// This must fail open with respect to media delivery: it is a completely
// separate function from resolve-claim, so a failure here (network,
// validation, DB error) can never affect whether a guest's photo/Loop is
// downloadable. The claim page calls this fire-and-forget.
//
// Input JSON: { claimToken: string, action: string, platform?: string | null }
// Output JSON (200): { status: "recorded" }
// Output JSON (400): { error: string }
// Output JSON (404): { status: "not_found" }
// Output JSON (410): { status: "expired" }

import {
  getServiceClient,
  isValidEngagementAction,
  isValidSocialCTAPlatform,
  sha256Hex,
} from "../_shared/boothAuth.ts";

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
    const { claimToken, action, platform } = body ?? {};

    if (typeof claimToken !== "string" || claimToken.length === 0) {
      return new Response(JSON.stringify({ error: "Invalid request body" }), { status: 400, headers: jsonHeaders });
    }
    if (!isValidEngagementAction(action)) {
      return new Response(JSON.stringify({ error: "Unknown engagement action" }), { status: 400, headers: jsonHeaders });
    }
    let normalizedPlatform: string | null = null;
    if (platform !== undefined && platform !== null) {
      if (!isValidSocialCTAPlatform(platform)) {
        return new Response(JSON.stringify({ error: "Unknown platform" }), { status: 400, headers: jsonHeaders });
      }
      normalizedPlatform = platform;
    }

    const supabase = getServiceClient();
    const claimTokenHash = await sha256Hex(claimToken);

    // Same validity rule as resolve-claim (found, status "ready", not
    // expired) — this is also what makes it impossible for a client to
    // record engagement against a session it doesn't actually hold a
    // claim token for.
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

    const { error: insertError } = await supabase.from("engagement_events").insert({
      delivery_session_id: session.id,
      action,
      platform: normalizedPlatform,
    });
    if (insertError) {
      return new Response(JSON.stringify({ error: insertError.message }), { status: 500, headers: jsonHeaders });
    }

    return new Response(JSON.stringify({ status: "recorded" }), { status: 200, headers: jsonHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: jsonHeaders });
  }
});
