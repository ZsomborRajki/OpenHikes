# Social OpenHikes — client-side implementation plan

Turning OpenHikes from a local-first trail viewer into an app where a walker can
publish a recorded or imported hike and browse what other people have published,
in the shape Komoot and AllTrails established: a personal library, a public
profile, a discovery feed, and a "save this to my hikes" action.

This document covers **the client only**. It names the server contract it
assumes but does not design the backend.

---

## 1. The premise, and the one rule everything else bends around

OpenHikes today has no backend, no account, and no network dependency for
anything a hiker does on a trail. That is not an accident of scope — it is the
product. A hiker in a valley with one bar has the map, the route, the recording,
the photos and the widget, and the app has an entire subsystem
([`TileNetworkPolicy`](OpenHikes/Tiles/TileNetworkPolicy.swift)) whose only job
is to *refuse* to use the radio.

So the rule for this whole feature is:

> **Social is a strictly additive, always-optional layer. Every existing screen,
> every recording, every import, every offline capability must behave
> identically for a user who never signs in, is signed out, is offline, or whose
> backend is down.**

Concretely, that means all of the following are invariants, not goals:

| Invariant | How it is enforced |
|---|---|
| No social code runs on the recording path | `HikeRecorder` gains no dependency on any social type. The sync engine reads recordings; recordings never call the sync engine. |
| No social network request competes with a hike | `SocialNetworkPolicy` denies every non-user-initiated request while `HikeRecorder.phase` is active — before it even considers connectivity. |
| No social state is required to open a hike | `Hike` stays the source of truth. Publication state lives in a sibling model; a missing row means "not published", never "cannot display". |
| Signed out is a first-class state | Every social entry point either hides or degrades to a sign-in prompt. Nothing throws, nothing spins, nothing blocks. |
| Offline is a first-class state | The feed renders from cache with a staleness marker. Publishing queues to a durable outbox and drains later. |
| Social never spends the tile budget | Feed items carry server-rendered static previews. `TileProvider.supportsBulkDownload` still gates every bulk download, and browsing the feed triggers none. |

If a design choice makes one of those harder to guarantee, the design choice is
wrong.

---

## 2. Product surface

Five capabilities, in the order they should ship:

1. **Account** — Sign in with Apple, which today is a disabled placeholder in
   [`SettingsView.swift:104`](OpenHikes/Settings/SettingsView.swift). Optional,
   revocable, and deletable.
2. **Publish** — from a hike's detail view: choose visibility, choose a privacy
   radius, choose which photos come along, publish. Queues offline.
3. **Profile** — the signed-in user's published trails, plus another user's.
4. **Discover** — a feed and a map-bounded search over published trails.
5. **Save** — turn someone else's published trail into a local `Hike`, at which
   point it is an ordinary hike: it can be styled, downloaded offline,
   auto-followed, exported to GPX and recorded against.

Deliberately **out of scope for v1**: comments, direct messages, groups, live
tracking of friends, real-time anything. Each of those adds a push channel and a
moderation surface, and none of them is needed for the loop above to work.

---

## 3. Architecture

### 3.1 A new product domain

The app is organised by product domain, following Apple's Food Truck and
Backyard Birds samples, and the target folders are Xcode file-system-synchronized
groups — a new Swift file under `OpenHikes/` is compiled by the app target
automatically. So social gets its own domain folder rather than being sprinkled
through `Hikes/` and `Settings/`:

```
OpenHikes/Social/
├── Account/
│   ├── SocialAccount.swift            // signed-in identity, @Observable
│   ├── AppleSignInController.swift    // ASAuthorizationController bridge
│   ├── CredentialStore.swift          // Keychain, the only secret store
│   └── AccountLifecycle.swift         // sign-out, revocation, delete-account
├── Model/
│   ├── TrailPublication.swift         // @Model: local hike ⇄ remote trail
│   ├── CachedRemoteTrail.swift        // @Model: a downloaded community trail
│   └── SocialIdentifiers.swift        // TrailID, UserID — typed, not raw UUID
├── Transport/
│   ├── SocialTransport.swift          // protocol + URLSession implementation
│   ├── SocialEndpoint.swift           // request construction, no business logic
│   ├── SocialNetworkPolicy.swift      // mirrors TileNetworkPolicy
│   └── SocialTransportError.swift
├── Publish/
│   ├── PublicationOutbox.swift        // durable queue, mirrors TrackJournal
│   ├── PublicationSyncEngine.swift    // drains the outbox
│   ├── PublicationPayload.swift       // Hike → wire, off-main
│   ├── RoutePrivacyMask.swift         // start/end trimming, timestamp policy
│   └── MediaUploader.swift            // EXIF-stripped photo upload
├── Discover/
│   ├── CommunityFeed.swift            // @Observable paging state
│   ├── CommunityFeedView.swift
│   ├── CommunityTrailView.swift
│   ├── RemoteMediaStore.swift         // cached previews + photos on disk
│   └── RemoteTrailImport.swift        // remote trail → local Hike
└── UI/
    ├── PublishSheet.swift
    ├── ProfileView.swift
    ├── SocialAccountSection.swift     // replaces the Settings placeholder
    └── SocialRow.swift                // one accessibility element per row
```

