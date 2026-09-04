//
//  HikeDetailView.swift
//  OpenHikes
//
//  Pushed when a hike is selected. Surfaces every stat we can derive from the
//  GPX file, with an interactive elevation graph at the top.
//

import AsyncAlgorithms
import SwiftData
import SwiftUI

struct HikeDetailView: View {
    let hike: Hike
    /// Reference type the map observes directly — writing to it doesn't re-render this view.
    let highlight: RouteHighlight
    /// Drives one-shot map commands (the Zoom button).
    let mapController: MapController
    /// Owns whether this hike is passively auto-saving OSM tiles while browsed.
    let autoSave: AutoSaveController
    /// The Pro unlock, observed rather than read from the process-wide
    /// ``MapEntitlement``. The offline controls below resolve a provider *and*
    /// capture its ``ActiveTileSource`` into the download button's action, so a
    /// snapshot that cannot invalidate this body is a snapshot that lets a
    /// lapsed subscription start a bulk download against a paid key.
    let entitlement: MapEntitlementStore
    /// Source of the user's live location. Auto-follow consumes
    /// ``LocationManager/fixes``, so it is driven per published fix, not by a timer.
    let locationManager: LocationManager
    /// Fed the same auto-follow matches as the chart/map, throttled, so the
    /// widget stays reasonably fresh while this hike is being viewed.
    let backgroundTracker: BackgroundTrailTracker
    /// OSM walking graph behind the surface and difficulty sections. `nil`
    /// disables both — see ``HikeTrailAnalysis``.
    var trailGraphProvider: (any TrailGraphProviding)?
    /// The walk under way, fed each on-route match from the follow loop
    /// below. Passed to the progress row and the controls as a reference the
    /// way `tracker` is, and never read from this body — see
    /// ``TrailWalkSession``.
    let walkSession: TrailWalkSession
    /// Offers the map's camera pill while this screen is up, and tells it
    /// where on the trail a photo taken now belongs. See
    /// ``PhotoCaptureController``.
    var photoCapture: PhotoCaptureController?
    /// Draws this hike's anchored photos on the map while this screen is up.
    /// See ``PhotoMapPinController``.
    var photoPins: PhotoMapPinController?
    /// Pushes the full-space viewer for a tapped thumbnail.
    var onOpenPhoto: (HikePhoto) -> Void = { _ in /* no-op default */ }
    /// Pushes a finished walk's summary — from the History segment's rows,
    /// and from End.
    var onOpenWalk: (HikeWalk) -> Void = { _ in /* no-op default */ }
    /// Collapses the sheet so the map is visible when zooming to the route.
    var onZoomToRoute: () -> Void = { /* no-op default */ }

    /// The active tile source, mirrored from Settings so offline downloads use the
    /// same provider (and API key) the map is currently drawing.
    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id
    // Shared with offline-storage helpers in the companion extension file.
    // swiftlint:disable private_swiftui_state
    @Environment(\.modelContext)
    var modelContext
    @State var downloader = OfflineTileDownloader()
    /// Disk space used by this hike's saved tiles; `nil` until measured.
    @State var storedBytes: Int64?
    /// Auto-save drain notifications, coalesced by ``storedBytesRefreshDebounce``.
    /// Each carries the measurement generation current when it was requested,
    /// which is what lets a refresh that has already happened for another
    /// reason retire the trailing one instead of paying for it twice.
    @State var storedBytesRefreshes = AsyncStream<Int>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    @State var storedBytesMeasurementTask: Task<Void, Never>?
    @State var storedBytesMeasurementGeneration = 0
    /// Why the last attempt to delete this hike's offline tiles did not
    /// happen, and so which alert is raised — see ``StoredTileDeletion``.
    @State var storageDeletionFailure: StoredTileDeletion.Failure?
    // swiftlint:enable private_swiftui_state
    @State private var isEditingTitle = false
    /// Draft text while the inline title field is open.
    @State private var titleDraft = ""
    /// Which face of the screen is up. `@State` here rather than in a leaf,
    /// deliberately: a flip is a tap, not a fix, and it has to replace the
    /// whole scroll view. It invalidates this body — and only this body,
    /// which `HikeDetailSegmentTests` pins from the sheet's side.
    @State private var segment = HikeDetailSegment.details
    private static let storedBytesRefreshDebounce: Duration = .seconds(5)

