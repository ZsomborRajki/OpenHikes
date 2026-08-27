# OpenHikes code review

The tree holds 173 first-party Swift files and 39,703 lines of shipping app
code, plus 2,303 in the shared package, 880 in the widget, and 44,800 lines of
tests across four bundles. Review covers correctness, concurrency,
maintainability, current API use, proportionality, release readiness, and
battery, radio, CPU and disk activity during a hike.

**This document is a live list, not a log.** A finding is only useful while it
is true, so a fixed one is deleted rather than annotated, and a claim that
stopped matching the code is deleted whether or not anything was done about it.
Decisions that have been investigated and settled — types that should not become
actors, older API that is justified rather than legacy, deliberate test seams,
and claims that turned out to be false — live in
`.github/copilot-instructions.md` under "Settled decisions", so they are loaded
as context rather than re-raised as findings.

## Overall: 9 / 10

The previous revision scored 7.5 and said the reason plainly: shipping readiness
had not kept pace with engineering quality. That gap is closed. The four things
that would have affected a real user or a real submission — a missing privacy
manifest, WeatherKit shown without Apple Weather attribution, a raw Celsius
number served to every locale, and a malformed `<ele>` crashing the hike detail
screen — are all fixed, tested, and in one case verified in a built bundle
rather than only in source.

What earns the nine beyond that: the test suite grew from 1,041 to 1,303 app
tests and from 76 to 153 in the shared package, and the growth is concentrated
exactly where the previous revision said it was missing. Every gap in what used
to be the "Test and project hygiene" table is closed — the long-running
recording path now has a nine-simulated-hour integration test that runs in 3.6
seconds, `zoomLevel`, `widgetPolyline`, Overpass expiry, `TrailBasemapRenderer`,
`TopEdgeReader`, `MainThreadWatchdog`, `TrailGlyphView.project`, `SharedStore`
and the store-open failure branch all have direct suites, and GPX import has a
fuzzer that generated roughly 58,000 corrupt documents across 19 corruption
kinds. Several of the new negative assertions were mutation-proven in
multi-suite runs rather than in isolation, which is a higher standard than the
repository previously held itself to and which caught one test that passed for
the wrong reason.

CI moved further than the code did. Coverage is now gated at a 55% floor rather
than printed into a log nobody reads, ThreadSanitizer went from 2 suites to 34,
Release is archived rather than merely compiled, every action is pinned to a
SHA, and CodeQL, dependency review, Dependabot and private vulnerability
reporting are all on.

