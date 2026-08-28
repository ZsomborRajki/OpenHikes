# OpenHikes code review

The open code-quality list: correctness, concurrency, current API use, release
readiness, and battery, radio, CPU and disk activity during a hike.

**This document is a live list, not a log.** A finding is only useful while it
is true, so a fixed one is deleted rather than annotated, and a claim that
stopped matching the code is deleted whether or not anything was done about it.

It carries no score, no census and no run report. A rating and a table of counts
have to be re-measured to stay true, go stale silently when they are not, and
nobody can act on either — git is the log, CI is the gate, and what belongs here
is the work that is still open.

Decisions that have been investigated and settled — types that should not become
actors, older API that is justified rather than legacy, deliberate test seams,
and claims that turned out to be false — live in
`.github/copilot-instructions.md` under "Settled decisions", so they are loaded
as context rather than re-raised as findings.

**1 open**: 0 High, 1 Medium, 0 Low.

---

## Medium

### 1. The app is English-only, and this is a deliberate deferral

There is no string catalog anywhere. The app is *structurally* localizable —
SwiftUI `Text` literals are already `LocalizedStringKey`, and 28 sites correctly
use `String(localized:)` where a `String` is needed — so this remains extraction
work rather than a rewrite.

This was raised, put to the maintainer, and deliberately deferred. It is recorded
because the condition is still true and still has consequences: the longer it
waits the larger it gets, and unit formatting has already drifted once in the
meantime. Locale-aware temperature and locale-aware speed were both symptoms of
this root and were both fixed at the formatting layer, which is the correct order
but not a substitute.

`README.md` records the limitation for users under "Current limitations".
**Fix, when it is wanted:** add a String Catalog to the app and widget targets
and let Xcode extract.

---

## Claims that are reasoned rather than observed

Not defects, and not speculation either — each is a specific assertion the code
makes that no test in the tree can currently settle. They are recorded so that a
future failure in one of these areas starts with the list of things nobody
actually watched happen.

| Claim | Why it is unobserved |
|---|---|
| The limited-photo-library presenter shows the system picker and merges the widened selection | The presenter *resolution* is observed and covered — and covering it corrected a reasoned-but-wrong window check. What remains is the last mile: `presentLimitedLibraryPicker` putting real system UI on screen and the widened selection coming back. One manual run with limited access granted would settle it |
| The two framework pins in `RenderIsolationTests+Observation.swift` would go red if the runtime changed | They are correct on the current toolchain and are the tripwire for `@Observable` dropping its `Equatable` filtering or SwiftData starting to coalesce. A runtime change cannot be induced, so unlike every other assertion in that family they are unproven in the red direction |
| Photo metadata survives the round trip into the user's library | GPS and capture date are written and unit-tested at the boundary, but the last mile has not been checked in the real Photos app. `GPSTimeStamp` in particular is written as a string where the EXIF spec defines three rationals; ImageIO is expected to reconcile it, and nothing here has confirmed that it does |
| `SharedStore` writes are atomic across processes | Asserted structurally, and the inode change is mutation-proven in-process. `flock()` has not been exercised from two processes at once |
| The payload version gate refuses a newer `schemaVersion` in a real App Group container | Proven against an injected container root; never run against a real one on a device |
| ActivityKit delivers the panel at all | Everything above the `HikeActivityPresenting` seam is tested, and nothing below it can be: a hosted unit test reports activities disabled and `Activity.request` throws. No Lock Screen or Dynamic Island rendering has been observed on a device |
| An orphaned panel from a previous launch is really found and ended | The takedown is fully covered above the seam, but `SystemHikeActivityPresenter` reaches it through `Activity<HikeActivityAttributes>.activities`, which is empty in a hosted test. That the framework lists a *previous process's* activity — and that ending it removes the panel — has not been watched on a device |
| Two panels of the same kind can be on screen at once | It is why `endUnowned` sweeps rather than ends one activity, and it cannot be pinned at the seam: `StubHikeActivityPresenter` models a single subject while the real implementation reads plural `Activity.activities`. The argument lives in the source comment and no test asserts it |
| MapKit re-enters `draw` after every `setNeedsDisplay(_ mapRect:)` | The whole overzoom path rests on it; reasoned about rather than watched under Instruments. If it is ever false the symptom is a rect that stays permanently blurry with no log, no assertion and no test to notice |
| Durable-accounting invalidation fires rarely enough to stay off the render path | It hangs off `freshModificationDate`, which `diskImage` reaches on the render path. Bounded by the number of expired *durable* tiles by argument, not by measurement. If the argument is wrong the measurement cache quietly stops caching — slower, still correct, and invisible |
| A real OSM `429` is honoured | `Retry-After` is tested at the parse and at the hand-off into the renderer's backoff, but no live 429 has been seen. An HTTP-date-formatted `Retry-After`, or a 429 the renderer classifies as a hard failure before reading the advice, would be silently ignored |
| `@Attribute(.externalStorage)` makes mirroring carry a route as a `CKAsset` | Documented behaviour that compiles; no twenty-thousand-point route has been watched crossing a real container |

## Missed platform opportunities

Not defects. Ranked by fit.

1. **App Intents and Shortcuts.** `AppIntents` is already imported for widget
   configuration, but there are no standalone intents — "start a recording",
   "how far did I hike today", "show my last hike" are all natural and all
   absent, which also means no Siri and no Spotlight surface.
2. **Control Center control (`ControlWidget`).** Start and stop a recording
   without unlocking. For this app's actual use — phone in a pocket, gloves on,
   at a trailhead — this fits better than for most apps that ship it.
3. **Localization.** See the finding above.

## Open product design decisions

Product choices rather than correctness findings.

1. **Pause semantics.** Pausing stops accumulation but the persisted route stays
   a single segment.
2. **Shipped trail graphs.** Cached Overpass regions do not provide offline
   matching in places the user has never visited.
3. **Widget takeover.** A live recording replaces the selected hike rather than
   appearing as a badge or secondary state.
4. **Precise GPS travels with an exported photo.** When `savesToPhotoLibrary` is
   on, the trail coordinate is written into both the asset and the file's GPS
   block, so a photo shared onward carries the walker's exact position. This is
   deliberate and documented, and iOS 17+ offers system-level scrubbing in the
   share sheet — but the app offers no way to reduce the precision itself.
5. **An unbounded hike title.** `HikeDetailView.commitTitleEdit` trims
   whitespace and stores whatever is left, and an imported GPX `<name>` is
   unbounded too. Nothing in the app is harmed by a long one, but the title is
   the only user-controlled field in the Live Activity payload, which shares a
   4 KB budget with everything else on the panel. `HikeActivityTests` holds the
   worst case to a quarter of that budget, so a title alone cannot break it —
   what is undecided is whether a title should be bounded at the point of entry
   rather than absorbed downstream.
6. **Two foreground location managers.** `LocationManager` and
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
