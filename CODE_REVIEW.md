# OpenHikes code review

The tree holds 164 first-party Swift files and 36,828 lines of shipping app
code, plus 3,948 in the shared package, 878 in the widget, and 31,988 lines of
tests across four bundles. Review covers correctness, concurrency,
maintainability, current API use, proportionality, and battery, radio, CPU and
disk activity during a hike.

**This document is a live list, not a log.** A finding is only useful while it
is true, so a fixed one is deleted rather than annotated, and a claim that
stopped matching the code is deleted whether or not anything was done about it.
Decisions that have been investigated and settled — types that should not become
actors, older API that is justified rather than legacy, deliberate test seams,
and claims that turned out to be false — live in
`.github/copilot-instructions.md` under "Settled decisions", so they are loaded
as context rather than re-raised as findings.

## Overall: 8 / 10

This is a genuinely well-engineered iOS codebase, and the number is held down by
a small number of specific things rather than by any general weakness.

What earns the eight: the concurrency model is fully Swift 6 with
`SWIFT_STRICT_CONCURRENCY = complete` and `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` set identically across all five targets with zero drift between Debug
and Release; there is not one deprecated SwiftUI call, not one `ObservableObject`,
not one Combine import, and not one `@available` guard left dead against the
26.5 floor; `print()` appears nowhere in shipping code and `Logger` appears in 32
files; the test-to-shipping ratio is 0.81:1 and the tests are overwhelmingly
behavioural rather than plumbing; and the comments are the best part of the
repository — they consistently explain *why*, name the run that produced the
lesson, and argue the alternative that was rejected.

What holds it back is listed below, but one thing matters more than the rest:
the measurement apparatus has grown to roughly 3,900 lines of diagnostics and
scripts against 41,600 of product, and nothing runs the suite that justifies it
on a schedule.

Per domain, for calibration: modernity 9, tiles 8.5, photos/shared/widget 8.5,
map & app composition 8, hikes/data/sync 8, build & CI 8, recording 7.5,
test suite 7.5.

## Open findings

### 1. `refreshLiveStateAfterJournalMerge` retries on a vacuous condition (Medium)

`OpenHikes/Recording/HikeRecorder+Helpers.swift:375-376`

The loop is written as:

```swift
while sessionID == expectedSessionID,
      acceptedFixRevision >= minimumRevision {
```

`minimumRevision` is captured from `acceptedFixRevision` before the call, and the
revision only ever increments, so the second clause is true on entry and stays
true for the life of the session. The loop is really `while sessionID ==
expectedSessionID`, and the clause that looks like a bound is not one.

The body retries whenever a fix arrives during the await — the
`guard acceptedFixRevision == revision … else { continue }` at line 387. Each
retry drains the journal queue, loads the whole session from disk, and
normalizes every point. That work is O(points), so the retry window *grows as
the recording gets longer*, which means the longer the hike runs the more likely
it is that another fix lands inside the window and triggers another retry. That
is the wrong direction for a loop with no iteration cap.

It is not an infinite loop in practice: fixes are distance-filtered and the path
only runs after merging widget fixes, so the common case converges on the first
pass. But it is an unbounded retry whose cost and failure probability both rise
with session length, and nothing tests the retry path at all. Give it an
explicit attempt cap that falls back to the un-refreshed state, or restructure
it as `repeat { … } while acceptedFixRevision != revision`, which is what the
`continue` is actually expressing.

### 2. `trimCache` deletes outside the mutation lock (Medium)

`OpenHikes/Tiles/Cache/TileCache+StorageManagement.swift:228-235`

Compare with `removeTiles(unclaimedBy:)` earlier in the same file, which at
line 129 wraps its entire enumerate-and-delete loop in
`mutationVersions.withLock` and calls `versions.invalidateAll()` inside it.
`trimCache` does neither: its deletion loop calls `removeItemIgnoringNotFound`
directly, with no version bump and no lock.

The mutation-version scheme exists precisely to make bump-then-delete atomic
against check-then-write, so a fetch that captured its token before a deletion
cannot write the file back afterwards. `trimCache` opts out of the one mechanism
built to prevent that.

