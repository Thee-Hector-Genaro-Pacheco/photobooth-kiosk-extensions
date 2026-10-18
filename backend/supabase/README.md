# Photo Booth — Supabase delivery backend (source only)

This directory contains **source only**. Nothing here has been deployed,
and no Supabase project, bucket, table, function, or secret has been
created on your behalf. You (Hector) run every command below manually,
when ready.

## What this is

Two migrations + four Edge Functions implementing the "accepted media →
private upload → QR claim link → guest downloads it" flow, with a booth
device credential so the publishable key alone can never trigger an upload:

- `migrations/0001_delivery_schema.sql` — `delivery_sessions` /
  `delivery_media` tables, RLS enabled with **no client policies**, and a
  **private** `booth-media` Storage bucket.
- `migrations/0002_booth_devices.sql` — `booth_devices`, the registry of
  provisioned iPad installations. Same "RLS on, zero client policies"
  posture.
- `migrations/0003_delivery_session_social_cta.sql` — adds four nullable
  columns to `delivery_sessions` holding a snapshot of the event's
  `SocialCTA` at the moment the session was created (Social Claim Funnel
  v1). Additive only; a session with no CTA just has all four as null.
- `migrations/0004_engagement_events.sql` — `engagement_events`, lightweight
  funnel analytics (`claim_viewed`, `social_cta_clicked`,
  `download_clicked`). Same "RLS on, zero client policies" posture. See
  "Social Claim Funnel v1" below for what this deliberately does NOT track.
- `migrations/0005_guest_feedback.sql` — `feedback_submissions` (what a
  guest sends from the claim page) and `feedback_triage` (internal only,
  one row created automatically per submission), plus the read-only
  `feedback_inbox` view. Same "RLS on, zero client policies" posture, with
  privileges also revoked from `anon`/`authenticated`. See "Guest feedback
  and Google review" below.
- `functions/_shared/boothAuth.ts` — shared helpers: the Supabase service
  client, UUID validation, `verifyBoothDevice`, and the
  `isValidSocialCTAPlatform`/`isValidEngagementAction` allowlist checks
  used by `create-delivery-session` and `record-engagement`.
- `functions/create-delivery-session/` — **privileged**. Called by the
  iPad app right after a guest accepts their photo/Loop. Requires a valid
  booth device credential (see below). Creates the DB rows and returns
  one signed Storage **upload** URL per media item.
- `functions/finalize-delivery-session/` — **privileged**, same device
  requirement. Called by the iPad app after every file has uploaded
  successfully. Flips the session to `ready`.
- `functions/verify-device/` — **privileged**, same device requirement.
  Called only by the admin UI's "Verify Registration" button — a real
  round-trip confirmation that a device is registered, so the app never
  has to fake that status locally.
- `functions/resolve-claim/` — **public/guest-facing**. Called by the
  claim page, never by the iPad app. No device credential required or
  accepted — its authorization capability is the claim token itself.
  Verifies the claim token, checks expiration, and returns short-lived
  signed **download** URLs (15 minutes), plus the session's `socialCTA`
  snapshot (or `null`).
- `functions/record-engagement/` — **public/guest-facing**, same
  authorization model as `resolve-claim` (claim token only, no device
  credential, deployed with `--no-verify-jwt`). Called by the claim page,
  fire-and-forget, to record `claim_viewed` / `social_cta_clicked` /
  `download_clicked`. Never accepts a client-supplied
  `delivery_session_id` — always re-resolves it from the claim token
  server-side, exactly like `resolve-claim`.
- `functions/submit-feedback/` — **public/guest-facing**, same model
  again (claim token only, `--no-verify-jwt`). Validates and stores
  optional post-download feedback. Never reads, writes, or returns triage
  data. Validation lives in `functions/_shared/feedback.ts`.
- `functions/event-analytics/` — **service-to-service read-only**. Called by the
  Pacific Rising Ops business agent. Authenticated via `REPORTING_AGENT_API_KEY`
  (`Authorization: Bearer <REPORTING_AGENT_API_KEY>`, deployed with `--no-verify-jwt`).
  Provides read-only queries for session counts, claim views, downloads, social CTA
  clicks (Instagram, TikTok, Google Review), feedback summaries, delivery health,
  and event comparisons.

## Social Claim Funnel v1 — what this does and does NOT track

