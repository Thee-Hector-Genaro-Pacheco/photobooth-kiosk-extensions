// backend/supabase/functions/verify-device/index.ts
//
// PRIVILEGED — same booth-device authentication as create-delivery-session
// and finalize-delivery-session (see _shared/boothAuth.ts). Exists purely
// so the admin UI can get a REAL round-trip confirmation that a device's
// Installation ID + Registration Hash have actually been registered in
// `booth_devices`, rather than ever locally faking a "Registered" status.
//
// If this succeeds (200, { registered: true }), the caller's credential
// was found, matched by hash, and enabled — nothing more is implied and
// nothing is changed server-side beyond the usual last_seen_at touch that
// verifyBoothDevice already performs.
//
// Input: none (device identity travels in the X-Booth-* headers)
// Output (200): { registered: true }
// Output (401/403): { registered: false, error: string }

import { getServiceClient, verifyBoothDevice } from "../_shared/boothAuth.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const supabase = getServiceClient();
    const auth = await verifyBoothDevice(req, supabase);
    if (!auth.ok) {
      return new Response(JSON.stringify({ registered: false, error: auth.error }), { status: auth.status });
    }
    return new Response(JSON.stringify({ registered: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ registered: false, error: String(err) }), { status: 500 });
  }
});
