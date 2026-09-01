# Accounts & sync

Backend: Supabase (hosted Postgres + Auth). Wired end-to-end — Sign in with Apple, whole-snapshot
push/pull of Favorites and Recents, sign-out. See `supabase/schema.sql` for the table + RLS policy.

- `Account` (in `Models/`) — identity only, never a credential.
- `AccountStore` — the signed-in account, persisted per-install in `UserDefaults`.
- `AppleSignIn` — maps `ASAuthorization` to an `Account`, plus a staleness check.
- `SyncBackend` — the seam `SupabaseBackend` (in `Services/`) implements. `UnconfiguredBackend`
  is what ships if `Secrets.xcconfig` has no real Supabase credentials — throws rather than
  pretending to sync.
- `SyncCoordinator` (in `Services/`) — owns the actual sign-in flow, and debounced push / one-shot
  pull. `SearchViewModel.syncCoordinator` is the instance the app uses; `Views/Account/ProfileSheet`
  is the UI.

## Still needed before this actually syncs anything

Nothing left in code — these are one-time setup steps outside the repo:

1. **Create a Supabase project** at supabase.com, then Project Settings → API for the project URL
   and anon key. Put both in `Secrets.xcconfig` (git-ignored; see `Secrets.xcconfig.example`).
2. **Run `supabase/schema.sql`** in that project's SQL editor.
3. **Enable the Apple provider**: Supabase dashboard → Authentication → Providers → Apple.
4. **Add the Sign in with Apple capability in Xcode**: target Waypoint → Signing & Capabilities →
   **+ Capability** → Sign in with Apple. The entitlement is already in `Waypoint.entitlements`,
   but Xcode still has to register it with the provisioning profile — the CLI can't do this step
   (`xcodebuild` has no account context). Until this is done, tapping the button fails with:

   ```
   error: Provisioning profile "iOS Team Provisioning Profile: com.danielguzman.waypoint"
          doesn't include the Sign In with Apple capability.
   ```

Until all four are done, sign-in still works locally (`AccountStore` persists an `Account` from
the on-device Apple credential) — it just doesn't sync anywhere, and `ProfileSheet` says so.

## Not built

**Sign in with Google** needs the `GoogleSignIn-iOS` package, an OAuth client ID from the Google
Cloud console, and a URL scheme in `Info.plist`. `Account.Provider.google` exists as a case but
nothing produces one yet — deferred, since Apple covers today's need and Google is a dependency
and a decision, not something to guess at.

## Why a server at all

Favorites and recents already sync between the user's own Apple devices via
`NSUbiquitousKeyValueStore` — no account needed for that. An account's job is to reach past that:
Android, the web, or just a backup that survives losing every Apple device at once. That's the
whole justification for Postgres existing here, and why sync is deliberately whole-snapshot
last-writer-wins rather than a fully-merged CloudKit-style store — see `SyncSnapshot`'s doc comment.
