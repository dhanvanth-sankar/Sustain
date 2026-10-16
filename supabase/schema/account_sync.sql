-- Account sync schema for Sustain. Run this in your Supabase project's SQL
-- editor (Dashboard -> SQL Editor -> New query) once, after enabling Sign in
-- with Apple as an Auth provider (Dashboard -> Authentication -> Providers ->
-- Apple -> toggle on; you'll need your Apple Developer Team ID, the
-- com.sustainapp.glp1 Services ID, Key ID, and the private key .p8 from
-- Apple's "Sign in with Apple" configuration — see Supabase's own Apple
-- provider docs for the exact steps, since that part happens in two
-- dashboards this repo can't script).
--
-- Five tables, one per `@Model` SwiftData type that needs to leave the
-- device (`Sustain/Models/*.swift` — MedicationProfile, DoseLog,
-- WeightEntry, ProteinEntry, SideEffectLog). Every table's primary key is
-- the SAME `id` SwiftData already generates locally (a client-side UUID),
-- not a server-generated one — that's what lets `CloudSyncManager`'s upsert
-- calls be naturally idempotent (pushing the same local record twice is a
-- no-op, not a duplicate) without needing any separate "have I already
-- synced this row" bookkeeping.
--
-- Row Level Security is the actual enforcement of "a user can only ever see
-- or touch their own data" — this is not optional or a nice-to-have on top
-- of the app's own logic, since PostgREST (what `CloudSyncManager` talks to
-- directly over REST) has no other access control of its own. Every policy
-- below is intentionally the same shape: `auth.uid() = user_id`, evaluated
-- against the JWT the client sent as its Authorization bearer token, which
-- `AuthManager` obtains from Supabase Auth. Without RLS enabled, ANY
-- authenticated user could read or write ANY other user's rows through the
-- same public REST endpoint.
--
-- RLS policies alone are NOT enough, though — this was a real bug caught by
-- an actual live sign-in test on a device (2026-07-30), not by reading the
-- code: RLS governs which ROWS a role may touch, but Postgres separately
-- requires the role to have base table-level GRANT privileges before it can
-- attempt the operation at all, RLS or not. Running only the `create
-- policy` statements below without the `grant` block further down produces
-- exactly the error that surfaced live: `permission denied for table
-- medication_profiles` (Postgres error 42501), even though every policy was
-- correctly in place. The `grant` block is not optional cleanup — it's
-- required for any of this to work.

create table if not exists public.medication_profiles (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  medication text not null,
  form text not null,
  frequency text not null,
  start_date timestamptz not null,
  current_dose_mg double precision not null,
  starting_weight_lbs double precision,
  target_weight_lbs double precision,
  is_active boolean not null default true,
  created_at timestamptz not null,
  planned_next_dose_mg double precision,
  planned_dose_change_date timestamptz,
  has_started_medication boolean not null default true,
  -- Added 2026-08-01 for last-write-wins conflict resolution — see
  -- `CloudSyncManager.pushLocalData`'s doc comment. `default now()` matters
  -- here specifically: a fresh install running this whole schema file for
  -- the first time gets a real value on insert without the app having to
  -- special-case it, and it also means the `alter table` below (for an
  -- already-live database that ran this file before this column existed)
  -- backfills every existing row instead of leaving it null.
  updated_at timestamptz not null default now(),
  -- Added 2026-08-01 for `.specificDays` schedules (e.g. Mon/Wed/Fri) — see
  -- `MedicationProfile.scheduledWeekdaysRaw`'s doc comment. Plain text, not
  -- an int array: a comma-joined list of Calendar weekday numbers (1-7),
  -- the exact same format the app already stores locally, kept identical
  -- end to end rather than introducing a Postgres array type for seven
  -- small integers. `default ''` matches every profile that isn't on a
  -- specific-days schedule (the overwhelming majority — no currently-
  -- approved GLP-1 needs this, only a compounded/custom program would).
  scheduled_weekdays text not null default '',
  -- Added 2026-08-02 for comp-010 in `sustain-pros-and-cons.json` (custom
  -- medication entry) — see `MedicationProfile.customMedicationName`'s doc
  -- comment and `CloudSyncManager`'s `MedicationProfileDTO`. Both nullable,
  -- with no default: `null` is the correct value for every non-`.custom`
  -- profile, not an empty-string placeholder like `scheduled_weekdays` uses
  -- (a name has no sensible "off" default the way an empty weekday list does).
  custom_medication_name text,
  custom_half_life_hours double precision,
  synced_at timestamptz not null default now()
);