Tests mirror it at `OpenHikesTests/Social/…`, and wire types get
`OpenHikesShared/Sources/OpenHikesShared/Social/` with
`OpenHikesShared/Tests/OpenHikesSharedTests/Social/`.

### 3.2 Composition

[`OpenHikesModel`](OpenHikes/App/OpenHikesModel.swift) is the composition root
and already owns every long-lived dependency behind an injectable initialiser.
Social adds exactly three, constructed the same way:

```swift
let socialAccount: SocialAccount
let publicationSyncEngine: PublicationSyncEngine
let communityFeed: CommunityFeed
```

All three take their transport, clock, defaults and storage directory as
initialiser parameters, exactly as `BackgroundTrailTracker`, `LocationManager`
and `OfflineTileDownloader` already do, so no test depends on wall-clock time, a
real connection, or the host app's settings.

`sceneDidBecomeActive()` gains one line — `publicationSyncEngine.sceneDidBecomeActive()`
— which *schedules* a drain rather than performing one, and returns immediately.

### 3.3 The shape of the whole thing

```
                    ┌──────────────────────────────────────┐
   Hike detail ───▶ │ PublishSheet                         │
                    │  RoutePrivacyMask → PublicationPayload│
                    └───────────────┬──────────────────────┘
                                    │ enqueue (synchronous, local, always succeeds)
                                    ▼
                    ┌──────────────────────────────────────┐
                    │ PublicationOutbox (Application Support)│  ← durable, survives kill
                    └───────────────┬──────────────────────┘
                                    │ drained by
                                    ▼
   HikeRecorder.phase ──gate──▶ ┌───────────────────────────┐
   PowerState.current ──gate──▶ │ PublicationSyncEngine     │
   NWPathMonitor ─────gate──▶   │   SerialAsyncQueue        │
                                └───────────┬───────────────┘
                                            │ SocialTransport
                                            ▼
                                        (backend)
                                            │
                    ┌───────────────────────┴──────────────┐
                    ▼                                      ▼
        CachedRemoteTrail (SwiftData)          RemoteMediaStore (disk)
                    │                                      │
                    └──────────────┬───────────────────────┘
                                   ▼
                          CommunityFeed / CommunityTrailView
                                   │ "Save to my hikes"
                                   ▼
                          RemoteTrailImport → Hike  (ordinary from here on)
```

---

## 4. Identity

### 4.1 Sign in with Apple, for real

[`SettingsView.swift:103–124`](OpenHikes/Settings/SettingsView.swift) already
draws the row, faded, un-tappable, with a "Coming soon" accessibility value. It
becomes `SocialAccountSection`, which renders one of three states: signed out
(the button), signing in (progress), signed in (handle, avatar, sign-out,
delete-account).

Requirements:

- `ASAuthorizationAppleIDProvider` + `SignInWithAppleButton`. Adds the **Sign in
  with Apple** capability to `OpenHikes.entitlements` alongside the existing
  `com.apple.developer.weatherkit` and App Group entries.
- The identity token goes straight to the backend; the client stores only the
  resulting session token and the opaque `user` identifier.
- **Credentials live in the Keychain, never in `UserDefaults`.** The app's
  defaults are shared, launch-argument-swappable under UI testing, and readable
  by anything with the container — none of which is acceptable for a bearer
  token. `SettingsKey` keeps no social secrets; it gets at most a `Bool` for
  "has an account" so a body can branch without touching the Keychain.
- `ASAuthorizationAppleIDProvider.getCredentialState(forUserID:)` at launch,
  behind the existing `AppLaunchEnvironment.isRunningTests` guard, so a revoked
  Apple ID signs the user out locally instead of failing every request.
- Sign-out clears the Keychain, the outbox, `CachedRemoteTrail`, and
  `RemoteMediaStore` — but **never a `Hike`**. A trail saved from the community
  belongs to the user after they save it.

### 4.2 Anonymous is the default

The app launches signed out and stays fully functional. `SocialAccount.state`
is `.signedOut` and every social surface reads that one property.

---

## 5. Persistence

### 5.1 The schema-change problem, stated plainly

The repository's own rule: *the SwiftData store is not migrated across schema
changes; a store written by an older shape of `Hike` is not a supported input,
and a user whose store no longer opens reinstalls the app* — losing their saved
hikes and their durable tiles with it.

Social needs new persisted state. That is a schema change. The mitigations, in
priority order:

1. **Ship the entire social schema in one release.** Design the models for
   everything in section 2 up front — including the fields v1 does not read —
   so the store shape changes once rather than five times.
2. **Do not touch `Hike`.** Not one new column. Publication state goes in a
   sibling model keyed by `hikeID`. This is the same argument
   [`HikePhoto`](OpenHikes/Photos/HikePhoto.swift) already makes about pixels: a
   SwiftData column is loaded whole whenever the row is touched, and the hikes
   list touches every row. Like/save counts churn constantly and have nothing to
   do with a route.
3. **Add a pre-flight escape hatch first.** Ship a "Export all hikes" action
   (a batch of the existing [`GPXExport`](OpenHikes/Hikes/GPXExport.swift)) in
   the release *before* the schema change, so a user whose store fails to open
   has already been offered a way out.
4. **Lean on the existing fallback.** `OpenHikesModel.loadContainer(persistent:fallback:)`
   already degrades to an in-memory store and surfaces a `StorageStartupIssue`
   rather than crashing. Confirm that the resulting banner tells the user
   plainly what has happened and what to do.

