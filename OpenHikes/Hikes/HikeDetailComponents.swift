//
//  HikeDetailComponents.swift
//  OpenHikes
//
//  Helper views used only by HikeDetailView.
//

import SwiftUI

/// How far along the trail the tracked position is, as a percentage and a
/// bar.
///
/// Isolated for the same reason `ElevationChartView` is: it reads
/// `TrackerState` directly, so an auto-follow tick invalidates this row alone
/// rather than `HikeDetailView.body`. It also makes a bad route match legible
/// — "97%" while standing at the trailhead is the symptom that a fix was
/// matched to the wrong leg of an out-and-back, which a marker on a graph
/// hides far better than a number does.
struct TrailProgressView: View {
    let profile: RouteProfile
    let tint: Color
    /// Tracker/live-follow positions — see ``TrackerState``.
    let tracker: TrackerState

    var body: some View {
        // The live match when auto-follow has one, otherwise wherever the
        // tracker was last left: a scrub, or the start of the trail.
        let live = tracker.liveTrackerDistance
        let distance = live ?? tracker.trackerDistance
        let fraction = profile.fractionComplete(atDistance: distance) ?? 0
        let remaining = profile.remainingDistanceMeters(atDistance: distance)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(
                    live == nil ? "Trail Progress" : "Live Progress",
                    systemImage: live == nil
                        ? "point.topleft.down.to.point.bottomright.curvepath"
                        : "location.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(live == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.blue))

                Spacer()

                Text("\(Int((fraction * 100).rounded()))% · \(Self.length(remaining)) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live == nil ? "Trail progress" : "Live trail progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent, \(Self.length(remaining)) remaining")
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Keeps route-tint updates local to the header symbol.
struct HikeHeaderSymbol: View {
    private static let size: CGFloat = 56
    private static let cornerRadius: CGFloat = 14

    let hike: Hike

    var body: some View {
        Image(systemName: hike.symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(
                hike.tintOpaque,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius)
            )
            .accessibilityHidden(true)
    }
}

/// Keeps route-tint changes inside the chart wrapper while tracker updates
/// continue to invalidate only `ElevationChartView`.
struct HikeElevationChart: View {
    let hike: Hike
    let profile: RouteProfile
    let tracker: TrackerState
    let onScrub: (Double) -> Void
    let onScrubbingChanged: (Bool) -> Void

    var body: some View {
        ElevationChartView(
            profile: profile,
            tint: hike.tintOpaque,
            tracker: tracker,
            onScrub: onScrub,
            onScrubbingChanged: onScrubbingChanged
        )
        .equatable()
    }
}

/// Keeps the progress-bar tint observation out of `HikeDetailView.body`.
struct HikeTrailProgress: View {
    let hike: Hike
    let profile: RouteProfile
    let tracker: TrackerState

    var body: some View {
        TrailProgressView(
            profile: profile,
            tint: hike.tintOpaque,
            tracker: tracker
        )
    }
}

/// Keeps the empty chart's tint observation out of `HikeDetailView.body`.
struct HikeElevationPlaceholder: View {
    private static let tintOpacity = 0.12

    let hike: Hike

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    hike.tintOpaque.opacity(Self.tintOpacity)
                )
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

/// Owns appearance-control observations while preserving the action bar's
/// original action, toggle, and width-control order.
struct RouteAppearanceControls<
    Actions: View,
    MiddleControls: View
>: View {
    let hike: Hike
    private let actions: Actions
    private let middleControls: MiddleControls

    init(
        hike: Hike,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder middleControls: () -> MiddleControls
    ) {
        self.hike = hike
        self.actions = actions()
        self.middleControls = middleControls()
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                actions
                colorControl
            }
            middleControls
            widthSlider
            RouteLinePatternPicker(hike: hike)
        }
    }

    private var colorControl: some View {
        tile {
            ColorPicker(
                "Route color",
                selection: tintBinding,
                supportsOpacity: true
            )
            .labelsHidden()
            Text("Color")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                // `labelsHidden()` keeps the picker's spoken name, so this
                // caption is a second stop that repeats it.
                .accessibilityHidden(true)
        }
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
            // The caption row is what the slider's own label and value say, so
            // it is not a stop of its own.
            .accessibilityHidden(true)
            Slider(value: widthBinding, in: 1...12, step: 1)
                .tint(hike.tintOpaque)
                .accessibilityLabel("Line width")
                .accessibilityValue("\(Int(hike.routeWidth)) points")
                .accessibilityIdentifier("route-width-slider")
        }
    }

    private var tintBinding: Binding<Color> {
        Binding(
            get: { hike.tint },
            set: { hike.tintHex = $0.hexRGBA }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { hike.routeWidth },
            set: { hike.routeWidth = $0 }
        )
    }

    private func tile<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: 5) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Owns the high-frequency download observations so per-tile progress only
/// rebuilds this tile rather than the entire hike detail hierarchy.
struct OfflineDownloadButton: View {
    let downloader: OfflineTileDownloader
    let canDownload: Bool
    let start: () -> Void