    /// Built once per hike in `.task`, never in `init`. Scrubbing then resolves
    /// points in O(log n).
    @State private var profile: RouteProfile?
    /// Stat tiles, computed once per hike with the route profile off the main
    /// actor so navigation does not pay the route-sized work.
    @State private var statItems: [Stat] = []
    /// Tracker/live-follow positions, isolated in a reference type — see
    /// ``TrackerState``. Drawn on the chart as two separate markers so a manual
    /// scrub and the live position can both be visible at once.
    @State private var tracker = TrackerState()
    /// True while a finger is actively dragging the elevation chart — pauses
    /// auto-follow's own updates to `trackerDistance` so it doesn't fight the drag.
    @State private var isScrubbing = false
    /// Where auto-follow last matched a fix — the only thing allowed to anchor
    /// the next match's tie-break.
    ///
    /// Deliberately not `tracker.trackerDistance`: that starts at 0 on every
    /// selection (a placeholder, not a position) and is also driven by the
    /// user's finger on the elevation chart. Anchoring on it let a scrub to
    /// the far end of the trail decide where the next reacquired fix matched —
    /// on an out-and-back, that is the difference between the start and the
    /// finish. `nil` means no fix has been matched yet, which is what tells
    /// ``RouteProfile/nearestPoint(to:near:heading:scope:)`` to work out the
    /// leg from scratch rather than continue from a position.
    @State private var followAnchor: FollowAnchor?
    @State private var offRouteSearch = OffRouteSearchPolicy()

