# Changelog

Keeping track of what I've added/changed/fixed as I go. Loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Background location during active navigation: requests "Always" authorization contextually (only when a trip actually starts, not on launch — Apple rejects apps that ask upfront) and lets location updates keep flowing if the app is backgrounded mid-drive, so rerouting/ETA stay accurate. Turned back off when the trip ends.
- Local notifications for the next turn when the app is backgrounded during navigation, using the same phrasing as the in-app voice guidance. This is honestly *local*, not push — there's no backend server to send anything from, so true remote/silent push isn't something this app can build without one.

## [0.2.0] - 2026-08-02

### Fixed
- Search bar needed two taps before the keyboard would actually pop up — the glass background was eating the first tap for its press animation. Fixed with a `simultaneousGesture` so focus happens right away.
- Was hammering the Google API way more than needed. Place detail was re-fetching full details every time you opened the same place, even ones you'd already seen. Added a simple in-memory cache (1 hour TTL) so repeat opens are free. Also added a debounce on route recalculation so flipping avoid-tolls/highways toggles back to back doesn't fire a request per toggle.

### Added
- Search-along-route — while navigating, a search button on the nav overlay lets you pull up Gas/Food/Coffee/EV Charging/Parking near where you're headed and add one as a stop without leaving the route. Right now it searches near a point about a third of the way down the remaining route rather than the whole path — good enough for now, might revisit later.
- Real multi-stop routing — "Add Stop" opens a search sheet and adds the place as an actual waypoint sent to Google Routes, so it's one real route through all your stops instead of separate legs glued together. Only shows one route option when you have stops since Google's Routes API doesn't do alternates + waypoints at the same time.
- Spoken turn-by-turn voice guidance using AVSpeechSynthesizer — announces the current turn, a heads-up before the next one, and arrival. Mute button actually works now.
- Auto-reroute — if you drift off the route it recalculates automatically instead of just sitting there wrong.
- Redid the home screen to look more like Apple Maps — partial-height sheet with search bar, saved places row, recents, favorites. Scrolling up expands it to full height.
- Swipeable route alternates in the directions card, matching how Apple Maps lets you page through route options.
- In-app directions — no more bouncing out to Apple Maps. Computes the route with MKDirections, draws it on our own map, shows distance/ETA. (Can't do real turn-by-turn since Apple doesn't expose that to third-party apps.)
- UI test suite covering search, category pills, place detail, and the directions flow.
- Google Places-backed place detail sheet — photos, ratings, reviews, hours, phone/website/address.
- Search sections only show up once you actually tap into the search bar, matching Apple Maps instead of dumping suggestions on you immediately.
- Full pass to make the UI look more like Apple Maps — custom map controls, glass search bar, real voice search, weather widget, Nearby section, tip card, Favorites with quick-add.
- Search with autocomplete, category pills, recents — Apple-Maps style bottom sheet.
- App icon + accent color.
- Initial project setup — folder structure, XcodeGen config, README/CHANGELOG/LICENSE.
- Base map view centered on current location, with a proper permission-denied screen instead of just showing a blank map.

### Fixed
- API key wasn't actually being read at runtime — Xcode's auto-generated Info.plist doesn't support custom keys, so `GOOGLE_PLACES_API_KEY` never made it into the app no matter what was in Secrets.xcconfig. Switched to a real Info.plist to fix it.
- Drive/Walk/Transit picker didn't actually switch modes when tapped. Swapped the native segmented picker for custom buttons wired directly to the view model.

### Changed
- Moved route preferences (avoid tolls/highways/etc) into the "Options" chip instead of a separate row, matching where Apple puts it.
- Bumped deployment target to iOS 26 to use Liquid Glass instead of the old material backgrounds.