### 5.2 New models

```swift
@Model
final class TrailPublication {
    /// The local hike this publishes. Not a SwiftData relationship: deleting a
    /// hike must not cascade into the publication record, because the trail is
    /// still live on the server until an unpublish is confirmed.
    var hikeID: UUID
    /// The server's identifier, nil until the first successful publish.
    var remoteID: String?
    var visibilityRaw: String        // "private" | "followers" | "public"
    var stateRaw: String             // "draft" | "queued" | "syncing" | "published" | "failed"
    var privacyStartMeters: Double
    var privacyEndMeters: Double
    var includesTimestamps: Bool
    var publishedPhotoIDs: [UUID]
    var lastSyncedAt: Date?
    var lastErrorDescription: String?
    var updatedAt: Date
}

@Model
final class CachedRemoteTrail {
    var remoteID: String
    var authorID: String
    var authorDisplayName: String
    var title: String
    var summary: String?
    var distanceMeters: Double
    var ascentMeters: Double
    var descentMeters: Double
    /// Decimated for the list; the full polyline is fetched on open.
    var previewPolyline: [RouteCoordinate]
    var fullPolyline: [RouteCoordinate]?
    var surfaceMetersByCategory: [String: Double]
    var difficultyMetersByGrade: [String: Double]
    var previewImageFileName: String?
    var attributionText: String?
    var fetchedAt: Date
    var expiresAt: Date
}
```

Enum-backed columns are stored as their **stable raw string**, matching what
`Hike.routeLinePatternID` already does and for the same reason: an unrecognised
value degrades to a default instead of failing to decode.

### 5.3 Files on disk need an owner and a sweep

`RemoteMediaStore` writes preview images and downloaded community photos into
Application Support. The repository rule applies without modification: *files
written outside SwiftData need an owner and a sweep*, because deletion is
fire-and-forget and termination can leave orphans. So `RemoteMediaStore` gets

```swift
func reclaimOrphans(claimedBy claimed: Set<String>)
```

driven at launch from a **complete** claim set, exactly like
`TileCache.trimCache(claimedBy:)` and `HikePhotoStore.reclaimOrphans(claimedBy:)`
— and, critically, **a fetch that fails sweeps nothing rather than sweeping with
an empty set.** Add the call next to the existing pair in
`OpenHikesModel.reclaimOrphanedPhotos(in:store:)`.

Unlike `HikePhotoStore`, this directory **is** excluded from backup: every byte
in it is re-fetchable, which is the same argument `TileCache`'s durable tier
already makes.

`CachedRemoteTrail` also needs a size cap and an eviction pass — it is the one
piece of social state that grows without the user asking for anything. Evict by
`expiresAt`, then least-recently-opened, to a byte budget shown in the existing
storage UI.

---

## 6. Wire contracts belong in the shared package

`OpenHikesShared` is the local Swift package consumed by the app and the widget,
and the convention is that cross-target payloads live there rather than being
duplicated. Social payloads go in
`OpenHikesShared/Sources/OpenHikesShared/Social/`:

- `PublishedTrailDTO`, `TrailAuthorDTO`, `FeedPageDTO`, `PublishRequestDTO` —
  `Codable`, `Sendable`, `Equatable`, with explicit `CodingKeys` so a field
  rename in Swift is not a wire break.
- `SocialDeepLink` — a sibling of
  [`TrailWidgetDeepLink`](OpenHikesShared/Sources/OpenHikesShared/Widget/TrailWidgetDeepLink.swift),
  built the same way: both the formatter and the parser in one file, so a link
  the app cannot recognise cannot be produced.

Two hard constraints on this:

- **`TrailWidgetDeepLink`'s existing format does not change.** Deep-link format
  is a persisted, cross-target contract. `SocialDeepLink` adds new hosts
  (`openhikes://trail/<remoteID>`, `openhikes://user/<userID>`) to the same
  scheme and leaves `hike` and `recording` byte-identical.
- **The `openhikes` scheme must now actually be registered.** A widget tap does
  not need it — the system routes `widgetURL` to the owning app — but a link
  pasted into Messages does. Add `CFBundleURLTypes` to
  [`OpenHikes/Info.plist`](OpenHikes/Info.plist), and add an
  `com.apple.developer.associated-domains` entry plus an `https://` universal
  link if shared trails should open from the web without a scheme prompt.

Wire types are the only social code the shared package gets. The widget does not
gain a social feed: it reads the App Group store and does not recompute anything,
and that stays true.

---

## 7. Networking

### 7.1 Transport is a protocol, not a singleton

```swift
nonisolated protocol SocialTransport: Sendable {
    func send<Response: Decodable & Sendable>(
        _ endpoint: SocialEndpoint,
        expecting: Response.Type
    ) async throws(SocialTransportError) -> Response

    func upload(
        _ data: Data,
        to endpoint: SocialEndpoint,
        progress: @Sendable (Double) -> Void
    ) async throws(SocialTransportError) -> URL
}
```

This mirrors [`TrailGraphProviding`](OpenHikes/Recording/OverpassTrailGraphProvider.swift)
— a `nonisolated` `Sendable` protocol with one production implementation and
stubs in tests. It is what makes every social suite runnable with no network,
the same way `StubTileProtocol` and `TrailGraphProviderStubs` already do for
tiles and graphs.

