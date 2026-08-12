# OpenTrails Code Review

Original review: 2026-08-11 at commit `2ee19ea`. Status updated against the working tree at `d5d0058` (`main`), after the recording feature landed.

## Executive summary

The app remains structurally sound. The infrastructure an earlier review called out as its outstanding risk is built: the tile pipeline, the background-relaunch path and the widget all have injectable seams, and the suites that used to share process-global singletons own their own state. Live hike recording now ships on the same terms — an app-scoped recorder, a crash-safe journal, injectable location/clock/sensor/transport seams, and no SwiftData write until Stop.

No current finding is a crash or data-loss defect, and no measured per-event cost remains.

What is left is CI, and the accuracy half of trail matching: geometry is matched at Stop, but nothing is matched live and nothing asks the user to resolve a gap the matcher wasn't sure about.

## Current build and test state

| Surface | Result | Notes |
|---|---:|---|
| iOS app build | Pass | `OpenTrails`, iPhone 17 Pro simulator |
| iOS app tests | Pass | **434 tests, 54 suites**, strict mode, 0 known issues, 0 skipped |
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

## Recording: what is built, and what is not

Recording is complete as a feature — it records hikes, survives a jetsam kill, and saves one `Hike` at Stop. Matching is where the design outran the implementation, and the shortfalls below are the honest list.

**Live matching never runs.** The HMM matcher (emission from each fix's own `horizontalAccuracy`, transition against graph shortest paths, Viterbi with backtrack) exists in `TrailMatcher` and runs exactly once, inside `HikeRecorder.persist(_:)`. The design's sliding window — a ~60 s tail that stays provisional while older geometry commits — is absent. The user-visible consequence is that `RecordingStats.matchedTrailName` is only ever assigned at save time, so `RecordingView`'s "Following: <trail>" line cannot appear during a recording at all. Either build the window, or drop the line.

**Ambiguity is detected and then discarded.** `TrailMatcher` computes a per-leg confidence margin, refuses to attribute a leg it isn't sure about, and reports `ambiguousLegCount`. `HikeRecorder` logs that count and throws it away. Nothing asks "which way did you go?", and an ambiguous leg is drawn exactly like a confident one — the raw geometry is preserved, which is the safe half, but the cleanest answer to sparse data (ask the person who was there) is not built.

**The trail graph is fetched once and never extended.** `HikeRecorder.prefetchTrailGraphIfNeeded(around:)` returns early once `lastGraphPrefetchCoordinate` is set, so exactly one zoom-12 region — roughly 7–10 km across at temperate latitudes — is ever fetched, around the first accepted fix. A walk that leaves that region gets no geometry for the rest of the day and silently falls back to the raw trace. Abstention is the right failure, but extending the corridor as the walk leaves it is not implemented.

**Motion activity is never consulted.** The speed gate is a fixed threshold. `CMMotionActivity` corroboration — distinguishing a stationary phone from a walking one, and a gondola or shuttle from an implausible GPS jump — is absent, so a lift is rejected as bad data rather than marked as a lift.

Everything else in the design is present and tested: the entry point and `SheetRoute`, the isolated recording UI and chunked map trace, the fix policy and stationary-drift control, barometric elevation fusion, the fixed-width journal with torn-tail and open-session recovery, one-time save, Overpass fetching with a real `User-Agent` and 429 backoff, pedometer-constrained gap inference, opt-in post-Stop Stadia matching, widget anchor sampling, the recording snapshot takeover and deep link, and the four recording settings.

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

### Recording accuracy

- [ ] **Live sliding-window matching**, or remove the "Following:" line that can never populate without it.
- [ ] **Post-recording ambiguity review**: offer option A / option B / "Use GPS only" for each leg `TrailMatcher` flagged ambiguous, and draw ambiguous legs distinctly instead of identically.
- [ ] **Extend the trail-graph corridor** as a recording leaves its first prefetched region, instead of prefetching once and abstaining thereafter.
- [ ] **Consult `CMMotionActivity`** so a lift or shuttle is marked rather than rejected, and so the stationary state machine has corroboration beyond position.

### Infrastructure

- [ ] **Add CI** (hygiene): compile gates for iOS, macOS and visionOS; the app, widget and shared-package test suites; strict mode, so a suite that can't run fails instead of disappearing.

### Product readiness

- [ ] **Add a localization catalog** before the app is offered in more than one language.
