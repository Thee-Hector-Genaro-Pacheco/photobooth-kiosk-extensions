// backend/supabase/functions/create-delivery-session/expiry.ts
//
// Server-authoritative expiry for delivery sessions. The iPad sends the
// event's retention policy as `expiresAt`, but that value is only a request:
// a modified client could otherwise keep guest media claimable forever.
// The requested value is honored only when it is in the future and no more
// than MAX_RETENTION_DAYS out; anything else (past, too far, missing,
// unparseable) gets DEFAULT_RETENTION_DAYS from now.
//
// Kept in its own module, with no imports, so it can be unit tested without
// starting the Deno.serve handler in index.ts.

/** Longest retention the server will ever grant, in days. */
export const MAX_RETENTION_DAYS = 30;

/** Retention used when the client's request is missing or out of range, in days. */
export const DEFAULT_RETENTION_DAYS = 14;

const DAY_MS = 24 * 60 * 60 * 1000;

/** Returns the ISO 8601 expiry to store for a session created at `now`. */
export function resolveExpiresAt(requested: unknown, now: Date = new Date()): string {
  const nowMs = now.getTime();
  const fallback = new Date(nowMs + DEFAULT_RETENTION_DAYS * DAY_MS).toISOString();

  if (typeof requested !== "string" || requested.length === 0) return fallback;
  const requestedMs = Date.parse(requested);
  if (Number.isNaN(requestedMs)) return fallback;

  const maxMs = nowMs + MAX_RETENTION_DAYS * DAY_MS;
  if (requestedMs <= nowMs || requestedMs > maxMs) return fallback;

  return new Date(requestedMs).toISOString();
}
