//
//  HikeDetailView.swift
//  OpenTrails
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
    /// Source of the user's live location, polled (throttled) to drive auto-follow.
    let locationManager: LocationManager
    /// Fed the same auto-follow matches as the chart/map, throttled, so the
    /// widget stays reasonably fresh while this hike is being viewed.
    let backgroundTracker: BackgroundTrailTracker
    /// Collapses the sheet so the map is visible when zooming to the route.
    var onZoomToRoute: () -> Void = { /* no-op default */ }

    /// The active tile source, mirrored from Settings so offline downloads use the
    /// same provider (and API key) the map is currently drawing.
    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id
    @Environment(\.displayScale)
    private var displayScale
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
    @State var storageDeletionFailed = false
    /// Whether the title is currently being edited inline.
    @State private var isEditingTitle = false
    /// Draft text while the inline title field is open.
    @State private var titleDraft = ""
    private static let storedBytesRefreshDebounce: Duration = .seconds(5)

    /// Built once per hike in `.task`, never in `init`. Scrubbing then resolves
    /// points in O(log n).
    @State private var profile: RouteProfile?
    /// Stat tiles, computed once per hike (each stat is an O(n) pass over the
    /// route, so they must not be recomputed on every body invalidation).
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
    /// ``RouteProfile/nearestPoint(to:near:heading:)`` to work out the leg
    /// from scratch rather than continue from a position.
    @State private var followAnchor: FollowAnchor?

    var body: some View {
        // Fires on every re-evaluation of this view's body. Auto-follow's
        // once-a-second tracker updates should NOT show up here — they live in
        // `tracker` (a `TrackerState`), which this body never reads, so those
        // updates invalidate only `ElevationChartView` below. If this mark
        // starts firing at that cadence again, something re-introduced a read
        // of `tracker`'s properties into this body (directly or via a
        // computed var it calls, like `elevationSection`).
        RenderSignpost.mark("HikeDetailBody")
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                elevationSection
                progressSection
                header
                statsGrid
                if hasMetadata { metadataSection }
                actionBar
            }
            .padding()
        }
        .navigationTitle(hike.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: hike.id) {
            let built = RouteProfile(route: hike.route)
            profile = built
            statItems = Self.makeStats(for: hike)
            // Place the tracker at the start of the track, on both graph and map.
            tracker.trackerDistance = 0
            tracker.liveTrackerDistance = nil
            followAnchor = nil
            highlight.move(to: built.coordinate(atDistance: 0))
            refreshStoredBytes()
            autoSave.hikeSelectionChanged(to: hike)
            // Keep the first live fix from racing the widget's initial trail snapshot.
            await backgroundTracker.waitForSelectionPublish()
            await followLocation(profile: built)
        }
        // Toggling off should clear the live dot immediately, not wait for the
        // next throttled poll. Toggling on should hand the map pin back to
        // auto-follow right away, rather than leaving a stale manual pin up
        // to a second until the next poll clears it.
        .onChange(of: hike.autoFollowEnabled) { _, enabled in
            if !enabled {
                tracker.liveTrackerDistance = nil
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
        }
        // Record verified coverage from complete and partial downloads so
        // storage accounting never claims tiles that failed to reach disk.
        .onChange(of: downloader.phase) { _, phase in
            guard phase != .downloading, let record = downloader.completedRecord else { return }
            hike.mergeOfflineDownload(record)
            refreshStoredBytes()
        }
        // Keeps the byte count live as the background auto-save drain grows it.
        // Watches `.count`, not the array itself — comparing two multi-thousand-
        // element `[String]`s on every drain cycle is itself main-thread work.
        .onChange(of: hike.autoSavedTileKeys.count) { _, _ in scheduleStoredBytesRefresh() }
        .task {
            // A trailing measurement, once the auto-save drain settles. The
            // task's own lifetime retires it when the view goes away, so
            // there's no timer to cancel by hand.
            for await generation in storedBytesRefreshes.stream
                .debounce(for: Self.storedBytesRefreshDebounce) {
                guard generation == storedBytesMeasurementGeneration else {
                    continue
                }
                refreshStoredBytes()
            }
        }
        .onDisappear {
            invalidateStoredBytesMeasurement()
        }
        .alert("Couldn’t Delete Offline Tiles", isPresented: $storageDeletionFailed) {
            Button("OK", role: .cancel) { /* dismiss */ }
        } message: {
            Text("OpenTrails couldn’t read the other hikes’ offline coverage. No tiles were deleted.")
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
            HStack(spacing: 12) {
                zoomButton
                if activeProvider.supportsBulkDownload {
                    OfflineDownloadButton(
                        downloader: downloader,
                        canDownload: canDownload
                    ) {
                        downloader.start(
                            route: hike.coordinates,
                            source: activeTileSource,
                            scale: displayScale
                        )
                    }
                }
                colorControl
            }
            autoSaveToggle
            autoFollowToggle
            widthSlider
            OfflineDownloadStatus(downloader: downloader, idleNote: autoSaveNote)
            storedTilesRow
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

    /// Passive gap-filler alongside (or instead of) the bulk `downloadButton`:
    /// saves tiles as they're actually browsed, so areas a bulk download
    /// missed — or, for OSM-style providers, everything — still end up saved.
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
    /// trail. On by default; the throttled poll in `followLocation` does the work.
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

    private var colorControl: some View {
        tile {
            // `supportsOpacity` lets the user set the line's transparency here; the
            // alpha is applied to the map polyline only (other UI uses `tintOpaque`).
            ColorPicker("Route color", selection: tintBinding, supportsOpacity: true)
                .labelsHidden()
            Text("Color")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Reads the hike's tint and writes the picked color (with alpha) back as
    /// "#RRGGBBAA", which live-updates the map polyline.
    private var tintBinding: Binding<Color> {
        Binding(get: { hike.tint }, set: { hike.tintHex = $0.hexRGBA })
    }

    private var widthSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label("Line width", systemImage: "lineweight")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(hike.routeWidth)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: widthBinding, in: 1...12, step: 1)
                .tint(hike.tintOpaque)
        }
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { hike.routeWidth }, set: { hike.routeWidth = $0 })
    }

    private var canDownload: Bool {
        activeProvider.supportsBulkDownload && hike.pointCount > 1
    }

    /// Status copy for auto-save — the only offline note for OSM-style
    /// providers, and the fallback once a bulk download (if any) is idle.
    private var autoSaveNote: String? {
        guard hike.autoSaveTilesEnabled else {
            return "Turn on Auto-Save, then pan and zoom around the trail to save its tiles for offline use."
        }
        let count = hike.autoSavedTileKeys.count
        if autoSave.isCapReached(for: hike) {
            return "Auto-saved \(count) tiles near the trail — storage limit reached."
        }
        return "Auto-saving tiles near the trail as you browse (\(count) so far)."
    }

    private func actionTile(icon: String, title: String, tint: Color = .accentColor) -> some View {
        tile {
            Image(systemName: icon)
                .font(.title3)
                .accessibilityHidden(true)
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 5) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// `renderable`, not `provider`: this drives whether a bulk download is
    /// offered at all, so it has to name the source the map is really drawing.
    private var activeProvider: TileProvider { .renderable(id: tileProviderID) }

    private var activeTileSource: ActiveTileSource { ActiveTileSource(activeProvider) }

    private enum HeaderLayout {
        static let symbolSize: CGFloat = 56
        static let symbolCornerRadius: CGFloat = 14
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: hike.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: HeaderLayout.symbolSize, height: HeaderLayout.symbolSize)
                .background(hike.tintOpaque, in: RoundedRectangle(cornerRadius: HeaderLayout.symbolCornerRadius))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if isEditingTitle {
                    TextField(hike.title, text: $titleDraft)
                        .font(.title2.bold())
                        .onSubmit { commitTitleEdit() }
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { commitTitleEdit() }
                            }
                        }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(hike.displayTitle)
                            .font(.title2.bold())
                        Button {
                            titleDraft = hike.displayTitle
                            isEditingTitle = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename hike")
                    }
                }
                Text(hike.date.formatted(date: .complete, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        hike.customName = trimmed.isEmpty ? nil : trimmed
        isEditingTitle = false
    }

    // MARK: Stats

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            ForEach(statItems) { stat in
                StatTile(label: stat.label, value: stat.value)
            }
        }
    }

    private static func makeStats(for hike: Hike) -> [Stat] {
        var items: [Stat] = [
            Stat("Distance", hike.distance.formatted(.measurement(width: .abbreviated, usage: .road)))
        ]
        if let duration = hike.duration { items.append(Stat("Duration", HikeFormat.duration(duration))) }
        if let gain = hike.elevationGain { items.append(Stat("Elevation Gain", HikeFormat.length(gain))) }
        if let loss = hike.elevationLoss { items.append(Stat("Elevation Loss", HikeFormat.length(loss))) }
        if let maxEl = hike.maxElevation { items.append(Stat("Max Elevation", HikeFormat.length(maxEl))) }
        if let minEl = hike.minElevation { items.append(Stat("Min Elevation", HikeFormat.length(minEl))) }
        if let avg = hike.averageSpeed { items.append(Stat("Avg Speed", HikeFormat.speed(avg))) }
        if let maxSpeed = hike.maxSpeed { items.append(Stat("Max Speed", HikeFormat.speed(maxSpeed))) }
        items.append(Stat("Track Points", hike.pointCount.formatted()))
        if let start = hike.startDate {
            items.append(Stat("Start", start.formatted(date: .abbreviated, time: .shortened)))
        }
        if let end = hike.endDate {
            items.append(Stat("End", end.formatted(date: .abbreviated, time: .shortened)))
        }
        return items
    }

    // MARK: Metadata

    private var hasMetadata: Bool {
        hike.trackDescription != nil || hike.author != nil || hike.keywords != nil
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details").font(.headline)
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
            // `Equatable` still covers slider/color churn (tint/profile changes).
            ElevationChartView(
                profile: profile,
                tint: hike.tintOpaque,
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
            .equatable()
        } else {
            elevationPlaceholder
        }
    }

    // MARK: Progress

    /// How far along the trail the tracked position is. Like the chart, this
    /// is handed `tracker` as a reference and never reads it here, so the
    /// once-a-second auto-follow tick redraws the bar and nothing above it.
    @ViewBuilder private var progressSection: some View {
        if let profile, profile.totalDistanceMeters > 0 {
            TrailProgressView(profile: profile, tint: hike.tintOpaque, tracker: tracker)
        }
    }

    // MARK: Auto-follow

    /// Polls the user's location once a second (throttled — GPS fixes can arrive
    /// far more often than that) and, while auto-follow is on, projects it onto
    /// the route to drive both the live chart marker and the persistent tracker.
    /// Runs for as long as this hike stays selected; cancelled when it changes.
    private func followLocation(profile: RouteProfile) async {
        while !Task.isCancelled {
            updateLiveFollow(profile: profile)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func updateLiveFollow(profile: RouteProfile) {
        guard hike.autoFollowEnabled,
              let fix = locationManager.routeFix(
                maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
              ),
              let match = profile.nearestPoint(
                to: fix.coordinate,
                near: FollowAnchor.tieBreak(followAnchor, course: fix.course),
                heading: fix.course
              ),
              match.offRouteMeters <= RouteProfile.followMatchThresholdMeters else {
            // Guarded so a stationary/off-route poll (nil already) doesn't
            // write `tracker` every second for nothing.
            if tracker.liveTrackerDistance != nil {
                tracker.liveTrackerDistance = nil
                RenderSignpost.mark("LiveFollowUpdate", "cleared")
            } else {
                RenderSignpost.mark("LiveFollowUpdate", "no-fix-or-off-route")
            }
            // Only worth telling the widget "no fix" while auto-follow is
            // actually trying to track this hike — if the user turned
            // auto-follow off, leave whatever it last showed alone.
            if hike.autoFollowEnabled {
                backgroundTracker.publishLiveFix(hike: hike, profile: profile, match: nil)
            }
            return
        }
        followAnchor = .matched(at: match.distanceAlongRoute, course: fix.course, from: followAnchor)
        let moved = tracker.liveTrackerDistance != match.distanceAlongRoute
        // Guarded like `trackerDistance` below — reassigning `@Observable`
        // storage to an equal value still triggers dependent views, so an
        // unconditional write here would invalidate `ElevationChartView` (and,
        // previously, `HikeDetailView` itself) on every "unchanged" poll too.
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
        // resolution) — avoids a redundant `TrackerState` update every second
        // at rest.
        if tracker.trackerDistance != match.distanceAlongRoute {
            tracker.trackerDistance = match.distanceAlongRoute
        }
        // Auto-follow owns the map: the live location puck already shows
        // where the user is, so the custom pin stays hidden here rather than
        // sitting on top of (and fading against) it. It only reappears while
        // the user is scrubbing the elevation graph, to compare other
        // sections of the trail. Clearing an already-clear highlight is free —
        // `move(to:)` does the comparison this poll used to do by hand.
        highlight.move(to: nil)
        RenderSignpost.mark("LiveFollowUpdate", moved ? "moved" : "unchanged")
        backgroundTracker.publishLiveFix(hike: hike, profile: profile, match: match)
    }

    private static let placeholderTintOpacity = 0.12

    private var elevationPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(hike.tintOpaque.opacity(Self.placeholderTintOpacity))
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.largeTitle)
                    .foregroundStyle(hike.tintOpaque)
                    .accessibilityHidden(true)
                Text("No elevation data in this file")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
    }
}
