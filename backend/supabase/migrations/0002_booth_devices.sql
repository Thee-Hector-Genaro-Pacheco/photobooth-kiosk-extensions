-- 0002_booth_devices.sql
--
-- Registry of provisioned booth (iPad) installations. Possession of the
-- public Supabase publishable key must never be sufficient on its own to
-- create upload sessions — this table is what create-delivery-session and
-- finalize-delivery-session check (via _shared/boothAuth.ts) before doing
-- any privileged work.
--
-- token_hash is SHA-256 of a 32-byte random secret generated on-device and
-- stored only in that device's iOS Keychain (see BoothDeviceIdentity.swift
-- on the client). The raw token is NEVER sent to or stored by this
-- database — only its hash, which Hector copies from the admin UI into a
-- row here manually. There is no manual step that ever involves the raw
-- token.
--
-- Same security posture as 0001: RLS is enabled, no policies are created
-- for anon/authenticated, so those roles get zero access. Only Edge
-- Function code running with the service/secret key can read or write
-- this table.

create table if not exists booth_devices (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid unique not null,
  token_hash text unique not null,
  display_name text,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);

create index if not exists booth_devices_installation_id_idx on booth_devices (installation_id);

alter table booth_devices enable row level security;

-- Intentionally no CREATE POLICY statements — see the note above.
