# Waypoint

Waypoint is an iOS maps app I'm building to practice SwiftUI and working with real APIs. The goal is basically a smaller version of Apple Maps — same look and feel, MapKit under the hood — but with richer place info (photos, ratings, reviews) pulled from Google Places, since Apple's built-in POI data is pretty bare.

*(screenshots coming soon)*

## What it does

- [x] Map centered on your current location, handles denied/restricted location permission
- [x] Search with a bottom sheet like Apple Maps — category shortcuts, autocomplete, recent searches, voice search
- [x] Custom map controls (3D, compass, map style, location) positioned like Apple Maps
- [x] Local Favorites/"Places" with a quick-add button
- [x] Weather widget using WeatherKit (needs the WeatherKit capability + paid dev account to actually show up)
- [x] Place detail sheet with photos, ratings, reviews, hours, phone number, website, and address (from Google Places)
- [x] In-app directions — Drive/Walk/Transit, route drawn right on the map, distance/ETA, no bouncing out to Apple Maps
- [x] Multi-stop routing — add extra stops and it routes through all of them, not just A to B
- [x] Turn-by-turn voice guidance and auto-reroute if you go off path
- [x] Recent searches saved locally

Check the [Roadmap](#roadmap) below for what's done vs. what's next.

## Built with

- Swift 6 / SwiftUI
- Liquid Glass UI (iOS 26+ only)
- MapKit for the map itself
- WeatherKit for the weather widget
- Speech framework + AVFoundation for voice search and voice guidance
- Google Places API + Google Routes API
- Plain URLSession/async-await for networking — didn't want to pull in a networking library for a project this size
- MVVM
- XcodeGen to generate the Xcode project from `project.yml` (the `.xcodeproj` isn't committed)
- No CocoaPods, just Swift Package Manager

## Setup

### You'll need

- Xcode 26+ (I'm on the Xcode 27 beta)
- iOS 26+ simulator or device
- [Homebrew](https://brew.sh)
- A Google Cloud project with the Places API (New) turned on, and an API key

### Steps

1. Clone it:
   ```sh
   git clone https://github.com/<your-account>/waypoint-ios.git
   cd waypoint-ios
   ```
2. Get XcodeGen if you don't have it:
   ```sh
   brew install xcodegen
   ```
3. Copy the secrets template and drop in your own API key:
   ```sh
   cp Secrets.xcconfig.example Secrets.xcconfig
   # edit Secrets.xcconfig and set GOOGLE_PLACES_API_KEY
   ```
   `Secrets.xcconfig` is gitignored so your key doesn't end up on GitHub. Also worth restricting the key to iOS apps in Google Cloud Console and locking it to this bundle ID (`com.danielguzman.waypoint`).
4. Generate the project:
   ```sh
   xcodegen generate
   ```
5. Open `Waypoint.xcodeproj` and run it.
6. If you want the weather widget working, you need a paid Apple Developer account with WeatherKit enabled for your team — otherwise it just stays hidden and everything else still works fine.

## Project structure

```
Waypoint/
├── Waypoint/
│   ├── App/            # entry point
│   ├── Models/          # Place, Review, PlacePhoto, etc.
│   ├── ViewModels/      # MapViewModel, PlaceDetailViewModel, etc.
│   ├── Views/
│   │   ├── Map/
│   │   ├── PlaceDetail/
│   │   └── Search/
│   ├── Services/        # LocationManager, GooglePlacesService
│   └── Resources/
├── WaypointTests/
├── project.yml               # XcodeGen config, source of truth
├── Secrets.xcconfig          # gitignored, your real key goes here
├── Secrets.xcconfig.example
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## Roadmap

**Done**
- [x] Map + location permission handling
- [x] Search
- [x] Recents/favorites (local only)
- [x] Place detail sheet
- [x] In-app directions
- [x] Multi-stop routing
- [x] Voice guidance + auto-reroute

**Maybe later**
- Accounts / sign in
- Saved lists
- Offline maps
- Android (probably not, but who knows)

## Notes

Solo project, just me working on it in feature branches. Not really looking for contributors right now but feel free to open an issue if something's broken.

## License

MIT — see [LICENSE](LICENSE).