    var body: some View {
        // Fires on every re-evaluation of this view's body. Auto-follow's
        // per-fix tracker updates should NOT show up here — they live in
        // `tracker` (a `TrackerState`), which this body never reads, so those
        // updates invalidate only the chart and the progress row below. If
        // this mark starts firing at that cadence again, something
        // re-introduced a read of `tracker`'s properties into this body
        // (directly or via a computed var it calls, like `elevationSection`).
        // The same goes for `walkSession`: a matched fix that extends a walk
        // redraws the progress row and the controls, and nothing above them.
        RenderSignpost.mark("HikeDetailBody")
        return VStack(spacing: 0) {
            segmentPicker
            switch segment {
            case .details: details
            case .history: HikeWalkHistory(hike: hike, onOpen: onOpenWalk)
            }
        }
        .navigationTitle(hike.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // On the container rather than on the Details face, so flipping to
        // History neither restarts the profile build nor stops the follow
        // loop: a walk keeps accruing while its walker reads its history.
        .task(id: hike.id) {
            let route = hike.route
            let distanceMeters = hike.distanceMeters
            let prepared: HikeDetailPreparedContent
            do throws(CancellationError) {
                prepared = try await HikeDetailPreparation.prepare(
                    route: route,
                    distanceMeters: distanceMeters
                )
            } catch {
                return
            }
            let built = prepared.profile
            profile = built
            statItems = prepared.stats
            // Place the tracker at the start of the track, on both graph and map.
            tracker.trackerDistance = 0
            tracker.liveTrackerDistance = nil
            followAnchor = nil
            offRouteSearch = OffRouteSearchPolicy()
            highlight.move(to: built.coordinate(atDistance: 0))
            refreshStoredBytes()
            autoSave.hikeSelectionChanged(to: hike)
            // Keep the first live fix from racing the widget's initial trail snapshot.
            await backgroundTracker.waitForSelectionPublish()
            await followLocation(profile: built)
        }
        .task(id: hike.id) {
            await loadTrailBreakdowns()
        }
        // Toggling off should clear the live dot immediately, not wait for the
        // next fix. Toggling on should hand the map pin back to auto-follow
        // right away, rather than leaving a stale manual pin up until the
        // walker's next step publishes one.
        .onChange(of: hike.autoFollowEnabled) { _, enabled in
            if !enabled {
                tracker.liveTrackerDistance = nil
                // Turning following off for the walked hike is the walker
                // saying *stop following*: the walk pauses and the Lock
                // Screen says so. With no walk the panel comes down instead —
                // nothing else would take it down, since the foreground feed
                // stops publishing the moment auto-follow is off.
                if !walkSession.autoFollowDidChange(hikeID: hike.id, enabled: false) {
                    backgroundTracker.endFollowActivity(hikeID: hike.id)
                }
            }
            switch FollowInteractionPolicy.highlightUpdate(
                autoFollowEnabled: enabled,
                isScrubbing: isScrubbing,
                profile: profile,
                trackerDistance: tracker.trackerDistance
            ) {
            case .unchanged: break
            case .clear: highlight.move(to: nil)
            case .move(let coordinate): highlight.move(to: coordinate)
            }
            if enabled, let profile {
                updateLiveFollow(profile: profile)
            }
        }
        // A scrub ends with the persistent tracker parked under the finger,
        // and auto-follow used to take it back on its next tick. Now that it
        // only wakes on a published fix, hand it back here — someone who has
        // stopped to drag the chart is, by definition, not producing new
        // fixes, so waiting for one could park the tracker there indefinitely.
        .onChange(of: isScrubbing) { _, scrubbing in
            guard !scrubbing, let profile else { return }
            updateLiveFollow(profile: profile)
        }
        // A download records and commits its own coverage now — see
        // ``OfflineDownloadClaim`` — because this screen is gone the moment
        // the walker taps back and the run carries on writing tiles either
        // way. What is left here is redrawing the storage row for a screen
        // that is still up, against a manifest already on disk.
        .onChange(of: downloader.phase) { _, phase in
            guard phase != .downloading, downloader.completedRecord != nil else { return }
            refreshStoredBytes()
        }
        .task {
            // A trailing measurement, once the auto-save drain settles. The
            // task's own lifetime retires it when the view goes away, so
            // there's no timer to cancel by hand.
            for await generation in storedBytesRefreshes.stream
                .debounce(for: Self.storedBytesRefreshDebounce) {
                guard generation == storedBytesMeasurementGeneration else { continue }
                refreshStoredBytes()
            }
        }
        .onDisappear {
            invalidateStoredBytesMeasurement()
        }
        // Offers the map's camera pill while this screen is up, and tells it
        // where a photo taken now belongs on this trail. The anchor is
        // evaluated at the shutter, not published as the chart moves — reading
        // `tracker` from this body is the one thing ``TrackerState`` exists to
        // prevent; inside a closure that runs once per photo it costs nothing.
        .photoCaptureSubject(photoCapture, for: hike) {
            PhotoTrailAnchor.coordinate(
                profile: profile,
                live: tracker.liveTrackerDistance,
                scrubbed: tracker.trackerDistance
            )
        }
        .offlineStorageAlerts(
            downloader: downloader,
            deletionFailure: $storageDeletionFailure
        )
    }

    /// The screen as it always was: everything derived from the file, with
    /// the walk's controls and live coverage in its progress section while a
    /// walk is under way.
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                elevationSection
                progressSection
                header
                statsGrid
                photoSection
                surfaceSection
                difficultySection
                if hasMetadata { metadataSection }
                actionBar
            }
            .padding()
        }
        // The elevation chart and the tinted header run right up under the
        // navigation bar. `.soft` is the progressive blur that lets them scroll
        // away behind it instead of meeting a hard line, which is what the
        // bar's own glass is drawn to sit on.
        .softScrollEdgeEffect(for: .top)
    }

    /// `Details | History`. *History* rather than *Walks* because it holds
    /// partial completions as well as full ones. Above the scroll view rather
    /// than inside it, so it stays put while either face scrolls.
    private var segmentPicker: some View {
        Picker("Section", selection: $segment) {
            ForEach(HikeDetailSegment.allCases) { face in
                Text(face.title).tag(face)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("walk-segment")
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// The two faces of the hike detail screen.
nonisolated enum HikeDetailSegment: String, CaseIterable, Identifiable, Sendable {
    case details = "details"
    case history = "history"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "Details"
        case .history: "History"
        }
    }
}

// MARK: - HikeDetailView + UI Helpers

private extension HikeDetailView {
    // MARK: Actions

    /// Trailing row of actions: zoom the map to the route, save it for offline use,
    /// and recolor the route line.
    private var actionBar: some View {
        VStack(spacing: 12) {
            RouteAppearanceControls(hike: hike) {
                zoomButton
                if let source = activeTileSource, activeProvider.supportsBulkDownload {
                    OfflineDownloadButton(
                        downloader: downloader,
                        canDownload: canDownload
                    ) {
                        downloader.start(
                            route: hike.route,
                            source: source,
                            claim: offlineDownloadClaim
                        )
                    }
                }
            } middleControls: {
                // No toggle at all rather than a disabled one: there is nothing
                // to save from a map that fetches no tiles, and
                // `OfflineStorageStatus` says so where the note goes.
                if !activeProvider.usesSystemBaseMap { autoSaveToggle }
                autoFollowToggle
            }
            OfflineStorageStatus(
                hike: hike,
                autoSave: autoSave,
                downloader: downloader,
                storedBytes: storedBytes,
                mapRendersTiles: !activeProvider.usesSystemBaseMap,
                scheduleStoredBytesRefresh: scheduleStoredBytesRefresh,
                deleteStoredTiles: deleteStoredTiles
            )
        }
    }

    private var zoomButton: some View {
        Button {
            onZoomToRoute()
            mapController.fitToRoute()
        } label: {
            actionTile(icon: "scope", title: "Zoom")
        }
        .buttonStyle(.plain)
        .disabled(hike.pointCount < 2)
    }

    /// Passive gap-filler alongside (or instead of) the bulk
    /// ``OfflineDownloadButton``: saves tiles as they're actually browsed, so
    /// areas a bulk download missed — or, for OSM-style providers, everything
    /// — still end up saved.
    private var autoSaveToggle: some View {
        Toggle(isOn: autoSaveBinding) {
            Label("Auto-Save Tiles", systemImage: "arrow.down.circle")
        }
        .disabled(hike.pointCount < 2)
    }

    /// Reads/writes `hike.autoSaveTilesEnabled` through `autoSave`, so toggling
    /// also starts/stops the store's active-hike tracking.
    private var autoSaveBinding: Binding<Bool> {
        Binding(
            get: { hike.autoSaveTilesEnabled },
            set: { autoSave.setEnabled($0, for: hike) }
        )
    }

    /// Auto-scrolls the elevation graph to the user's live position along this
    /// trail. On by default; the fix-driven loop in `followLocation` does the work.
    private var autoFollowToggle: some View {
        Toggle(isOn: autoFollowBinding) {
            Label("Auto-Follow Trail", systemImage: "location.fill.viewfinder")
        }
        .disabled(hike.pointCount < 2)
    }

    private var autoFollowBinding: Binding<Bool> {
        Binding(
            get: { hike.autoFollowEnabled },
            set: { hike.autoFollowEnabled = $0 }
        )
    }

    private var canDownload: Bool { activeProvider.supportsBulkDownload && hike.pointCount > 1 }

    private func actionTile(icon: String, title: String, tint: Color = .accentColor) -> some View {
        ActionTile(tint: tint) {
            Image(systemName: icon)
                .font(.title3)
                .accessibilityHidden(true)
            Text(title).font(.caption2.weight(.medium))
        }
    }

    /// `renderable`, not `provider`: this drives whether a bulk download is
    /// offered at all, so it has to name the source the map is really drawing.
    private var activeProvider: TileProvider { .renderable(id: tileProviderID, entitlement: entitlement.state) }

    /// `nil` when the selected map draws no raster tiles, which is also when
    /// there is nothing a download could fetch.
    private var activeTileSource: ActiveTileSource? { activeProvider.renderedSource }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            HikeHeaderSymbol(hike: hike)

            VStack(alignment: .leading, spacing: 4) {
                if isEditingTitle {
                    TextField(hike.title, text: $titleDraft)
                        .font(.title2.bold())
                        .accessibilityLabel("Hike name")
                        .accessibilityIdentifier("hike-title-field")
                        .onSubmit { commitTitleEdit() }
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { commitTitleEdit() }
                            }
                        }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(hike.displayTitle)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        shareButton
                        renameButton
                    }
                }
                Text(hike.date.formatted(date: .complete, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    /// Hands the route to the share sheet as a `.gpx` file — the export half
    /// of the import this app already does.
    ///
    /// The payload is a `Sendable` ``GPXExport/Track`` snapshot rather than the
    /// `Hike`: `ShareLink` passes the exporter to the system, which calls it
    /// off the main actor, where a `@Model` must not be read. Building the
    /// snapshot is a retain of the route's storage, not a copy of it, and the
    /// XML itself is written only once a destination is picked.
    ///
    /// The preview carries an icon so the sheet's header reads as the document
    /// being sent rather than as a bare line of text.
    private var shareButton: some View {
        ShareLink(
            item: HikeGPXFile(track: GPXExport.Track(hike: hike)),
            preview: SharePreview(
                hike.displayTitle,
                icon: Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            )
        ) {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .minimumTapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share hike")
        .disabled(hike.pointCount < 2)
    }

    private var renameButton: some View {
        Button {
            titleDraft = hike.displayTitle
            isEditingTitle = true
        } label: {
            Image(systemName: "pencil")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .minimumTapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rename hike")
    }

    private func commitTitleEdit() {
        hike.customName = HikeTitle.bounded(titleDraft)
        isEditingTitle = false
    }

    // MARK: Stats

    private var statsGrid: some View {
        StatGrid {
            ForEach(statItems) { stat in
                StatTile(label: stat.label, value: stat.value)
            }
        }
    }

    // MARK: Photos

    /// Always drawn, on every hike: the strip when there are photos, and the
    /// offer to go and find some either way. See ``HikePhotoSection``.
    private var photoSection: some View {
        HikePhotoSection(hike: hike, mapPins: photoPins, onOpen: onOpenPhoto)
    }

    // MARK: Trail data

    /// Reads the breakdown straight off the hike, so the write that fills it
    /// in redraws the section rather than this view. Renders nothing until
    /// there is one — see ``loadTrailBreakdowns()``.
    private var surfaceSection: some View {
        HikeSurfaceSection(hike: hike)
    }

    /// Mirrors ``surfaceSection``.
    private var difficultySection: some View {
        HikeDifficultySection(hike: hike)
    }

    /// Asks OpenStreetMap what this route runs on, and how hard it is, the
    /// first time the hike is opened.
    ///
    /// It runs here rather than inside the two sections because they are
    /// hidden until they have something to show, and a view that isn't in the
    /// hierarchy can't run the task that would put it there. Doing it once for
    /// both is also the cheaper arrangement: they read different tags off the
    /// same ways, so they share one fetch and one decode.
    ///
    /// Failure is deliberately invisible. Nobody asked for this, so an
    /// Overpass outage, a flight-mode gap or a valley nobody has mapped leaves
    /// the screen exactly as it was; the next open tries again.
    private func loadTrailBreakdowns() async {
        guard let trailGraphProvider,
              hike.surfaceBreakdown == nil || hike.difficultyBreakdown == nil
        else { return }
        let breakdowns = await HikeTrailAnalysis.breakdowns(
            route: hike.route,
            provider: trailGraphProvider
        )
        guard !Task.isCancelled, !breakdowns.isEmpty else { return }
        // No transition and no curve of our own: SwiftUI's default animation
        // and default insertion — a fade — are what every other section that
        // appears late on this screen already uses.
        withAnimation {
            if let surface = breakdowns.surface {
                hike.surfaceBreakdown = surface
            }
            if let difficulty = breakdowns.difficulty {
                hike.difficultyBreakdown = difficulty
            }
        }
    }

    // MARK: Metadata

    private var hasMetadata: Bool {
        hike.trackDescription != nil || hike.author != nil || hike.keywords != nil
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let description = hike.trackDescription { DetailRow(label: "Description", value: description) }
            if let author = hike.author { DetailRow(label: "Author", value: author) }
            if let keywords = hike.keywords { DetailRow(label: "Keywords", value: keywords) }
        }
    }

    // MARK: Elevation

    @ViewBuilder private var elevationSection: some View {
        if let profile, profile.samples.count > 1 {
            // `tracker` is passed down as a reference, never read here — that's
            // what keeps this body from re-running on every auto-follow tick.
            HikeElevationChart(
                hike: hike,
                profile: profile,
                tracker: tracker,
                onScrub: { distance in
                    tracker.trackerDistance = distance
                    highlight.move(to: profile.coordinate(atDistance: distance))
                },
                onScrubbingChanged: { scrubbing in
                    isScrubbing = scrubbing
                    // Auto-follow owns the map pin: once the finger lifts, hand
                    // it back so the pin doesn't sit at a stale scrub position
                    // fighting the live location puck.
                    if !scrubbing, hike.autoFollowEnabled {
                        highlight.move(to: nil)
                    }
                }
            )
        } else {
            HikeElevationPlaceholder(hike: hike)
        }
    }

    // MARK: Progress

    /// How far along the trail the tracked position is. Like the chart, this
    /// is handed `tracker` as a reference and never reads it here, so the
    /// per-fix auto-follow update redraws the bar and nothing above it.
    @ViewBuilder private var progressSection: some View {
        if let profile, profile.totalDistanceMeters > 0 {
            HikeTrailProgress(
                hike: hike,
                profile: profile,
                tracker: tracker,
                walk: walkSession
            )
            // Reads the session the way the bar reads `tracker`: as a
            // reference this body never dereferences.
            WalkControls(hike: hike, session: walkSession, onOpenWalk: onOpenWalk)
        }
    }

    // MARK: Auto-follow

    /// Projects each published fix onto the route to drive both the live chart
    /// marker and the persistent tracker, while auto-follow is on. Runs for as
    /// long as this hike stays selected; cancelled when it changes.
    ///
    /// Driven by ``LocationManager/fixes`` rather than by a 1 Hz timer: the
    /// source already throttles to one publish a second and already drops a
    /// repeat of the last coordinate, so this now stops entirely while the
    /// walker is standing still instead of re-deriving the same match once a
    /// second through every rest stop. The two moments that used to depend on
    /// the next tick — a scrub ending, and auto-follow being switched on —
    /// are handled by the `onChange` handlers in `body`.
    private func followLocation(profile: RouteProfile) async {
        for await _ in locationManager.fixes {
            updateLiveFollow(profile: profile)
        }
    }

    /// The no-match half of ``updateLiveFollow(profile:)``: clears the live dot
    /// and tells the widget there is nothing to show.
    private func clearLiveFollow(profile: RouteProfile, reason: String) {
        // Guarded so a run of off-route fixes (nil already) doesn't write
        // `tracker` for nothing.
        if tracker.liveTrackerDistance != nil {
            tracker.liveTrackerDistance = nil
            RenderSignpost.mark("LiveFollowUpdate", "cleared")
        } else {
            RenderSignpost.mark("LiveFollowUpdate", reason)
        }
        // Only worth telling the widget "no fix" while auto-follow is
        // actually trying to track this hike — if the user turned
        // auto-follow off, leave whatever it last showed alone. A paused
        // walk is left alone too: the widget says Paused, and that stands.
        if hike.autoFollowEnabled, walkSession.publishes(hikeID: hike.id) {
            backgroundTracker.publishLiveFix(
                hike: hike,
                profile: profile,
                match: nil,
                walk: walkSession.payload(for: hike.id)
            )
        }
    }

    private func updateLiveFollow(profile: RouteProfile) {
        // Split from the match below so only a fix that actually reached the
        // matcher feeds the search policy: a fix too inaccurate to match says
        // nothing about where the walker is relative to the route, and must
        // neither re-arm the whole-route search nor spend one of the fixes
        // that delays it.
        // Before the match, so a walk left unmatched for six hours is closed
        // on the fix that would otherwise have quietly extended it.
        walkSession.endIfAbandoned()
        guard hike.autoFollowEnabled,
              let fix = locationManager.routeFix(
                maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
              ) else {
            clearLiveFollow(profile: profile, reason: "no-fix")
            return
        }
        let searchScope = offRouteSearch.scope
        let match = profile.nearestPoint(
            to: fix.coordinate,
            near: FollowAnchor.tieBreak(followAnchor, course: fix.course),
            heading: fix.course,
            scope: searchScope
        )
        let onRoute = (match?.offRouteMeters ?? .greatestFiniteMagnitude)
            <= RouteProfile.followMatchThresholdMeters
        offRouteSearch.record(matched: onRoute, scope: searchScope)
        guard onRoute, let match else {
            // Leaving the route is what rearms auto-start after an End: the
            // walker is off this trail, so coming back to it is a new walk.
            walkSession.recordOffRoute(hikeID: hike.id)
            clearLiveFollow(profile: profile, reason: "off-route")
            return
        }
        followAnchor = .matched(at: match.distanceAlongRoute, course: fix.course, from: followAnchor)
        // The walk starts here, on the first matched fix with following on,
        // and this is where every later match extends it. Selection alone
        // starts nothing.
        let completedWalk = walkSession.recordForegroundMatch(
            hike: hike,
            profile: profile,
            distance: match.distanceAlongRoute
        )
        let moved = tracker.liveTrackerDistance != match.distanceAlongRoute
        // Guarded like `trackerDistance` below — reassigning `@Observable`
        // storage to an equal value still triggers dependent views, so an
        // unconditional write here would invalidate `ElevationChartView` (and,
        // previously, `HikeDetailView` itself) on every fix that matched to
        // the same place too.
        if moved { tracker.liveTrackerDistance = match.distanceAlongRoute }
        // Don't fight an in-progress manual scrub; the live dot still moves,
        // but the persistent tracker stays under the user's finger.
        guard FollowInteractionPolicy.appliesMatchToPersistentTracker(
            isScrubbing: isScrubbing
        ) else {
            RenderSignpost.mark("LiveFollowUpdate", moved ? "moved-scrubbing" : "unchanged-scrubbing")
            return
        }
        // Skip the tracker write when the projected position hasn't actually
        // moved (e.g. paused, or GPS noise below the route-matching
        // resolution) — avoids a redundant `TrackerState` update on a fix that
        // projects to the same distance along the route.
        if tracker.trackerDistance != match.distanceAlongRoute {
            tracker.trackerDistance = match.distanceAlongRoute
        }
        // Auto-follow owns the map: the live location puck already shows
        // where the user is, so the custom pin stays hidden here rather than
        // sitting on top of (and fading against) it. It only reappears while
        // the user is scrubbing the elevation graph, to compare other
        // sections of the trail. Clearing an already-clear highlight is free —
        // `move(to:)` does the comparison this path used to do by hand.
        highlight.move(to: nil)
        RenderSignpost.mark("LiveFollowUpdate", moved ? "moved" : "unchanged")
        // A paused walk still moves the dot above, and publishes nothing. Nor
        // does the fix that just completed a walk: with the record gone the
        // two questions below say "publish, with no walk", which is a fresh
        // plain follow over the finished panel the end has already queued.
        guard !completedWalk, walkSession.publishes(hikeID: hike.id) else { return }
        backgroundTracker.publishLiveFix(
            hike: hike,
            profile: profile,
            match: match,
            walk: walkSession.payload(for: hike.id)
        )
    }

}
