-- 0006_engagement_events_google_platform.sql
--
-- Expand engagement_events.platform allowlist to include 'google' so clicks
-- on the Google Review CTA can be recorded under the existing social_cta_clicked
-- funnel action without creating a separate analytics table.
--
-- Also updates delivery_sessions.social_cta_platform for consistency with
-- the shared platform allowlist in boothAuth.ts.

alter table engagement_events
  drop constraint if exists engagement_events_platform_check;

alter table engagement_events
  add constraint engagement_events_platform_check
  check (platform is null or platform in ('instagram', 'tiktok', 'facebook', 'x', 'other', 'google'));

alter table delivery_sessions
  drop constraint if exists delivery_sessions_social_cta_platform_check;

alter table delivery_sessions
  add constraint delivery_sessions_social_cta_platform_check
  check (social_cta_platform is null or social_cta_platform in ('instagram', 'tiktok', 'facebook', 'x', 'other', 'google'));