The claim page can show an optional social CTA (e.g. "Follow
@pacifichorizonlabs on Instagram") above the guest's media, sourced from
the iPad app's existing `EventConfiguration.socialCTA` — nothing new to
configure beyond what the admin editor's "Social" section already exposes.
The flow:

```
EventConfiguration.socialCTA (iPad, admin-configured, already existed)
  -> SupabaseDeliveryService sends it as part of create-delivery-session
  -> stored as a snapshot on delivery_sessions (0003 migration)
  -> resolve-claim returns it as part of its normal response
  -> the claim page renders it (or nothing, if it's null)
```

It's a snapshot, not a live reference: if an admin edits or clears an
event's CTA later, sessions already created keep showing what was
configured when that guest's media was captured — same pattern as
`BoothSession`'s existing `paymentState`/`entitlements` snapshots.

**Following is never required to receive media.** The "Follow" button
opens Instagram in a new tab; the guest's photo/Loop renders and is
downloadable identically whether or not that button is ever tapped, and
identically whether or not any CTA is configured at all.

**Engagement tracking only ever records a click, never a follow.** The
`engagement_events` table (0004 migration) has exactly three allowed
`action` values: `claim_viewed`, `social_cta_clicked`, `download_clicked`.
There is deliberately no `instagram_followed`, `instagram_liked`, or
`verified_follow` action, and none will be added without an actual
approved Instagram API integration that can confirm those things — a
click on the Instagram CTA is not evidence of a follow, and this schema
has no way to claim otherwise. Likewise `download_clicked`, not
`download_completed`: browser JS can know the guest tapped Download, not
that the file finished saving. No biometric data, Instagram
credentials/usernames, IP addresses, or user-agent strings are ever
recorded.

To measure the funnel, query `engagement_events` grouped by `action`
(optionally joined to `delivery_sessions` for a date/event filter), e.g.:

```sql
select action, count(*) from engagement_events group by action;
```

**Setting up the Pacific Horizon Labs CTA** (or any other event's CTA) —
no new UI, this uses the existing admin "Social" section on the iPad:

- Display Name: `@pacifichorizonlabs` (rendered verbatim as "Follow
  @pacifichorizonlabs" / "Tag @pacifichorizonlabs when you post.")
- Profile URL: `https://www.instagram.com/pacifichorizonlabs/`
- Message: e.g. "Follow us on Instagram to see new event experiences, AI
  portraits & creative technology."
- Platform: defaults to Instagram (`SocialCTA(platform: .instagram, ...)`
  in `AdminEventEditorView`'s "Enable Social CTA" toggle — no platform
  picker exists in the admin UI yet since only Instagram is needed for v1).

## Guest feedback and Google review

### What the guest sees

After a guest's first **Save / Share** tap, the claim page shows a compact
panel below the media controls (`../claim-page/feedback.js`). The save
itself starts exactly as before; the panel never blocks, delays, or
replaces it. It has two independent, optional parts:

1. **Google review**, on top. "Share your experience on Google" with a
   **★ Leave a Google Review** button that opens Google in a new tab. Shown
   to every guest whenever `GOOGLE_REVIEW_URL` is set. It is rendered once,
   from the URL alone, before the form exists: the star rating, tags,
   comment, and whether feedback was sent never show, hide, or change it.
   No review gating, no "5 stars" wording, no reward or incentive.
2. **Private feedback**, below. A 1–5 star rating ("N out of 5" for screen
   readers), optional tags, an optional comment (1000 characters max), and
   an unticked-by-default checkbox for quoting the comment as an anonymous
   testimonial. **Send Feedback** posts to `submit-feedback`; **Not now**
   removes the form (and the whole panel if no Google link is configured).

Messages: success "Thank you — your feedback helps us improve the Photo
Booth."; duplicate (409) "Feedback already received. Thank you."; expired
or unknown claim "This link can no longer take feedback."; network or
server failure "Couldn’t send your feedback. Please try again." with the
form kept for a retry. None of these touch the media section.

### GOOGLE_REVIEW_URL (manual step)

Set it in `../claim-page/index.html`: the `GOOGLE_REVIEW_URL` constant near
the top of the `<script type="module">` block, next to `TIKTOK_URL`. It is
`""` until you paste the direct review link from Google Business Profile →
**Ask for reviews** (shape `https://g.page/r/<id>/review`, or
`https://search.google.com/local/writereview?placeid=<id>`), then redeploy
the claim page. It's a public URL, not a secret.

While it's empty, not https, not a Google host, or still a template value
(`YOUR…`, `<id>`), the Google section isn't rendered at all: no fake link,
no generic Google search. Private feedback works normally either way.

### Migration order and deploy

Migrations run in filename order with `supabase db push`:
`0001_delivery_schema` → `0002_booth_devices` →
`0003_delivery_session_social_cta` → `0004_engagement_events` →
`0005_guest_feedback`. 0005 depends only on `delivery_sessions` from 0001.

```
cd backend/supabase
supabase db push
supabase functions deploy submit-feedback --no-verify-jwt
```

Then redeploy the claim page with `feedback.js` next to `index.html`.

### Guest submission flow

```
claim page (Send Feedback)
  -> POST submit-feedback { claimToken, rating, categories?, comment?, consentToAnonymousTestimonial? }
  -> validate body (shape, allowlist, sizes)
  -> SHA-256(claimToken) -> delivery_sessions row; must be status 'ready' and unexpired
  -> insert feedback_submissions (session id + event id copied from that row)
  -> trigger inserts feedback_triage (status 'new')
```

| Status | Body | When |
|---|---|---|
| 201 | `{ "status": "received" }` | stored |
| 400 | `{ "error": "..." }` | bad JSON, unknown or internal field, bad rating/category/comment/consent |
| 404 | `{ "status": "not_found" }` | no ready session for this token |
| 409 | `{ "status": "already_submitted" }` | this session already has feedback |
| 410 | `{ "status": "expired" }` | session expired |
| 413 | `{ "error": "Request too large" }` | body over 8 KB |
| 500 | `{ "error": "Could not save feedback" }` | anything else; no database detail is returned |

Validation (`functions/_shared/feedback.ts`):
- Accepted keys are exactly `claimToken`, `rating`, `categories`,
  `comment`, `consentToAnonymousTestimonial`. Anything else rejects the
  request, including every triage field and any session or event id
  (`deliverySessionId`, `eventId`, …), so the browser can never choose
  which session it writes to.
- `rating`: whole number 1–5, required.
- `categories`: optional, only `photo_quality`, `ai_effects`,
  `qr_delivery`, `print_experience`, `ease_of_use`,
  `something_went_wrong`; duplicates collapse.
- `comment`: optional, trimmed, max 1000 characters (counted the same way
  as Postgres `char_length`); blank becomes null.
- `consentToAnonymousTestimonial`: optional boolean, absent = `false`.

### Duplicate rule

One submission per delivery session, enforced by a unique index on
`feedback_submissions.delivery_session_id`, so it holds even under
concurrent requests. A second submit for the same claim returns 409
`already_submitted` and stores nothing. A session is one capture, and a
group sharing one QR shares one feedback slot; that's the scope the claim
token actually identifies.

### Security model

- **Writes** happen only through `submit-feedback`, which runs with the
  service role injected by Supabase. No key is in the claim page, the iPad
  app, or Git.
- **RLS** is enabled on `feedback_submissions` and `feedback_triage` with no
  policies, matching every other table here. On top of that, all
  privileges on both tables and the `feedback_inbox` view are revoked
  from `anon` and `authenticated`, so the Data API can't select, insert,
  update, or delete them even with the publishable key.
- `feedback_inbox` is created `with (security_invoker = true)`, so it
  can't be used to bypass those privileges.
- The public endpoint never reads or returns triage data.

### Privacy

- Stored per submission: rating, categories, comment, consent flag,
  source, timestamps, and the server-derived session and event ids.
- Never stored: name, email, phone, IP address, user agent, face data,
  or any media.
- Feedback is optional and never required to get media.
- Testimonial consent defaults to unticked and covers quoting the guest's
  own words without their name. It does not cover their photos, the
  event, the date, or anything else from the session.
- If a delivery session is deleted, its feedback stays with
  `delivery_session_id` set to null.

### Triage in Supabase Studio

There's no authenticated admin web UI in this project (the iPad admin
screen is a kiosk surface guests stand next to), so triage happens in the
Supabase dashboard, which runs with full privileges: **SQL Editor** for
the queries below, or **Table Editor → feedback_triage** to edit a row.
An admin dashboard is a later milestone.

Lifecycle, all set by a person (nothing is classified automatically):

- `status`: `new` → `triaged` → `planned` → `implemented` → `verified`
- `classification` (required when leaving `new`): `not_actionable`,
  `needs_more_data`, `bug`, `ux_improvement`, `feature_request`,
  `event_specific`
- `actionable`: null until reviewed; must be false for not_actionable /
  needs_more_data and true for the other four. Only actionable items can
  be planned, implemented, or verified; implemented/verified need
  `resolved_at`. CHECK constraints reject anything inconsistent.
- Also: `actionability_reason`, `product_area`, `severity`, `linked_issue`,
  `resolution_note`. `triaged_at`, `created_at`, and `updated_at` fill
  themselves in.

```sql
-- Newest feedback
select * from feedback_inbox order by created_at desc limit 50;

-- Low ratings (1–2 stars)
select created_at, rating, categories, comment, status
from feedback_inbox where rating <= 2 order by created_at desc;

-- Tagged "Something went wrong"
select * from feedback_inbox
where 'something_went_wrong' = any (categories) order by created_at desc;

-- Untriaged
select * from feedback_inbox where status = 'new' order by created_at;

-- Actionable work not yet verified
select feedback_id, classification, product_area, severity, status, linked_issue, comment
from feedback_inbox where actionable and status <> 'verified'
order by severity desc nulls last, created_at;

-- Counts by category
select category, count(*) from feedback_submissions, unnest(categories) as category
group by category order by count(*) desc;

-- Rating average and distribution
select round(avg(rating), 2) as average, count(*) as total from feedback_submissions;
select rating, count(*) from feedback_submissions group by rating order by rating;

-- Ratings per event
select event_id, count(*), round(avg(rating), 2) as average
from feedback_submissions group by event_id order by count(*) desc;

-- Testimonial consent (quote the comment only, without a name)
select created_at, rating, comment from feedback_inbox
where consent_to_anonymous_testimonial and comment is not null
order by created_at desc;

-- Triage as actionable work
update feedback_triage
set status = 'triaged', classification = 'bug', actionable = true,
    actionability_reason = 'QR page slow on cellular', product_area = 'claim_page',
    severity = 'medium'
where feedback_id = '<feedback-id>';

-- Triage as not actionable (or needs_more_data)
update feedback_triage
set status = 'triaged', classification = 'not_actionable', actionable = false,
    actionability_reason = 'Venue Wi-Fi outage'
where feedback_id = '<feedback-id>';

-- Move actionable work along
update feedback_triage set status = 'planned', linked_issue = 'https://github.com/.../issues/42'
where feedback_id = '<feedback-id>';
update feedback_triage set status = 'implemented', resolved_at = now(),
    resolution_note = 'Signed URLs now prefetched'
where feedback_id = '<feedback-id>';
update feedback_triage set status = 'verified' where feedback_id = '<feedback-id>';
```

## Current Supabase key model — read this before deploying

Supabase is migrating key naming from the legacy `ANON_KEY`/
`SERVICE_ROLE_KEY` convention to `sb_publishable_...` / `sb_secret_...`.
This backend is written for the new naming:

| Term used here | Legacy name | Public or secret? |
|---|---|---|
| Publishable key (`sb_publishable_...`) | "anon key" | **Public by design** |
| Secret key (`sb_secret_...`) | "service role key" | **Secret — never on-device, never in Git** |

`_shared/boothAuth.ts`'s `getServiceClient()` reads the **current hosted
Supabase environment variable** `SUPABASE_SECRET_KEYS` — a JSON object of
secret keys keyed by name (e.g. `{"default": "sb_secret_..."}") — and uses
the `"default"` entry. `SUPABASE_SERVICE_ROLE_KEY` (the legacy single-string
variable) is kept only as a **migration-compatibility fallback** for older
projects that haven't moved to `SUPABASE_SECRET_KEYS` yet; it is not the
primary path and shouldn't be designed around going forward.

**You never manually set any of these as a function secret.** Supabase
auto-injects `SUPABASE_SECRET_KEYS` (or, on older projects,
`SUPABASE_SERVICE_ROLE_KEY`) plus `SUPABASE_URL` into every deployed Edge
Function's environment automatically. You never copy/paste a secret key
anywhere.

## The booth device credential — why it exists

The publishable key is public. If `create-delivery-session` only checked
"did the caller send a valid publishable key," anyone who extracted that
key from the iPad app or the claim page's JS could create upload sessions
and fill your bucket. So the two privileged functions require a **second,
private credential**: a 32-byte random secret generated on-device and
stored only in that specific iPad's iOS Keychain
(`BoothDeviceIdentity.swift`), scoped `...AfterFirstUnlockThisDeviceOnly`
so it can never migrate to another physical device via backup/restore.

Exact token lifecycle:
- Stored persistently **only** in the iOS Keychain.
- Loaded into memory only momentarily, when building an outgoing request.
- Transmitted only over HTTPS, as the `X-Booth-Token` header.
- Never logged, never displayed in any UI (including this app's own admin
  screen), never written to a plist/UserDefaults/file, never committed.
- **You (Hector) never manually copy the raw token anywhere** — there is
  no step in this process that involves it. The server stores only
  `SHA-256(token)`.

The admin UI shows three states, and only ever claims the third after a
real check — never a local guess:

- **Not Generated** — no identity exists on this installation yet.
- **Identity Generated / Registration Required** — a local
  Installation ID + token exist, but this app cannot yet confirm the
  backend knows about them (either you haven't registered them yet, or
  the backend isn't deployed). Shown with the Installation ID and
  Registration Hash to copy.
- **Registered** — reached only after tapping **Verify Registration** and
  getting back a real confirmed response from `verify-device`.

To provision an iPad:

1. On the iPad, open the admin screen (long-press "PHOTO BOOTH" on the
   Ready screen) and tap **Generate Device Identity** under "Delivery
   Device." This is a one-time action per iPad installation (or per
   re-provision, which is destructive — see the in-app confirmation, and
   note it also resets status back to "Registration Required").
2. The screen shows an **Installation ID** (a UUID) and a **Registration
   Hash** (hex SHA-256). Copy both — never the raw token; there is nothing
   else to copy.
3. Insert a row into `booth_devices` (Table Editor, or SQL below) with
   those two values:
   ```sql
   insert into booth_devices (installation_id, token_hash, display_name)
   values ('PASTE-INSTALLATION-ID-HERE', 'paste-registration-hash-here', 'iPad — front desk');
   ```
   Do this once per physical iPad you deploy.
4. Back on the iPad, tap **Verify Registration**. Once `verify-device` is
   deployed and the row above exists, this flips the status to
   **Registered**. Before the backend is deployed, this will correctly
   fail with "could not confirm" rather than pretending to succeed.

If you ever need to revoke a specific iPad's delivery access without
regenerating anything, set `enabled = false` on its row.

## Which values are public vs. secret — full list

**PUBLIC / safe on the client:**
- Project URL
- `sb_publishable_...` publishable key
- Public claim-page URL
- Installation ID (a UUID — identifies a device, doesn't authenticate it)
- Booth device **token hash** (a one-way hash — not the credential itself)

**SECRET — must never be saved into the iPad project, Git, this repo, or
any document/prompt:**
- `sb_secret_...` server key (auto-injected into Edge Functions by
  Supabase — you never copy/paste it)
- The raw booth device token (generated and stored automatically in the
  iPad's Keychain — there is no manual copy step for it; if any future
  instruction ever asks you to paste it somewhere, that instruction is
  wrong and you should stop)

## One-time manual setup (run these yourself — nothing here is automated)

1. **Create the Supabase project** (Free plan) at https://supabase.com/dashboard.
   Note the project's Reference ID and region.

2. **Install/authenticate the Supabase CLI** (only if not already):
   ```
   brew install supabase/tap/supabase
   supabase login
   ```

3. **Link this repo's `backend/supabase` directory to your project:**
   ```
   cd backend/supabase
   supabase link --project-ref <your-project-ref>
   ```

4. **Run all migrations** (creates the tables, RLS, the private bucket,
   the device registry, the social CTA snapshot columns, and
   `engagement_events`):
   ```
   supabase db push
   ```

5. **Deploy all six functions with `--no-verify-jwt`.** This is
   load-bearing for all three privileged functions
   (`create-delivery-session`, `finalize-delivery-session`,
   `verify-device`), not just the two public ones — relying on Supabase's
   platform JWT/apikey gate for them was tried and caused booth
   authentication failures (403s) in practice, so it's deliberately
   bypassed everywhere. Their real, and only, access control is
   `verifyBoothDevice()` — the app-level `X-Booth-Installation-ID` /
   `X-Booth-Token` check against `booth_devices` — enforced in each
   function's own code, independent of anything Supabase's gateway would
   otherwise check. `resolve-claim` and `record-engagement` are
   public/guest-facing and use the same flag so the claim page never needs
   to embed any Supabase key; their authorization is the claim token
   itself.
   ```
   supabase functions deploy create-delivery-session --no-verify-jwt
   supabase functions deploy finalize-delivery-session --no-verify-jwt
   supabase functions deploy verify-device --no-verify-jwt
   supabase functions deploy resolve-claim --no-verify-jwt
   supabase functions deploy record-engagement --no-verify-jwt
   supabase functions deploy submit-feedback --no-verify-jwt
   ```

   If `create-delivery-session` and `resolve-claim` were already deployed
   before the Social Claim Funnel v1 change, both need a **re-deploy** to
   pick up the socialCTA read/write logic — same commands above.

6. **Get your public values** from Project Settings → API in the Supabase
   dashboard: Project URL and the publishable key.

7. **Create the iPad-only local config file** (never committed — already
   in `.gitignore`) at:
   `ios/photobooth/photobooth/SupabaseDeliveryConfig.plist`
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>projectURL</key>
       <string>https://YOUR-PROJECT-REF.supabase.co</string>
       <key>publishableKey</key>
       <string>YOUR-PUBLISHABLE-KEY</string>
       <key>publicClaimBaseURL</key>
       <string>https://YOUR-CLAIM-PAGE-DOMAIN</string>
   </dict>
   </plist>
   ```
   Add this file to the Xcode target as a bundle resource. Once present,
   `BoothFlow` automatically uses `SupabaseDeliveryService` instead of
   `UnconfiguredDeliveryService` — no code change needed. This file
   contains ONLY the three public values above — never a secret.

8. **Provision this iPad as a booth device** — follow "The booth device
   credential" section above (generate on-device, register the
   Installation ID + Registration Hash in `booth_devices`). Do this for
   every physical iPad.

9. **Host the claim page.** `../claim-page/index.html` is a single static
   file with no build step and no Supabase key embedded. Any static host
   works (Cloudflare Pages, Netlify, Vercel, GitHub Pages, etc. — your
   choice, not decided here). Requirements:
   - Edit the one placeholder constant at the top of the `<script>` block
     (`SUPABASE_FUNCTIONS_BASE_URL`) with your real project's functions
     URL (public, safe to ship in this file).
   - Deploy `feedback.js` alongside `index.html` (same directory, served
     at `/feedback.js`); the page imports it.
   - Configure the host so **every** path under `/s/*` serves this same
     `index.html` (an SPA-style rewrite/fallback) — the page reads the
     claim token from the URL path client-side.
   - Whatever domain you land on is what `publicClaimBaseURL` (step 7)
     must match, since the QR code is built from that value.

## Verifying after deployment

Once steps 1–9 are done:

1. Configure a Sponsored (or any free-digital) event on the iPad admin
   screen if you haven't already. Under "Delivery Device," tap **Verify
   Registration** and confirm the status reaches **Registered** (not
   just "Identity Generated") for the Installation ID/Registration Hash
   you registered in `booth_devices`.
2. Run Classic or AR Party through to **Use Photo**.
3. The Delivery screen should show a real QR code (not "DIGITAL DELIVERY
   NOT CONFIGURED" or "BOOTH DELIVERY DEVICE NOT PROVISIONED") with
   "Available until <date>".
4. In the Supabase dashboard, check **Table Editor → delivery_sessions**
   for a new row with `status = ready`, and **Storage → booth-media** for
   the uploaded object under `events/<event-id>/sessions/<session-id>/`.
5. Scan the QR with a phone — confirm the claim page loads, shows the
   photo, and the **Download Photo** button works.
6. Turn off Wi-Fi on the iPad, repeat step 2 — confirm the Delivery screen
   shows a retryable "DELIVERY FAILED" (not "not configured," not "not
   provisioned," and not a fake success), and that the local photo is
   still visible in Review if you go back. Turn Wi-Fi back on and tap
   **Try Again** — confirm it now succeeds.
7. In `booth_devices`, set this iPad's row to `enabled = false`, then run
   a capture through to Use Photo again — confirm the Delivery screen
   shows "BOOTH DELIVERY DEVICE NOT PROVISIONED" (a distinct, non-retryable
   admin state), not a generic network error. Set `enabled` back to
   `true` afterward.
8. Let a test session's `expires_at` pass (or set a short retention policy
   in the admin editor for a quick test), then reload the same claim URL —
   confirm the claim page shows "This link has expired," not the media.
9. In the admin editor's "Social" section, enable Social CTA with Display
   Name `@pacifichorizonlabs`, Profile URL
   `https://www.instagram.com/pacifichorizonlabs/`, and a message, then run
   a capture through to a real QR. Scan it and confirm the claim page shows
   the social card above the media, "Follow @pacifichorizonlabs" opens
   Instagram in a new tab, "Continue to my photo" scrolls to the media, and
   the photo/Loop downloads whether or not you tap Follow.
10. In `engagement_events`, confirm rows appear for `claim_viewed` (on
    page load), `social_cta_clicked` (on tapping Follow), and
    `download_clicked` (on tapping Download) — each with the correct
    `delivery_session_id` and, for the CTA click, `platform = 'instagram'`.
11. Disable the event's Social CTA (or use an older/self-serve event with
    none configured) and confirm the claim page renders identically minus
    the social card, and `claim_viewed`/`download_clicked` still record
    normally.

12. Guest feedback: tap **Save / Share** on a claim page and confirm the
    feedback panel appears below the media, the photo still saves, and
    sending a rating creates one row in `feedback_inbox` with
    `status = 'new'`. Sending again from the same link shows "Feedback
    already received. Thank you." and adds no row. With `GOOGLE_REVIEW_URL` set, confirm the
    Google button shows for both a 1-star and a 5-star rating.

## Pacific Rising Ops — Event Analytics API

The `event-analytics` Edge Function provides a secure, read-only analytics layer for the Pacific Rising Ops business agent. It allows server-to-service querying of session metrics, claim funnel performance, social clicks, feedback aggregates, and delivery health without exposing guest PII, claim tokens, or infrastructure secrets.

### Authentication & Security Model

- **Service-to-Service Secret**: Configured in Supabase Edge Functions via `REPORTING_AGENT_API_KEY`.
- **Authorization Header**:
  ```http
  Authorization: Bearer <REPORTING_AGENT_API_KEY>
  ```
- **Deployment**: Deployed with `--no-verify-jwt` because it implements its own constant-time token comparison (`verifyReportingAuth`) against `REPORTING_AGENT_API_KEY`.
- **Privacy Guarantees**:
  - Never returns claim tokens, claim token hashes, booth device tokens, or storage object paths.
  - Never returns guest free-text comments or any PII in aggregate responses.
  - 100% read-only: performs SELECT queries only, never mutates any row.
  - Fails closed with 401 Unauthorized if the header is missing, malformed, or invalid.

### Eventual Environment Setup & Deploy (Run manually when ready)

```bash
# Set secret (do not check real secrets into git):
supabase secrets set REPORTING_AGENT_API_KEY=YOUR_SECURE_RANDOM_KEY

# Deploy function:
supabase functions deploy event-analytics --no-verify-jwt
```

### Supported Operations & Request Contracts

All requests are `POST` to `/functions/v1/event-analytics` with `Content-Type: application/json`.

#### 1. `latest_event`
Fetches the UUID of the most recently active event in the database.

**Request:**
```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/event-analytics" \
  -H "Authorization: Bearer <REPORTING_AGENT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "latest_event"
  }'
```

**Example Response (200 OK):**
```json
{
  "operation": "latest_event",
  "eventId": "11111111-2222-3333-4444-555555555555",
  "lastActivityAt": "2026-10-17T20:45:00.000Z",
  "sessionCount": 42
}
```

#### 2. `event_summary`
Returns comprehensive high-level metrics for an event, including sessions, claim views, downloads, social clicks, feedback rating distribution, and delivery status counts.

**Request:**
```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/event-analytics" \
  -H "Authorization: Bearer <REPORTING_AGENT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "event_summary",
    "eventId": "11111111-2222-3333-4444-555555555555"
  }'
```

**Example Response (200 OK):**
```json
{
  "operation": "event_summary",
  "eventId": "11111111-2222-3333-4444-555555555555",
  "startedAt": "2026-10-17T18:00:00.000Z",
  "lastActivityAt": "2026-10-17T22:15:00.000Z",
  "sessions": {
    "total": 42,
    "ready": 40,
    "preparing": 2,
    "expired": 0
  },
  "claims": {
    "views": 38,
    "uniqueSessionsViewed": 35
  },
  "downloads": {
    "total": 52,
    "uniqueSessionsDownloaded": 32
  },
  "social": {
    "instagramClicks": 14,
    "instagramUniqueSessions": 11,
    "tiktokClicks": 6,
    "tiktokUniqueSessions": 5,
    "googleReviewClicks": 9,
    "googleReviewUniqueSessions": 8
  },
  "feedback": {
    "submissions": 12,
    "averageRating": 4.75,
    "ratings": {
      "1": 0,
      "2": 0,
      "3": 1,
      "4": 1,
      "5": 10
    }
  },
  "delivery": {
    "totalSessions": 42,
    "readySessions": 40,
    "unfinalizedSessions": 2,
    "expiredSessions": 0,
    "mediaItemsCount": 84
  }
}
```

*Note on funnel transparency:*
- `googleReviewClicks` records clicks on the Google Review CTA button only; it is never described as completed reviews.
- `instagramClicks` and `tiktokClicks` record outbound clicks only; they are never described as follows.

#### 3. `feedback_summary`
Returns private feedback metrics, rating distribution, tag categories, testimonial consent counts, and internal triage status for an event without returning guest comments or identifying details.

**Request:**
```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/event-analytics" \
  -H "Authorization: Bearer <REPORTING_AGENT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "feedback_summary",
    "eventId": "11111111-2222-3333-4444-555555555555"
  }'
```

**Example Response (200 OK):**
```json
{
  "operation": "feedback_summary",
  "eventId": "11111111-2222-3333-4444-555555555555",
  "submissions": 12,
  "averageRating": 4.75,
  "ratings": {
    "1": 0,
    "2": 0,
    "3": 1,
    "4": 1,
    "5": 10
  },
  "categories": {
    "photo_quality": 8,
    "ai_effects": 5,
    "qr_delivery": 7,
    "print_experience": 0,
    "ease_of_use": 9,
    "something_went_wrong": 1
  },
  "consentedTestimonialsCount": 8,
  "triage": {
    "total": 12,
    "new": 10,
    "triaged": 2,
    "planned": 0,
    "implemented": 0,
    "verified": 0,
    "actionable": 1
  }
}
```

#### 4. `delivery_health`
Returns only operational metrics that the current schema can prove (sessions created, ready, preparing/unfinalized, expired, media breakdown, completion rate).

**Request:**
```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/event-analytics" \
  -H "Authorization: Bearer <REPORTING_AGENT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "delivery_health",
    "eventId": "11111111-2222-3333-4444-555555555555"
  }'
```

**Example Response (200 OK):**
```json
{
  "operation": "delivery_health",
  "eventId": "11111111-2222-3333-4444-555555555555",
  "sessionsCreated": 42,
  "sessionsReady": 40,
  "sessionsPreparing": 2,
  "sessionsExpired": 0,
  "totalMediaItems": 84,
  "mediaBreakdown": {
    "photo": 42,
    "loopVideo": 42
  },
  "completionRate": 0.95,
  "hasUnfinalizedSessions": true
}
```

#### 5. `compare_events`
Compares metrics between two events and computes deterministic numerical deltas (Event B minus Event A).

**Request:**
```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/event-analytics" \
  -H "Authorization: Bearer <REPORTING_AGENT_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "compare_events",
    "eventIdA": "11111111-1111-1111-1111-111111111111",
    "eventIdB": "22222222-2222-2222-2222-222222222222"
  }'
```

**Example Response (200 OK):**
```json
{
  "operation": "compare_events",
  "eventIdA": "11111111-1111-1111-1111-111111111111",
  "eventIdB": "22222222-2222-2222-2222-222222222222",
  "eventA": { "...": "EventSummary shape for Event A" },
  "eventB": { "...": "EventSummary shape for Event B" },
  "deltas": {
    "sessionsTotalDelta": 10,
    "readySessionsDelta": 8,
    "claimViewsDelta": 12,
    "uniqueSessionsViewedDelta": 9,
    "downloadsDelta": 15,
    "uniqueSessionsDownloadedDelta": 8,
    "instagramClicksDelta": 4,
    "tiktokClicksDelta": 2,
    "googleReviewClicksDelta": 3,
    "feedbackSubmissionsDelta": 5,
    "averageRatingDelta": 0.25
  }
}
```

## Deliberately not done in this pass

- No feedback triage dashboard; triage is SQL (see "Guest feedback and
  Google review"). No per-IP rate limiting on `submit-feedback` beyond
  one submission per claim and the claim token itself.

- No scheduled/automatic deletion of expired sessions, Storage objects, or
  disabled booth devices.
- `finalize-delivery-session` trusts the client's "I uploaded everything"
  signal rather than verifying object existence in Storage first (noted
  in that function's file header).
- No dashboard for `engagement_events` — funnel numbers are read via SQL
  (Table Editor or a query) for v1, not a built graph/report.
- No automatic rotation of a booth device's credential — regenerating is
  a manual, explicitly-confirmed admin action, and the old registration
  simply stops matching until you register the new hash.
- No payment integration of any kind — this backend only ever delivers
  media the iPad app has already determined the guest is entitled to for
  free (`EventPolicy`/`EntitlementResolver`, unchanged by this phase).
