// backend/supabase/functions/finalize-delivery-session/index.ts
//
// PRIVILEGED — same booth-device authentication requirement as
// create-delivery-session (see that file's header and
// _shared/boothAuth.ts). Called by the iPad app after every media file has
// been successfully PUT to its signed upload URL. Flips the session to
// "ready" so resolve-claim (called by the public claim page) starts
// serving it. Until this runs, a guest hitting the claim link gets
// "not found" rather than a half-uploaded session.
//
// Input JSON: { deliverySessionID: string }
// Output JSON: { status: "ready" }
//
// NOTE (documented, not implemented, to keep this pass small): a stricter
// version could call supabase.storage.from(BUCKET).list() to verify every
// expected object actually exists before marking the session ready,
// rather than trusting the client's "I uploaded everything" signal. Worth
// adding once real guest traffic starts.

import { getServiceClient, isValidUUID, verifyBoothDevice } from "../_shared/boothAuth.ts";

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
    const { deliverySessionID } = body ?? {};
    if (!isValidUUID(deliverySessionID)) {
      return new Response(JSON.stringify({ error: "Invalid request body" }), { status: 400 });
    }

    const { error } = await supabase
      .from("delivery_sessions")
      .update({ status: "ready" })
      .eq("id", deliverySessionID);

    if (error) {
      return new Response(JSON.stringify({ error: error.message }), { status: 500 });
    }

    return new Response(JSON.stringify({ status: "ready" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
