// backend/supabase/functions/event-analytics/handler.ts
//
// HTTP request handler for the event-analytics Edge Function.
// Supports dependency injection for data fetching to allow deterministic unit testing.

import {
  computeCompareEvents,
  computeDeliveryHealth,
  computeEventSummary,
  computeFeedbackSummary,
  type DeliveryMediaRow,
  type DeliverySessionRow,
  type EngagementEventRow,
  type FeedbackSubmissionRow,
  type FeedbackTriageRow,
  isValidUUID,
  type LatestEventResult,
  verifyReportingAuth,
} from "./analytics.ts";

export interface EventDataPayload {
  sessions: DeliverySessionRow[];
  engagementEvents: EngagementEventRow[];
  feedbackSubmissions: FeedbackSubmissionRow[];
  mediaItems: DeliveryMediaRow[];
  triageRows?: FeedbackTriageRow[];
}

export interface AnalyticsDataProvider {
  getLatestEvent(): Promise<LatestEventResult>;
  getEventData(eventId: string): Promise<EventDataPayload>;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const jsonHeaders = {
  ...corsHeaders,
  "Content-Type": "application/json",
};

export async function handleEventAnalytics(
  req: Request,
  provider: AnalyticsDataProvider,
  expectedKey: string | undefined
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  // Enforce service-to-service authentication
  const authHeader = req.headers.get("Authorization");
  const isAuthorized = await verifyReportingAuth(authHeader, expectedKey);
  if (!isAuthorized) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  let body: Record<string, unknown>;
  try {
    const raw = await req.json();
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
        status: 400,
        headers: jsonHeaders,
      });
    }
    body = raw as Record<string, unknown>;
  } catch {
    return new Response(JSON.stringify({ error: "Malformed JSON" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const { operation, eventId, eventIdA, eventIdB } = body;

  if (typeof operation !== "string" || operation.trim().length === 0) {
    return new Response(JSON.stringify({ error: "Missing operation" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  try {
    switch (operation) {
      case "latest_event": {
        const result = await provider.getLatestEvent();
        return new Response(JSON.stringify(result), {
          status: 200,
          headers: jsonHeaders,
        });
      }

      case "event_summary": {
        if (!isValidUUID(eventId)) {
          return new Response(JSON.stringify({ error: "Invalid or missing eventId" }), {
            status: 400,
            headers: jsonHeaders,
          });
        }
        const data = await provider.getEventData(eventId);
        const summary = computeEventSummary(
          eventId,
          data.sessions,
          data.engagementEvents,
          data.feedbackSubmissions,
          data.mediaItems
        );
        return new Response(JSON.stringify(summary), {
          status: 200,
          headers: jsonHeaders,
        });
      }

      case "feedback_summary": {
        if (!isValidUUID(eventId)) {
          return new Response(JSON.stringify({ error: "Invalid or missing eventId" }), {
            status: 400,
            headers: jsonHeaders,
          });
        }
        const data = await provider.getEventData(eventId);
        const summary = computeFeedbackSummary(
          eventId,
          data.feedbackSubmissions,
          data.triageRows || []
        );
        return new Response(JSON.stringify(summary), {
          status: 200,
          headers: jsonHeaders,
        });
      }

      case "delivery_health": {
        if (!isValidUUID(eventId)) {
          return new Response(JSON.stringify({ error: "Invalid or missing eventId" }), {
            status: 400,
            headers: jsonHeaders,
          });
        }
        const data = await provider.getEventData(eventId);
        const health = computeDeliveryHealth(eventId, data.sessions, data.mediaItems);
        return new Response(JSON.stringify(health), {
          status: 200,
          headers: jsonHeaders,
        });
      }

      case "compare_events": {
        if (!isValidUUID(eventIdA) || !isValidUUID(eventIdB)) {
          return new Response(
            JSON.stringify({ error: "Invalid or missing eventIdA or eventIdB" }),
            {
              status: 400,
              headers: jsonHeaders,
            }
          );
        }
        const [dataA, dataB] = await Promise.all([
          provider.getEventData(eventIdA),
          provider.getEventData(eventIdB),
        ]);

        const summaryA = computeEventSummary(
          eventIdA,
          dataA.sessions,
          dataA.engagementEvents,
          dataA.feedbackSubmissions,
          dataA.mediaItems
        );
        const summaryB = computeEventSummary(
          eventIdB,
          dataB.sessions,
          dataB.engagementEvents,
          dataB.feedbackSubmissions,
          dataB.mediaItems
        );

        const comparison = computeCompareEvents(eventIdA, summaryA, eventIdB, summaryB);
        return new Response(JSON.stringify(comparison), {
          status: 200,
          headers: jsonHeaders,
        });
      }

      default: {
        return new Response(JSON.stringify({ error: `Unknown operation: ${operation}` }), {
          status: 400,
          headers: jsonHeaders,
        });
      }
    }
  } catch (_err) {
    return new Response(JSON.stringify({ error: "Could not retrieve analytics" }), {
      status: 500,
      headers: jsonHeaders,
    });
  }
}
