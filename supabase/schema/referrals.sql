-- Referral program schema — see `Sustain-In-Product-Growth-Loops-Research-2026-08.md`
-- §1 and §5 for why this exists and the reward math behind it, and
-- `supabase/functions/referrals/index.ts` for the server-side logic that
-- actually reads and writes these tables. Run this in your Supabase
-- project's SQL editor (Dashboard -> SQL Editor -> New query) once, the same
-- way `account_sync.sql` was run.
--
-- Two tables, deliberately small:
--
-- `referral_codes` — one row per user who has ever generated a code (created
-- lazily, the first time the app asks for "my code," not at sign-up). The
-- code itself is short and shareable on purpose (8 lowercase-alphanumeric
-- characters, generated server-side in the Edge Function, never guessable
-- from a user_id), unlike `account_sync.sql`'s tables which all use the
-- SwiftData-generated UUID directly as their primary key — a referral code
-- is meant to be typed or pasted by a second person, so it needs to be
-- short, not just unique.
--
-- `referrals` — one row per successful redemption. `referred_user_id` is
-- UNIQUE: a person can redeem exactly one code, ever, which is what makes
-- "give a month, get a month" resistant to someone farming their own
-- referral link for repeated rewards. `reward_granted_at` is set only after
-- the Edge Function successfully calls RevenueCat's promotional-entitlement
-- API for both parties — see that function's comments for why the DB write
-- and the RevenueCat grant are sequenced the way they are.

create table if not exists public.referral_codes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references auth.users(id) on delete cascade,
  referred_user_id uuid not null references auth.users(id) on delete cascade unique,
  redeemed_at timestamptz not null default now(),
  reward_granted_at timestamptz
);

create index if not exists referrals_referrer_user_id_idx on public.referrals(referrer_user_id);

alter table public.referral_codes enable row level security;
alter table public.referrals enable row level security;

grant usage on schema public to authenticated;
grant select, insert on public.referral_codes to authenticated;
grant select on public.referrals to authenticated;

-- Real bug, caught live: the Edge Function (`supabase/functions/referrals/
-- index.ts`) talks to these tables as `service_role`, not `authenticated` —
-- it uses the service-role key specifically so it can write
-- `reward_granted_at` and look up any code regardless of who's asking (see
-- that function's header comment). RLS is bypassed for `service_role`, but
-- Postgres' base table-level GRANTs are a separate, non-optional layer on
-- top of RLS — exactly the same lesson `account_sync.sql`'s own header
-- comment already documents ("RLS policies alone are NOT enough... Postgres
-- separately requires the role to have base table-level GRANT privileges").
-- Missing this produced a live error: `permission denied for table
-- referral_codes` (Postgres 42501), even though every RLS policy above was
-- already correct.
grant usage on schema public to service_role;
grant select, insert, update on public.referral_codes, public.referrals to service_role;

-- A code has to be look-up-able by someone who is NOT its owner — that's the
-- entire point of sharing it — so this is deliberately `using (true)`
-- rather than the `auth.uid() = user_id` pattern every table in
-- `account_sync.sql` uses. This is not a privacy regression: a row here is
-- only ever a (user_id, short code) pair, both of which are already
-- inherently meant to be shared, unlike every other synced table which
-- holds actual health data.
create policy "any signed-in user can look up a code" on public.referral_codes
  for select using (true);

create policy "insert own code" on public.referral_codes
  for insert with check (auth.uid() = user_id);

-- Both sides of a referral can see it happened (so a referrer can eventually
-- see "3 friends joined" in Settings), but nothing about a referral's
-- *reward* status is writable by either party directly — only the
-- service-role Edge Function writes `reward_granted_at`, since that's the
-- one field that must never be set by a client claiming its own reward was
-- granted. No client-facing insert/update policy exists on this table at
-- all; every write goes through the Edge Function's service-role key.
create policy "see your own referrals, either side" on public.referrals
  for select using (auth.uid() = referrer_user_id or auth.uid() = referred_user_id);