The render-isolation family was audited by mutation rather than by reading, and
the result is worth stating because the repository leans on it. Roughly thirty
zero-assertions were tested by breaking the behaviour each one claims to hold;
**two were decorative** — green with the guard deleted — and the rest went red
as they should. The claim survives, but it turns out to be two claims. Where the
app compares because the framework cannot (`RouteHighlight.move(to:)`,
`LocationManager.publish`, whose subject `CLLocationCoordinate2D` is not
`Equatable`) and where the app split or derived the state (`DisplayedRoute`,
`SheetPresentation`'s coarse flags, `RecordingStats`, `@Query` in the leaf), the
isolation is architecture and is genuinely protected. The two decorative zeroes
are a narrower and different claim — that a *no-op* edit costs nothing — and
that one is authored by `@Observable`'s `Equatable` filtering rather than by any
code here. It is true, it is now labelled as the runtime's rather than the
app's, and it is pinned by tests that fail if the runtime stops. The audit also
found one genuine hole that had nothing to do with any of that:
`LocationManager.minimumPublishInterval` was entirely unprotected — deleting the
throttle left the whole suite green — and it is now covered by the throttle's
observable effect rather than by an observation count that structurally could
not see it.

What holds it at nine rather than ten is a short and honest list: the app is
still English-only; the coverage figure CI gates on is measured with the suite
that exercises the view layer switched off, so it says less than it appears to;
and a handful of claims in the photo, sync and render paths are reasoned rather
than observed and need a device or a future OS to settle. None of these blocks a
release. All of them are below.

Per domain, for calibration: tiles 9.5, recording 9, photos/widget/shared 9,
build & CI 9.5, map & app composition 9, data/GPX/sync 9, test suite 9,
settings/purchases/weather 8.5.

Findings below are ordered by severity. **4 open**: 0 High, 1 Medium, 3 Low.

---

## Medium

### 1. The app is English-only, and this is now a deliberate deferral

There is no string catalog anywhere. The app is *structurally* localizable —
SwiftUI `Text` literals are already `LocalizedStringKey`, and 31 sites correctly
use `String(localized:)` where a `String` is needed — so this remains extraction
work rather than a rewrite.

This was raised as a finding, put to the maintainer, and **deliberately
deferred**. It is recorded here rather than deleted because the condition is
still true and still has consequences: the longer it waits the larger it gets,
and unit formatting has already drifted once in the meantime. Two of the fixes
in this pass — locale-aware temperature and locale-aware speed — were symptoms
of the same root, and both were fixed at the formatting layer rather than at the
localization layer, which is the correct order but not a substitute.

`README.md` records the limitation for users under "Current limitations". **Fix,
when it is wanted:** add a String Catalog to the app and widget targets and let
Xcode extract.

## Low

### 2. The coverage number depends entirely on which bundles CI runs

Two measurements of the same tree on the same simulator, minutes apart:

| Test selection | `OpenHikes.app` line coverage |
|---|---|
| `OpenHikesTests` + `OpenWidgetTests` — **what CI gates on** | **58.56%** (16,432/28,062) |
| The full plan, adding the 44 `OpenHikesUITests` | **83.73%** (23,496/28,062) |

That 25-point gap is the finding. It is not that the app is poorly covered; it
is that the coverage figure the project publishes and gates on is measured with
the suite that exercises SwiftUI view bodies switched off, and the number
therefore describes CI's configuration at least as much as it describes the
code. The CI job is explicit about this — it passes `-only-testing:OpenHikesTests
-only-testing:OpenWidgetTests` — and the exclusion is deliberate and well
argued: functional UI automation drives real gestures and timing-sensitive
waits, which a shared runner makes slow and flaky.

The consequence is that the ten largest "zero-coverage" files —
`SettingsView` 0/778, `FieldMetricsSection` 0/680, `PhotoDiscoverySheet` 0/596,
`HikeDetailComponents` 0/535, `MapPaywallView` 0/364, `HikePhotoViewer` 0/344,
`RecordingRouteReviewControls` 0/320, `HikePhotoSection` 0/287,
`HikeDifficultySection` 0/223, `HikeSurfaceSection` 0/221, being 29 files and
6,019 lines — are largely *not* untested. They are tested by a suite whose
results never reach the gate. Someone reading 58.56% and concluding the view
layer is unverified would be wrong, and someone reading 83.73% and concluding CI
would catch a regression in it would also be wrong.

**Fix:** nothing here needs a code change, and the floor should not be raised to
83% — that would make the gate depend on a suite CI does not run. What is worth
doing is publishing both numbers with their selections attached, so the 58.56%
is understood as "the logic layer under CI" rather than as the app's coverage.
The `accessibility-ui-tests` job already demonstrates the pattern for admitting
UI classes to CI one at a time as their flake rate becomes known.

Where the number genuinely is low, it is low for reasons worth keeping in view.
Of the eight logic types the previous revision named as the pointed gaps, **two
moved and six did not**: `MapEntitlementStore` 18.50% → 40.46%,
`PhotoLibraryReader` 2.75% → **24.31%**, `SearchCompleter` 14.89% → 16.67% (its
testable logic was extracted into `SearchQueryPolicy`, which is covered, so the
residue is thinner than the number implies), and `SyncedSettings`,
`OfflineTileDownloader+Quota`, `CloudSyncCoordinator`, `RecordingSensors` and
`HikeRecorder+State` all unchanged to two decimal places.

`PhotoLibraryReader` is worth reading as a method rather than a number. It first
appeared to have *regressed* — 3.12% → 2.75% — and the shape was the diagnosis
rather than the rate: covered lines held at exactly **6** while the file grew
192 → 218, so no test had been lost and new uncovered code had landed in the
least-covered logic type in the app. That is an argument for always recording
`covered/total` alongside the percentage. Covering it then found a real bug that
reasoning had got backwards: a `.fullScreen` presentation removes the
*presenting* controller's view from the window, so the window check that ran
before the responder walk refused in exactly the case the walk exists for.
`LimitedLibraryPresenter` went 0% → 100% in the same pass.

The residual 165 of 218 uncovered lines in `PhotoLibraryReader` are an argued
ceiling rather than an open gap: `requestAccess()` and the
`presentLimitedLibraryPicker` body put system UI on screen (the latter's
completion handler would never fire, so a test would hang rather than fail), and
`thumbnail`, `imageData` and `assets(takenIn:)` need a real `PHAsset`, which has
no initialiser. Seeding one via `PHAssetCreationRequest` was considered and
rejected because it mutates simulator state that outlives the run. Everything
above that line is now covered.

### 3. `PerformanceReports/` is 1.6 GB on this machine

The unbounded growth is fixed — `Scripts/run-performance-tests.sh` now prunes to
the ten most recent run directories, configurable through `--keep` and
`OPENHIKES_PERFORMANCE_RETAINED_RUNS`, and renaming a directory exempts it. The
existing 1.6 GB predates the pruning and is not removed automatically. It is
gitignored and untracked, so this costs disk rather than repository hygiene, and
the next run will start reclaiming it.

### 4. Claims that are reasoned rather than observed

Not defects, and not speculation either — each of these is a specific assertion
the code makes that no test in the tree can currently settle. They are recorded
so that a future failure in one of these areas starts with the list of things
nobody actually watched happen.

| Claim | Why it is unobserved |
|---|---|
| The limited-photo-library presenter shows the system picker and merges the widened selection | The presenter *resolution* is now observed and 100% covered — and covering it corrected a reasoned-but-wrong window check. What remains unobserved is the last mile: `presentLimitedLibraryPicker` putting real system UI on screen and the widened selection coming back. One manual run with limited access granted would settle it |
| The two framework pins in `RenderIsolationTests+Observation.swift` would go red if the runtime changed | They are correct on Xcode 26.5 / iOS 26.5 and are the tripwire for `@Observable` dropping its `Equatable` filtering or SwiftData starting to coalesce. But a runtime change cannot be induced, so unlike every other assertion in that family they are unproven in the red direction |
| `RouteStyle.generation` prevents a stale callback re-arming a duplicate observation registration | With the callback re-reading `trackedHike`, this is `generation`'s only unshared job — a duplicate registration would apply every later write once per hike ever followed. Reasoned from the code, not observed, and no test covers it. Recorded in-source as uncovered |
| Photo metadata survives the round trip into the user's library | GPS and capture date are written and unit-tested at the boundary, but the last mile has not been checked in the real Photos app |
| `SharedStore` writes are atomic across processes | Asserted structurally, and the inode change is mutation-proven in-process. `flock()` has not been exercised from two processes at once |
| The payload version gate refuses a newer `schemaVersion` in a real App Group container | Proven against an injected container root; never run against a real one on a device |
| MapKit re-enters `draw` after every `setNeedsDisplay(_ mapRect:)` | The whole overzoom path rests on it; reasoned about rather than watched under Instruments. If it is ever false the symptom is a rect that stays permanently blurry with no log, no assertion and no test to notice |
| Durable-accounting invalidation fires rarely enough to stay off the render path | It hangs off `freshModificationDate`, which `diskImage` reaches on the render path. Bounded by the number of expired *durable* tiles by argument, not by measurement. If the argument is wrong the measurement cache quietly stops caching — slower, still correct, and invisible |
| A real OSM `429` is honoured | `Retry-After` is tested at the parse and at the hand-off into the renderer's backoff, but no live 429 has been seen. An HTTP-date-formatted `Retry-After`, or a 429 the renderer classifies as a hard failure before reading the advice, would be silently ignored |
| `@Attribute(.externalStorage)` makes mirroring carry a route as a `CKAsset` | Documented behaviour that compiles; no twenty-thousand-point route has been watched crossing a real container |

---

## Missed platform opportunities

Not defects. Ranked by fit.

1. **Live Activities / ActivityKit.** The big one. The app records GPS for hours
   and already has every input: `SharedRecordingSnapshot` is essentially a
   `ContentState`, the widget renders elapsed time with `style: .timer`, and
   `RecordingWidgetContent` could be reused nearly as-is. For a hike recorder in
   2026, a Dynamic Island and lock-screen presence during recording is close to
   table stakes, and the distance from here to there is short. The polyline
   generator such a feature would depend on is now tested, which it was not when
   this was first written.
2. **App Intents and Shortcuts.** `AppIntents` is already imported for widget
   configuration, but there are no standalone intents — "start a recording",
   "how far did I hike today", "show my last hike" are all natural and all
   absent, which also means no Siri and no Spotlight surface.
3. **Control Center control (`ControlWidget`).** Start and stop a recording
   without unlocking. For this app's actual use — phone in a pocket, gloves on,
   at a trailhead — this fits better than for most apps that ship it.
4. **Interactive widget buttons.** The widget is read-only; pause and resume
   from the home screen would compose with the above.
5. **Localization.** See Finding 1.

## On proportionality

Worth restating because it is the largest structural comment in this document,
and because the recommendation it carried has been acted on.

| Component | Lines |
|---|---|
| Shipping app | 39,518 |
| Shared package + widget | 3,180 |
| Tests, all four bundles | 43,300 |
| `General/Diagnostics/` | ~2,265 |
| `Scripts/` + `ci_scripts/` | ~1,670 |
| All documentation | ~1,655 |

The DEBUG-only half of the diagnostics — `PerformanceLog`, `MainThreadWatchdog`,
`RenderInstrumentation`, `ProcessResourceSample`, `PerformanceCounterProbe` —
compiles to nothing in release and is rigorously gated. For a MapKit-heavy app
whose central architectural claim is render isolation, a harness that can prove
the claim is not indulgent; it is the evidence.

`FieldMetrics/` remains about 1,200 lines that ship in release to consume a
MetricKit payload arriving at most once a day, read by opening Settings. It
answers a question nothing else can — the real energy cost of a multi-hour
recording on someone else's phone — but it only earns its keep if someone looks.

The narrow recommendation this section used to carry is now **closed**:
`Scripts/perf-report.py` has `--baseline`, `--write-baseline` and
`--fail-on-regression` with a 10% default tolerance, and detects growth, falls,
falls-to-zero, vanished counters and new counters;
`Scripts/run-performance-tests.sh` exposes `--baseline` and `--update-baseline`.
A regression is now detected rather than eyeballed. The second half of the
recommendation — schedule `PerformanceUITests` or accept in writing that it is a
manual tool — has been settled by **accepting it in writing**:
`.github/copilot-instructions.md` records that neither the functional UI
automation nor the performance suite runs in CI, and argues why (both drive a
booted simulator through real gestures and timing-sensitive waits, and the
performance suite needs stable hardware for its numbers to mean anything).

That leaves one honest residual: the apparatus is still hand-driven, and
sophistication nobody runs is indistinguishable from dead code. It is now
detectable rather than merely elegant, which was the point.

## Validation performed

| Validation | Result |
|---|---|
| Strict SwiftLint | **Clean, exit 0.** `Scripts/lint.sh`, 0.65.0, `--strict`, whole tree. Worth knowing: `.swiftlint.yml` names no `severity: error` explicitly, but several rules default to it, and the `SwiftLintBuildToolPlugin` runs as a *prebuild* command — so an error-severity violation exits 2 and kills the target at `[0/1] Planning build` before a file compiles. Lint is a build gate here, not advice |
| Shared package tests | **153 tests in 20 suites passed** (was 76 in 12) |
| App and widget unit tests | **1,303 tests in 154 suites (`OpenHikesTests`) + 23 in 3 suites (`OpenWidgetTests`), all passing**, on a dedicated simulator |
| UI automation | **All 44 `OpenHikesUITests` passing** in the same run — re-run this pass rather than taken on trust. `Scripts/run-ui-tests.sh`'s class list was verified against disk; no drift |
| Full test plan | **1,370 tests, 0 failures, 0 skipped, 0 expected failures** — `** TEST SUCCEEDED **` against the fully integrated tree |
| Code coverage | **58.56% (16,432/28,062) under CI's selection**, clearing the 55% floor by 3.56 points; **83.73% (23,496/28,062) with UI automation included**. `OpenHikesTests` 98.76%; `OpenWidgetTests` 42.75%; `OpenWidgetExtension` 13.80%. See Finding 2 |
| Privacy manifest | **Present and verified in a built bundle** — `OpenHikes/PrivacyInfo.xcprivacy` declares `CA92.1`, `C617.1` + `3B52.1` and `35F9.1`, with `NSPrivacyTracking = false` and no collected data types. Bundled at the app root through the file-system-synchronized group, confirmed by `plutil -p` against the product rather than the source. The widget extension deliberately carries none: audited, and neither it nor the shared package uses any required-reason API |
| Technical debt markers | **Zero** `TODO`, `FIXME`, `HACK` or `XXX:` in shipping code |
| Debug output | **Zero** `print()` in shipping code |
| Document citations | **Clean.** No source comment cites a finding number or quotes a figure from `PERFORMANCE.md` or `CODE_REVIEW.md`; four violations found and fixed this pass, one of which quoted a figure the document no longer contained |
| Unsafe constructs | 5 `try!`/`fatalError` sites in 42,886 lines, all previously argued; 28 `swiftlint:disable` in shipping code and 9 in tests, every one matched by an `enable` and narrowly scoped |
| Deprecated API sweep | Zero Combine, zero `ObservableObject`, zero `NavigationView`, zero `foregroundColor`/`cornerRadius`, zero `XCTest` in the unit bundles, zero version-availability guards (the 6 `@available` hits are 3 comments and 3 `@available(*, unavailable)` `NSCoder` init-blockers) |
| Test barriers | **No fixed sleep or yield count was added as a barrier this pass** — verified by diff, zero `Task.sleep`/`Task.yield` lines added to any modified tracked test file. Every pre-existing hit is a stub delay, a cancellation observation, or the settle helper's own poll interval |
| Dependencies | 4 declared (`swift-collections`, `swift-algorithms`, `swift-async-algorithms`, SwiftLintPlugins), all Apple-owned or build-tool-only, all pinned to exact revisions. `swift-numerics` is transitive and unimported. CI fails on `Package.resolved` drift |
| Info.plist audit | Complete and correct. All six usage strings present and well-worded; `UIBackgroundModes` = `location` + `remote-notification`; `ITSAppUsesNonExemptEncryption` declared; GPX UTI imported rather than exported. The photo-add string no longer promises an "OpenHikes" album the app never creates |
| Build settings audit | `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION MainActor`, `SWIFT_TREAT_WARNINGS_AS_ERRORS YES`, `IPHONEOS_DEPLOYMENT_TARGET 26.5`, `TARGETED_DEVICE_FAMILY 1` identical across all five targets and both configurations. `VALIDATE_PRODUCT` now set on the app's Release config as well as the widget's; `SUPPORTED_PLATFORMS` now declared on both widget configurations |
| iOS build | **Debug simulator build passes** with Swift warnings as errors, app and embedded widget, against the fully integrated tree |
| CI | 6 macOS jobs plus CodeQL and dependency review. Coverage gated at a 55% floor; ThreadSanitizer raised from 2 suites to 34; Release archived rather than only compiled; shared package additionally tested in Release; every action pinned to a SHA; a `verify-xcode` composite action guards all seven macOS jobs |
| Repository settings | Description set. Private vulnerability reporting, Dependabot alerts and automated security fixes all enabled. Secret scanning and push protection were already on |
| Repository hygiene | 355 tracked files, plus 72 new ones this pass not yet committed. `DerivedData/`, `PerformanceReports/`, `Secrets.plist`, `TestResults/`, `xcuserdata/`, `buildServer.json` and `.DS_Store` correctly untracked and gitignored; `.swiftlint.yml` now also excludes `**/.*` so a dot-directory worktree cannot be linted into the result |
| Governance | `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `CODEOWNERS`, issue templates and a PR template all present; README links the first two |
| Dead code | **Could not be run in this environment.** `periphery scan` shells out to `xcodebuild -list -json` before it does anything else, and that call resolves package dependencies with no way to pass `-disableAutomaticPackageResolution`, so it fails offline with `Couldn't get the list of tags`. It is not a project defect and will run normally on a networked machine; `.periphery.yml` was deliberately left alone rather than given offline flags, which would change behaviour for everyone to work around one sandbox. A static check confirmed every new type is referenced from shipping code — weaker than the previous "no unused code detected" |
| Physical-device energy trace | Not run — see `PERFORMANCE.md` § "Validating on a device" |

One structural note that is **not** a gap: only a handful of tests use
`#expect(throws:)`, but the app models failure as returned enums and optionals
(`.tooShort`, `.failed`, `nil`) rather than thrown errors, and a large fraction
of the suite exercises refusal, empty, cancel and denied paths through returned
state. Error-path coverage is broad; it simply is not expressed through throws.

## Open product design decisions

Product choices rather than correctness findings.

1. **Pause semantics.** Pausing stops accumulation but the persisted route stays
   a single segment.
2. **Shipped trail graphs.** Cached Overpass regions do not provide offline
   matching in places the user has never visited.
3. **Widget takeover.** A live recording replaces the selected hike rather than
   appearing as a badge or secondary state.
4. **Two foreground location managers.** `LocationManager` and
   `SystemRecordingLocationSource` each own a `CLLocationManager`, and both
   receive updates during a recording. Verified rather than assumed: the
   foreground manager never stops once started, and the recording source asks
   for `kCLLocationAccuracyBest` with a 10 m filter against the foreground
   manager's baseline. iOS coalesces same-process location demand to the most
   demanding request, so this does not imply twice the GPS hardware power; what
   it duplicates is delegate dispatch and authorization handling, and both now
   deliver through `onMainActor` so it no longer costs a `Task` per fix. The
   separation is deliberate: the recording source owns background semantics
   (`allowsBackgroundLocationUpdates`, a `CLBackgroundActivitySession`, no
   automatic pausing) that must not leak into ordinary map browsing. Revisit
   only if a device energy trace shows meaningful CPU overhead, and preserve
   those background semantics if the two are ever consolidated.
