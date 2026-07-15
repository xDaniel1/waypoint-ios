# Waypoint

A native iOS maps app: Apple Maps' look, feel, native MapKit rendering, and the Liquid Glass design system — with Google Maps–style rich place details (photos, ratings, reviews, hours) layered on top via the Google Places API.

*(screenshot / demo GIF coming once there's UI to show)*

## Features

- [x] Native MapKit map centered on the user's current location, with graceful handling of denied/restricted location permission
- [x] Apple-Maps-style search: persistent Liquid Glass bottom sheet, category shortcuts, live autocomplete, recents
- [ ] Tap-to-open place detail sheet: photos, star ratings, reviews, hours, phone, website, address (sourced from Google Places, not Apple's default POI data)
- [ ] "Get Directions" handoff to Apple Maps for turn-by-turn navigation
- [ ] Recent searches / favorites (local storage)

See [Roadmap](#roadmap) for what's built vs. planned.

## Tech stack

- Swift 6, SwiftUI
- Liquid Glass (`.glassEffect`, `GlassEffectContainer`, `.glassProminent` button style) — iOS 26+ only, so custom UI matches system chrome
- MapKit (native `Map` view and annotations)
- Google Places API (New) — Place Details, Text/Nearby Search, Photos
- URLSession + async/await for networking (no third-party networking libraries)
- MVVM architecture
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` from `project.yml` (the `.xcodeproj` itself is not committed)
- Swift Package Manager only — no CocoaPods

## Setup

### Prerequisites

- Xcode 26 or later (developed against Xcode 27 beta)
- iOS 26 or later on device/simulator — the deployment target is iOS 26.0 to support Liquid Glass
- [Homebrew](https://brew.sh)
- A Google Cloud project with **Places API (New)** enabled and an API key ([console.cloud.google.com](https://console.cloud.google.com/))

### Steps

1. Clone the repo:
   ```sh
   git clone https://github.com/<your-account>/waypoint-ios.git
   cd waypoint-ios
   ```
2. Install XcodeGen if you don't already have it:
   ```sh
   brew install xcodegen
   ```
3. Copy the secrets template and add your Google Places API key:
   ```sh
   cp Secrets.xcconfig.example Secrets.xcconfig
   # then edit Secrets.xcconfig and set GOOGLE_PLACES_API_KEY
   ```
   `Secrets.xcconfig` is git-ignored — your key never gets committed.
4. Generate the Xcode project:
   ```sh
   xcodegen generate
   ```
5. Open `Waypoint.xcodeproj` and run on an iOS 26+ simulator or device.

## Project structure

```
Waypoint/
├── Waypoint/
│   ├── App/            # App entry point (WaypointApp.swift)
│   ├── Models/          # Place, Review, PlacePhoto, etc.
│   ├── ViewModels/      # MapViewModel, PlaceDetailViewModel, etc.
│   ├── Views/
│   │   ├── Map/         # Main map screen
│   │   ├── PlaceDetail/ # Bottom sheet + subviews
│   │   └── Search/
│   ├── Services/        # LocationManager, GooglePlacesService
│   └── Resources/       # Assets, colors
├── WaypointTests/
├── project.yml               # XcodeGen spec — source of truth for the Xcode project
├── Secrets.xcconfig          # git-ignored, holds your real API key
├── Secrets.xcconfig.example  # committed template
├── .gitignore
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## Roadmap

**Phase 1 (MVP)**
- [x] Base map view with current-location centering and permission handling
- [x] Search bar
- [ ] Place detail sheet (photos, ratings, reviews, hours, contact info)
- [ ] Directions handoff to Apple Maps
- [ ] Recent searches / favorites (local only)

**Phase 2 (future)**
- User accounts
- Saved lists / collections
- Offline maps
- Android version
- Social features

## Contributing

This is currently a solo/small project. Work happens on feature branches (`feature/*`) with conventional commit messages (`feat:`, `fix:`, `docs:`, `chore:`). Issues and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
