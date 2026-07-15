# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Full Apple-Maps-mirrored UI pass: custom-positioned glass map controls (3D toggle + compass bottom-left, map-style menu + location button bottom-right, via MapKit's scope-based standalone controls), a blue-tinted glass search field with a profile placeholder button, real on-device voice search (`SpeechRecognitionService` via `SFSpeechRecognizer`/`AVAudioEngine`), a WeatherKit-backed floating weather widget (hidden until the WeatherKit capability is enabled with a paid account), an honestly-labeled "Nearby" section (`NearbyPlacesService`, real `MKLocalPointsOfInterestRequest` data) and dismissible tip card in place of Apple's private Siri/transit suggestions, and a local Favorites/"Places" feature (`FavoritesStore`) with a quick-add row.
- Apple-Maps-style search: a persistent Liquid Glass bottom sheet (collapsed/medium/large detents, map stays interactive underneath) with a floating search field, category shortcut pills (Restaurants, Coffee, Gas, Groceries, Hotels), live autocomplete suggestions via `MKLocalSearchCompleter`, and a "Recents" list persisted locally via `RecentSearchesStore`. Selecting a result resolves it with `MKLocalSearch`, drops a marker on the map, and recenters the camera.
- App icon (indigo-to-teal gradient with a pin/waypoint glyph) and accent color, replacing the placeholder that disabled icon compilation.
- Initial project scaffold: folder structure, XcodeGen `project.yml`, `.gitignore`, README, CHANGELOG, LICENSE, and gitignored `Secrets.xcconfig` / committed `Secrets.xcconfig.example` for the Google Places API key.
- Base MapKit map view centered on the user's current location, using `CLLocationUpdate.liveUpdates()` via `LocationManager` and `MapViewModel`. Shows a graceful in-app prompt with a link to Settings when location permission is denied or restricted, instead of a blank map.

### Changed
- Raised deployment target from iOS 17.0 to iOS 26.0 and adopted Liquid Glass: the location-permission card uses `.glassEffect`/`GlassEffectContainer` and `.buttonStyle(.glassProminent)` instead of `.regularMaterial`. System chrome (map controls, sheets, toolbars) now renders with Liquid Glass automatically since the app links against the iOS 26 SDK.

## [0.1.0] - Unreleased

Initial pre-release development version. Not yet tagged.
