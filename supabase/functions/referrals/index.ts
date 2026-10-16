// The referral program's entire server side — see
// `Sustain-In-Product-Growth-Loops-Research-2026-08.md` for why this exists
// (give-a-month-get-a-month is one of the best-quantified, cheapest growth
// levers available, and this project had never actually built it, only
// flagged it as "open" three separate times) and
// `supabase/schema/referrals.sql` for the two tables this reads and writes.
//
// Deploy with the Supabase CLI from the repo root:
//   supabase functions deploy referrals
//
// SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY are
// auto-injected the same way `delete-account` documents — nothing to set
// for those. One secret DOES need to be set manually, unlike
// `delete-account`:
//   supabase secrets set REVENUECAT_SECRET_API_KEY=sk_...
// This is RevenueCat's *secret* key (Project Settings -> API Keys -> Secret
// keys in the RevenueCat dashboard), never the public SDK key already in
// `Secrets.xcconfig` — it authorizes granting free entitlement time to any
// subscriber, so it must never reach the app binary, exactly the same
// posture as the Anthropic key `anthropic-proxy` protects.
//
// Two actions, one function, chosen the same way `delete-account` keeps
// related account-lifecycle logic in one file rather than one Edge
// Function per verb — this is a small enough surface that splitting it into
// two deployable functions would just be two copies of the same
// auth-resolution boilerplate below.
//
//   POST { "action": "code" }              -> { "code": "a1b2c3d4" }
//   POST { "action": "redeem", "code": …  } -> { "rewarded": true }
//
// Security model, same shape as `delete-account`: every action resolves the
// caller's identity from their own bearer token via Supabase Auth's
// `/auth/v1/user`, never from anything the client claims in the request
// body. A referral code is looked up by its own `select using (true)`
// policy (see the schema file for why that's safe), but every WRITE to
// `referral_codes`/`referrals` beyond a user inserting their own first code
// goes through this function's service-role key, specifically so a client
// can never set `reward_granted_at` on itself and claim a reward that was
// never actually paid out via RevenueCat.

const jsonHeaders = { "content-type": "application/json" };
const REVENUECAT_ENTITLEMENT_ID = "premium";
const REVENUECAT_REWARD_DURATION = "monthly"; // one free month, matching the give-a-month-get-a-month framing throughout the research doc.

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
  const revenueCatSecretKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
  if (!projectUrl || !serviceRoleKey || !anonKey) {
    console.error("referrals is missing one of SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY.");
    return jsonResponse({ error: "Server is not configured." }, 500);
  }
  if (!revenueCatSecretKey) {
    console.error("referrals is missing REVENUECAT_SECRET_API_KEY — set it with `supabase secrets set`.");
    return jsonResponse({ error: "Referral rewards aren't configured yet." }, 500);
  }

  const authHeader = req.headers.get("authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return jsonResponse({ error: "Missing bearer token." }, 401);
  }
  const callerAccessToken = authHeader.slice("Bearer ".length);

  const whoAmIResponse = await fetch(`${projectUrl}/auth/v1/user`, {
    headers: { authorization: `Bearer ${callerAccessToken}`, apikey: anonKey },
  });
  if (!whoAmIResponse.ok) {
    return jsonResponse({ error: "Could not verify caller identity." }, 401);
  }
  const callerUser = await whoAmIResponse.json();
  const callerId = callerUser?.id;
  if (typeof callerId !== "string" || callerId.length === 0) {
    return jsonResponse({ error: "Could not verify caller identity." }, 401);
  }

  let body: { action?: string; code?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid request body." }, 400);
  }

  const restHeaders = {
    authorization: `Bearer ${serviceRoleKey}`,
    apikey: serviceRoleKey,
    "content-type": "application/json",
  };

  if (body.action === "code") {
    return await handleGetOrCreateCode(projectUrl, restHeaders, callerId);
  }
  if (body.action === "redeem") {
    if (typeof body.code !== "string" || body.code.trim().length === 0) {
      return jsonResponse({ error: "Missing referral code." }, 400);
    }
    return await handleRedeem(projectUrl, restHeaders, callerId, body.code.trim().toLowerCase(), revenueCatSecretKey);
  }
  return jsonResponse({ error: "Unknown action." }, 400);
});

async function handleGetOrCreateCode(
  projectUrl: string,
  restHeaders: Record<string, string>,
  userId: string,
): Promise<Response> {
  const existing = await fetch(
    `${projectUrl}/rest/v1/referral_codes?user_id=eq.${userId}&select=code`,
    { headers: restHeaders },
  );
  if (existing.ok) {
    const rows = await existing.json();
    if (Array.isArray(rows) && rows.length > 0 && typeof rows[0].code === "string") {
      return jsonResponse({ code: rows[0].code }, 200);
    }
  }

  // Generate and insert, retrying on the rare chance of a collision — an
  // 8-character lowercase-alphanumeric code has ~2.8 trillion possibilities,
  // so this loop is a formality, not a real bottleneck, at any scale this
  // app is realistically going to reach.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = randomCode(8);
    const insertResponse = await fetch(`${projectUrl}/rest/v1/referral_codes`, {
      method: "POST",
      headers: { ...restHeaders, prefer: "return=representation" },
      body: JSON.stringify({ user_id: userId, code }),
    });
    if (insertResponse.ok) {
      return jsonResponse({ code }, 200);
    }
    // A 409 here means the code (not the user_id) collided — safe to just
    // retry with a fresh random code. Any other failure isn't worth
    // retrying blindly.
    if (insertResponse.status !== 409) {
      const bodyText = await insertResponse.text();
      console.error(`referral_codes insert failed: ${bodyText}`);
      return jsonResponse({ error: "Couldn't create a referral code." }, 500);
    }
  }
  return jsonResponse({ error: "Couldn't create a referral code." }, 500);
}

