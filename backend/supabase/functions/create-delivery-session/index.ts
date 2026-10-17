// backend/supabase/functions/create-delivery-session/index.ts
//
// PRIVILEGED — called only by the native iPad app (SupabaseDeliveryService.
// swift), never by a browser. Deployed with --no-verify-jwt, same as every
// other function in this backend: relying on Supabase's own platform JWT/
// apikey gate here was tried and caused booth authentication failures
// (403s) in practice, so it's deliberately bypassed. The only real access
// control is this app's own booth-device check (verifyBoothDevice) —
// X-Booth-Installation-ID / X-Booth-Token, checked against `booth_devices`
// — enforced in this function's own code below. The publishable key the
// client sends is not what gates this function; verifyBoothDevice is.
//
// Creates the delivery_sessions/delivery_media rows and returns one signed
// Storage upload URL per media item.
//
// Input JSON (camelCase — must match SupabaseDeliveryService.swift exactly):
//   {
//     eventID: string, localSessionID: string, claimToken: string,
//     expiresAt?: string (ISO 8601; a request only, see expiry.ts),
//     media: [{ mediaID: string, kind: "photo" | "loopVideo", mimeType: string }],
//     socialCTA: { platform: string, displayName: string, profileURL: string, message: string } | null
//   }
// Output JSON:
//   { deliverySessionID: string, expiresAt: string, uploads: [{ mediaID: string, uploadURL: string }] }
//
// `expiresAt` is decided here, not by the client: resolveExpiresAt keeps the
// requested value only if it's in the future and within MAX_RETENTION_DAYS,
// otherwise DEFAULT_RETENTION_DAYS. The stored value is echoed back.
//
// `socialCTA` is a snapshot of the event's SocialCTA at the moment this
// session was created (see BoothSession.socialCTASnapshot on the client) —
// optional, and its absence never fails this call. Only the four known
// fields are ever read off the client-supplied object and only after
// validation; nothing from it is ever spread directly into a database
// insert, so a client can't smuggle arbitrary columns/values through it.
//
// Object paths are built ONLY from server-validated UUIDs
// (events/<eventID>/sessions/<localSessionID>/<mediaID>.<ext>) — eventID,
// localSessionID, and every mediaID are checked against a strict UUID
// pattern before they ever touch a path string, so `../`, absolute paths,
// and cross-event injection are rejected outright rather than sanitized.
// Paths never overwrite: createSignedUploadUrl is called without
// `upsert`, and every path includes the media item's own fresh UUID.
//
// This is a native-client-only endpoint, so no browser CORS handling is
// needed (CORS is a browser concept; URLSession doesn't send/require it).

import {
  getServiceClient,
  isValidSocialCTAPlatform,
  isValidUUID,
  sha256Hex,
  verifyBoothDevice,
} from "../_shared/boothAuth.ts";
import {
  DEFAULT_RETENTION_DAYS,
  MAX_RETENTION_DAYS,
  resolveExpiresAt,
} from "./expiry.ts";

export { DEFAULT_RETENTION_DAYS, MAX_RETENTION_DAYS, resolveExpiresAt };

const BUCKET = "booth-media";