The production implementation owns its own `URLSession` with an **ephemeral**
configuration, exactly as `TileCache` does — the app does not want a second
`URLCache` on disk competing with the tile tiers for the storage budget it
measures.

### 7.2 Policy: a hike beats a feed, always

`SocialNetworkPolicy` is deliberately modelled on
[`TileNetworkPolicy`](OpenHikes/Tiles/TileNetworkPolicy.swift), including its
returning-a-reason design, because a request that silently never fires is the
hardest thing in this app to debug and this policy exists to create exactly that
situation on purpose.

```swift
nonisolated enum SocialRequestPurpose: String, Sendable {
    /// The user tapped something and is looking at a spinner.
    case userInitiated
    /// Outbox drain, feed prefetch, profile refresh. First to be given up.
    case background
}

nonisolated enum SocialNetworkPolicy {
    static func decide(
        _ purpose: SocialRequestPurpose,
        conditions: TileNetworkConditions,
        isRecording: Bool,
        allowsCellular: Bool,
        power: PowerState = .current
    ) -> TileNetworkDecision
}
```

Decision order, and why:

1. `isRecording && purpose == .background` → `.denied("recording")`. **First,
   before connectivity is even consulted.** A live recording owns the radio, the
   CPU and the battery budget; nothing about a feed is worth a fix.
2. `!conditions.isOnline` → `.denied("offline")`.
3. `conditions.isConstrained` → `.denied("low-data-mode")`. Low Data Mode is an
   explicit instruction and there is no in-app setting that overrides it, exactly
   as with tiles.
4. `conditions.isExpensive && !allowsCellular` → `.denied("cellular")`.
5. Beyond here, `.userInitiated` is allowed.
6. `power.isLowPowerModeEnabled` → `.denied("low-power-mode")`.
7. `RecordingEnergyPolicy.conserves(power.thermalState)` → `.denied("thermal")`.
8. `conditions.isExpensive` → `.denied("cellular-speculative")`.

Reuses `TileNetworkConditions`, `TileNetworkDecision`, `PowerState` and
`RecordingEnergyPolicy` rather than re-deriving them — one source of truth for
"is the radio worth it" across the whole app.

Two new settings keys, remembering that **the string values are a storage
contract**:

```swift
static let socialCellularSync   = "settings.socialCellularSync"    // default false
static let socialAutoRefresh    = "settings.socialAutoRefresh"     // default false
```

Both default off. Tiles default cellular *on* because a blank map is a bug
report; a stale feed is not.

---

## 8. Publishing

### 8.1 The outbox makes publishing an offline action

Tapping **Publish** must succeed instantly, on a mountain, in airplane mode.
So it does exactly two things, both local and both synchronous:

1. Write a `TrailPublication` row with `state = .queued`.
2. Append a `PublicationOutboxEntry` to a durable JSON queue in Application
   Support.

`PublicationOutbox` is modelled on
[`TrackJournal`](OpenHikes/Recording/TrackJournal.swift) — the app already has a
crash-safe append-only local journal and knows how to test one. Entries are
idempotent: each carries a client-generated `idempotencyKey` so a drain that
succeeds server-side and fails to record locally does not publish twice.

### 8.2 Draining

`PublicationSyncEngine` drains through the existing
[`SerialAsyncQueue`](OpenHikes/Recording/SerialAsyncQueue.swift), so uploads
never overlap and cancellation is already solved. It wakes on:

- `sceneDidBecomeActive()`
- a network path becoming satisfied
- an explicit "Retry" tap
- a recording ending

and on nothing else. **No timer, no polling.** The pattern to copy is
`OpenHikesModel.pollWeather(policy:)`: an `AsyncStream` merged from real events
plus one re-armed sleep to an exact deadline for backoff, rather than a tick that
wakes hundreds of times to conclude it has nothing to do.

Failures back off exponentially with jitter, cap at ~1 hour, and surface in the
hike detail view as a quiet, retryable row — never an alert, never a blocking
modal. A permanent failure (4xx other than 429) stops retrying and says why.

### 8.3 Building the payload, off-main

`PublicationPayload.make(from:)` follows the pattern
[`GPXExport.Track`](OpenHikes/Hikes/GPXExport.swift) already establishes: a
`Hike` is a `@Model`, main-actor and context-bound, so it cannot cross to a
background executor. Lift a `Sendable` value type on the main actor, then
serialize off it. Serialization, compression and EXIF stripping are blocking work
and belong off the main thread by contract, with `assertOffMainThread` like every
other hot path in this app.

### 8.4 Privacy masking is part of the payload, not the UI

`RoutePrivacyMask` trims the published polyline:

```swift
struct RoutePrivacyMask: Sendable {
    var startRadiusMeters: Double   // default 500
    var endRadiusMeters: Double     // default 500
    var includesTimestamps: Bool    // default false
}
```

Defaults hide the start and end. A route published straight from a recording
starts at the walker's front door often enough that this cannot be opt-in.
`RouteProfile`'s cumulative-distance index is already the right tool for finding
the trim points; reuse it rather than re-walking the route.

Timestamps default to **off**. A published track with per-fix times reveals pace,
schedule and habitual routes, and nothing in the discovery experience needs them.
Publishing with timestamps is a deliberate toggle with an explanation next to it.

