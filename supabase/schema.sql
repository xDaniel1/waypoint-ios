-- Run this once in your Supabase project's SQL editor (Project -> SQL Editor -> New query).
-- Backs Waypoint's account sync: one row per signed-in user, holding their whole Favorites +
-- Recents snapshot as JSON. See Waypoint/Services/SupabaseBackend.swift and SyncCoordinator.swift.

create table if not exists public.sync_snapshots (
    user_id uuid primary key references auth.users (id) on delete cascade,
    favorites jsonb not null default '[]'::jsonb,
    recents jsonb not null default '[]'::jsonb,
    updated_at timestamptz not null default now()
);

alter table public.sync_snapshots enable row level security;

-- Each user can only ever read or write their own row — enforced in Postgres, not just in the app.
create policy "Users manage their own sync snapshot"
    on public.sync_snapshots
    for all
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Also required, outside this file, before Sign in with Apple works end-to-end:
--   1. Supabase dashboard -> Authentication -> Providers -> Apple -> enable it.
--      (Client ID = your app's bundle ID, com.danielguzman.waypoint; Supabase's native
--      `signInWithIdToken` flow doesn't need the Services ID / key pair that web Sign in with
--      Apple normally requires.)
--   2. Xcode -> Waypoint target -> Signing & Capabilities -> add "Sign in with Apple".
--      (The entitlement is already in Waypoint.entitlements; Xcode still has to register it
--      with your provisioning profile, which the CLI can't do.)
--   3. Put your project's URL and anon key into Secrets.xcconfig (see Secrets.xcconfig.example).

-- ---------------------------------------------------------------------------
-- Traffic reports: the incident layer behind "Report" during navigation.
--
-- Apple's and Google's incident feeds are readable by their own apps and nothing else, so an
-- app that wants to tell one driver what another just drove into has to keep its own. This is
-- that table. See Waypoint/Services/TrafficReportsService.swift.
-- ---------------------------------------------------------------------------

create table if not exists public.traffic_reports (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    -- Matches ReportedIncident.Kind's raw values: Accident, Hazard, Road Closed, Slow Traffic.
    kind text not null,
    latitude double precision not null,
    longitude double precision not null,
    created_at timestamptz not null default now()
);

-- The app asks for a bounding box of recent reports, so that's what gets indexed.
create index if not exists traffic_reports_area_idx
    on public.traffic_reports (created_at desc, latitude, longitude);

alter table public.traffic_reports enable row level security;

-- Anyone signed in can see everyone's reports — that's the entire point of the layer.
create policy "Signed-in users read all reports"
    on public.traffic_reports
    for select
    to authenticated
    using (true);

-- But you can only file one as yourself, and only delete your own.
create policy "Users file their own reports"
    on public.traffic_reports
    for insert
    to authenticated
    with check (auth.uid() = user_id);

create policy "Users delete their own reports"
    on public.traffic_reports
    for delete
    to authenticated
    using (auth.uid() = user_id);

-- Reports go stale fast and the app already ignores anything older than two hours. Sweeping them
-- server-side keeps the table from growing forever; run it on a schedule (Database -> Cron) or by
-- hand.
--   delete from public.traffic_reports where created_at < now() - interval '1 day';
