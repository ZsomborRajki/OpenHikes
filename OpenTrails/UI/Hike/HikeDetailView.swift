//
//  HikeDetailView.swift
//  OpenTrails
//
//  Pushed when a hike is selected. Surfaces every stat we can derive from the
//  GPX file, with an interactive elevation graph at the top.
//

import SwiftUI

/// The elevation graph's tracker positions, held in a reference type so the
/// once-a-second auto-follow poll moves the chart without re-rendering the
/// rest of `HikeDetailView` (header, stats grid, buttons) — the same
/// technique `RouteHighlight`/`SheetMetrics` use for the map. `HikeDetailView`
/// only ever passes this object down; it never reads its properties directly,
/// so mutating them invalidates `ElevationChartView` (which does read them)
/// and nothing above it.
@MainActor
@Observable
final class TrackerState {
    /// Persistent tracker position along the route (metres from start). Starts
    /// at the GPX start, follows the finger while scrubbing, and stays where
    /// it's left.
    var trackerDistance: Double = 0
    /// The user's live GPS fix projected onto the route (metres from start), or
    /// `nil` when auto-follow is off, there's no fix, or the fix is too far
    /// from the trail to match.
    var liveTrackerDistance: Double?
}

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
    /// widget/Watch stay reasonably fresh while this hike is being viewed.
    let backgroundTracker: BackgroundTrailTracker
    /// Collapses the sheet so the map is visible when zooming to the route.
    var onZoomToRoute: () -> Void = {}

    /// The active tile source, mirrored from Settings so offline downloads use the
    /// same provider (and API key) the map is currently drawing.
    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id
    @Environment(\.displayScale) private var displayScale
    @State private var downloader = OfflineTileDownloader()
    /// Disk space used by this hike's saved tiles; `nil` until measured.
    @State private var storedBytes: Int64?

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
    /// Whether auto-follow has matched a fix at least once since this hike
    /// was selected. `trackerDistance` starts at 0 on every selection — that's
    /// a placeholder, not a real previous position, so it can't be trusted as
    /// a tie-break anchor until a real match has actually happened. Once one
    /// has, `trackerDistance` holds a genuine last-known position, and *should*
    /// anchor ties again if the fix is briefly lost and reacquired.
    @State private var hasMatchedOnce = false

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
                header
                statsGrid
                if hasMetadata { metadataSection }
                actionBar
            }
            .padding()
        }
        .navigationTitle(hike.title)
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
            hasMatchedOnce = false
            highlight.move(to: built.coordinate(atDistance: 0))
            refreshStoredBytes()
            autoSave.hikeSelectionChanged(to: hike)
            await followLocation(profile: built)
        }
        // Toggling off should clear the live dot immediately, not wait for the
        // next throttled poll. Toggling on should hand the map pin back to
        // auto-follow right away, rather than leaving a stale manual pin up
        // to a second until the next poll clears it.
        .onChange(of: hike.autoFollowEnabled) { _, enabled in
            if enabled {
                if !isScrubbing { highlight.move(to: nil) }
            } else {
                tracker.liveTrackerDistance = nil
                // Hand the pin back to the persistent tracker so it reappears
                // at the last-followed/scrubbed position instead of staying
                // hidden from auto-follow's ownership of the map.
                if !isScrubbing {
                    highlight.move(to: profile?.coordinate(atDistance: tracker.trackerDistance))
                }
            }
        }
        // Record the download once it finishes, so its tiles can be measured/removed.
        .onChange(of: downloader.phase) { _, phase in
            guard phase == .finished else { return }
            let record = OfflineDownloadRecord(
                providerID: activeTileSource.providerID,
                scale: Double(displayScale),
                maxZoom: activeTileSource.maximumZ
            )
            if !hike.offlineDownloads.contains(record) { hike.offlineDownloads.append(record) }
            refreshStoredBytes()
        }
        // Keeps the byte count live as the background auto-save drain grows it.
        // Watches `.count`, not the array itself — comparing two multi-thousand-
        // element `[String]`s on every drain cycle is itself main-thread work.
        .onChange(of: hike.autoSavedTileKeys.count) { _, _ in refreshStoredBytes() }
    }

    // MARK: Offline storage

    /// Measures this hike's saved tiles off the main thread. Deliberately reads
    /// only plain, cheap properties here (array references, not `.coordinates`,
    /// which remaps the whole route) — everything expensive (tile-grid
    /// enumeration across every download record, the keys `Set` union, and the
    /// disk stat calls) happens inside the detached task. This runs on every
    /// auto-save drain cycle while the user is actively panning the map, so
    /// anything synchronous here is felt as a UI hitch.
    private func refreshStoredBytes() {
        let route = hike.route
        let offlineDownloads = hike.offlineDownloads
        let autoSavedTileKeys = hike.autoSavedTileKeys
        guard !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty else { storedBytes = 0; return }
        Task {
            storedBytes = await Task.detached {
                let coordinates = route.map(\.clCoordinate)
                let keys = Array(
                    Set(OfflineTileDownloader.storedTileKeys(route: coordinates, offlineDownloads: offlineDownloads))
                        .union(autoSavedTileKeys)
                )
                return TileCache.shared.bytes(forKeys: keys)
            }.value
        }
    }

    /// Forgets this hike's downloads and auto-saved tiles, and deletes them from
    /// disk. The key computation (tile-grid enumeration per download record) is
    /// real CPU work, so it's done inside the detached task, mirroring
    /// ``refreshStoredBytes()``.
    private func deleteStoredTiles() {
        // First, and before the manifest is read: switching auto-save off folds
        // in the tiles saved since the last drain. Reading the manifest ahead of
        // that would delete a snapshot taken up to two seconds ago and strand
        // everything saved since — durably, where nothing would reclaim it.
        autoSave.setEnabled(false, for: hike)
        let route = hike.route
        let offlineDownloads = hike.offlineDownloads
        let autoSavedTileKeys = hike.autoSavedTileKeys
        hike.offlineDownloads.removeAll()
        hike.autoSavedTileKeys.removeAll()
        storedBytes = 0
        downloader.reset()
        Task.detached {
            let coordinates = route.map(\.clCoordinate)
            let keys = Array(
                Set(OfflineTileDownloader.storedTileKeys(route: coordinates, offlineDownloads: offlineDownloads))
                    .union(autoSavedTileKeys)
            )
            TileCache.shared.removeTiles(forKeys: keys)
        }
    }

    @ViewBuilder
    private var storedTilesRow: some View {
        if !hike.offlineDownloads.isEmpty || !hike.autoSavedTileKeys.isEmpty {
            HStack {
                Label(
                    storedBytes.map { "Offline tiles · \(Self.byteText($0))" } ?? "Offline tiles",
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive, action: deleteStoredTiles) {
                    Text("Delete").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Actions

    /// Trailing row of actions: zoom the map to the route, save it for offline use,
    /// and recolor the route line.
    private var actionBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                zoomButton
                if activeProvider.supportsBulkDownload { downloadButton }
                colorControl
            }
            autoSaveToggle
            autoFollowToggle
            widthSlider
            if let note = downloadNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(downloader.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
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

    private var downloadButton: some View {
        Button {
            if downloader.phase == .downloading {
                downloader.cancel()
            } else {
                downloader.start(route: hike.coordinates, source: activeTileSource, scale: displayScale)
            }
        } label: {
            downloadTile
        }
        .buttonStyle(.plain)
        .disabled(!canDownload && downloader.phase != .downloading)
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

    @ViewBuilder
    private var downloadTile: some View {
        switch downloader.phase {
        case .downloading:
            tile {
                ProgressView().controlSize(.small)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .finished:
            actionTile(icon: "checkmark.circle.fill", title: "Saved", tint: .green)
        default:
            actionTile(icon: "arrow.down.circle", title: "Offline",
                       tint: canDownload ? Color.accentColor : .secondary)
        }
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

    private var downloadNote: String? {
        switch downloader.phase {
        case .failed(let message): return message
        case .finished: return "Saved for offline use."
        case .downloading: return "Saving \(downloader.total) tiles…"
        case .idle: return autoSaveNote
        }
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
            Image(systemName: icon).font(.title3)
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: hike.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(hike.tintOpaque, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(hike.title)
                    .font(.title2.bold())
                Text(hike.date.formatted(date: .complete, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
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

    @ViewBuilder
    private var elevationSection: some View {
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
                    if !scrubbing && hike.autoFollowEnabled {
                        highlight.move(to: nil)
                    }
                }
            )
            .equatable()
        } else {
            elevationPlaceholder
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
              let coordinate = locationManager.coordinate,
              let match = profile.nearestPoint(
                to: coordinate,
                near: hasMatchedOnce ? (tracker.liveTrackerDistance ?? tracker.trackerDistance) : nil
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
        hasMatchedOnce = true
        let moved = tracker.liveTrackerDistance != match.distanceAlongRoute
        // Guarded like `trackerDistance` below — reassigning `@Observable`
        // storage to an equal value still triggers dependent views, so an
        // unconditional write here would invalidate `ElevationChartView` (and,
        // previously, `HikeDetailView` itself) on every "unchanged" poll too.
        if moved { tracker.liveTrackerDistance = match.distanceAlongRoute }
        // Don't fight an in-progress manual scrub; the live dot still moves,
        // but the persistent tracker stays under the user's finger.
        guard !isScrubbing else {
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

    private var elevationPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(hike.tintOpaque.opacity(0.12))
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.largeTitle)
                    .foregroundStyle(hike.tintOpaque)
                Text("No elevation data in this file")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
    }
}

