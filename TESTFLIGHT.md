# Shipping to TestFlight

Not the App Store — internal/external beta testing only. Split into what's
already wired up in the repo vs. what only you can do (Apple accounts/portal).

## Done (repo side)

- [x] App icon set (`icon-1024`, dark, tinted variants) — required for archive to succeed
- [x] `ITSAppUsesNonExemptEncryption: false` in `Info.plist` — app only does standard HTTPS via `URLSession`, no custom crypto, so this skips the manual export-compliance prompt on every upload
- [x] `exportOptions.plist` — archive export config (method `app-store-connect`, team `Q9AGJR7SC5`, automatic signing)
- [x] `Scripts/archive.sh` — regenerates the project, archives Release, sets the build number from `git rev-list --count HEAD` (so every archive gets a unique, monotonically increasing build number without hand-editing `project.yml`), and exports the `.ipa`

## Left (account/portal side)

1. **Apple Developer Program enrollment** for team `Q9AGJR7SC5`, if not already active — required for TestFlight at all.
2. **Enable capabilities on the App ID** (`com.danielguzman.waypoint`) in developer.apple.com → Certificates, Identifiers & Profiles, to match what's already declared in `Waypoint.entitlements`:
   - App Groups (`group.com.danielguzman.waypoint`)
   - WeatherKit
   - iCloud (key-value storage)

   `CODE_SIGN_STYLE: Automatic` means Xcode will often offer to flip these on itself the first time it hits a signing mismatch — but WeatherKit in particular can take time to propagate, so do this before the first archive, not during.
3. **Create the app record in App Store Connect** for bundle ID `com.danielguzman.waypoint` (App Store Connect → Apps → +), if it doesn't exist yet. The first archive upload can also auto-create it, but doing it manually first avoids surprises.
4. **Fill in Test Information** (App Store Connect → your app → TestFlight tab): what to test, beta app description, contact email. Required before any tester — internal or external — can be invited.
5. **App Privacy answers** (data collection nutrition label) — required before a build can go to *external* testers, even without a public App Store listing.
6. **Real `Secrets.xcconfig`** with a production Google Places/Routes/Weather/Air Quality API key, restricted to iOS apps with bundle ID `com.danielguzman.waypoint` in Google Cloud Console. It's git-ignored on purpose; `Scripts/archive.sh` refuses to run without it.
7. **Choose internal vs. external testers**:
   - Internal: up to 100 people who are members of your App Store Connect team, available immediately, no review.
   - External: up to 10,000 via link or email invite, but the *first* build of a version needs a lightweight Beta App Review (usually hours) before they can install it.
8. Remember TestFlight builds **expire after 90 days** — plan on periodic re-uploads for a longer-running beta.

## When you're ready to cut a build

```sh
./Scripts/archive.sh
```

Then upload the resulting `build/export/Waypoint.ipa` via Xcode Organizer, Transporter.app, or `xcrun altool` with an App Store Connect API key (Users and Access → Keys, in App Store Connect — another one-time account step).
