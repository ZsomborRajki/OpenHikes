//
//  HikeDetailComponents.swift
//  OpenHikes
//
//  Helper views used only by HikeDetailView.
//

import OpenHikesData
import OpenHikesShared
import SwiftUI

/// The one tile the hike detail's action row is built from — Zoom, Follow,
/// Offline and Share. See ``HikeActionRow``.
///
/// Liquid Glass rather than the filled `.quaternary` rectangle each of the
/// three used to carry a copy of. These are controls, and glass is the
/// controls layer: the tiles now float over the sheet the way the `.glass`
/// buttons beside them do, and `.interactive()` gives them the same press
/// response, which a filled rectangle behind a `.plain` button never had.
///
/// The read-only ``StatList`` deliberately did *not* move with them. It is
/// content, not a control, and glass drawn behind content inside a glass sheet
/// reads as neither.
struct ActionTile<Content: View>: View {
    private let tint: Color
    private let isProminent: Bool
    private let content: Content

    /// - Parameter isProminent: Fills the glass with `tint` and draws the
    ///   content white — the look of a switch that is on, for the one tile in
    ///   the row that is a switch.
    init(tint: Color = .accentColor, isProminent: Bool = false, @ViewBuilder _ content: () -> Content) {
        self.tint = tint
        self.isProminent = isProminent
        self.content = content()
    }

    var body: some View {
        VStack(spacing: ActionTileMetrics.contentSpacing) { content }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ActionTileMetrics.verticalPadding)
            .glassSurface(
                .regular.tint(isProminent ? tint : nil).interactive(),
                in: .rect(cornerRadius: ActionTileMetrics.cornerRadius)
            )
            .foregroundStyle(isProminent ? Color.white : tint)
    }
}

