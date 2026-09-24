//
//  RecordingStatsSection.swift
//  OpenHikes
//
//  The live numbers, in the strip and the list a saved hike's detail draws
//  its own in, so a walk looks the same while it is recorded as after.
//

import OpenHikesData
import SwiftUI

/// Distance, duration and ascent in the strip, and the rest in the list.
///
/// This is the per-fix reader, and so the boundary for it: `HikeRecorder.stats`
/// is a `let` holding a stable ``RecordingStats``, and `@Observable`
/// instruments `var`s only, so ``RecordingCard`` can hand the reference down
/// without the card itself re-running on every accepted fix.
struct RecordingStatsSection: View {
    let recorder: HikeRecorder

    private var stats: RecordingStats { recorder.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            StatStrip {
                StatFigure(label: "Distance", value: distance)
                RecordingDurationFigure(recorder: recorder)
                StatFigure(label: "Elevation Gain", value: elevationGain)
            }
            StatList {
                StatRow(label: "Moving", value: HikeFormat.duration(stats.movingSeconds))
                StatRow(label: "Current Speed", value: currentSpeed)
                StatRow(label: "Avg Speed", value: averageSpeed)
                StatRow(label: "Accuracy", value: accuracy)
                // `StatRow` already exposes itself as one label/value element;
                // only the identifier UI automation waits on is added here.
                StatRow(label: "Points", value: stats.pointCount.formatted())
                    .accessibilityIdentifier("recording-point-count")
            }
        }
    }

    private var distance: String {
        Measurement(value: stats.distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var elevationGain: String {
        guard let gain = stats.elevationGainMeters else { return "—" }
        return HikeFormat.elevation(
            Measurement(value: gain, unit: UnitLength.meters)
        )
    }

    private var averageSpeed: String {
        guard let speed = stats.averageSpeedMetersPerSecond else { return "—" }
        return HikeFormat.speed(
            Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
        )
    }

    /// The last few minutes rather than the whole walk — and the word
    /// "Stopped" rather than a rounded-down number, because a hiker standing
    /// at a viewpoint is not travelling at 0.1 km/h, they have stopped, and
    /// the distance beside this has stopped counting for the same reason.
    private var currentSpeed: String {
        if stats.isStationary { return "Stopped" }
        guard let speed = stats.recentSpeedMetersPerSecond else { return "—" }
        return HikeFormat.speed(
            Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
        )
    }

    /// A radius, so it is formatted like the distance above it rather than
    /// hard-coded to metres — which is what it was, and what made this the one
    /// figure on the recording screen a US hiker could not read.
    private var accuracy: String {
        guard let horizontalAccuracy = stats.horizontalAccuracy else { return "Searching…" }
        guard horizontalAccuracy <= RecordingFixPolicy.maximumHorizontalAccuracy else { return "Weak signal" }
        let radius = Measurement(value: horizontalAccuracy, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return "±\(radius)"
    }
}

/// The strip's duration, which is a clock: the one figure that changes with
/// no fix behind it.
///
/// Its own view so the 1 Hz tick redraws this figure and not the strip, and
/// so the per-fix redraw of ``RecordingStatsSection`` finds an unchanged
/// recorder reference here and skips it.
private struct RecordingDurationFigure: View {
    private static let label = "Duration"

    let recorder: HikeRecorder
    /// Read here, on the render path, unlike ``MapView/Coordinator``'s
    /// notification observers — and for the opposite reason. The coordinator
    /// gates work that MapKit does off SwiftUI's path entirely; this gates
    /// whether a `TimelineView` is *in the hierarchy at all*, which is a
    /// question only SwiftUI can answer. Scene phase changes a handful of
    /// times per hike, so the redraw it costs is bounded by transitions rather
    /// than by fixes.
    @Environment(\.scenePhase)
    private var scenePhase

    var body: some View {
        // Only while the readout is on screen. A recording keeps running in
        // the user's pocket for hours, and iOS does *not* suspend a
        // `TimelineView` in an app held awake by background location — it was
        // measured redrawing at a steady 1 Hz with the screen off, which is
        // ~21,600 pointless redraws over a six-hour walk. The elapsed value is
        // derived from a timestamp, not accumulated, so nothing is lost by not
        // counting: the readout is correct again on the first tick after
        // return.
        if recorder.sessionStartedAt == nil {
            StatFigure(label: Self.label, value: "—")
        } else if scenePhase == .active {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                // The tick only says *when* to redraw; the value comes from
                // ``HikeRecorder/elapsedSeconds()``, which counts from a
                // monotonic source wherever it has one rather than from the
                // wall clock.
                StatFigure(label: Self.label, value: HikeFormat.duration(recorder.elapsedSeconds()))
            }
        } else {
            StatFigure(label: Self.label, value: HikeFormat.duration(recorder.elapsedSeconds()))
        }
    }
}