### 8.5 Which geometry gets published — a real licensing question

`Hike.route` may be the **trail-matched** route, snapped onto the OpenStreetMap
walking graph by `TrailMatcher`; `Hike.rawRoute` holds the unmatched GPS trace
when matching moved it. Likewise `surfaceMetersByCategory` and
`difficultyMetersByGrade` are derived from OSM data.

Publishing snapped geometry redistributes OSM-derived geometry, which engages
ODbL's share-alike terms. Therefore:

- **Publish `rawRoute` when it is non-empty**, and `route` only when the two are
  the same (an import, or a recording that stayed raw).
- If matched geometry is published anyway — a legitimate product choice, since a
  snapped route is a nicer thing to follow — it carries an explicit
  `attributionText` field, surfaced in `CommunityTrailView`, and the decision is
  reviewed with counsel rather than settled in a pull request.
- Surface and difficulty breakdowns are shipped as derived statistics with the
  same attribution.

`CachedRemoteTrail.attributionText` exists for this and is displayed, not stored
and forgotten.

### 8.6 Photos: strip EXIF before it leaves the device

[`HikePhotoStore`](OpenHikes/Photos/HikePhotoStore.swift) deliberately writes the
**original bytes through untouched, EXIF included**, because the local copy is a
photograph of the walk and nothing should be lost from it. That is right for the
device and wrong for a server.

`MediaUploader` therefore re-encodes through ImageIO with a whitelist —
orientation and colour space in; GPS, device, serial numbers, timestamps and
Maker Notes out. Downscale to a published bound (long edge ~2048) before upload,
which is also what keeps the upload affordable on cellular. This is blocking
ImageIO work: off-main, `assertOffMainThread`, no exceptions.

The photo's *trail anchor* is published only when the user publishes coordinates
at all, and it is masked by the same `RoutePrivacyMask` — a photo pinned 30 m
from a trimmed start point undoes the trimming.

---

## 9. Discovery and consumption

### 9.1 Feed state is a reference type

Render isolation is a load-bearing convention here: high-frequency state lives in
stable `@Observable` reference types (`RouteHighlight`, `SheetMetrics`,
`RouteStyle`, `MapController`, `TrackerState`, `LocationManager`) and **parent
SwiftUI bodies must not read their changing properties**.

A paging feed with scroll position, in-flight page loads and per-row image state
is exactly that kind of state. `CommunityFeed` is an `@Observable` reference type
owned by `OpenHikesModel`; `CommunityFeedView` reads it, its parents do not.
Verify with `RenderSignpost` and the `RENDER_SIGNPOST_LOG=1` scheme variable, and
add a `SocialRenderIsolationTests` suite alongside the existing
`RenderIsolationTests` and `SheetQueryIsolationTests`.

### 9.2 Images

Copy [`HikePhotoImage`](OpenHikes/Photos/HikePhotoImage.swift): decode off-main,
draw thumbnails at the size the row actually draws, never a full-size decode in a
list. Feed rows use server-provided static previews — **not** live map tiles.
Rendering a feed through `TileOverlay` would turn a scroll into a tile storm
against a provider that does not permit bulk downloads, and would spend the
walker's offline budget on other people's routes.

### 9.3 Saving a community trail

`RemoteTrailImport.save(_:into:)` converts a `CachedRemoteTrail` into a `Hike`
using the same construction path as
`OpenHikesModel.importHike(from:into:)` — a random tint, the remote title, the
polyline, the author in `Hike.author`, and a provenance note in
`Hike.trackDescription`.

After that the trail is an ordinary hike. It gets styling, auto-save, offline
downloads, GPX export, auto-follow, the widget and route matching for free, and
nothing downstream needs to know where it came from. That is the payoff for
keeping publication state out of `Hike`.

Offline downloads for a saved trail still go through
`OfflineTileDownloader` and are still gated by
`TileProvider.supportsBulkDownload` — OpenStreetMap remains passive auto-save
only. Saving a community trail does **not** implicitly download its tiles; that
is a second, explicit tap, exactly as for a local hike.

---

## 10. Where the UI attaches

### 10.1 The sheet rule, which will otherwise cost a day

`OpenHikesView` keeps `MapSheet` presented permanently and puts it back if it is
ever dismissed. A `.sheet`, `.fullScreenCover`, `.photosPicker` or
`.fileImporter` attached to the same view as that sheet **is never presented at
all** — no error, no log, just a button that does nothing. `CODE_REVIEW.md`
records this having already bitten the photo picker.

Therefore:

- `PublishSheet`, the visibility picker, the photo-selection sheet, the report
  sheet and the share sheet are all presented from **inside** `MapSheet`'s
  hierarchy, next to its existing `.fileImporter` and `.photoCapturePickers`.
- Alerts are the exception and stay on the root view, where they survive the
  sheet being rebuilt. Sign-in errors, sign-out confirmation and delete-account
  confirmation are alerts on `OpenHikesView`.

### 10.2 Navigation

[`SheetRoute`](OpenHikes/App/Navigation/SheetRoute.swift) gains cases:

```swift
case community                     // the feed
case communityTrail(String)        // remote ID — a value, not a model
case profile(String)               // user ID
case publish(Hike)
```