As the section below records, this was investigated before and found
unreachable — a tile promoted after the claim snapshot keeps its fetch-time
mtime and therefore sorts last in the oldest-first order, so reaching it needs
`size(tile) > 0.8 × 500 MB`. That analysis still holds. The finding is not that
the bug is live; it is that the safety is arithmetic and accidental while the
mechanism designed to guarantee it is sitting right there unused, and that
`trimTargetFraction` is a tunable someone could lower without knowing it is
load-bearing. Wrapping the loop the way its sibling already does costs nothing
and converts an accident into an invariant.

### 3. Bare `Task {}` on `@MainActor` types, against the project's own rule (Medium)

`OpenHikes/Map/Location/BackgroundTrailTracker.swift:342`,
`OpenHikes/Recording/HikeRecorder+Lifecycle.swift:311`,
`OpenHikes/Recording/HikeRecorder+Helpers.swift:284,307`,
`OpenHikes/Recording/HikeRecorder+Energy.swift:81`,
`OpenHikes/Photos/HikePhotoImport.swift:123`,
`OpenHikes/App/OpenHikesModel.swift:394`

The architecture notes state the rule plainly, and state what it cost when it
was broken: a `Task {}` started from a method on a `@MainActor` type inherits
that isolation and runs its body on the main thread, which is how
`CloudSyncCoordinator` once pinned the main thread for seconds building a
`CKContainer` on a fresh install. `CloudSyncCoordinator.offMainThread(_:)` is the
guarded seam that came out of it.

Every site above is currently benign, and for a specific reason each time: the
body either suspends immediately into an actor-isolated call, or the work is
marked `@concurrent` (`HikePhotoImport.erase()` at line 137), or it is a
`Task.sleep`. So this is not a live performance bug. It is that seven call sites
are relying on a property of their *callee* to stay off the main thread, when
the project's stated convention is to express that at the *call site* with
`Task.detached` or a `nonisolated` trampoline. `HikePhotoImport.discardFiles` is
the clearest illustration: delete `@concurrent` from `erase()` during some future
refactor and file deletion silently moves onto the main thread, with nothing to
catch it. `scheduleLiveMatching` already does this correctly with
`Task(priority: .utility)` — the pattern exists in the same file, it is just not
applied uniformly.

### 4. The entitlement is not persisted, and its lifecycle is untested (Medium)

`OpenHikes/Purchases/MapEntitlement.swift:31,54`,
`OpenHikes/Purchases/MapEntitlementStore.swift:117-121`

`MapEntitlementState` starts `.unknown` on every cold launch, and `.unknown`
allows paid providers. Nothing is cached to `UserDefaults`. The reasoning is
sound — a paying subscriber must never see a downgraded map while StoreKit
resolves — but the consequence is that *every* launch serves paid tiles to
everybody until the first `currentEntitlements` pass completes, which on a cold
start with poor connectivity is not instant. Those are billed Stadia or
Thunderforest requests against the developer's own key.

A non-authoritative last-known value in `UserDefaults`, used only to decide what
to draw before StoreKit answers and overwritten the moment it does, keeps the
subscriber experience identical and closes the leak. It is not a security
control and does not need to be — the tile keys are bundled in the binary
anyway, so the threat model here is accidental cost, not a determined attacker.

Separately, `MapEntitlementStore` has a clean injection point in its
`currentEntitlements` closure and no suite that uses it. `MapEntitlementTests`
covers the static gate and `MapSubscriptionTermsTests` covers wording and the
product-ID cross-check against `OpenHikes.storekit` — which is a genuinely good
test — but nothing drives `purchase()`, `restore()`, `refresh()` or
`sceneDidBecomeActive()`, so no test covers the free → subscribed → expired
transition. For the one subsystem in the app that takes money, that is the wrong
place to have no coverage.

### 5. Photo import runs in an uncancelled unstructured task (Medium)

`OpenHikes/App/Navigation/OpenHikesView+Photos.swift:72`

`attachPickedPhotos` starts a `Task` that iterates the picked items and captures
`subject.hike`, a SwiftData model. It is not stored and not cancelled on
selection change or disappearance. The per-iteration `subject.hike.isAttached`
check is a real guard and stops the obvious failure, but the task can still
outlive the selection that started it.

The file next door already solves exactly this problem: `ImportSelectionGate` at
`OpenHikesView.swift:573`, held at `OpenHikesView.swift:42`, exists so a GPX
import cannot land against a selection the user has since changed. Photo import
should hold the task and cancel it the same way, or route through the same gate.

