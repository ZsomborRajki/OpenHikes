# OpenHikes code review

The current tree contains 165 Swift files and 39,533 lines, plus project and
package configuration, scripts, entitlements, tests, and documentation. The
review focuses on correctness, concurrency, maintainability, current API use,
and especially battery, radio, CPU, and disk activity during a hike.


## Test and project hygiene

The following open gaps remain:

| Gap | Impact |
|---|---|
| `SearchCompleter`, `WeatherManager`, `DirectionalPolylineRenderer`, `TrailBasemapRenderer`, `TopEdgeReader`, and `MainThreadWatchdog` lack direct suites | Timing, rendering, and stall behavior can regress |
| Widget deep-link branches lack UI automation | Live recording, existing hike, and deleted hike routing are unguarded |
| Deleting a currently pushed hike lacks UI automation | Navigation cleanup is unguarded |
| No `.xcstrings` catalog exists | Localization will require a broad later migration |

Strict SwiftLint passes, and every first-party Xcode target treats Swift
warnings as errors. The remaining warning debt is limited to duplicate
`@executable_path` runpath warnings emitted when Xcode links Thread Sanitizer
runtimes; normal debug and release builds are warning-free.

## API and dependency assessment

- For battery telemetry, prefer native Instruments, signposts, and current
  MetricKit reporting rather than an analytics SDK that adds its own network
  and background cost.

## Battery validation plan

Static review can identify unnecessary work but cannot certify battery life.
Run these scenarios on a physical device with a fixed route to validate the
P1/P2 energy remediations:

1. Foreground map browsing and live follow without recording.
2. Screen-locked background recording with normal connectivity.
3. Screen-locked recording with no service or a failing Overpass endpoint.
4. A 20-minute stationary pause.
5. Auto-save and a maximum-budget offline download.

Capture Energy Log/Power Profiler, Location activity, Network, CPU wakeups,
thermal state, and disk writes. Live matching, GPX parsing, location publication
and recording-trace rebuilds now carry signposts, and `PerformanceLog` will
write them to a TSV alongside CPU and footprint samples under
`--ui-test-performance-log=`; graph prefetch, tile planning, and storage
measurement still need theirs. Compare against the same device, route, screen
state, and radio conditions rather than using a universal percentage-per-hour
target.

## Validation performed

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed |
| Shared package tests | 51 tests in 8 suites passed with warnings treated as errors |
| App and widget unit tests | 633 tests in 70 suites plus 19 widget tests in 3 suites passed with strict suite preconditions enabled |
| iOS debug build | Passed with first-party Swift warnings treated as errors |
| iOS release build | Passed with first-party Swift warnings treated as errors |
| macOS compile | Passed with code signing disabled |
| GPX Thread Sanitizer suite | Passed, including concurrent timestamp parsing |
| UI automation and launch metrics | All 6 tests passed, including record-review-save |
| Render and resource performance suite | All 5 `PerformanceUITests` passed; baseline and findings in `PERFORMANCE.md` |
| Package resolution | Passed; CoreGPX is absent from `Package.resolved` |
| CI workflow | Added; equivalent local commands passed, hosted run awaits the next push. UI automation and the performance suite are excluded from CI and run locally through their scripts |
| visionOS build | Not run; the visionOS 26.5 platform is not installed |
| Physical-device energy trace | Not run |

## Open product design decisions

These remain product choices rather than correctness findings:

1. **Pause semantics:** pausing stops accumulation but the persisted route stays
   a single segment.
2. **Shipped trail graphs:** cached Overpass regions do not provide offline
   matching in places the user has never visited.
3. **Widget takeover:** a live recording currently replaces the selected hike
   rather than appearing as a badge or secondary state.
4. **Two foreground location managers** (originally finding 20): `LocationManager`
   and `SystemRecordingLocationSource` each own a `CLLocationManager`, and both
   receive updates during an active recording. This was verified rather than
   assumed — the foreground manager never stops once started, and the recording
   source asks for `kCLLocationAccuracyBest` with a 10 m filter against the
   foreground manager's ten-meter/25 m baseline. iOS coalesces same-process
   location demand to the most demanding request, so this does not imply twice
   the GPS hardware power; what it duplicates is delegate dispatch,
   authorization handling, and actor hops. The separation is kept deliberately:
   the recording source owns background semantics (`allowsBackgroundLocationUpdates`,
   a `CLBackgroundActivitySession`, and no automatic pausing) that must not
   leak into ordinary map browsing. Revisit only if a device energy trace shows
   meaningful CPU overhead, and preserve those background semantics if the two
   are ever consolidated.
