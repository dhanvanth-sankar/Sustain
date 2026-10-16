// Deletes the calling user's own account and, via `on delete cascade` on
// every table in supabase/schema/account_sync.sql, every row of their
// synced data. This is what AuthManager.swift's deleteAccount() calls, and
// exists specifically to satisfy Guideline 5.1.1(v): "If your app supports
// account creation, you must also offer account deletion... within the
// app." Adding real accounts (this session's whole point) without this
// would introduce a fresh rejection risk of the exact same shape as this
// app's two real past rejections — a feature shipped without the
// compliance piece Apple explicitly requires alongside it.
//
// Deploy with the Supabase CLI from the repo root:
//   supabase functions deploy delete-account
//
// No secrets need to be set for this one. SUPABASE_URL, SUPABASE_ANON_KEY,
// and SUPABASE_SERVICE_ROLE_KEY are all reserved, auto-injected environment
// variables Supabase provides to every Edge Function automatically —
// `supabase secrets set` will actually refuse any name starting with
// SUPABASE_ ("Env name cannot start with SUPABASE_, skipping"), confirmed
// live 2026-07-30 after an earlier version of this comment incorrectly said
// the service-role key needed to be set manually. The service-role key is
// exactly as sensitive as the Anthropic key anthropic-proxy protects the
// same way (it must never reach the app binary), but here that protection
// comes for free — it's injected server-side by Supabase, never passed
// through the CLI or committed anywhere.
//
// Security model: this function does NOT trust a user_id passed in the
// request body — that would let anyone who can reach this endpoint delete
// an arbitrary account just by guessing/enumerating a UUID. Instead it
// reads the caller's own access token from the Authorization header
// (exactly what AuthManager.shared.session.accessToken already is),
// resolves it to a user via Supabase Auth's own "who is this token for"
// endpoint, and only ever deletes that resolved user — a user can only
// ever delete themselves.

const jsonHeaders = { "content-type": "application/json" };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const projectUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!projectUrl || !serviceRoleKey || !anonKey) {
    console.error("delete-account is missing one of SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY.");
    return jsonResponse({ error: "Server is not configured." }, 500);
  }

  const authHeader = req.headers.get("authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return jsonResponse({ error: "Missing bearer token." }, 401);
  }
  const callerAccessToken = authHeader.slice("Bearer ".length);

  // Resolve the token to a user the same way Supabase Auth itself would —
  // this is what makes it safe to trust "the user this token belongs to"
  // as the deletion target, rather than anything the client claims in the
  // request body.
  const whoAmIResponse = await fetch(`${projectUrl}/auth/v1/user`, {
    headers: { authorization: `Bearer ${callerAccessToken}`, apikey: anonKey },
  });
  if (!whoAmIResponse.ok) {
    return jsonResponse({ error: "Could not verify caller identity." }, 401);
  }
  const callerUser = await whoAmIResponse.json();
  const userId = callerUser?.id;
  if (typeof userId !== "string" || userId.length === 0) {
    return jsonResponse({ error: "Could not verify caller identity." }, 401);
  }

  const deleteResponse = await fetch(`${projectUrl}/auth/v1/admin/users/${userId}`, {
    method: "DELETE",
    headers: {
      authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
    },
  });

  if (!deleteResponse.ok) {
    const bodyText = await deleteResponse.text();
    console.error(`Failed to delete user ${userId}: ${bodyText}`);
    return jsonResponse({ error: "Account deletion failed." }, 500);
  }

  return jsonResponse({ deleted: true }, 200);
});

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders(), ...jsonHeaders },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type, apikey",
    "access-control-allow-methods": "POST, OPTIONS",
  };
}