### 6. Trail breakdown taxonomy duplicates ~250 lines structurally (Low)

`OpenHikes/Hikes/TrailSurfaceBreakdown.swift`,
`OpenHikes/Hikes/TrailDifficultyBreakdown.swift`,
`OpenHikes/Hikes/HikeSurfaceSection.swift`,
`OpenHikes/Hikes/HikeDifficultySection.swift`

The two breakdown types are structurally identical: the same nested `Share`
struct, the same `init(meters:)`, the same `sorted()`, the same
`dominant` / `surveyedFraction` / `isEmpty` / `meters(for:)` surface. The two
analyzers duplicate their sampling loop almost line for line, and the two
sections mirror each other in the view layer as well.

A `TrailCategory` protocol on `TrailSurface` and `TrailDifficulty` with a
generic `TrailBreakdown<Category>` collapses the model half; a single sampling
function parameterized by a classification closure collapses the analyzer half.
This is a readability and drift argument, not a correctness one — the risk is
that a fix lands in one copy and not the other.

### 7. Five SwiftLint rules are both opted in and disabled (Low)

`.swiftlint.yml`

`required_deinit`, `file_types_order`, `conditional_returns_on_newline`,
`switch_case_on_newline` and `vertical_whitespace_between_cases` each appear in
both `opt_in_rules` and `disabled_rules`. The disable wins, so behaviour is
correct and `Scripts/lint.sh` is clean — but the file contradicts itself, and
every disabled rule elsewhere in this config carries a comment arguing for it,
which is what makes these five stand out. Delete the `opt_in_rules` entries.

### 8. `aps-environment` is hardcoded to `development` (Low)

`OpenHikes/OpenHikes.entitlements:4-5`

Xcode rewrites this key during archive and distribution, so this is very
unlikely to ship broken. It is listed because it is the one entitlement value in
the file that is environment-specific and hand-written, and because nothing in
CI archives, so nothing would notice if the rewrite ever failed to happen.

## Missed platform opportunities

Not defects. Ranked by fit.

1. **Live Activities / ActivityKit.** This is the big one. The app records GPS
   for hours and already has every input a Live Activity needs:
   `SharedRecordingSnapshot` is essentially a `ContentState` already, the widget
   renders elapsed time with `style: .timer`, and `RecordingWidgetContent` is a
   view that could be reused nearly as-is. For a hike recorder in 2026, a
   Dynamic Island and lock-screen presence during recording is close to
   table stakes, and the distance from here to there is short.
2. **App Intents and Shortcuts.** `AppIntents` is already imported for widget
   configuration, but there are no standalone intents — "start a recording",
   "how far did I hike today", "show my last hike" are all natural and all
   absent, which also means no Siri and no Spotlight surface.
3. **Control Center control (`ControlWidget`).** Start and stop a recording
   without unlocking to the app. For this app's actual use — phone in a pocket,
   gloves on, at a trailhead — this is a better fit than for most apps that ship it.
4. **Interactive widget buttons.** The widget is read-only; pause and resume
   from the home screen are available and would compose with the above.
5. **Localization.** There is still no `.xcstrings` catalog, so the app is
   English-only and every user-facing string is a literal. The longer this
   waits the larger the migration.

## Test and project hygiene

