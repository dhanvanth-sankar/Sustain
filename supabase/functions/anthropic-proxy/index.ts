// Anthropic proxy — the backend piece that finally moves the API key off the
// device. Both AIProteinEstimator.swift and WeeklySummaryGenerator.swift used
// to call api.anthropic.com directly with a key embedded in the app binary
// (extractable by anyone who inspects a shipped build). This function holds
// the real key as a server-side secret and forwards requests on the app's
// behalf — the app now only ever talks to this endpoint.
//
// Deploy with the Supabase CLI from the repo root:
//   supabase functions deploy anthropic-proxy
//
// Before deploying, set the real key as a secret (never committed, never
// visible to the client):
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-your-real-key
//
// Supabase verifies the caller's JWT (the project's anon key) automatically
// before this code ever runs, as long as the function is deployed without
// --no-verify-jwt (the default) — that's the one access control this proxy
// relies on. The anon key is meant to be public (same design as a Firebase
// config), so embedding it in the app is fine; it is NOT the same thing as
// the Anthropic key, which never leaves this server.

const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

// Defense in depth beyond just "requires the anon key": constrain what a
// caller can actually ask this proxy to do, so a leaked/extracted anon key
// can't be used to run up an arbitrary bill on a different, more expensive
// model or an oversized request. Keep this in sync with the `model` and
// `max_tokens` values the Swift call sites actually use.
//
// Both models are used by AIProteinEstimator.swift's photo-estimate call, which
// now runs a cheap-first cascade: claude-haiku-4-5 is tried first for every
// photo, and claude-sonnet-5 is only called on the subset where Haiku itself
// signals trouble (a parse/truncation failure, or a self-reported "low"
// confidence). WeeklySummaryGenerator.swift also uses claude-haiku-4-5 for its
// plain-prose summary call, unconditionally (no escalation there — that call
// isn't vision + arithmetic, so it doesn't have the same accuracy failure mode).
const ALLOWED_MODELS = new Set(["claude-haiku-4-5", "claude-sonnet-5"]);
// Raised from 700 to 1200 alongside AIProteinEstimator.swift's client-side
// max_tokens bump — a real complex plate (many distinct items, each needing
// its own entry in the prompt's required per-item breakdown) was hitting this
// ceiling and getting its JSON cut off mid-response. This ceiling has to move
// in lockstep with the client value below it, or the client's own bump does
// nothing (a request above this number gets rejected here with a 400 before
// it ever reaches Anthropic).
const MAX_TOKENS_CEILING = 1200;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    // Misconfigured project (secret not set) — fail loudly server-side rather
    // than silently forwarding a request with no key.
    console.error("ANTHROPIC_API_KEY secret is not set on this project.");
    return jsonResponse({ error: "Server is not configured." }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400);
  }

  const model = body.model;
  if (typeof model !== "string" || !ALLOWED_MODELS.has(model)) {
    return jsonResponse({ error: `Model not permitted: ${String(model)}` }, 400);
  }

  const maxTokens = body.max_tokens;
  if (typeof maxTokens !== "number" || maxTokens <= 0 || maxTokens > MAX_TOKENS_CEILING) {
    return jsonResponse({ error: `max_tokens must be between 1 and ${MAX_TOKENS_CEILING}.` }, 400);
  }

  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return jsonResponse({ error: "messages is required." }, 400);
  }

  const anthropicResponse = await fetch(ANTHROPIC_ENDPOINT, {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const responseText = await anthropicResponse.text();
  return new Response(responseText, {
    status: anthropicResponse.status,
    headers: { ...corsHeaders(), "content-type": "application/json" },
  });
});

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders(), "content-type": "application/json" },
  });
}

function corsHeaders(): Record<string, string> {
  // Not strictly needed for a native iOS URLSession caller (no browser
  // preflight involved), but harmless to include and keeps this reusable if a
  // web client is ever added to the same portfolio.
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type, apikey",
    "access-control-allow-methods": "POST, OPTIONS",
  };
}
