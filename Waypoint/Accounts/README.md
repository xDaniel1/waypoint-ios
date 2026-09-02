# Accounts & sync

Backend: Supabase (hosted Postgres + Auth). Wired end-to-end — Sign in with Apple, Sign in with
Google, whole-snapshot push/pull of Favorites and Recents, sign-out. See `supabase/schema.sql` for
the table + RLS policy.

- `Account` (in `Models/`) — identity only, never a credential.
- `AccountStore` — the signed-in account, persisted per-install in `UserDefaults`.
- `AppleSignIn` / `GoogleAccountSignIn` — map each provider's own authorization result to an
  `Account`. (`GoogleAccountSignIn`, not `GoogleSignIn`, so the type doesn't collide with the SDK
  module of the same name.)
- `SyncBackend` — the seam `SupabaseBackend` (in `Services/`) implements. `UnconfiguredBackend`
  is what ships if `Secrets.xcconfig` has no real Supabase credentials — throws rather than
  pretending to sync.
- `SyncCoordinator` (in `Services/`) — owns both sign-in flows, and debounced push / one-shot
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

5. **Create a Google OAuth iOS client** at console.cloud.google.com/apis/credentials (bundle ID
   `com.danielguzman.waypoint`), then put its client ID and reversed-client-ID URL scheme into
   `Secrets.xcconfig` — see the comment above `GOOGLE_IOS_CLIENT_ID` there for the exact values
   Google shows you.
6. **Enable the Google provider**: Supabase dashboard → Authentication → Providers → Google → add
   that same iOS client ID under "Client IDs".

Until all of these are done, sign-in still works locally (`AccountStore` persists an `Account`
from the on-device credential) — it just doesn't sync anywhere, and `ProfileSheet` says so.

## Why a server at all

Favorites and recents already sync between the user's own Apple devices via
`NSUbiquitousKeyValueStore` — no account needed for that. An account's job is to reach past that:
Android, the web, or just a backup that survives losing every Apple device at once. That's the
whole justification for Postgres existing here, and why sync is deliberately whole-snapshot
last-writer-wins rather than a fully-merged CloudKit-style store — see `SyncSnapshot`'s doc comment.