| Gap | Impact |
|---|---|
| No long-running recording integration test | The single highest-risk path in the app. Suites deliver fixes one at a time; nothing drives hundreds of fixes across simulated hours with pause/resume, energy transitions and journal flushes, then stops and checks the saved hike. Memory growth, flush regressions and journal corruption over a real session are all unobserved |
| No permission-denial coverage | Nothing simulates `CLAuthorizationStatus` becoming `.denied` mid-recording, or Photos access being revoked during discovery |
| No StoreKit lifecycle coverage | See finding 4 |
| Remaining sleep/yield barriers | `TileTransportTests.swift:285,290`, `AutoSaveDrainTests.swift:100`, `OverpassTrailGraphProviderTests.swift:40,198,245`, plus the two absence assertions in `HikeRecorderTests+Sensors.swift:208,286`. `settleDelegateHop(until:)` exists for exactly this and is not used here |
| Untested critical calculations | `CachingTileOverlayRenderer.zoomLevel(for:zoomScale:tileWidth:)` reverse-engineers a zoom level through `log2` with a `+0.5` rounding bias and no test; a wrong answer means wrong tile keys. Also untested: `RecordingTrace.widgetPolyline(maxPoints:)` downsampling, `RecordingRouteReview.legChoices`, Overpass 30-day cache expiry, `TrailMatcher.match` single-point input |
| A few assertions cannot fail | `GPXImportTests.swift:353` asserts `count == 1` then `count <= 1`; `GPXExportTests.swift:228` matches any date in the filename, so an export-time-vs-hike-time bug passes; `HikeAttachmentTests.swift:35` asserts SwiftData's own behaviour |
| `SearchCompleter`, `WeatherManager`, `TrailBasemapRenderer`, `TopEdgeReader`, `MainThreadWatchdog`, `SheetPresentation`, `ImportSelectionGate` lack direct suites | The last two are pure-logic types extracted specifically for testability, which makes their absence the most surprising |
| No fuzz testing for GPX, no snapshot testing anywhere | `MercatorTests` runs 20,000 seeded random coordinates per zoom level and is the best test in the repository. The same technique applied to GPX parsing would be cheap and valuable |
| No `.xcstrings` catalog | Localization will require a broad later migration |
| No CodeQL or dependency review in CI | No security scanning of any kind |
| `Scripts/perf-report.py` has no `--baseline` | Every performance report is read in isolation; a regression against `PERFORMANCE.md`'s numbers has to be spotted by eye |

Strict SwiftLint passes and every first-party Swift target treats warnings as
errors. `GCC_TREAT_WARNINGS_AS_ERRORS` is unset, which is harmless today because
there is no Objective-C or C in the project.

## On proportionality

Worth stating plainly because it is the largest structural comment in this
document.

| Component | Lines |
|---|---|
| Shipping app | 36,828 |
| Shared package + widget | 4,826 |
| Tests, all four bundles | 31,988 |
| `General/Diagnostics/` | 2,265 |
| `Scripts/` + `ci_scripts/` | 1,295 |
| All documentation | 1,026 |

The DEBUG-only half of the diagnostics — `PerformanceLog`,
`MainThreadWatchdog`, `RenderInstrumentation`, `ProcessResourceSample`,
`PerformanceCounterProbe`, roughly 695 lines — compiles to nothing in release
and is rigorously gated. For a MapKit-heavy app whose central architectural
claim is render isolation, a harness that can prove the claim is not indulgent;
it is the evidence. That half is justified.

The rest is where the judgement gets harder. `FieldMetrics/` is about 1,200
lines that ship in release to consume a MetricKit payload that arrives at most
once a day, on a real device, and is read by opening Settings. It is carefully
built — an actor, bounded storage, nothing uploaded, no main-thread cost — and
it answers a question nothing else can, namely the real energy cost of a
multi-hour recording on someone else's phone. But it only earns its keep if
someone actually looks, and around it sit a 538-line bespoke `perf-report.py`, a
TSV log format, and a `PerformanceUITests` suite that runs in no CI job. That is
an apparatus whose numbers are hand-maintained in a markdown file and whose
suite nothing runs on a schedule, which is the exact shape of tooling that rots
first and quietly.

None of it is badly built. The recommendation is narrow: give
`Scripts/perf-report.py` a `--baseline` flag so a regression is detected rather
than eyeballed, and either schedule `PerformanceUITests` or accept in writing
that it is a manual tool. Sophistication that nobody runs is indistinguishable
from dead code, and this is currently closer to that line than the rest of the
repository is to any line.