`shows(hikeID:)` must return `true` for `.publish(hike)` so deleting a hike
correctly pops its publish screen — the same cleanup `.hike` and `.photo`
already do. `prefersFullHeight` returns `true` for `.communityTrail`, which draws
a map and a photo strip and is a stamp at the medium detent.

Community routes carry **identifiers, not models**, unlike `.hike(Hike)`. A
`CachedRemoteTrail` can be evicted by the cache pass while it is on the
navigation stack, and a route holding the model would hand the stack a deleted
object.

### 10.3 Accessibility is not a follow-up

The convention is enforced by a CI job: a composite row is one accessibility
element, not four, and `AccessibilityUITests` fails when it is not.

- `SocialRow`, feed rows and profile rows hide their decoration and expose a
  single label/value pair, like `HikeRow`, `StatTile` and `DetailRow`.
- Identifiers go on the **leaf** views automation taps — SwiftUI pushes a
  container's identifier down onto every descendant, which would leave the whole
  feed answering to one name.
- A glyph-only button (like, save, share) carries its own `accessibilityLabel`
  and a `minimumTapTarget()`.
- Selection drawn only as a tint or a checkmark also carries `.isSelected`.
- Every new screen gets a `performAccessibilityAudit` sweep in
  `AccessibilityUITests`, with the same `.contrast` / `.textClipped` /
  `.dynamicType` exclusions and no new ones without an argument written next to
  it.

---

## 11. Refactor inventory

Nothing below is a rewrite. The architecture already separates concerns well
enough that social attaches at the edges.

| File | Change | Why |
|---|---|---|
| [`OpenHikesModel.swift`](OpenHikes/App/OpenHikesModel.swift) | Add `socialAccount`, `publicationSyncEngine`, `communityFeed` to both initialisers; add the `RemoteMediaStore` sweep beside `reclaimOrphanedPhotos`; one line in `sceneDidBecomeActive()` | Composition root; the orphan-sweep rule |
| `ModelContainer(for: Hike.self)` (two call sites in the same file) | → `Hike.self, TrailPublication.self, CachedRemoteTrail.self` | The one schema change; ship it once |
| [`SettingsView.swift`](OpenHikes/Settings/SettingsView.swift) | Replace `appleSignInPlaceholder` with `SocialAccountSection`; add cellular-sync and auto-refresh toggles; add community-cache size to the storage section | The placeholder is already drawn and already has its accessibility contract |
| [`SettingsKey.swift`](OpenHikes/App/Configuration/SettingsKey.swift) | Add `socialCellularSync`, `socialAutoRefresh` + their `SettingsDefault` entries | Key strings are a storage contract; they are collected in one place on purpose |
| [`SheetRoute.swift`](OpenHikes/App/Navigation/SheetRoute.swift) | New cases; extend `shows(hikeID:)` and `prefersFullHeight` | Navigation cleanup on delete is already the file's job |
| [`MapSheet.swift`](OpenHikes/Map/MapSheet.swift) | Host the publish/share/report modals; add a Community entry point | Modals must be presented from inside the sheet |
| [`HikeDetailView.swift`](OpenHikes/Hikes/HikeDetailView.swift) | A publication section next to the existing Share button; add the *action*, don't restructure the *view* | The action bar is already the extension point |
| [`OpenHikesView.swift`](OpenHikes/App/Navigation/OpenHikesView.swift) | Route the new deep links; host social alerts | Deep-link routing already lives here |
| [`Info.plist`](OpenHikes/Info.plist) | Register `CFBundleURLTypes` for `openhikes`; add associated domains if universal links ship | The scheme is currently unregistered by design |
| [`OpenHikes.entitlements`](OpenHikes/OpenHikes.entitlements) | Add Sign in with Apple; associated domains if used | `network.client` is already present |
| [`TrailWidgetDeepLink.swift`](OpenHikesShared/Sources/OpenHikesShared/Widget/TrailWidgetDeepLink.swift) | **No change.** New hosts go in a sibling `SocialDeepLink` | Deep-link format is a persisted contract |
| [`Hike.swift`](OpenHikes/Hikes/Hike.swift) | **No change.** | Every column here is paid for by the hikes list |
| [`HikeRecorder*.swift`](OpenHikes/Recording/) | **No change.** | The recording path takes on no social dependency, ever |
| [`TileCache*`, `OfflineTileDownloader`, `AutoSave*`](OpenHikes/Tiles/) | **No change.** | Social never spends the tile budget |
| `.github/workflows/ci.yml` | Nothing structural; new `xcodebuild` steps (if any) need `-skipPackagePluginValidation` | A fresh runner fails on the SwiftLint plugin fingerprint without it |
| [`Scripts/run-ui-tests.sh`](Scripts/run-ui-tests.sh) | Add any new UI test class to the explicit class list | Classes are named explicitly; a new one is otherwise unreachable |
| [`README.md`](README.md), [`.github/copilot-instructions.md`](.github/copilot-instructions.md) | Add `Social/` to the layout tables and the domain list | `CODE_REVIEW.md` already records this being missed for `Photos/` |

---

## 12. Concurrency and isolation rules

Restated because social is the first subsystem in this app with a large,
latency-variable I/O surface, and every one of these already has a precedent
here:

- **UI and SwiftData coordination stay main-actor isolated.** All three new
  `@Observable` types are main-actor. Writing `TrailPublication` happens on the
  main actor; building the bytes to upload does not.
