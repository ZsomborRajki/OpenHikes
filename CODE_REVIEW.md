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

Bugs

1. Use-after-delete race in  HikePhotoImport.add  ( HikePhotoImport.swift:38-46 )
 hike.addPhoto(photo)  runs after an  await , with no check that the hike still exists.  attachPickedPhotos  loads up to 10 transferables serially — seconds during which the user can pop back and swipe-delete the hike. Touching an invalidated  PersistentModel  traps, and  discardFiles  has already run so the new file leaks. Guard  !hike.isDeleted  after each await and erase the orphan.

2. Camera pill can be stuck hidden ( MapView.swift:106  vs  :190 )
 observePhotoControls  runs before  addPhotoControls  creates the view, so  applyPhotoControlsVisibility  early-returns on  guard let photoControls . If  isAvailable  is already true when the map is built, the pill stays  isHidden  until the next availability change. The tests miss this because they call  observePhotoControls  a second time, after the view exists. Apply visibility at the end of  addPhotoControls .

3.  observePhotoControls  isn't idempotent — no  isObserving…  guard like  observeLocation  has, and  observeMapController  explicitly documents this hazard. The tests currently register two observers → duplicate overlapping fade animations.

4. Viewer title likely invisible in light mode ( HikePhotoViewer.swift:56-67 )
 Color.black.ignoresSafeArea()  +  .toolbarBackground(.hidden, for: .navigationBar)  with no  .toolbarColorScheme(.dark, …) . The title renders in  .label  (black-on-black); toolbar glyphs are tinted so they survive. Worth a visual check.

5.  MapSheet  detent doesn't do what its comment says ( MapSheet.swift:150 ) — popping the viewer always forces  .medium , so a detail screen read at  .large  is silently collapsed.

Incompleteness

• Every failure is silent.  add  returns  nil  for non-image bytes / write failure and both call sites discard it. No success feedback either — and  RecordingView  has no gallery, so a photo taken mid-walk gives zero confirmation.
• No tests for  HikePhotoImport  — the one file that owns the "app copy first, delete files before the model" ordering its header argues for.
• No orphan-file reconciliation or storage cap. The delete is a fire-and-forget  Task(.utility) ; if it doesn't finish before termination, files under  HikePhotos/  leak with nothing to reclaim them (contrast  TileOwnership ).  byteCount(of:)  is used only by tests, so photos are invisible to both storage UIs.
• No UI/accessibility coverage for  photos-section ,  photo-viewer ,  map-camera-button , and no launch-argument hook to seed photos — the feature is unreachable in the simulator (no camera, out-of-process picker).
• README not updated:  Photos/  missing from the project-layout table and the Features list;  .github/copilot-instructions.md 's domain list too.

Doc/code mismatches

•  ImageDataFormat.jpeg.pathExtension == "jpg" , but captures route through  detect()  →  UTType.jpeg.preferredFilenameExtension == "jpeg"  (verified). So captures are stored  .jpeg , contradicting both that constant's doc and  HikePhoto.pathExtension 's. Harmless, but the constant is effectively unused.
•  HikePhoto.capturedAt  claims it falls back to the picked asset's date — the import path always uses  .now , which also drives gallery ordering.
•  HikePhotoLoader 's "cancels the decode" claim: the store calls are synchronous and check no cancellation; only the result is dropped.

• High — Photo picker cannot open ( OpenHikesView.swift:197 ,  PhotoCapturePresentation.swift:64 ): the root already presents the permanent  MapSheet ; the second modal queues forever.
• High — Camera photos can be silently lost ( OpenHikesView+Photos.swift:38 ,  HikePhotoImport.swift:54 ): encoding/write failures return  nil  without an error, retry, or retained image.
• High — Metadata and image files can diverge ( HikePhotoImport.swift:39 ,  MapSheet.swift:302 ): fire-and-forget file deletion occurs independently of SwiftData persistence, producing missing images or orphaned files after failures/termination.
• Medium — Recording photos never receive route coordinates ( RecordingView.swift:68 ): anchoring reads  currentHike.route , which remains empty until recording stops.
• Medium — Named album handling conflicts with add-only authorization ( PhotoLibraryWriter.swift:44 ): add-only access cannot reliably find an existing “OpenHikes” album, risking duplicates or fallback to Recents.
• Medium — Camera metadata reflects acceptance time ( CameraPicker.swift:97 ): timestamp and trail position are resolved after the camera review screen, not when the shutter fires.
• Medium — Viewer toolbar may be unreadable in light mode ( HikePhotoViewer.swift:55 ): dark content is shown beneath a transparent navigation bar without forcing contrasting toolbar/status-bar styling.