## Validation performed

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed (`Scripts/lint.sh`, 0.65.0, `--strict`), clean |
| Shared package tests | 76 tests in 12 suites passed in 0.46 s |
| Repository hygiene audit | 350 tracked files. `DerivedData/`, `PerformanceReports/`, `Secrets.plist`, `TestResults/`, `xcuserdata/` and `.DS_Store` are all correctly untracked and gitignored. `Secrets.example.plist` holds placeholders only |
| Toolchain | Xcode 26.6 (17F113), Swift 6.3.3 |
| Repository visibility and license | PUBLIC and MIT licensed. `LICENSE` at the root, with a `## License` section in the README that states the OpenStreetMap/Stadia/Thunderforest tile obligations separately, because they are not ours to grant |
| Build settings audit | `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION MainActor`, `SWIFT_TREAT_WARNINGS_AS_ERRORS YES`, `SWIFT_APPROACHABLE_CONCURRENCY YES`, `IPHONEOS_DEPLOYMENT_TARGET 26.5`, `TARGETED_DEVICE_FAMILY 1` — identical across all five targets and both configurations, no drift |
| Deprecated API sweep | Zero `@available`/`#available` guards, zero Combine, zero `ObservableObject`, zero `NavigationView`, zero `foregroundColor`/`.cornerRadius`, zero completion-handler `URLSession`, zero `print()` in shipping code, zero `XCTest` in the unit bundles |
| App and widget unit tests | 1,027 tests in 113 suites in `OpenHikesTests`, plus 23 in 3 suites in `OpenWidgetTests`, all passing |
| Cross-cutting consistency | Every DocC symbol link resolves; every `.swift` path referenced from a comment exists; `group.tappium.com.OpenHikes` agrees across both entitlements files and `SharedStore.appGroupID`; the widget's entitlements carry only the App Group while the app carries iCloud, WeatherKit, push and network; every `xcodebuild` call in `ci.yml` and `run-ui-tests.sh` carries `-skipPackagePluginValidation`; `ci_post_clone.sh` sets both `IDESkip…` keys; every `--ui-test-*` flag matches `AppLaunchEnvironment` in both directions; `@concurrent` is spelled one way throughout; and `ModelConfiguration+OpenHikes.swift` is the only place `cloudKitDatabase` is named, with no other `ModelConfiguration(` literal anywhere |
| iOS debug and release builds | Not re-run this pass; previously passed with Swift warnings as errors |
| UI automation | Not re-run. No `--ui-test-*` flag, launch path or accessibility surface changed |
| Physical-device energy trace | Not run — see `PERFORMANCE.md` § "Validating on a device" |

## Open product design decisions

These are product choices rather than correctness findings.

1. **Pause semantics.** Pausing stops accumulation but the persisted route stays
   a single segment.
2. **Shipped trail graphs.** Cached Overpass regions do not provide offline
   matching in places the user has never visited.
3. **Widget takeover.** A live recording replaces the selected hike rather than
   appearing as a badge or secondary state.
4. **Two foreground location managers.** `LocationManager` and
   `SystemRecordingLocationSource` each own a `CLLocationManager`, and both
   receive updates during an active recording. Verified rather than assumed: the
   foreground manager never stops once started, and the recording source asks
   for `kCLLocationAccuracyBest` with a 10 m filter against the foreground
   manager's ten-meter/25 m baseline. iOS coalesces same-process location demand
   to the most demanding request, so this does not imply twice the GPS hardware
   power; what it duplicates is delegate dispatch and authorization handling.
   Both delegates now deliver through `onMainActor`, so the duplication no
   longer costs a `Task` allocation per fix. The separation is kept
   deliberately: the recording source owns background semantics
   (`allowsBackgroundLocationUpdates`, a `CLBackgroundActivitySession`, and no
   automatic pausing) that must not leak into ordinary map browsing. Revisit
   only if a device energy trace shows meaningful CPU overhead, and preserve
   those background semantics if the two are ever consolidated.
5. **Stop-name pre-fill.** `RecordingView.swift:469` pre-fills `stopNameDraft`
   with the hike's default title, while the alert says *"leave it blank to keep
   the default"* and the `TextField` prompt already shows that default. Tapping
   Stop → Save without typing therefore writes `customName`, permanently marking
   the hike user-named. Either the pre-fill is wrong or the copy is.
6. **`backgroundLocationShare` above 100%.** `FieldMetricsDigest.swift:384`
   divides background location time by fg+bg lifetime, which MetricKit accounts
   separately, so values above 1.0 are representable and would render as "112%".
   Clamping is a behaviour change to a shipped metric.
7. **Speed is always km/h.** `HikeFormat.swift:79-86` formats speed with
   `.kilometersPerHour` and `.asProvided`, while distance uses `usage: .road`
   and adapts to locale. A US user therefore sees miles for distance and km/h
   for speed in the same view. Changing it is a visible behaviour change, but
   the current state is internally inconsistent.
8. **`OpenWidgetExtension` has no `SUPPORTED_PLATFORMS`.** It stays iPhone-only
   through `SDKROOT` and `TARGETED_DEVICE_FAMILY = 1`. Adding it is a pbxproj
   edit with more blast radius than the defect.