async function handleRedeem(
  projectUrl: string,
  restHeaders: Record<string, string>,
  callerId: string,
  code: string,
  revenueCatSecretKey: string,
): Promise<Response> {
  const codeResponse = await fetch(
    `${projectUrl}/rest/v1/referral_codes?code=eq.${encodeURIComponent(code)}&select=user_id`,
    { headers: restHeaders },
  );
  if (!codeResponse.ok) {
    return jsonResponse({ error: "Couldn't look up that code." }, 500);
  }
  const codeRows = await codeResponse.json();
  if (!Array.isArray(codeRows) || codeRows.length === 0) {
    return jsonResponse({ error: "That referral code doesn't exist." }, 404);
  }
  const referrerId = codeRows[0].user_id as string;

  if (referrerId === callerId) {
    return jsonResponse({ error: "You can't redeem your own referral code." }, 400);
  }

  // The `referred_user_id` unique constraint in the schema is the real
  // enforcement of "one redemption per person, ever" — this check just lets
  // the response say something clearer than a raw 409 from the insert below.
  const alreadyRedeemed = await fetch(
    `${projectUrl}/rest/v1/referrals?referred_user_id=eq.${callerId}&select=id`,
    { headers: restHeaders },
  );
  if (alreadyRedeemed.ok) {
    const rows = await alreadyRedeemed.json();
    if (Array.isArray(rows) && rows.length > 0) {
      return jsonResponse({ error: "You've already redeemed a referral code." }, 400);
    }
  }

  const insertReferral = await fetch(`${projectUrl}/rest/v1/referrals`, {
    method: "POST",
    headers: { ...restHeaders, prefer: "return=representation" },
    body: JSON.stringify({ referrer_user_id: referrerId, referred_user_id: callerId }),
  });
  if (!insertReferral.ok) {
    const bodyText = await insertReferral.text();
    console.error(`referrals insert failed: ${bodyText}`);
    // A 409 here means the unique constraint caught a redemption the
    // check above missed (a genuine race — two redemption attempts landing
    // at nearly the same moment) — still the right user-facing message.
    if (insertReferral.status === 409) {
      return jsonResponse({ error: "You've already redeemed a referral code." }, 400);
    }
    return jsonResponse({ error: "Couldn't record the referral." }, 500);
  }
  const referralRow = (await insertReferral.json())[0];

  // Grant both sides a free month. Both calls are attempted even if one
  // fails, so a transient RevenueCat error for one person doesn't also cost
  // the other their reward. `reward_granted_at` is only set if BOTH
  // succeeded — a partial grant is left unmarked rather than recorded as
  // done, so it's honestly queryable later (via the RevenueCat dashboard or
  // a follow-up manual grant) rather than silently lost. There's no
  // automatic retry queue in this pass — see the research doc's §5 for why
  // that was scoped out of this session.
  const [referrerGranted, referredGranted] = await Promise.all([
    grantPromotionalEntitlement(referrerId, revenueCatSecretKey),
    grantPromotionalEntitlement(callerId, revenueCatSecretKey),
  ]);

  if (referrerGranted && referredGranted) {
    await fetch(`${projectUrl}/rest/v1/referrals?id=eq.${referralRow.id}`, {
      method: "PATCH",
      headers: restHeaders,
      body: JSON.stringify({ reward_granted_at: new Date().toISOString() }),
    });
    return jsonResponse({ rewarded: true }, 200);
  }

  console.error(`referrals: partial reward grant for referral ${referralRow.id} (referrer=${referrerGranted}, referred=${referredGranted})`);
  return jsonResponse({
    rewarded: false,
    error: "Your referral was recorded, but granting the free month didn't fully complete. Contact support@hearthlyapps.com and we'll sort it out.",
  }, 502);
}

async function grantPromotionalEntitlement(appUserId: string, revenueCatSecretKey: string): Promise<boolean> {
  const response = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${appUserId}/entitlements/${REVENUECAT_ENTITLEMENT_ID}/promotional`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${revenueCatSecretKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ duration: REVENUECAT_REWARD_DURATION }),
    },
  );
  if (!response.ok) {
    const bodyText = await response.text();
    console.error(`RevenueCat promotional grant failed for ${appUserId}: ${bodyText}`);
    return false;
  }
  return true;
}

function randomCode(length: number): string {
  const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let result = "";
  for (const byte of bytes) {
    result += charset[byte % charset.length];
  }
  return result;
}

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
