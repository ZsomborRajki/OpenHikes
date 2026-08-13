# OpenTrails Code Review

Original review: 2026-08-11 at commit `2ee19ea`. Status updated against the working tree at `d5d0058` (`main`), after the recording feature landed.

## Executive summary

The app remains structurally sound. The infrastructure an earlier review called out as its outstanding risk is built: the tile pipeline, the background-relaunch path and the widget all have injectable seams, and the suites that used to share process-global singletons own their own state. Live hike recording now ships on the same terms — an app-scoped recorder, a crash-safe journal, injectable location/clock/sensor/transport seams, and no SwiftData write until Stop.

No current finding is a crash or data-loss defect, and no measured per-event cost remains. The recording accuracy work identified by this review is now implemented: graph coverage extends with the hike, motion activity informs fix handling, matching runs live, and uncertain post-recording legs wait for an explicit choice.

What is left is CI and product readiness rather than a known recording gap.

## Current build and test state

| Surface | Result | Notes |
|---|---:|---|
| iOS app build | Pass | `OpenTrails`, iPhone 17 Pro simulator |
| iOS app tests | Pass | **452 tests, 54 suites**, strict mode, 0 known issues, 0 skipped |
| Widget tests | Pass | **17 tests, 2 suites** |
| Shared package tests | Pass | **49 tests, 7 suites** |
| macOS build | Pass | Unsigned, arm64 |
| visionOS build | **Not verified** | No visionOS runtime installed on this machine |
| iPadOS | **Not verified** | No iPad simulator installed |
| CI | **Absent** | `.github/workflows` does not exist |

## Test gaps

One remains, and it is a property of the environment rather than of the suite.

**Conditional suites can still vanish silently.** `WidgetFeedSuites` and the widget target's `Trail widget` suite disable entirely without the App Group container. Both now report the skip, and strict mode turns it into a failure:

```sh
xcodebuild test … "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) REQUIRE_ALL_SUITES"
```

Nothing passes that yet, because nothing runs the tests except a person. It becomes real coverage the moment CI does.

## Recording: completed implementation

Recording now covers the full reviewed flow: it records hikes, survives a jetsam kill, and saves one `Hike` only after Stop and any required review.

**Live matching uses a bounded provisional window.** `HikeRecorder` continuously runs the HMM matcher over at most 21 points while retaining roughly the latest 20 points / 60 seconds as provisional geometry. Older matched geometry becomes stable, newer fixes remain raw until the next pass, stale tasks cannot overwrite a newer session, and `RecordingStats.matchedTrailName` drives the live "Following:" status.

**Ambiguous legs wait for the hiker.** Sparse-route alternatives remain attached to the exact `TrailMatchResult` shown after Stop. The review presents option A, option B, and GPS for each uncertain leg, highlights that leg distinctly on the map, and does not insert a `Hike` until every choice is resolved. A finished journal survives relaunch until the review is saved or discarded.

**Graph coverage extends with the route.** Prefetching is keyed by exact zoom-12 graph regions, so every newly entered region is requested once rather than only the starting region. Cache readers await an active refresh and use expired data only when that refresh fails.

**Motion activity participates in recording.** An injectable Core Motion source corroborates stationary periods and permits otherwise implausible non-pedestrian movement such as a lift or shuttle. That metadata is persisted on route coordinates and preserved when Stadia returns simplified geometry.

The rest of the recording design remains present and tested: the entry point and `SheetRoute`, the isolated recording UI and chunked map trace, the accuracy-aware fix policy and stationary-drift control, barometric elevation fusion, the fixed-width journal with torn-tail and open-session recovery, one-time save, Overpass fetching with a real `User-Agent` and 429 backoff, pedometer-constrained gap inference, widget anchor sampling, the recording snapshot takeover and deep link, and the four recording settings.

## Repository hygiene

- **No CI.** `.github/workflows` does not exist. The passing state above is local and unprotected on pull requests; cross-platform compile failures have reached `main` before. Add compile gates for iOS, macOS, and visionOS plus all three test suites, run them in strict mode (see above) so a suite that can't run fails rather than disappearing.
- **No localization catalog.** All user-facing strings are in source — fine for a single-language prototype, a product-readiness task before localization.

## Open questions

Carried over from the recording design, and still unanswered. Each one changes code, so none of them should be settled by drift.

1. **Canonical geometry.** Today the matched route is `Hike.route` and the raw trace sits beside it in `rawRoute`, kept only when a match actually moved the line. The alternative is raw-as-canonical with the match as a display layer: more honest about provenance, more work for every existing consumer. The current choice is the simpler one, not necessarily the right one.
2. **Pause semantics.** A pause stops distance accumulation and journals a marker, but the saved route stays one continuous segment. If a pause should produce a genuine break in the drawn line, `GPXImport`'s flattening assumption and the single-segment route model both have to change together.
3. **Shipped trail graphs.** Overpass-on-demand with a local cache works offline only where you have already been. Prebuilt regional graphs from Geofabrik extracts would work offline where you are going, at the cost of a build pipeline and a download story. Worth it?
4. **Widget takeover.** A live recording currently displaces the selected hike on the widget entirely. The alternative is keeping the trail on screen with a small recording badge.
5. **Battery profile default.** High accuracy is the right default for a hiking app and costs roughly 10%/hour with the screen off. Over a six-hour day that is a real bill, and Balanced may be the better default with High as an explicit choice.

## TODO

### Infrastructure

- [ ] **Add CI** (hygiene): compile gates for iOS, macOS and visionOS; the app, widget and shared-package test suites; strict mode, so a suite that can't run fails instead of disappearing.

### Product readiness

- [ ] **Add a localization catalog** before the app is offered in more than one language.
