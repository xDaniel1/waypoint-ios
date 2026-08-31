# Accounts & sync — scaffolding

Started 2026-08-30. **Not wired to any UI yet, and there is no server.** These are the pieces
tomorrow's work plugs into, deliberately built so the backend choice is a swap and not a rewrite.

- `Account` (in `Models/`) — identity only, never a credential.
- `AccountStore` — the signed-in account, persisted per-install in `UserDefaults`.
- `AppleSignIn` — maps `ASAuthorization` to an `Account`, plus a staleness check.
- `SyncBackend` — the seam. `UnconfiguredBackend` ships today and throws rather than pretending.

## Two capabilities are needed before any of this runs

Neither is in the entitlements file yet, because adding either one makes the app fail to sign and
blocks installing to a device at all.

1. **Sign in with Apple** (`com.apple.developer.applesignin`). Available to any paid account — no
   approval needed. It just isn't enabled on the App ID yet, so the profile doesn't carry it:

   ```
   error: Provisioning profile "iOS Team Provisioning Profile: com.danielguzman.waypoint"
          doesn't include the Sign In with Apple capability.
   ```

   Fix: open the project in Xcode → target Waypoint → Signing & Capabilities → **+ Capability** →
   Sign in with Apple. Xcode regenerates the profile. Then add
   `com.apple.developer.applesignin = ["Default"]` back to `Waypoint.entitlements` *and*
   `WaypointCarPlay.entitlements`. (The command line can't do this step — `xcodebuild` reports
   "No Accounts" because the developer account lives in Xcode, not the CLI.)

2. **Sign in with Google** needs the `GoogleSignIn-iOS` package and an OAuth client ID from the
   Google Cloud console, plus a URL scheme in `Info.plist`. Not added — it's a dependency and a
   decision, not something to guess at.

## The open question

What the account is actually *for*. Favorites and recents already sync between the user's Apple
devices through `NSUbiquitousKeyValueStore` — no account, no server, already working. An account
only earns its place if the data has to reach something that isn't an Apple device (Android, web),
and that means running a real server with real user data on it. That decision is still open.
