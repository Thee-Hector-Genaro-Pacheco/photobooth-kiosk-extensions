-- 0004_engagement_events.sql
--
-- Lightweight, additive funnel analytics for the claim page — Social Claim
-- Funnel v1. Deliberately minimal: no biometric data, no Instagram
-- credentials/usernames, no IP or user-agent fingerprinting, no
-- "instagram_followed"/"verified_follow" action (Instagram has not
-- confirmed any such thing through an approved API — a CTA click is not a
-- follow, and this schema has no way to represent one).
--
-- Only three actions exist for v1: claim_viewed, social_cta_clicked,
-- download_clicked. `platform` is only ever set for actions where it's
-- meaningful (social_cta_clicked) and is nullable for the others.
--
-- Same security posture as every other table in this backend: RLS
-- enabled, zero client policies. Only record-engagement (service role)
-- ever writes here; only trusted internal dashboards/SQL (run by Hector,
-- with the secret key) ever read it — no anon/authenticated policy is
-- created.

create table if not exists engagement_events (
  id uuid primary key default gen_random_uuid(),
  delivery_session_id uuid not null references delivery_sessions (id) on delete cascade,
  action text not null check (action in ('claim_viewed', 'social_cta_clicked', 'download_clicked')),
  platform text check (platform is null or platform in ('instagram', 'tiktok', 'facebook', 'x', 'other')),
  created_at timestamptz not null default now()
);

create index if not exists engagement_events_delivery_session_idx
  on engagement_events (delivery_session_id);

create index if not exists engagement_events_action_idx
  on engagement_events (action);

alter table engagement_events enable row level security;

-- Intentionally no CREATE POLICY statements — see the note above.