- **Delegate callbacks are `nonisolated` and hop explicitly.**
  `ASAuthorizationControllerDelegate` and any `URLSessionDelegate` follow the
  existing `Task { @MainActor in … }` pattern.
- **JSON coding, image re-encoding, compression and disk enumeration are
  off-main by contract**, with `assertOffMainThread`, matching `HikePhotoStore`
  and the tile pipeline.
- **Shared off-main types are `Sendable`**, and mutable state reachable from more
  than one executor uses the existing lock pattern.
- **Typed throws.** `throws(SocialTransportError)`, matching
  `throws(GPXImport.ImportFailure)`.
- **No fire-and-forget `Task` that outlives its owner.** Every long-running task
  is held and cancelled — `SerialAsyncQueue` for the drain, a stored `Task` for
  the feed page, cancelled on disappear.

---

## 13. Privacy, safety, and review

The App Store review surface changes materially the moment the app has
user-generated content. Client-side obligations:

- **Consent per publish.** Nothing is uploaded because the user signed in.
  Publishing is a per-hike action with an explicit visibility choice.
- **Location defaults to masked.** Start and end trimmed by default, timestamps
  off by default (§8.4).
- **EXIF stripped before upload** (§8.6).
- **Account deletion in-app.** Required by App Store Review Guideline 5.1.1(v)
  for any app with account creation. `AccountLifecycle` needs a delete flow that
  clears local social state and confirms server-side deletion, reachable from
  Settings in at most two taps.
- **UGC moderation affordances.** Guideline 1.2 requires a way to report
  objectionable content, a way to block a user, and a published mechanism for
  removal. All three are client work: a report action on a trail and a profile,
  a block action, and a locally-honoured block list so a blocked author's content
  is filtered from the cached feed immediately rather than after the next fetch.
- **Privacy manifest.** The app has no `PrivacyInfo.xcprivacy` today, and does
  not need one: it collects nothing. Social makes it mandatory. It must be
  created in Phase 2 declaring the newly collected types — identifiers, user
  content, coarse location, photos — with their purposes and linkage.
- **Encryption declaration.** `ITSAppUsesNonExemptEncryption` is `false` today.
  Standard HTTPS remains exempt; adding any custom cryptography would change that
  answer and require re-checking export compliance.
- **The user's own data is never held hostage.** Sign-out and account deletion
  leave every `Hike`, every photo and every offline tile exactly where they are.

---

## 14. Testing

Following the repository's conventions, not inventing new ones.

### 14.1 Unit and integration — Swift Testing, `OpenHikesTests/Social/`

Suites run **in parallel in one process**, so no suite may touch a singleton or
a shared directory. The tile suites solve this with `TileSandbox`; social gets
`SocialSandbox`:

```swift
struct SocialSandbox {
    let outboxDirectory: URL      // temporary, per-suite
    let mediaDirectory: URL       // temporary, per-suite
    let transport: StubSocialTransport
    let clock: TestClock          // TestSupport already has advance(by:)
    let defaults: UserDefaults    // isolated suite name
    let container: ModelContainer // in-memory
}
```

Coverage:

| Suite | Asserts |
|---|---|
| `SocialNetworkPolicyTests` | Every branch of §7.2, especially that `isRecording` denies a background request before connectivity is consulted |
| `PublicationOutboxTests` | Durability across a simulated kill, ordering, idempotency keys, no duplicate on replay |
| `PublicationSyncEngineTests` | Backoff schedule against `TestClock`, cancellation, no overlap, permanent-vs-transient failure |
| `RoutePrivacyMaskTests` | Trim distances against `RouteProfile`; a route shorter than the mask publishes nothing rather than publishing the start |
| `PublicationPayloadTests` | `rawRoute` preference (§8.5), timestamp stripping, `Sendable` lift correctness |
| `MediaUploaderTests` | GPS/device/Maker Note tags absent from the encoded output; orientation preserved |
| `RemoteTrailImportTests` | Round-trip to a `Hike` that behaves like an imported one |
| `RemoteMediaStoreTests` | Orphan reclamation, and that a failed claim fetch sweeps **nothing** |
| `SocialAccountTests` | Signed-out is fully functional; revoked credential signs out locally |
| `SocialRenderIsolationTests` | Feed churn does not invalidate parent bodies |

A test that provokes a `nonisolated` delegate callback (Apple sign-in,
`URLSession`) must wait through `settleDelegateHop(until:)` in
[`SettleSupport.swift`](OpenHikesTests/General/SettleSupport.swift), naming the
effect it expects, rather than spinning `Task.yield()`s — the bundle is
main-actor isolated project-wide and a yield count buys an amount of progress
that depends on machine load.

**No suite talks to a real backend.** If one ever genuinely cannot run without an
environment capability, it reports the skip through `SuitePrecondition`, because
strict mode turns a missing precondition into a failure.

### 14.2 Shared package — `swift test --package-path OpenHikesShared`

DTO encode/decode round-trips, `SocialDeepLink` formatter/parser symmetry, and a
regression test asserting `TrailWidgetDeepLink`'s output is unchanged.

### 14.3 UI automation — XCUITest

New launch arguments, alongside the existing `--ui-testing`,
`--ui-test-import-gpx=`, `--ui-test-trail-graph=`:

