-- 0005_guest_feedback.sql
--
-- Optional post-download guest feedback from the claim page, plus internal
-- engineering triage for it. Two tables on purpose:
--
--   feedback_submissions  what the guest sent. Written only by the
--                         submit-feedback Edge Function (service role),
--                         which validates every field and derives the
--                         session and event from the claim token itself.
--   feedback_triage       internal only. Never written by any public
--                         endpoint; a row is created automatically (status
--                         'new') for every submission by the trigger below,
--                         and is then edited by Hector in SQL / Table Editor.
--
-- No PII: no name, email, phone, IP, user agent, face data, or media is
-- stored. The guest's free-text comment is the only open field and is
-- capped at 1000 characters.
--
-- Abuse rule: ONE submission per delivery session (unique index below). A
-- second submit for the same claim gets 409 from submit-feedback.
--
-- Retention: if a delivery session is ever deleted, its feedback is kept
-- with delivery_session_id set to null (event_id is kept), so product
-- feedback outlives guest media.
--
-- Same security posture as every other table in this backend: RLS enabled
-- with zero policies for anon/authenticated. Privileges are also revoked
-- from those roles outright, so even a future mistaken policy can't expose
-- these tables through the Data API.

create table if not exists feedback_submissions (
  id uuid primary key default gen_random_uuid(),
  delivery_session_id uuid references delivery_sessions (id) on delete set null,
  -- Copied server-side from delivery_sessions.event_id, never from the client.
  event_id uuid not null,
  rating smallint not null check (rating between 1 and 5),
  -- Must match FEEDBACK_CATEGORIES in functions/_shared/feedback.ts and the
  -- claim page's feedback.js.
  categories text[] not null default '{}' check (
    categories <@ array[
      'photo_quality', 'ai_effects', 'qr_delivery',
      'print_experience', 'ease_of_use', 'something_went_wrong'
    ]::text[]
  ),
  comment text check (comment is null or char_length(comment) between 1 and 1000),
  -- Covers quoting the guest's own words anonymously, nothing else: not
  -- their media, not the event, not the date.
  consent_to_anonymous_testimonial boolean not null default false,
  source text not null default 'claim_page' check (source in ('claim_page')),
  created_at timestamptz not null default now()
);

create unique index if not exists feedback_submissions_one_per_session_idx
  on feedback_submissions (delivery_session_id);

create index if not exists feedback_submissions_event_idx
  on feedback_submissions (event_id);

create index if not exists feedback_submissions_created_at_idx
  on feedback_submissions (created_at desc);

-- Lifecycle:
--   status:          new -> triaged -> planned -> implemented -> verified
--   classification:  set when leaving 'new'; one of not_actionable,
--                    needs_more_data, bug, ux_improvement,
--                    feature_request, event_specific
--   actionable:      null = not reviewed yet, true/false once triaged
-- Only actionable items (bug / ux_improvement / feature_request /
-- event_specific) may move to planned, implemented, or verified.
-- Every value here is set by a person reviewing the feedback; nothing
-- classifies feedback automatically.
create table if not exists feedback_triage (
  feedback_id uuid primary key references feedback_submissions (id) on delete cascade,
  status text not null default 'new'
    check (status in ('new', 'triaged', 'planned', 'implemented', 'verified')),
  classification text
    check (classification in (
      'not_actionable', 'needs_more_data', 'bug',
      'ux_improvement', 'feature_request', 'event_specific'
    )),
  actionable boolean,
  actionability_reason text,
  product_area text
    check (product_area in (
      'capture', 'ar_effects', 'loop', 'qr_delivery', 'claim_page',
      'printing', 'admin', 'hardware', 'event_ops', 'other'
    )),
  severity text check (severity in ('low', 'medium', 'high', 'critical')),
  linked_issue text,
  resolution_note text,
  triaged_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Leaving 'new' requires a classification and an actionable decision.
  constraint feedback_triage_reviewed_check check (
    status = 'new' or (classification is not null and actionable is not null)
  ),
  -- actionable must agree with the classification.
  constraint feedback_triage_actionable_matches_check check (
    classification is null
    or (classification in ('not_actionable', 'needs_more_data') and actionable = false)
    or (classification in ('bug', 'ux_improvement', 'feature_request', 'event_specific') and actionable = true)
  ),
  -- Only actionable work can be planned, implemented, or verified.
  constraint feedback_triage_progress_check check (
    status not in ('planned', 'implemented', 'verified') or actionable = true
  ),
  -- Implemented/verified items record when they were resolved.
  constraint feedback_triage_resolved_check check (
    status not in ('implemented', 'verified') or resolved_at is not null
  )
);

create index if not exists feedback_triage_status_idx on feedback_triage (status);
create index if not exists feedback_triage_classification_idx on feedback_triage (classification);

-- Every submission gets a 'new' triage row, so nothing can be missed and
-- the public endpoint never has to (or get to) touch feedback_triage.
create or replace function create_feedback_triage_row()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  insert into feedback_triage (feedback_id) values (new.id);
  return new;
end;
$$;

drop trigger if exists feedback_submissions_create_triage on feedback_submissions;
create trigger feedback_submissions_create_triage
  after insert on feedback_submissions
  for each row execute function create_feedback_triage_row();

create or replace function touch_feedback_triage()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  if new.status <> 'new' and old.status = 'new' and new.triaged_at is null then
    new.triaged_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists feedback_triage_touch on feedback_triage;
create trigger feedback_triage_touch
  before update on feedback_triage
  for each row execute function touch_feedback_triage();

-- Read-only joined view for triage queries. security_invoker makes it obey
-- the caller's own RLS/privileges instead of the view owner's, so it can't
-- become a back door for anon/authenticated.
create or replace view feedback_inbox
with (security_invoker = true) as
select
  s.id as feedback_id,
  s.created_at,
  s.event_id,
  s.delivery_session_id,
  s.rating,
  s.categories,
  s.comment,
  s.consent_to_anonymous_testimonial,
  t.status,
  t.classification,
  t.actionable,
  t.actionability_reason,
  t.product_area,
  t.severity,
  t.linked_issue,
  t.resolution_note,
  t.triaged_at,
  t.resolved_at
from feedback_submissions s
join feedback_triage t on t.feedback_id = s.id;

alter table feedback_submissions enable row level security;
alter table feedback_triage enable row level security;

revoke all on feedback_submissions from anon, authenticated;
revoke all on feedback_triage from anon, authenticated;
revoke all on feedback_inbox from anon, authenticated;
revoke execute on function create_feedback_triage_row() from public, anon, authenticated;
revoke execute on function touch_feedback_triage() from public, anon, authenticated;

-- Intentionally no CREATE POLICY statements — see the note at the top.