function extensionFor(mimeType: string): string {
  switch (mimeType) {
    // The app now records Loop as video/mp4 (see LoopVideoWriter.swift) —
    // video/quicktime is kept mapped too for any already-created sessions.
    case "video/mp4":
      return "mp4";
    case "video/quicktime":
      return "mov";
    case "image/jpeg":
      return "jpg";
    default:
      return "bin";
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const supabase = getServiceClient();

    const auth = await verifyBoothDevice(req, supabase);
    if (!auth.ok) {
      return new Response(JSON.stringify({ error: auth.error }), { status: auth.status });
    }

    const body = await req.json();
    const { eventID, localSessionID, claimToken, expiresAt, media } = body ?? {};
    if (
      !isValidUUID(eventID) || !isValidUUID(localSessionID) ||
      typeof claimToken !== "string" || claimToken.length < 16 ||
      !Array.isArray(media) || media.length === 0
    ) {
      return new Response(JSON.stringify({ error: "Invalid request body" }), { status: 400 });
    }
    for (const item of media) {
      if (!isValidUUID(item?.mediaID) || typeof item?.kind !== "string" || typeof item?.mimeType !== "string") {
        return new Response(JSON.stringify({ error: "Invalid media manifest entry" }), { status: 400 });
      }
    }

    // Optional social CTA snapshot — validated field-by-field and never
    // spread directly from the request body. Absence (null/undefined) is
    // completely normal and never rejected.
    let socialCTAColumns = {
      social_cta_platform: null as string | null,
      social_cta_display_name: null as string | null,
      social_cta_profile_url: null as string | null,
      social_cta_message: null as string | null,
    };
    if (body?.socialCTA != null) {
      const cta = body.socialCTA;
      const platform = cta?.platform;
      const displayName = cta?.displayName;
      const profileURL = cta?.profileURL;
      const message = cta?.message;
      if (
        !isValidSocialCTAPlatform(platform) ||
        typeof displayName !== "string" || displayName.length === 0 || displayName.length > 200 ||
        typeof profileURL !== "string" || profileURL.length === 0 || profileURL.length > 500 ||
        typeof message !== "string" || message.length > 500
      ) {
        return new Response(JSON.stringify({ error: "Invalid socialCTA" }), { status: 400 });
      }
      let parsedURL: URL;
      try {
        parsedURL = new URL(profileURL);
      } catch {
        return new Response(JSON.stringify({ error: "Invalid socialCTA profileURL" }), { status: 400 });
      }
      if (parsedURL.protocol !== "https:") {
        return new Response(JSON.stringify({ error: "Invalid socialCTA profileURL" }), { status: 400 });
      }
      socialCTAColumns = {
        social_cta_platform: platform,
        social_cta_display_name: displayName,
        social_cta_profile_url: parsedURL.toString(),
        social_cta_message: message,
      };
    }

    // Only the hash is stored — the plaintext claimToken is the guest's
    // bearer secret (embedded in the QR code) and is never written to the
    // database.
    const claimTokenHash = await sha256Hex(claimToken);
    const serverExpiresAt = resolveExpiresAt(expiresAt);

    const { data: session, error: sessionError } = await supabase
      .from("delivery_sessions")
      .insert({
        external_session_id: localSessionID,
        event_id: eventID,
        claim_token_hash: claimTokenHash,
        status: "preparing",
        expires_at: serverExpiresAt,
        ...socialCTAColumns,
      })
      .select("id")
      .single();

    if (sessionError || !session) {
      return new Response(
        JSON.stringify({ error: sessionError?.message ?? "Could not create delivery session" }),
        { status: 500 },
      );
    }

    const uploads: { mediaID: string; uploadURL: string }[] = [];
    for (const item of media) {
      // Every path segment here is a server-validated UUID (checked
      // above) or a fixed literal — never raw client input.
      const objectPath = `events/${eventID}/sessions/${localSessionID}/${item.mediaID}.${extensionFor(item.mimeType)}`;

      const { error: mediaError } = await supabase.from("delivery_media").insert({
        delivery_session_id: session.id,
        external_media_id: item.mediaID,
        storage_object_path: objectPath,
        media_kind: item.kind,
        mime_type: item.mimeType,
      });
      if (mediaError) {
        return new Response(JSON.stringify({ error: mediaError.message }), { status: 500 });
      }

      const { data: signed, error: signError } = await supabase.storage
        .from(BUCKET)
        .createSignedUploadUrl(objectPath);
      if (signError || !signed) {
        return new Response(
          JSON.stringify({ error: signError?.message ?? "Could not create upload URL" }),
          { status: 500 },
        );
      }

      uploads.push({ mediaID: item.mediaID, uploadURL: signed.signedUrl });
    }

    return new Response(
      JSON.stringify({ deliverySessionID: session.id, expiresAt: serverExpiresAt, uploads }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
