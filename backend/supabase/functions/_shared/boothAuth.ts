// backend/supabase/functions/_shared/boothAuth.ts
//
// Shared helpers for the Edge Functions in this directory. Imported by
// relative path, so `supabase functions deploy <name>` bundles this file
// automatically — no separate deploy step needed for it.
//
// KEY MODEL: Supabase is migrating from legacy ANON_KEY/SERVICE_ROLE_KEY
// naming to sb_publishable_.../sb_secret_.... getServiceClient() below
// reads SUPABASE_SECRET_KEY first and falls back to
// SUPABASE_SERVICE_ROLE_KEY, because the exact *env var name* Supabase
// auto-injects may lag behind the *key format* rename on some project
// generations. Verify against Supabase's current Edge Function docs at
// deploy time and simplify this fallback once you've confirmed which name
// your project actually injects. Either way, this is read from the
// environment Supabase provides automatically — it is never hardcoded
// here, never stored in this repo, and never touched by the iPad app or
// the claim page.

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const data = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Decodes a lowercase-hex string (as sent by SupabaseDeliveryService.swift
/// in the `X-Booth-Token` header) back into raw bytes.
export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const bytes = new Uint8Array(Math.floor(clean.length / 2));
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(clean.substr(i * 2, 2), 16);
  }
  return bytes;
}

export function getServiceClient(): SupabaseClient {
  const secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const projectURL = Deno.env.get("SUPABASE_URL");
  if (!secretKey || !projectURL) {
    throw new Error("Supabase server credentials are not available in this Edge Function's environment.");
  }
  return createClient(projectURL, secretKey);
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/// Strict UUID check used before any user-supplied identifier is allowed
/// into a Storage object path — the only thing standing between a caller
/// and `../` traversal or cross-event path injection.
export function isValidUUID(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export type BoothDeviceCheck =
  | { ok: true; installationID: string }
  | { ok: false; status: number; error: string };

/**
 * Verifies the caller is a provisioned, enabled booth device. Possession
 * of the public publishable key is NOT sufficient on its own to reach this
 * far in the app's own authorization logic — this checks a separate
 * per-installation secret token that exists only in one specific iPad's
 * Keychain and in exactly one `booth_devices` row.
 *
 * The comparison is a database equality lookup on the *hash* column (never
 * the raw token, and never an application-side string compare), so there
 * is no local timing side-channel to defend against here — Postgres does
 * an indexed exact match, not a byte-by-byte JS comparison.
 */
export async function verifyBoothDevice(req: Request, supabase: SupabaseClient): Promise<BoothDeviceCheck> {
  const installationID = req.headers.get("X-Booth-Installation-ID");
  const rawTokenHex = req.headers.get("X-Booth-Token");
  if (!installationID || !rawTokenHex || !isValidUUID(installationID)) {
    return { ok: false, status: 401, error: "Missing or malformed booth device credentials." };
  }

  const tokenHash = await sha256Hex(hexToBytes(rawTokenHex));

  const { data: device, error } = await supabase
    .from("booth_devices")
    .select("id, enabled")
    .eq("installation_id", installationID)
    .eq("token_hash", tokenHash)
    .maybeSingle();

  if (error) {
    return { ok: false, status: 500, error: error.message };
  }
  if (!device || device.enabled !== true) {
    return { ok: false, status: 403, error: "This booth device is not registered or is disabled." };
  }

  // Best-effort — a failure updating last_seen_at should never block the
  // actual privileged operation the caller is authorized to perform.
  await supabase.from("booth_devices").update({ last_seen_at: new Date().toISOString() }).eq("id", device.id);

  return { ok: true, installationID };
}
