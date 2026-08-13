//
//  HikeDetailComponents.swift
//  OpenTrails
//
//  Private helper views used only by HikeDetailView.
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
    }

    @ViewBuilder private var tile: some View {
        switch downloader.phase {
        case .downloading:
            actionTile {
                ProgressView().controlSize(.small)
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
        case .downloading:  "Saving \(downloader.total) tiles…"
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