    var body: some View {
        Button {
            if downloader.phase == .downloading {
                downloader.cancel()
            } else {
                start()
            }
        } label: {
            tile
        }
        .buttonStyle(.plain)
        .disabled(!canDownload && downloader.phase != .downloading)
        // The tile's text is a bare "45%" or "Saved", which says nothing about
        // what the button does — so the action is named here and the progress
        // is carried as the value.
        .accessibilityLabel(
            downloader.phase == .downloading
                ? "Cancel offline map download"
                : "Save maps for offline use"
        )
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("offline-download-button")
    }

    private var accessibilityValue: String {
        switch downloader.phase {
        case .downloading:
            downloader.progress.formatted(.percent.precision(.fractionLength(0)))
        case .finished: "Saved"
        case .failed: "Failed"
        case .idle: "Not saved"
        }
    }

    @ViewBuilder private var tile: some View {
        switch downloader.phase {
        case .downloading:
            actionTile {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .finished:
            actionTile(tint: .green) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Saved").font(.caption2.weight(.medium))
            }
        default:
            actionTile(tint: canDownload ? .accentColor : .secondary) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Offline").font(.caption2.weight(.medium))
            }
        }
    }

    private func actionTile<Content: View>(
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 5) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(tint)
    }
}

/// Keeps the per-tile `total` observation out of `HikeDetailView.body`.
struct OfflineDownloadStatus: View {
    let downloader: OfflineTileDownloader
    let idleNote: String?

    private var note: String? {
        switch downloader.phase {
        case .failed(let message): message
        case .finished: "Saved for offline use."
        case .downloading: downloader.total == 0
            ? "Preparing offline tiles…"
            : "Saving \(downloader.total) tiles…"
        case .idle: idleNote
        }
    }

    var body: some View {
        if let note {
            Text(note)
                .font(.caption2)
                .foregroundStyle(downloader.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }
}

/// Owns auto-save manifest observations so each drain updates only the note
/// and storage row. The parent is notified only when a debounced byte
/// measurement should be scheduled.
struct OfflineStorageStatus: View {
    let hike: Hike
    let autoSave: AutoSaveController
    let downloader: OfflineTileDownloader
    let storedBytes: Int64?
    let scheduleStoredBytesRefresh: () -> Void
    let deleteStoredTiles: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            OfflineDownloadStatus(
                downloader: downloader,
                idleNote: autoSaveNote
            )
            storedTilesRow
        }
        .onChange(of: hike.autoSavedTileKeys.count) { _, _ in
            scheduleStoredBytesRefresh()
        }
    }

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

    @ViewBuilder private var storedTilesRow: some View {
        if !hike.offlineDownloads.isEmpty || !hike.autoSavedTileKeys.isEmpty {
            HStack {
                Label(
                    storedBytes.map { bytes in
                        "Offline tiles · \(Self.byteText(bytes))"
                    } ?? "Offline tiles",
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Offline tiles")
                .accessibilityValue(storedBytes.map(Self.byteText) ?? "Measuring")

                Spacer()

                Button(
                    role: .destructive,
                    action: deleteStoredTiles
                ) {
                    Text("Delete").font(.caption.weight(.medium))
                }
                .glassButtonStyle()
                .controlSize(.small)
                // "Delete" alone doesn't say what goes.
                .accessibilityLabel("Delete this hike's offline tiles")
                .accessibilityIdentifier("delete-offline-tiles-button")
            }
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }
}
