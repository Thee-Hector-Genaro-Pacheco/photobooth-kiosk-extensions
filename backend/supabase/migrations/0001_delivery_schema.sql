-- 0001_delivery_schema.sql
--
-- Minimal claim-delivery schema: two tables plus a private Storage bucket.
-- No guest face landmarks, no biometric data, no unnecessary PII — just
-- what's needed to resolve a claim token into signed media download URLs.
--
-- The claim token itself is NEVER stored — only claim_token_hash (SHA-256
-- of the token). The plaintext token is the public bearer capability
-- embedded in the QR code; anyone with only database access can't derive
-- it back from the hash.
--
-- SECURITY POSTURE (read before adding policies):
-- RLS is enabled on both tables and the Storage bucket is private, but NO
-- policies are created for the `anon` or `authenticated` roles. In
-- Postgres/Supabase, enabling RLS with zero matching policies means those
-- roles have ZERO access — not "read-only", not "scoped", literally none.
-- Every read/write in this schema happens exclusively through the Edge
-- Functions in backend/supabase/functions/, which run with the
-- service-role key (auto-injected by Supabase into every deployed
-- function's environment — never stored here, never touched by the iPad
-- app or the claim page). Do NOT add a policy like "authenticated/anon can
-- read all booth-media" — that defeats the whole point of this design.

create extension if not exists pgcrypto;

create table if not exists delivery_sessions (
  id uuid primary key default gen_random_uuid(),
  -- The local BoothSession.id from the iPad app. Not the public secret —
  -- see claim_token_hash for that.
  external_session_id uuid not null unique,
  event_id uuid not null,
  claim_token_hash text not null unique,
  status text not null default 'preparing' check (status in ('preparing', 'ready', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists delivery_sessions_claim_token_hash_idx
  on delivery_sessions (claim_token_hash);

create table if not exists delivery_media (
  id uuid primary key default gen_random_uuid(),
  delivery_session_id uuid not null references delivery_sessions (id) on delete cascade,
  -- The local MediaItem.id from the iPad app.
  external_media_id uuid not null,
  storage_object_path text not null,
  media_kind text not null check (media_kind in ('photo', 'loopVideo')),
  mime_type text not null,
  created_at timestamptz not null default now(),
  unique (delivery_session_id, external_media_id)
);

create index if not exists delivery_media_session_idx
  on delivery_media (delivery_session_id);

-- Private Storage bucket for guest media. `public = false` is load-bearing:
-- this must never flip to true, and object paths are never guessable
-- (each includes a fresh UUID), so there is no permanent public URL.
insert into storage.buckets (id, name, public)
values ('booth-media', 'booth-media', false)
on conflict (id) do nothing;

alter table delivery_sessions enable row level security;
alter table delivery_media enable row level security;

-- Intentionally no CREATE POLICY statements for delivery_sessions or
-- delivery_media — see the security posture note above.
