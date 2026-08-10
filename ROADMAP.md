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

- [x] **Speed limit is dead code.** `SpeedLimitService` targets Google's Roads API, which needs a
      premium Asset Tracking licence we don't have — it 403s and silently hides the sign. MapKit
      exposes no speed-limit API to third parties at all.
      *Decide:* pay a data provider (TomTom/HERE), or delete the feature rather than ship
      something that can never display.

- [x] **No traffic overlay.** `showsTraffic` is never set on the `Map`. Native, free, one property.

- [x] **Add Stop sheet doesn't open.** Tapping "Add Stop" in the directions card does nothing.
      Tap registers and the state closure looks correct on paper; root cause still unknown.
      Two structural fixes attempted (enum-backed `.sheet(item:)`, then hoisting presentation to
      `MapScreen`) — neither worked.

- [ ] **Stop reordering is dead.** `DirectionsViewModel.moveStops` exists but nothing calls it;
      the drag handles on the endpoint rows do nothing.

- [x] **Transit detail sheet outruns its data.** Built against Google's rich transit legs;
      MapKit's transit data is far thinner, so parts of the sheet have nothing to fill them.

- [x] **Test suite not run since the search-UI rework.** Can't currently claim it's green.

## 2. Additions that are possible with public APIs

- [x] **Leave at / arrive by.** `MKDirections.Request` supports `departureDate` / `arrivalDate`
      and we never set them. Apple Maps offers this; it's a real shippable feature.
- [x] **Route step list** ("Details") during active navigation.
- [ ] **CarPlay support.** Biggest remaining "feels like a real maps app" gap.
- [ ] **Apple Watch companion.**
- [ ] **Guides shelves**, built honestly from Google top-rated collections rather than Apple's
      licensed Infatuation/Time Out editorial (which has no API).

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
