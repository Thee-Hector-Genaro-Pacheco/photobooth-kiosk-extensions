-- 0003_delivery_session_social_cta.sql
--
-- Additive only — adds a snapshot of the event's SocialCTA (see
-- EventConfiguration.swift / BoothSession.socialCTASnapshot) to each
-- delivery session, captured at session-creation time by
-- create-delivery-session. All four columns are nullable: a session with
-- no social CTA configured simply has all four as null, and resolve-claim
-- treats that as "no CTA to show" rather than an error.
--
-- This is a snapshot, not a live reference to any event-configuration
-- table (none exists in this backend — EventConfiguration lives only on
-- the iPad). If an admin later changes or clears the event's CTA, already-
-- created delivery sessions keep whatever was true when the guest's media
-- was captured, matching BoothSession's existing snapshot semantics for
-- paymentState/entitlements.
--
-- Same security posture as 0001/0002: RLS already enabled on
-- delivery_sessions with no client policies, so no new policy is needed
-- here — only Edge Function code with the service/secret key can read or
-- write these columns.

alter table delivery_sessions
  add column if not exists social_cta_platform text,
  add column if not exists social_cta_display_name text,
  add column if not exists social_cta_profile_url text,
  add column if not exists social_cta_message text;

alter table delivery_sessions
  add constraint delivery_sessions_social_cta_platform_check
  check (social_cta_platform is null or social_cta_platform in ('instagram', 'tiktok', 'facebook', 'x', 'other'));