- `--ui-test-social-stub=<fixture>` — bind a bundled JSON fixture as the transport.
- `--ui-test-signed-in` — start in a signed-in state with a fake session.
- `--ui-test-social-offline` — force the transport to fail, to prove degradation.

Helpers go in
[`OpenHikesUITests/UITestSupport.swift`](OpenHikesUITests/UITestSupport.swift),
and any new class must be added to `Scripts/run-ui-tests.sh`'s explicit class
list or it is unreachable through the script.

`AccessibilityUITests` gains audits for the feed, the trail view, the profile and
the publish sheet — and that suite **does** run in CI (`continue-on-error` for
now), so those are the tests most likely to catch a regression before merge.

### 14.4 Performance

The feed is the first scrolling image list in the app. Add a
`--ui-test-performance-log=social-feed` scenario to `PerformanceUITests` and
record its baseline in [`PERFORMANCE.md`](PERFORMANCE.md) alongside the existing
ones. Remember what that suite learned: absolute memory under XCUITest is
automation overhead (~130 MB), so compare only within a run; warm the
accessibility tree before counting; and let the measure block end on its own.

### 14.5 The commands

```sh
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenHikesTests/PublicationSyncEngineTests

swift test --package-path OpenHikesShared --filter SocialDeepLinkTests

Scripts/run-ui-tests.sh --suite AccessibilityUITests --all
Scripts/lint.sh
```

`Scripts/lint.sh` is the authority — the Xcode build's SwiftLint plugin runs
without `--strict` and warns rather than decides.

---

## 15. Performance budget

| Budget | Limit |
|---|---|
| Network requests during an active recording | **0**, unless the user tapped something |
| Main-thread work per feed row | 0 decodes, 0 JSON, 0 file reads |
| Feed page size | 20 items, preview polylines decimated server-side |
| Community cache | Hard byte cap, evicted by `expiresAt` then LRU, shown in Settings storage |
| Publish upload | Photos downscaled to a long edge of ~2048 before upload; user-cancellable |
| Timers introduced | **0** — event-driven wake-ups only, per §8.2 |
| Cold-launch cost | 0 network. Credential state check and outbox drain are scheduled, not awaited |

Signposts (`RenderSignpost`) around feed decode, image decode and payload
serialization, so `PerformanceLog` picks them up like the existing hot paths.

---

## 16. Delivery phases

Each phase is independently shippable and independently revertible.

**Phase 0 — Safety net.** Batch GPX export of every hike. Ships *before* the
schema change so a user whose store fails to open has already been offered a way
out. No social code.

**Phase 1 — Schema and scaffolding.** The full social schema in one container
change. `Social/` domain folder, `SocialTransport` protocol with a stub-only
implementation, `SocialNetworkPolicy` and its complete test suite. No UI, no
network, nothing user-visible. This is the phase that de-risks everything else.

**Phase 2 — Identity.** Sign in with Apple replaces the placeholder. Entitlement,
Keychain, revocation handling, sign-out, account deletion. Still no content.
Verify the signed-out path is untouched.

**Phase 3 — Publish.** Outbox, sync engine, privacy masking, media upload, the
publication section in hike detail. Verify: publish in airplane mode, kill the
app, relaunch, confirm it drains.

**Phase 4 — Discover.** Feed, trail view, profile, remote media cache and its
sweep, "save to my hikes". Verify: feed renders from cache offline; browsing it
downloads no map tiles.

**Phase 5 — Safety and polish.** Report, block, block-list filtering, privacy
manifest, deep links and universal links, empty and error states, the
accessibility audits, the performance baseline.

---

## 17. Open decisions

1. **Matched or raw geometry?** §8.5. A licensing question with a product cost
   either way; needs a decision before Phase 3, not during it.
2. **Does the widget ever show social content?** Recommendation: no. The widget
   reads the App Group store and recomputes nothing, and a feed in a widget means
   a background network budget on a timeline the user did not ask for.
3. **Does a published trail's tile coverage transfer?** Recommendation: no. Tiles
   are cached per provider, per scale, per user's own policy, and re-deriving
   another user's coverage would spend the offline budget without a request.
4. **Followers, or public-only, in v1?** A follower graph doubles the client
   state and the moderation surface. Public-only is a smaller first release and
   the model above already carries the `visibility` column for later.
5. **What happens to a published trail when the local hike is deleted?**
   `TrailPublication` deliberately holds `hikeID` rather than a relationship, so
   this is a choice: orphan the record and offer an unpublish, or unpublish
   automatically. It needs an answer with the delete confirmation copy.
6. **Push notifications.** Out of scope above, and adding them later means a
   capability, a token lifecycle, and a background wake path that the offline
   invariants in §1 would then have to be re-argued against.

---

## 18. What this plan deliberately does not do

- It does not add a column to `Hike`.
- It does not put a network call anywhere on the recording path.
- It does not make any existing screen depend on an account.
- It does not introduce a timer.
- It does not touch the tile pipeline.
- It does not change any persisted identifier: provider IDs, `SettingsKey`
  strings, `SharedStore.appGroupID`, the widget kind, the cache-key shape, or
  `TrailWidgetDeepLink`'s format.

If an implementation finds itself needing to do one of these, that is the signal
to stop and revisit this document rather than to make the change.