nonisolated enum ActionTileMetrics {
    static let cornerRadius: CGFloat = 12
    static let contentSpacing: CGFloat = 5
    static let verticalPadding: CGFloat = 8
    /// Under the 12pt gap between tiles, so a row reads as separate targets at
    /// rest and merges as it tightens.
    static let glassSpacing: CGFloat = 10
}

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
    /// The hike this row is drawn for, so it knows whether the walk under
    /// way is its own.
    var hikeID: UUID?
    /// The walk under way, if any — see ``TrailWalkSession``. Read here for
    /// the same reason `tracker` is: a matched fix that extends the walk
    /// redraws this row and nothing above it.
    var walk: TrailWalkSession?

    var body: some View {
        // The live match when auto-follow has one, otherwise wherever the
        // tracker was last left: a scrub, or the start of the trail.
        let live = tracker.liveTrackerDistance
        let distance = live ?? tracker.trackerDistance
        // While this hike is being walked, the figure is coverage: what the
        // walk has actually spanned rather than where the hiker stands.
        let walked = walk.flatMap { session in
            session.walkedHikeID == hikeID ? session.coveredFraction : nil
        }
        // Both figures describe coverage during a walk, including a reverse
        // walk or one with gaps. The chart's manual position is independent.
        let remaining = walked.map { (1 - $0) * profile.totalDistanceMeters }
            ?? profile.remainingDistanceMeters(atDistance: distance)
        let fraction = walked ?? profile.fractionComplete(atDistance: distance) ?? 0
        let percent = Int((fraction * 100).rounded())
        let caption = walked == nil ? "\(percent)%" : "\(percent)% walked"
        // How long that is, while a walk is under way — the rest of the route
        // at this walk's own pace. Read here, per matched fix, for the reason
        // the coverage is: this row and nothing above it redraws.
        let timeLeft = walked == nil ? nil : walk?.secondsLeft()
        let left = timeLeft.map { "\(Self.length(remaining)) · \(HikeFormat.travelTime($0)) left" }
            ?? "\(Self.length(remaining)) left"

        VStack(alignment: .leading, spacing: walked == nil ? 6 : 10) {
            if walked != nil {
                // A walk under way reads like Maps' navigation card: the three
                // numbers a hiker glances down for, big, and the bar under them.
                WalkFigures(remaining: Self.length(remaining), timeLeft: timeLeft)
            } else {
                HStack(spacing: 6) {
                    Label(
                        title(walking: false, live: live != nil),
                        systemImage: symbol(walking: false, live: live != nil)
                    )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(live == nil ? .secondary : Color.blue)

                    Spacer()

                    Text("\(caption) · \(left)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)
            if walked != nil {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(walking: walked != nil, live: live != nil))
        // The covered length as well as the percentage: a percentage of a long
        // trail hides a hiker's first few hundred metres, and this is the
        // value a test waits on to know a fix landed.
        //
        // Through the same formatter as the remaining figure beside it. The
        // word "metres" used to be written into the sentence, so a US hiker
        // heard a distance in metres followed by one in miles.
        .accessibilityValue(
            Self.spokenValue(
                percent: percent,
                covered: walked.map { $0 * profile.totalDistanceMeters },
                timeLeft: timeLeft,
                remaining: remaining
            )
        )
        .accessibilityIdentifier("trail-progress")
    }

    /// Built a clause at a time rather than as one `+` chain inside the
    /// modifier: Xcode 26.6's type checker gives up on the chain, which fails
    /// the CodeQL build while Xcode 27 compiles it.
    private static func spokenValue(
        percent: Int,
        covered: Double?,
        timeLeft: TimeInterval?,
        remaining: Double
    ) -> String {
        let remainingClause = "\(length(remaining)) remaining"
        guard let covered else { return "\(percent) percent, \(remainingClause)" }
        // The time before the distance left rather than after it, so
        // "remaining" stays the last thing said — and the last field, which is
        // what the walk suite reads the distance off.
        var clauses = ["\(percent) percent walked", "\(length(covered)) covered"]
        if let timeLeft {
            clauses.append("about \(HikeFormat.spokenTravelTime(timeLeft)) to go")
        }
        clauses.append(remainingClause)
        return clauses.joined(separator: ", ")
    }

    private func title(walking: Bool, live: Bool) -> String {
        if walking { return "Hike Progress" }
        return live ? "Live Progress" : "Trail Progress"
    }

    private func symbol(walking: Bool, live: Bool) -> String {
        if walking { return "figure.walk" }
        return live ? "location.fill" : "point.topleft.down.to.point.bottomright.curvepath"
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// The walk's own figures, the way Apple Maps' navigation card draws them:
/// how long is left at this walk's pace, how far, and the clock time that
/// puts the hiker at the end.
///
/// Laid out by ``StatStrip``, which turns the three into a column at an
/// accessibility text size. Silent to VoiceOver, like everything else inside
/// ``TrailProgressView``: the row speaks all of it as one value.
private struct WalkFigures: View {
    let remaining: String
    /// `nil` until the walk has a pace to project — the first few hundred
    /// metres — when only the distance is worth a number.
    let timeLeft: TimeInterval?

    var body: some View {
        StatStrip {
            if let timeLeft {
                figure(HikeFormat.travelTime(timeLeft), caption: "left")
            }
            figure(remaining, caption: "to go")
            if let timeLeft {
                figure(
                    Date.now.addingTimeInterval(timeLeft).formatted(date: .omitted, time: .shortened),
                    caption: "arrival"
                )
            }
        }
    }

    private func figure(_ value: String, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(StatCardMetrics.minimumScale)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var walk: TrailWalkSession?

    var body: some View {
        TrailProgressView(
            profile: profile,
            tint: hike.tintOpaque,
            tracker: tracker,
            hikeID: hike.id,
            walk: walk
        )
    }
}

/// Keeps the empty chart's tint observation out of `HikeDetailView.body`.
struct HikeElevationPlaceholder: View {
    let hike: Hike

    var body: some View {
        ElevationPlaceholderView(
            tint: hike.tintOpaque,
            // "in this file" for as long as every hike without heights had
            // arrived as one. A recorded walk with no barometer never had a
            // file, and since the trail maker neither has a drawn trail — which
            // is exactly the hike a free subscriber's drawn trail *always* is,
            // because the heights ride the gate ``StadiaElevationSource``
            // enforces.
            message: "No elevation data for this hike"
        )
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
        // A download is the longest wait in the app and the one a hiker walks
        // away from, so the two ways it settles are worth feeling.
        //
        // The other three are not, and each for its own reason. `downloading`
        // is the wait itself; `idle` is a cancel the hiker asked for a moment
        // ago; and `needsSpace` has not settled at all — it is the run stopping
        // to ask a question, and it raises an alert to ask it. Answering that
        // one belongs with the ambient haptics this change deliberately leaves
        // out, not with the outcomes.
        .sensoryFeedback(trigger: downloader.phase) { _, phase in
            switch phase {
            case .finished: HapticMoment.outcomeSucceeded.feedback
            case .failed: HapticMoment.outcomeFailed.feedback
            case .idle, .downloading, .needsSpace: nil
            }
        }
    }

    private var accessibilityValue: String {
        switch downloader.phase {
        case .downloading:
            downloader.progress.formatted(.percent.precision(.fractionLength(0)))
        case .finished: "Saved"
        case .failed: "Failed"
        case .needsSpace: "Needs space"
        case .idle: "Not saved"
        }
    }

    @ViewBuilder private var tile: some View {
        switch downloader.phase {
        case .downloading:
            ActionTile {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .finished:
            ActionTile(tint: .green) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Saved").font(.caption2.weight(.medium))
            }
        default:
            ActionTile(tint: canDownload ? .accentColor : .secondary) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Offline").font(.caption2.weight(.medium))
            }
        }
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
        // The confirmation carries the detail; this only has to stop the row
        // reading as idle while a dialog is up behind it.
        case .needsSpace: "Waiting for space to be freed…"
        case .idle: idleNote
        }
    }

    var body: some View {
        if let note {
            Text(note)
                .font(.caption2)
                .foregroundStyle(downloader.isFailed ? .red : .secondary)
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
    /// Whether the selected map fetches tiles at all. `false` replaces the
    /// auto-save note, which would otherwise invite the hiker to turn on a
    /// switch that is no longer drawn and could save nothing if it were.
    let mapRendersTiles: Bool
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
        guard mapRendersTiles else {
            return "Apple Maps uses no downloadable tiles, so nothing is saved for this hike."
                + " Pick another map source in Settings to save one for offline use."
        }
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
                // A caption is 14 points tall, which is too small a region to
                // land on — including for VoiceOver's own direct-touch
                // exploration, which is what the hit-region audit measures.
                .minimumTapTarget()

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
        bytes.formatted(.byteCount(style: .file))
    }
}
