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
    /// Draws this hike's marked places on the map while this screen is up.
    /// See ``TrailPlacePinController``.
    var placePins: TrailPlacePinController?
    /// How this hike is offered to the community, or `nil` for a launch that
    /// must not reach CloudKit — see
    /// ``OpenHikesModel/makeCommunityTransport()``. Taken as a dependency
    /// rather than read from the environment, like everything else this screen
    /// needs, so a preview or a suite decides it outright.
    var communityTransport: (any CommunityTransporting)?
    /// Pushes the full-space viewer for a tapped thumbnail.
    var onOpenPhoto: (HikePhoto) -> Void = { _ in /* no-op default */ }
    /// Pushes a finished walk's summary — from the History segment's rows,
    /// and from End.
    var onOpenWalk: (HikeWalk) -> Void = { _ in /* no-op default */ }
    /// Collapses the sheet so the map is visible when zooming to the route.
    var onZoomToRoute: () -> Void = { /* no-op default */ }
    /// Whether the sheet this screen is pushed into is resting at its smallest
    /// detent, where only the search field's worth of height is on screen.
    ///
    /// The one thing of this screen's that reaches down there is the section
    /// picker — see ``segmentPicker`` for what it does about it. A plain
    /// `Bool` rather than the presentation itself, and no new cost: the sheet's
    /// own body already reads ``SheetPresentation/isCompact`` for its hikes
    /// list, so this screen is rebuilt on that transition either way.
    var isSheetCompact = false

    /// The active tile source, mirrored from Settings so offline downloads use the
    /// same provider (and API key) the map is currently drawing.
    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id
    // Shared with the offline-storage and community helpers in the
    // companion extension files.
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
    /// Whether the community share form is up. Presented from inside this
    /// screen, which is inside the persistent sheet's *contents* — see the
    /// repository instructions on why a `.sheet` beside that presentation is
    /// never presented at all.
    @State var isSharingToCommunity = false
    /// Whether the takedown-request form is up. Here for the reason
    /// ``isSharingToCommunity`` is, and presented from the same place.
    @State var isWithdrawingFromCommunity = false
    /// The hike a photo contribution would be attached to, non-`nil` while
    /// that form is up.
    ///
    /// The target rather than a `Bool`, because unlike the two above this
    /// sheet cannot be built from the hike alone: where the photographs go is
    /// worked out by ``CommunityPublishingCheck`` and is the one thing the
    /// form has to be handed. Presented from the same place as the other two
    /// and for the same reason.
    @State var contributionTarget: CommunityPhotoTarget?
    /// Whether the takedown-request form is up *about the photographs*. A
    /// second flag rather than a second case of ``isWithdrawingFromCommunity``
    /// because the two name different records and a hike can be in only one of
    /// the two conversations — a flag that had to say which would be a third
    /// thing to keep in step with the two columns that already decide it.
    @State var isWithdrawingPhotosFromCommunity = false
    /// What the hiker's *is this still live?* tap came back with, non-`nil`
    /// while the alert reporting it is up.
    ///
    /// An answer rather than a `Bool` because all three outcomes have to be
    /// said out loud — still live, taken down, and could not ask — and only
    /// one of them offers an action. See
    /// ``CommunityPublicationCheck/Liveness``, which this adds the failure to
    /// for the reason the check itself throws rather than swallowing.
    @State var publicationLiveness: CommunityLivenessAnswer?
    // swiftlint:enable private_swiftui_state
    /// Owned by the navigation session so changing presentation hosts keeps
    /// the selected section and an unfinished rename. Read only by this screen.
    @Bindable var interaction = HikeDetailInteraction()
    private static let storedBytesRefreshDebounce: Duration = .seconds(5)
    /// How long the section picker takes to fade as the sheet settles at,
    /// or leaves, its smallest detent. See ``segmentPicker``.
    private static let compactFadeDuration: TimeInterval = 0.2

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
    /// Focus for the header's name field, so tapping the pencil puts the
    /// keyboard up on the field rather than asking for a second tap.
    ///
    /// Raised from the field's own `onAppear` rather than from the button that
    /// flips ``HikeDetailInteraction/isEditingTitle``: the field does not
    /// exist yet at the moment of the tap, and focus asked for before then is
    /// dropped.
    @FocusState private var isTitleFieldFocused: Bool
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
        VStack(spacing: 0) {
            segmentPicker
            switch interaction.segment {
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
        // loop: a walk keeps accruing while its hiker reads its history.
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
        // hiker's next step publishes one.
        .onChange(of: hike.autoFollowEnabled) { _, enabled in
            walkSession.autoFollowDidChange(hikeID: hike.id, enabled: enabled)
            if !enabled {
                tracker.liveTrackerDistance = nil
                // A walk keeps its phase and its feeds, just as it does when
                // this screen closes. Only a plain follow loses its panel.
                if !walkSession.isWalking(hike.id) {
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
        // the hiker taps back and the run carries on writing tiles either
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
        // A hike being *walked* is the other half of what the switch is for.
        // Merely reading a trail's detail holds nothing, which is why the
        // question is the walk session's rather than this screen's presence.
        // The read is deliberately inside the closure: this body must not gain
        // `walkSession` as an input — see the note on the signpost above.
        .keepsScreenAwake { walkSession.isWalking(hike.id) }
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
                statsSummary
                photoSection
                placeSection
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
    ///
    /// **Hidden, not removed, at the compact detent.** Eighty points of sheet
    /// is a navigation bar and about twenty points more, and those twenty are
    /// exactly where this sits — so a sheet dragged down to peek at the map
    /// kept the top of the segmented control poking out over it. Taking the
    /// picker out of the stack instead would pull the scroll view up by its
    /// height and put the top of the elevation section in that same sliver:
    /// the same leak, with a different thing leaking. It would also change the
    /// spacing the other detents are read at, which is the one thing this must
    /// not touch.
    ///
    /// `allowsHitTesting` along with the opacity, because the sliver is
    /// tappable: without it, a tap aimed at the sheet's chrome down there
    /// switches a section the hiker cannot see.
    private var segmentPicker: some View {
        Picker("Section", selection: $interaction.segment) {
            ForEach(HikeDetailSegment.allCases) { face in
                Text(face.title).tag(face)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("walk-segment")
        .padding(.horizontal)
        .padding(.vertical, 8)
        .opacity(isSheetCompact ? 0 : 1)
        .allowsHitTesting(!isSheetCompact)
        // The flag flips when the drag settles rather than as it moves, so
        // without this the picker blinks out a frame after the sheet stops.
        .animation(.easeInOut(duration: Self.compactFadeDuration), value: isSheetCompact)
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
                            // What a previous run already put on disk and
                            // claimed, so a download killed at 90% resumes
                            // rather than starting over — see
                            // ``OfflineTileDownloader/defaultClaimBatchSize``.
                            alreadySaved: OfflineTileDownloader.resumableKeys(
                                from: hike.offlineDownloads,
                                source: source
                            ),
                            claim: offlineDownloadClaim
                        )
                    }
                }
            } middleControls: {
                // No toggle at all rather than a disabled one: there is nothing
                // to save from a map that fetches no tiles, and
                // `OfflineStorageStatus` says so where the note goes.
                if !activeProvider.usesSystemBaseMap { autoSaveToggle }
                FollowToggles(hike: hike, session: walkSession)
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

    /// The same place-card title row the recording screen opens with, so a
    /// hike looks the same while it is recorded as after it is saved.
    private var header: some View {
        PlaceCardHeader {
            HikeHeaderSymbol(hike: hike)
        } title: {
            if interaction.isEditingTitle {
                TextField(hike.title, text: $interaction.titleDraft)
                    .accessibilityLabel("Hike name")
                    .accessibilityIdentifier("hike-title-field")
                    .focused($isTitleFieldFocused)
                    .onAppear { isTitleFieldFocused = true }
                    // The return key is the whole of how a rename is
                    // confirmed here, and the keyboard toolbar that used
                    // to carry a *Done* beside it is deliberately gone.
                    //
                    // A `ToolbarItemGroup(placement: .keyboard)` on this
                    // field is what stopped the app ever reporting itself
                    // idle, which XCUITest pays for at 60 seconds a
                    // gesture. On a simulator in the state that provokes
                    // it, `testRenamingAHikeUpdatesItsRow` took 677.9s
                    // across eight of those waits; with this accessory
                    // removed and nothing else changed, 28.3s. Nothing is
                    // spinning — the app sits at 0% CPU throughout — so
                    // what is left over is an animation that never
                    // reports completion, not work.
                    //
                    // It is the accessory arriving and leaving *with the
                    // field* that does it rather than the accessory
                    // itself, and both halves cost 60s. Declared here, the
                    // app stalls from the moment the pencil is tapped.
                    // Hoisted onto the always-present header and gated on
                    // `isEditingTitle`, the keyboard rises clean and the
                    // commit stalls instead, because the button leaves as
                    // the keyboard does — 138.8s, which is the shape #539
                    // was filed on. ``CommunityReviewView`` keeps its own
                    // keyboard *Done*, where it is the only way to reach
                    // the decision, and measures clean at 20.5s on the
                    // same simulator: there both the field and the
                    // accessory are always in the hierarchy.
                    .submitLabel(.done)
                    .onSubmit { commitTitleEdit() }
            } else {
                Text(hike.displayTitle)
                    .accessibilityAddTraits(.isHeader)
            }
        } subtitle: {
            dateAndActions
        }
    }

    /// The four glyphs used to follow the name on its own line, where their
    /// tap targets — 44pt each, so up to 176pt of the row — left a long title
    /// wrapping after a word or two. They sit on the date's line instead: the
    /// date is the shortest text on the screen, so it leaves them room without
    /// the name having to give any up, and the name now gets the full width.
    private var dateAndActions: some View {
        HStack(spacing: 0) {
            Text(hike.date.formatted(date: .abbreviated, time: .omitted))

            Spacer(minLength: 8)

            shareButton
            archiveButton
            communityShareButton
            renameButton
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
            interaction.titleDraft = hike.displayTitle
            interaction.isEditingTitle = true
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
        hike.customName = HikeTitle.bounded(interaction.titleDraft)
        isTitleFieldFocused = false
        interaction.isEditingTitle = false
    }

    // MARK: Stats

    private var statsSummary: some View {
        StatSummary(stats: statItems)
    }

    // MARK: Photos

    /// Always drawn, on every hike: the strip when there are photos, and the
    /// offer to go and find some either way. See ``HikePhotoSection``.
    private var photoSection: some View {
        HikePhotoSection(hike: hike, mapPins: photoPins, onOpen: onOpenPhoto)
    }

    /// The places marked along this trail, and the pins that draw them.
    ///
    /// Its own view for the reason every other section here is one — see
    /// ``HikePlaceSection``, which also carries why this screen only *reads*
    /// them.
    private var placeSection: some View {
        HikePlaceSection(hike: hike, mapPins: placePins) { place in
            // The same span a photograph's *Show on map* frames, because it is
            // the same question — see ``MapController/showPhotoSpot(_:)``.
            mapController.showPhotoSpot(place.clCoordinate)
            onZoomToRoute()
        }
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
        hike.trackDescription != nil
            || hike.author != nil
            || hike.importedAuthorName != nil
            || hike.keywords != nil
    }

    /// GPX metadata, plus the one credit that does not come from a file.
    ///
    /// ``Hike/importedAuthorName`` is a name a person typed into this app in
    /// order to be credited by it, and until this row existed it was collected
    /// at the moment of saving and then drawn nowhere: the preview screen is
    /// headed *Shared by Anna*, and the hike it saves appears in the library
    /// as one of the hiker's own. For a hike imported with no description that
    /// went further than losing a line — ``hasMetadata`` was false, so the
    /// whole section was absent and the screen had no place the credit could
    /// have been.
    ///
    /// Labelled *Shared by* rather than *Author*, and a separate row rather
    /// than a fallback into that one, because the two are different claims.
    /// ``Hike/author`` is whatever a GPX file's `<author>` element said, which
    /// this app neither vouches for nor collected; this is somebody who
    /// published a walk here. Only one of them is ever set today — the
    /// community import writes no `author` — but a row that can say which it
    /// is costs nothing and cannot mislead later.
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let description = hike.trackDescription { DetailRow(label: "Description", value: description) }
            if let author = hike.author { DetailRow(label: "Author", value: author) }
            if let sharedBy = hike.importedAuthorName { DetailRow(label: "Shared by", value: sharedBy) }
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
            WalkControls(hike: hike, session: walkSession, profile: profile, onOpenWalk: onOpenWalk)
        }
    }

    // MARK: Auto-follow

    /// Projects each published fix onto the route while following is on or
    /// this hike has a walk under way. Only following moves the chart and
    /// persistent tracker; the walk and its feeds keep taking matches either
    /// way. Runs while this hike stays selected; cancelled when it changes.
    ///
    /// Driven by ``LocationManager/fixes`` rather than by a 1 Hz timer: the
    /// source already throttles to one publish a second and already drops a
    /// repeat of the last coordinate, so this now stops entirely while the
    /// hiker is standing still instead of re-deriving the same match once a
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
    private func clearLiveFollow(profile: RouteProfile) {
        // Guarded so a run of off-route fixes (nil already) doesn't write
        // `tracker` for nothing.
        if tracker.liveTrackerDistance != nil {
            tracker.liveTrackerDistance = nil
        }
        // An active walk still reports losing the route with its chart off.
        // A paused walk is left alone: the widget says Paused, and that stands.
        if hike.autoFollowEnabled || walkSession.isWalking(hike.id),
           walkSession.publishes(hikeID: hike.id) {
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
        // nothing about where the hiker is relative to the route, and must
        // neither re-arm the whole-route search nor spend one of the fixes
        // that delays it.
        // Before the match, so a walk left unmatched for six hours is closed
        // on the fix that would otherwise have quietly extended it.
        walkSession.endIfAbandoned()
        guard hike.autoFollowEnabled || walkSession.isWalking(hike.id),
              let fix = locationManager.routeFix(
                maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
              ) else {
            clearLiveFollow(profile: profile)
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
            // Leaving the route is what rearms the offer after an End or an
            // Ignore: the hiker is off this trail, so coming back is a new walk.
            walkSession.recordOffRoute(hikeID: hike.id, offRouteMeters: match?.offRouteMeters)
            clearLiveFollow(profile: profile)
            return
        }
        followAnchor = .matched(at: match.distanceAlongRoute, course: fix.course, from: followAnchor)
        // The walk is offered here, on the first matched fix with following
        // on, and this is where every later match extends it once the hiker
        // has said Start. Selection alone offers nothing.
        let completedWalk = walkSession.recordForegroundMatch(
            hike: hike,
            profile: profile,
            distance: match.distanceAlongRoute,
            at: fix.timestamp
        )
        if hike.autoFollowEnabled {
            updateLiveTracker(distance: match.distanceAlongRoute)
        }
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

    /// Updates only the detail's live display. Scrubbing parks the manual
    /// tracker without suspending the walk's widget or Lock Screen feed.
    private func updateLiveTracker(distance: Double) {
        let moved = tracker.liveTrackerDistance != distance
        // Guarded like `trackerDistance` below — reassigning `@Observable`
        // storage to an equal value still triggers dependent views, so an
        // unconditional write here would invalidate `ElevationChartView` (and,
        // previously, `HikeDetailView` itself) on every fix that matched to
        // the same place too.
        if moved { tracker.liveTrackerDistance = distance }
        // Don't fight an in-progress manual scrub; the live dot still moves,
        // but the persistent tracker stays under the user's finger.
        guard FollowInteractionPolicy.appliesMatchToPersistentTracker(
            isScrubbing: isScrubbing
        ) else {
            return
        }
        // Skip the tracker write when the projected position hasn't actually
        // moved (e.g. paused, or GPS noise below the route-matching
        // resolution) — avoids a redundant `TrackerState` update on a fix that
        // projects to the same distance along the route.
        if tracker.trackerDistance != distance {
            tracker.trackerDistance = distance
        }
        // Auto-follow owns the map: the live location puck already shows
        // where the user is, so the custom pin stays hidden here rather than
        // sitting on top of (and fading against) it. It only reappears while
        // the user is scrubbing the elevation graph, to compare other
        // sections of the trail. Clearing an already-clear highlight is free —
        // `move(to:)` does the comparison this path used to do by hand.
        highlight.move(to: nil)
    }

}
