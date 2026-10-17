// backend/supabase/functions/create-delivery-session/index.ts
//
// PRIVILEGED — called only by the native iPad app (SupabaseDeliveryService.
// swift), never by a browser. Two independent checks gate this function:
// 1. Supabase's own platform gate (a valid publishable-key Authorization
//    header — enforced by the platform before this code even runs, since
//    this function is deployed WITHOUT --no-verify-jwt).
// 2. This app's own booth-device check (verifyBoothDevice) — the
//    publishable key is public, so it is deliberately NOT sufficient on
//    its own to reach the code below that check.
//
// Creates the delivery_sessions/delivery_media rows and returns one signed
// Storage upload URL per media item.
//
// Input JSON (camelCase — must match SupabaseDeliveryService.swift exactly):
//   {
//     eventID: string, localSessionID: string, claimToken: string,
//     expiresAt: string (ISO 8601),
//     media: [{ mediaID: string, kind: "photo" | "loopVideo", mimeType: string }]
//   }
// Output JSON:
//   { deliverySessionID: string, uploads: [{ mediaID: string, uploadURL: string }] }
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

import { getServiceClient, isValidUUID, verifyBoothDevice } from "../_shared/boothAuth.ts";

const BUCKET = "booth-media";

function extensionFor(mimeType: string): string {
  switch (mimeType) {
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
      typeof expiresAt !== "string" || !Array.isArray(media) || media.length === 0
    ) {
      return new Response(JSON.stringify({ error: "Invalid request body" }), { status: 400 });
    }
    for (const item of media) {
      if (!isValidUUID(item?.mediaID) || typeof item?.kind !== "string" || typeof item?.mimeType !== "string") {
        return new Response(JSON.stringify({ error: "Invalid media manifest entry" }), { status: 400 });
      }
    }

    const { sha256Hex } = await import("../_shared/boothAuth.ts");
    // Only the hash is stored — the plaintext claimToken is the guest's
    // bearer secret (embedded in the QR code) and is never written to the
    // database.
    const claimTokenHash = await sha256Hex(claimToken);

    const { data: session, error: sessionError } = await supabase
      .from("delivery_sessions")
      .insert({
        external_session_id: localSessionID,
        event_id: eventID,
        claim_token_hash: claimTokenHash,
        status: "preparing",
        expires_at: expiresAt,
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
      JSON.stringify({ deliverySessionID: session.id, uploads }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