-- Run these manually in the Supabase SQL editor against the already-live
-- project — `create table if not exists` above is a no-op once the table
-- already exists, so it won't add these columns to a database that was set
-- up before they existed. Safe to run even if a column already exists
-- elsewhere (e.g. a brand-new project created after this file was updated):
-- `if not exists` makes each one a no-op there too.
-- alter table public.medication_profiles add column if not exists updated_at timestamptz not null default now();
-- alter table public.medication_profiles add column if not exists scheduled_weekdays text not null default '';
-- alter table public.medication_profiles add column if not exists custom_medication_name text;
-- alter table public.medication_profiles add column if not exists custom_half_life_hours double precision;

create table if not exists public.dose_logs (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  date timestamptz not null,
  dose_mg double precision not null,
  form text not null,
  injection_site text,
  skipped boolean not null default false,
  notes text not null default '',
  synced_at timestamptz not null default now()
);

create table if not exists public.weight_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  date timestamptz not null,
  weight_lbs double precision not null,
  source text not null default 'manual',
  synced_at timestamptz not null default now()
);

create table if not exists public.protein_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  date timestamptz not null,
  grams double precision not null,
  note text not null default '',
  source text not null default 'manual',
  synced_at timestamptz not null default now()
);

create table if not exists public.side_effect_logs (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  date timestamptz not null,
  symptom text not null,
  severity integer not null,
  notes text not null default '',
  synced_at timestamptz not null default now()
);

-- Every user's own rows load fast when this app's actual query pattern
-- (PostgREST implicitly filtering by user_id via the RLS policies below) has
-- an index to use instead of a sequential scan as row counts grow.
create index if not exists medication_profiles_user_id_idx on public.medication_profiles(user_id);
create index if not exists dose_logs_user_id_idx on public.dose_logs(user_id);
create index if not exists weight_entries_user_id_idx on public.weight_entries(user_id);
create index if not exists protein_entries_user_id_idx on public.protein_entries(user_id);
create index if not exists side_effect_logs_user_id_idx on public.side_effect_logs(user_id);

alter table public.medication_profiles enable row level security;
alter table public.dose_logs enable row level security;
alter table public.weight_entries enable row level security;
alter table public.protein_entries enable row level security;
alter table public.side_effect_logs enable row level security;

-- Base table-level privileges for the "authenticated" role — Supabase's role
-- for any request carrying a valid signed-in user's JWT, which is every
-- request `CloudSyncManager` makes (it always sends the user's access token,
-- never just the anon key, since these tables' RLS policies need auth.uid()
-- to resolve). Deliberately NOT granted to "anon" — an unauthenticated
-- request has no business touching these tables at all, and RLS's
-- `auth.uid() = user_id` policies would reject it anyway even if it could
-- (anon's auth.uid() resolves to null, matching no row), so the anon grant
-- would be a no-op that only adds a second, redundant layer to reason about.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.medication_profiles,
  public.dose_logs,
  public.weight_entries,
  public.protein_entries,
  public.side_effect_logs
to authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['medication_profiles', 'dose_logs', 'weight_entries', 'protein_entries', 'side_effect_logs']
  loop
    execute format('create policy "select own rows" on public.%I for select using (auth.uid() = user_id)', t);
    execute format('create policy "insert own rows" on public.%I for insert with check (auth.uid() = user_id)', t);
    execute format('create policy "update own rows" on public.%I for update using (auth.uid() = user_id) with check (auth.uid() = user_id)', t);
    execute format('create policy "delete own rows" on public.%I for delete using (auth.uid() = user_id)', t);
  end loop;
end $$;

-- Deleting a row from auth.users (which `supabase/functions/delete-account/
-- index.ts` does via the Admin API when a user taps "Delete account" in
-- Settings) cascades through every `references auth.users(id) on delete
-- cascade` foreign key above, so a deleted account's data doesn't have to be
-- separately cleaned up table by table — this is the actual mechanism behind
-- Guideline 5.1.1(v)'s "account deletion must really delete the data, not
-- just deactivate it" requirement.
