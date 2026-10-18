// backend/supabase/functions/event-analytics/index.ts
//
// Read-only business analytics endpoint for Pacific Rising Ops.
//
// Authenticated via service-to-service secret:
// Authorization: Bearer <REPORTING_AGENT_API_KEY>
//
// Deploy with:
// supabase functions deploy event-analytics --no-verify-jwt
//
// Configure secret with:
// supabase secrets set REPORTING_AGENT_API_KEY=...

import { getServiceClient } from "../_shared/boothAuth.ts";
import {
  type AnalyticsDataProvider,
  type EventDataPayload,
  handleEventAnalytics,
} from "./handler.ts";

const supabaseProvider: AnalyticsDataProvider = {
  async getLatestEvent() {
    const supabase = getServiceClient();

    // Look for the most recently active event in delivery_sessions
    const { data: sessionData, error: sessionErr } = await supabase
      .from("delivery_sessions")
      .select("event_id, created_at")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (sessionErr) {
      throw new Error(`Failed to query delivery_sessions: ${sessionErr.message}`);
    }

    if (sessionData?.event_id) {
      const eventId = sessionData.event_id;
      const { count } = await supabase
        .from("delivery_sessions")
        .select("id", { count: "exact", head: true })
        .eq("event_id", eventId);

      return {
        operation: "latest_event",
        eventId,
        lastActivityAt: sessionData.created_at,
        sessionCount: count ?? 0,
      };
    }

    // Fallback: check if any feedback exists if no delivery sessions exist
    const { data: fbData, error: fbErr } = await supabase
      .from("feedback_submissions")
      .select("event_id, created_at")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (fbErr) {
      throw new Error(`Failed to query feedback_submissions: ${fbErr.message}`);
    }

    if (fbData?.event_id) {
      return {
        operation: "latest_event",
        eventId: fbData.event_id,
        lastActivityAt: fbData.created_at,
        sessionCount: 0,
      };
    }

    return {
      operation: "latest_event",
      eventId: null,
      lastActivityAt: null,
      sessionCount: 0,
    };
  },

  async getEventData(eventId: string): Promise<EventDataPayload> {
    const supabase = getServiceClient();

    // 1. Fetch sessions for the event
    const { data: sessions, error: sessErr } = await supabase
      .from("delivery_sessions")
      .select("id, event_id, status, created_at, expires_at")
      .eq("event_id", eventId);

    if (sessErr) {
      throw new Error(`Failed to fetch sessions: ${sessErr.message}`);
    }

    const sessionRows = sessions || [];
    const sessionIds = sessionRows.map((s) => s.id);

    // 2. Fetch engagement events for those sessions
    let engagementRows = [];
    if (sessionIds.length > 0) {
      const { data: engagements, error: engErr } = await supabase
        .from("engagement_events")
        .select("id, delivery_session_id, action, platform, created_at")
        .in("delivery_session_id", sessionIds);

      if (engErr) {
        throw new Error(`Failed to fetch engagement events: ${engErr.message}`);
      }
      engagementRows = engagements || [];
    }

    // 3. Fetch media items for those sessions (strictly omitting storage_object_path)
    let mediaRows = [];
    if (sessionIds.length > 0) {
      const { data: media, error: mediaErr } = await supabase
        .from("delivery_media")
        .select("id, delivery_session_id, media_kind, created_at")
        .in("delivery_session_id", sessionIds);

      if (mediaErr) {
        throw new Error(`Failed to fetch media: ${mediaErr.message}`);
      }
      mediaRows = media || [];
    }

    // 4. Fetch feedback submissions for the event (strictly omitting comment text/PII)
    const { data: feedback, error: fbErr } = await supabase
      .from("feedback_submissions")
      .select("id, delivery_session_id, event_id, rating, categories, consent_to_anonymous_testimonial, created_at")
      .eq("event_id", eventId);

    if (fbErr) {
      throw new Error(`Failed to fetch feedback: ${fbErr.message}`);
    }
    const feedbackRows = feedback || [];

    // 5. Fetch feedback triage rows if available
    let triageRows = [];
    if (feedbackRows.length > 0) {
      const fbIds = feedbackRows.map((f) => f.id);
      const { data: triage } = await supabase
        .from("feedback_triage")
        .select("feedback_id, status, classification, actionable, product_area, severity")
        .in("feedback_id", fbIds);

      triageRows = triage || [];
    }

    return {
      sessions: sessionRows,
      engagementEvents: engagementRows,
      feedbackSubmissions: feedbackRows,
      mediaItems: mediaRows,
      triageRows,
    };
  },
};

Deno.serve((req: Request) => {
  const expectedKey = Deno.env.get("REPORTING_AGENT_API_KEY");
  return handleEventAnalytics(req, supabaseProvider, expectedKey);
});
