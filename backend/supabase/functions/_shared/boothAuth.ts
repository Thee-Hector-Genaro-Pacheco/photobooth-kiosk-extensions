// backend/supabase/functions/_shared/boothAuth.ts
//
// Shared helpers for the Edge Functions in this directory. Imported by
// relative path, so `supabase functions deploy <name>` bundles this file
// automatically — no separate deploy step needed for it.
//
// KEY MODEL: current hosted Supabase Edge Functions auto-inject
// SUPABASE_SECRET_KEYS — a JSON object of secret keys keyed by name (e.g.
// {"default": "sb_secret_..."}). getServiceClient() below parses that and
// uses the "default" entry. This is read from the environment Supabase
// provides automatically; Hector never copies a secret key into this repo,
// a plist, or anywhere else.
//
// SUPABASE_SERVICE_ROLE_KEY (the legacy single-string env var) is kept
// ONLY as a MIGRATION COMPATIBILITY fallback for older projects that
// haven't moved to the SUPABASE_SECRET_KEYS model yet — it is not the
// primary production path. Do not design new code around it.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const data = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function getServiceClient(): SupabaseClient {
  const projectURL = Deno.env.get("SUPABASE_URL");
  if (!projectURL) {
    throw new Error("SUPABASE_URL is not available in this Edge Function's environment.");
  }

  // Current hosted Supabase environment: a JSON object of secret keys,
  // keyed by name. "default" is the project's primary secret
  // (sb_secret_...) key.
  let secretKey: string | undefined;
  const secretKeysRaw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (secretKeysRaw) {
    try {
      const secretKeys = JSON.parse(secretKeysRaw) as Record<string, string>;
      secretKey = secretKeys["default"];
    } catch {
      // Malformed value — fall through to the legacy path below.
    }
  }

  // MIGRATION COMPATIBILITY ONLY — not the primary production path. Some
  // older projects may still inject SUPABASE_SERVICE_ROLE_KEY instead of
  // SUPABASE_SECRET_KEYS; this keeps this backend working there too
  // without requiring Hector to manually source a secret from anywhere.
  if (!secretKey) {
    secretKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  }

  if (!secretKey) {
    throw new Error("No Supabase secret key is available in this Edge Function's environment.");
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

// Platforms allowed for SocialCTA snapshots and funnel engagement tracking.
const SOCIAL_CTA_PLATFORMS = ["instagram", "tiktok", "facebook", "x", "other", "google"] as const;

export function isValidSocialCTAPlatform(value: unknown): value is string {
  return typeof value === "string" && (SOCIAL_CTA_PLATFORMS as readonly string[]).includes(value);
}

// Deliberately does NOT include anything like "instagram_followed" or
// "verified_follow" — this backend has no way to confirm a real follow
// (no approved Instagram API integration), so no action name may imply
// one. A social CTA click is tracked as a click, nothing more.
const ENGAGEMENT_ACTIONS = ["claim_viewed", "social_cta_clicked", "download_clicked"] as const;

export function isValidEngagementAction(value: unknown): value is string {
  return typeof value === "string" && (ENGAGEMENT_ACTIONS as readonly string[]).includes(value);
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
 * `X-Booth-Token` carries the canonical base64url token string exactly as
 * generated on-device (see BoothDeviceIdentity.swift) — hashed here as-is
 * (SHA-256 of its UTF-8 bytes), with no intermediate binary<->text
 * conversion to drift out of sync with the client. The lookup is split
 * into three explicit steps (device found by installation ID -> hash
 * matches -> enabled) so a 403 can be attributed internally to exactly one
 * cause; the public response stays a generic 403 either way so guests
 * never see which specific check failed.
 */
export async function verifyBoothDevice(req: Request, supabase: SupabaseClient): Promise<BoothDeviceCheck> {
  const installationID = req.headers.get("X-Booth-Installation-ID");
  const rawToken = req.headers.get("X-Booth-Token");
  console.log(
    `[boothAuth] installationID=${installationID ?? "missing"} tokenHeaderPresent=${!!rawToken} tokenLength=${rawToken?.length ?? 0}`,
  );

  if (!installationID || !rawToken || !isValidUUID(installationID)) {
    console.log("[boothAuth] result=REJECTED reason=MISSING_OR_MALFORMED_CREDENTIALS");
    return { ok: false, status: 401, error: "Missing or malformed booth device credentials." };
  }

  const tokenHash = await sha256Hex(rawToken);
  console.log(`[boothAuth] computedHashPrefix=${tokenHash.slice(0, 8)}`);

  const genericRejection = { ok: false as const, status: 403, error: "This booth device is not registered or is disabled." };

  const { data: device, error } = await supabase
    .from("booth_devices")
    .select("id, enabled, token_hash")
    .eq("installation_id", installationID)
    .maybeSingle();

  if (error) {
    console.log(`[boothAuth] result=ERROR reason=QUERY_ERROR message=${error.message}`);
    return { ok: false, status: 500, error: error.message };
  }

  if (!device) {
    console.log("[boothAuth] result=REJECTED reason=DEVICE_NOT_FOUND");
    return genericRejection;
  }

  console.log(`[boothAuth] deviceFound=true storedHashPrefix=${device.token_hash.slice(0, 8)} enabled=${device.enabled}`);

  if (device.token_hash !== tokenHash) {
    console.log("[boothAuth] result=REJECTED reason=TOKEN_HASH_MISMATCH");
    return genericRejection;
  }

  if (device.enabled !== true) {
    console.log("[boothAuth] result=REJECTED reason=DEVICE_DISABLED");
    return genericRejection;
  }

  console.log("[boothAuth] result=OK");
  // Best-effort — a failure updating last_seen_at should never block the
  // actual privileged operation the caller is authorized to perform.
  await supabase.from("booth_devices").update({ last_seen_at: new Date().toISOString() }).eq("id", device.id);

  return { ok: true, installationID };
}
