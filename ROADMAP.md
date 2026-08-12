# Waypoint — Apple Maps parity roadmap

Working list. Top section gets fixed first, in order. Bottom section is the honest
"can't do with public APIs" list — noted so we stop rediscovering it, not to be built.

Status: `[ ]` todo · `[~]` in progress · `[x]` done

---

## 1. Bugs / regressions (fix these first)

- [x] **Traffic-unaware ETAs.** `AppleRoutesService` uses `MKRoute.expectedTravelTime`, which
      Apple documents as travel time *under ideal conditions*. Traffic-aware timing only comes
      from `MKDirections.calculateETA()` → `MKETAResponse.expectedTravelTime`. Every ETA and
      duration shown today is optimistic. Regression from the Google Routes → MapKit migration,
      since Google's numbers were traffic-aware.
      *Fix:* call `calculateETA` for the selected route and display that.

- [x] **Speed limit.** Confirmed Google's Roads `ListSpeedLimits` returns `API_KEY_SERVICE_BLOCKED`
      even with billing fully active — it's gated behind an Asset Tracking licence, not spend.
      MapKit exposes no speed-limit API at all. *Now sourced from OpenStreetMap via the Overpass
      API* (free, keyless), with **NYC DOT's VZV Speed Limits** open data layered underneath
      inside the five boroughs — OSM turned out to have no `maxspeed` at all on Brooklyn
      residential streets, which is why the sign never appeared. Both are real posted limits; the
      sign hides when neither has data rather than guessing.

- [x] **Nav banner didn't look like Apple's.** It floated as a rounded card with the map and status
      bar above it. Now full-bleed to the top edge with only the bottom corners rounded, a deeper
      adaptive blue, and a "Then …" shelf. Also fixed an off-by-one: the banner paired the distance
      to the *next* maneuver with the *current* step's instruction, which MapKit leaves empty — so
      it read as a distance above a blank line.

- [x] **No traffic overlay.** `showsTraffic` is never set on the `Map`. Native, free, one property.

- [ ] **Add Stop sheet doesn't open.** STILL BROKEN — `test11_multiStopRouting` fails on
      "Add Stop sheet should present a search field". Was marked done; a full suite run on
      2026-08-12 disproved that. Three structural fixes tried now: enum-backed `.sheet(item:)`,
      hoisting presentation to `MapScreen`, and consolidating SearchSheet's four chained `.sheet`
      modifiers into one (that last one was a real latent bug and is worth keeping, but it did not
      fix this). Root cause still unknown.

- [x] **Stop reordering.** Grips now appear only on stop rows, and only with 2+ stops, and open a
      Move Up / Move Down menu wired to `moveStops`. Previously every row (origin, destination,
      even "Add Stop") drew a grip and none did anything. Apple uses drag-to-reorder; these rows
      live in a plain VStack rather than a List, so a menu is the honest interim.

- [~] **Transit detail sheet outruns its data.** Built against Google's rich transit legs;
      MapKit's transit data is far thinner, so parts of the sheet have nothing to fill them.

- [ ] **Test suite is NOT green.** Full run on 2026-08-12: 15 passed, 6 failed. Failures:
      `test03` (search field not found), `test07_inAppDirections`, `test10_navigationVoiceAndControls`
      (reported as an app crash, but passes in isolation — likely suite state pollution),
      `test11` (Add Stop), `test13` (bottom bar toggle), `test15` (swipe-to-edit a favorite).
      Several of these sit under roadmap items previously marked done.

## 2. Additions that are possible with public APIs

- [x] **Leave at / arrive by.** `MKDirections.Request` supports `departureDate` / `arrivalDate`
      and we never set them. Apple Maps offers this; it's a real shippable feature.
- [x] **Route step list** ("Details") during active navigation.
- [ ] **CarPlay support.** Biggest remaining "feels like a real maps app" gap.
- [ ] **Apple Watch companion.**
- [x] **Guides shelves.** Five themed collections (Great Coffee, Dinner Tonight, Parks & Outdoors,
      Nightlife, Arts & Culture) as Apple-style photo cards, each opening a list of real places.
      Apple's guides are licensed editorial with no API, so these are assembled from top-rated
      nearby places and the card says so rather than posing as curation. Note: had to switch to
      Google's `includedPrimaryTypes` — `includedTypes` matches anywhere that merely *has* a cafe,
      which put UNIQLO and Barnes & Noble in "Great Coffee".

## 3. Can't match with public APIs — do not chase

Recorded so we stop re-investigating. All of these need private APIs or licensed data.

- **Lane guidance** — `MKRoute` returns no lane data.
- **Junction View** (3D road-level view at complex interchanges) — private to Apple Maps.
- **Speed limits / speed cameras** — no public API ([Apple dev forums](https://developer.apple.com/forums/thread/656038)).
- **Offline maps** — MapKit doesn't expose tile downloads to third-party apps.
- **Crowdsourced hazard reports** — Apple's is fleet/crowd sourced; ours is local-only by design.
- **EV routing** with charge/elevation-aware stops — Maps app feature, not in MapKit.
- **Place photos / ratings / reviews / hours from Apple** — not exposed to third parties at any
  price, which is why the app runs a Google hybrid for place content.

## Reference

- [MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections)
- [MKDirections.ETAResponse](https://developer.apple.com/documentation/mapkit/mkdirections/etaresponse)
- [Apple Maps feature list](https://www.apple.com/maps/)
