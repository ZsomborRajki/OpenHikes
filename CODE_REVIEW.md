# OpenTrails — code quality action plan

This file tracks **open** engineering work only. A finding that has been fixed is deleted from here rather than ticked; git history is the record of what was done.

Verified locally at `92d6dd7` (Xcode 26.5, iPhone 17 Pro simulator): the app and widget build, all test bundles pass, `swiftlint lint` reports 0 violations, and all 10 build configurations are on `SWIFT_VERSION = 6.0` with `SWIFT_STRICT_CONCURRENCY = complete`. macOS, visionOS and iPadOS are **unverified** — nothing builds them. None of this is enforced on a pull request, which is why item 1 comes first: until CI exists, every item below can silently regress.

---

## 1. Continuous integration — no gate exists

`.github/workflows/` does not exist; `.github/` contains only `copilot-instructions.md`. Every result above was produced by hand on one machine, and cross-platform compile breaks have reached `main` before.

Add a pull-request workflow on a macOS runner with Xcode 26.5 gating these jobs:

| Job | Command |
|---|---|
| iOS build (app + widget) | `xcodebuild build -project OpenTrails.xcodeproj -scheme OpenTrails -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| App, widget and UI tests | `xcodebuild test -project OpenTrails.xcodeproj -scheme OpenTrails -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Shared package tests | `swift test --package-path OpenTrailsShared` |
| Lint | `swiftlint lint --strict` |
| macOS compile gate | `xcodebuild build -scheme OpenTrails -destination 'platform=macOS'` |
| visionOS compile gate | `xcodebuild build -scheme OpenTrails -destination 'platform=visionOS Simulator,name=Apple Vision Pro'` |

Requirements the workflow has to satisfy:

- **Run the tests in strict-suite mode.** `WidgetFeedSuites` and the widget target's `Trail widget` suite disable themselves without an App Group container, so a green run can mean nothing ran. `REQUIRE_ALL_SUITES` turns a missing precondition into a failure:

  ```sh
  xcodebuild test -project OpenTrails.xcodeproj -scheme OpenTrails \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) REQUIRE_ALL_SUITES"
  ```

- **No secrets needed.** `OpenTrails/Secrets.plist` is gitignored and optional; OpenStreetMap is the keyless default, so a clean checkout builds. Keep it that way rather than adding a required CI secret.
- **Signing must not block simulator jobs.** The WeatherKit entitlement needs a development team for device builds; simulator and compile-gate jobs should disable signing rather than carry a certificate.
- Cache SwiftPM dependencies (the app resolves swift-collections, swift-algorithms and swift-async-algorithms) so a run is not dominated by resolution.

## 2. Build settings drift between targets

- [ ] **Set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on `OpenWidgetExtension`, `OpenWidgetTests` and `OpenTrailsUITests`.** Only the app and `OpenTrailsTests` set it (4 of 10 configurations). `OpenWidget/` is compiled into *two* targets that disagree about what an unannotated type means, so widget UI code is main-actor by convention in one and by nothing in the other. CI (item 1) is what keeps this from drifting back.

## 3. UI performance

- [ ] **Pin what `MapSheet` reads, then close it** (`OpenTrails/Map/MapSheet.swift`, `OpenTrailsTests/Map/RouteAppearanceIsolationTests.swift`). `RouteStyle` keeps a colour/width drag out of `OpenTrailsView.body`, and two tests hold that closed — but `MapSheet` holds `@Query(sort: \Hike.date, ...) private var hikes: [Hike]`, and `tintHex`/`routeWidth` are persisted attributes of the models that query returns. The drag reaches the sheet through the store instead of through the root view, costing the `NavigationStack`, the hikes `List` and every `HikeRow` per sample; the auto-save drain appending to `hike.autoSavedTileKeys` takes the same path. Measure before redesigning: add an `ObservationCounter` test over the sheet's real read set asserting that a width/tint drag and an `autoSavedTileKeys` append cost it nothing. If `@Query` does invalidate per sample, narrow what the sheet observes to the fields `HikeRow` renders.
- [ ] **Get the offline-download tap off the main actor** (`OpenTrails/Hikes/HikeDetailView.swift:321`, `OpenTrails/Tiles/Offline/OfflineTileDownloader.swift:84`). The button passes `hike.coordinates` — a full `route.map(\.clCoordinate)` remap — and `start(route:source:scale:)` then runs `Self.tiles(covering:)` over every zoom level synchronously, all on the main actor at tap time. `DisplayedRouteCoordinateCache` already exists because the remap is expensive, and `refreshStoredBytes` already does its remap inside a detached task; this is the one path that does not.

## 4. Missing tests

- [ ] **A sheet-isolation suite.** The highest-value gap: it is the one invalidation channel the existing isolation tests were written to close and do not cover. Same technique as `RouteAppearanceIsolationTests`, which counts reads through the real `DisplayedRoute.forSelection` call so a read added back fails there rather than passing against a copy. Pairs with the first item in section 3.
- [ ] **Unit suites for the untested files:**

  | File | What is untested |
  |---|---|
  | `Map/Search/SearchCompleter.swift` | Debounce and result delivery — `HikeSearch`, its sibling on the same screen, has a full suite |
  | `Weather/WeatherManager.swift` | `WeatherPollingTests` covers `WeatherPollState`, not the manager |
  | `Map/Rendering/DirectionalPolylineRenderer.swift` | Arrow placement and spacing (`MapCoordinatorTests` only asserts renderer selection and line width) |
  | `Map/Rendering/TrailBasemapRenderer.swift` | App-side rendering (the shared `TrailBasemap` is covered) |
  | `Map/TopEdgeReader.swift` | The sheet-top reporting that map-button placement depends on |
  | `General/Diagnostics/MainThreadWatchdog.swift` | Stall detection and the once-only start guard |

- [ ] **UI automation for the two remaining unguarded flows.** `OpenTrailsUITests` now covers launch, GPX import, simulated-location recording start, the record → review → save round trip, and launch performance. Still missing: the widget deep link's three branches in `openWidgetLink` (live recording, pushed hike, deleted hike), and deleting a hike whose detail view is pushed, which `MapSheet.delete`'s `path.removeAll` exists specifically for.

## 5. Product readiness

- [ ] **Add a localization catalog.** No `.xcstrings` exists; all user-facing strings are in source. Fine for one language, a prerequisite for a second.

---

## Open design decisions

Unresolved, carried from the recording design. Each changes code, so none should be settled by drift. Canonical geometry is settled: `Hike.route` stays the reviewed line and `rawRoute` the trace beside it, but the hiker now chooses per section which one the route holds, so a saved line is a decision rather than a default.

1. **Pause semantics.** A pause stops distance accumulation and journals a marker, but the saved route stays one continuous segment. Making a pause a real break in the drawn line requires changing `GPXImport`'s flattening assumption and the single-segment route model together.
2. **Shipped trail graphs.** Overpass-on-demand plus a local cache works offline only where you have already been. Prebuilt regional graphs from Geofabrik extracts would work offline where you are going, at the cost of a build pipeline and a download story.
3. **Widget takeover.** A live recording currently displaces the selected hike on the widget entirely; the alternative keeps the trail on screen with a recording badge.
