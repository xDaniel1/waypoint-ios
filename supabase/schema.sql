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
