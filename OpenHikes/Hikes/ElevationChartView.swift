//
//  ElevationChartView.swift
//  OpenHikes
//
//  The interactive elevation graph, split out so it only re-renders when its own
//  inputs change — not when unrelated parent state (line width, download progress)
//  moves. `Equatable` (via `.equatable()`) covers `tint`/`profile` changes;
//  `tracker`'s properties are read directly in `body` below, so `Observation`
//  invalidates this view (and only this view) whenever they change, without
//  needing an equality check.
//

import Charts
import SwiftUI

struct ElevationChartView: View, Equatable {
    let profile: RouteProfile
    let tint: Color
    /// Tracker/live-follow positions — see ``TrackerState``.
    let tracker: TrackerState
    var onScrub: (Double) -> Void
    /// Reports drag start/end so the parent can pause auto-follow's own
    /// updates to `tracker.trackerDistance` while a finger is on the chart.
    var onScrubbingChanged: (Bool) -> Void = { _ in /* no-op default */ }

    /// Live chart selection under the finger (transient); owned here so scrubbing
    /// doesn't touch the parent until it resolves a distance.
    @State private var selectedDistance: Double?
    /// Measured plot width, used to keep vertical exaggeration consistent
    /// regardless of screen size. `0` until the first layout pass reports it.
    @State private var plotWidth: CGFloat = 0

    private static let chartHeight: CGFloat = 200
    /// How many times steeper the chart renders a slope than it truly is —
    /// the standard cartographic "vertical exaggeration" used on elevation
    /// profiles, so trails read as hilly without a small bump looking like a
    /// cliff. See `elevationDomain` for how it's applied.
    private static let verticalExaggeration: Double = 3
    /// Ceiling on the exaggerated span, as a multiple of the route's own
    /// elevation range. Without this, a long, nearly flat route (e.g. a 13km
    /// trail with 140m of relief) computes a span thousands of meters wide —
    /// mathematically "flat" is right, but centering that on the real data
    /// pushes the axis down into implausible (even negative) elevations.
    private static let maxSpanMultiplier: Double = 4

    /// Opacity for the area-fill gradient: top (opaque-ish) and bottom (near-clear).
    private static let areaGradientTopOpacity: Double = 0.45
    private static let areaGradientBottomOpacity: Double = 0.05
    /// Opacity for the scrub rule line.
    private static let ruleOpacity: Double = 0.4
    /// Opacity for the pause rules. Fainter than the scrub line: the scrub
    /// line answers a finger and should follow it plainly, while these are
    /// part of the trail's own story and must not compete with the profile
    /// they annotate.
    private static let pauseRuleOpacity: Double = 0.35
    /// Dotted rather than dashed, which is what tells it apart from the scrub
    /// rule above at a glance.
    private static let pauseRuleDash: [CGFloat] = [2, 4]
    /// Symbol sizes for the "my location" live-dot: outer white halo and inner blue fill.
    private static let liveHaloSymbolSize: CGFloat = 170
    private static let liveFillSymbolSize: CGFloat = 110
    /// Opacity for the callout shadow.
    private static let shadowOpacity: Double = 0.15
    /// Padding fraction applied to elevation domain so data never hugs the axis edges.
    private static let domainPaddingFraction: Double = 0.15
    /// How many swipes an adjustable-action user needs to cross the whole
    /// trail. Enough to land on the features of a long route, few enough that
    /// reaching the far end is not a chore.
    private static let accessibilityScrubSteps: Double = 20

    // `tracker` is always the same instance (owned by the parent's `@State`),
    // so it's deliberately excluded here — its mutations reach this view via
    // Observation, not via this equality check. This only needs to catch the
    // parent reconstructing the view with a genuinely different `tint`/`profile`.
    //
    // The plotted samples are compared in full, not merely counted: everything
    // this body draws — the marks, both scales, the scrub callout — is derived
    // from `profile.samples` and nothing else, so they are exactly the input
    // that decides whether the picture changed. Comparing lengths instead let
    // two different trails of the same size pass as equal and froze the graph
    // on the old one. It's bounded work by construction: `RouteProfile` caps
    // the plotted samples at `plottedSampleBudget`.
    //
    // The pause distances are compared alongside them because they are the one
    // thing this body draws that is *not* derived from the samples: two routes
    // can plot the same elevations and have been walked with and without a
    // break in the middle.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tint == rhs.tint
            && lhs.profile.samples == rhs.profile.samples
            && lhs.profile.pauseDistances == rhs.profile.pauseDistances
    }

    var body: some View {
        // Live follow is *meant* to invalidate this body (and the progress
        // row) once per published fix — at most once a second, and only while
        // the walker is moving. That rate is the reference every other body's
        // rate is judged against: anything else moving at it is following
        // location it was supposed to be insulated from.
        RenderSignpost.mark("ElevationChartBody", "\(profile.samples.count) samples")
        let domain = elevationDomain(profile, plotWidth: plotWidth)
        let trackerSample = profile.sample(atDistance: tracker.trackerDistance)
        let liveSample = tracker.liveTrackerDistance.flatMap { profile.sample(atDistance: $0) }
        return Chart {
            routeMarks(domain: domain)
            pauseMarks()
            trackerMarks(sample: trackerSample)
            liveMarks(sample: liveSample)
        }
        .chartXSelection(value: $selectedDistance)
        .chartXScale(domain: 0...(profile.samples.last?.distanceMeters ?? 1))
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Measurement(value: meters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Measurement(value: meters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .asProvided)))
                    }
                }
            }
        }
        .frame(height: Self.chartHeight)
        // The graph is a selection target with no leaves of its own, so without
        // this it is invisible to VoiceOver and its scrub is unreachable. One
        // element with an adjustable action is the same interaction in the
        // rotor: swipe up/down steps the tracker along the trail and speaks
        // the point it lands on. Everything below has to be applied *after*
        // it, since it replaces the subtree it wraps — including any
        // identifier hung underneath.
        .accessibilityElement()
        // Kept on the same view as the selection, which Swift Charts installs
        // through `.chartXSelection` above rather than as a gesture of ours:
        // UI automation scrubs the plot area by coordinate, and there is no
        // leaf inside a chart to hang this on.
        .accessibilityIdentifier("elevation-chart")
        .accessibilityLabel("Elevation profile")
        .accessibilityValue(Self.description(of: trackerSample, in: profile))
        .accessibilityAdjustableAction { direction in
            guard let distance = adjustedDistance(direction) else { return }
            onScrub(distance)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { plotWidth = $0 }
        .onChange(of: selectedDistance) { _, distance in
            // While scrubbing, move the persistent tracker; keep it put on release.
            onScrubbingChanged(distance != nil)
            guard let distance else { return }
            onScrub(distance)
        }
    }

    /// The area and the line, as two series rather than one interleaved loop.
    ///
    /// The styling is applied to each `ForEach` instead of to the marks inside
    /// it, which is the whole reason for the split: a modifier on a mark is
    /// evaluated per mark, so the previous spelling built a `LinearGradient` —
    /// and the two `Color.opacity` calls behind it — once for every plotted
    /// sample, up to ``RouteProfile/plottedSampleBudget`` of them. Applied to
    /// the series it is built once and the fill is identical, because both
    /// spellings paint the same gradient over the same area.
    ///
    /// That cost is paid on every pass of this body, and the app does not
    /// control how often that is: going to the background, UIKit lays the
    /// hosting view out twice for the app-switcher snapshot, and both passes
    /// go through here. See P4 in `PERFORMANCE.md`.
    ///
    /// Drawing order is unchanged. Swift Charts groups marks into series
    /// before it draws, so "every area, then every line" and "each sample's
    /// area then its line" are the same picture — and it is the one the line
    /// has to be on top of.
    @ChartContentBuilder
    private func routeMarks(domain: ClosedRange<Double>) -> some ChartContent {
        ForEach(profile.samples) { sample in
            AreaMark(
                x: .value("Distance", sample.distanceMeters),
                yStart: .value("Base", domain.lowerBound),
                yEnd: .value("Elevation", sample.elevation)
            )
        }
        .interpolationMethod(.catmullRom)
        .foregroundStyle(
            LinearGradient(
                colors: [tint.opacity(Self.areaGradientTopOpacity), tint.opacity(Self.areaGradientBottomOpacity)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        ForEach(profile.samples) { sample in
            LineMark(
                x: .value("Distance", sample.distanceMeters),
                y: .value("Elevation", sample.elevation)
            )
        }
        .interpolationMethod(.catmullRom)
        .foregroundStyle(tint)
        .lineStyle(StrokeStyle(lineWidth: 2))
    }

    /// Where the walker stopped recording, as a rule through the profile.
    ///
    /// A rule rather than a break in the line: the pause took time out of the
    /// walk but no distance out of it, so the x-axis runs on and the profile
    /// stays continuous across it — see ``RouteBoundary``. Declared before the
    /// tracker so a scrub landing on a pause draws over it rather than under.
    ///
    /// Bounded by the number of pauses, not by the length of the route.
    @ChartContentBuilder
    private func pauseMarks() -> some ChartContent {
        ForEach(profile.pauseDistances, id: \.self) { distance in
            RuleMark(x: .value("Distance", distance))
                .foregroundStyle(.secondary.opacity(Self.pauseRuleOpacity))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: Self.pauseRuleDash))
        }
    }

    @ChartContentBuilder
    private func trackerMarks(sample: ElevationSample?) -> some ChartContent {
        if let sample {
            RuleMark(x: .value("Distance", sample.distanceMeters))
                .foregroundStyle(.secondary.opacity(Self.ruleOpacity))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            PointMark(
                x: .value("Distance", sample.distanceMeters),
                y: .value("Elevation", sample.elevation)
            )
            .foregroundStyle(tint)
            .symbolSize(90)
            .annotation(
                position: .top,
                spacing: 4,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
                calloutLabel(sample)
            }
        }
    }

    @ChartContentBuilder
    private func liveMarks(sample: ElevationSample?) -> some ChartContent {
        // The live GPS position, mirroring the map's "my location" dot
        // (white halo + blue center). Declared last so it draws over the
        // tracker pin when the two land close together.
        if let sample {
            PointMark(
                x: .value("Distance", sample.distanceMeters),
                y: .value("Elevation", sample.elevation)
            )
            .foregroundStyle(.white)
            .symbolSize(Self.liveHaloSymbolSize)
            PointMark(
                x: .value("Distance", sample.distanceMeters),
                y: .value("Elevation", sample.elevation)
            )
            .foregroundStyle(.blue)
            .symbolSize(Self.liveFillSymbolSize)
        }
    }

    private func calloutLabel(_ sample: ElevationSample) -> some View {
        VStack(spacing: 1) {
            Text(HikeFormat.length(Measurement(value: sample.elevation, unit: .meters)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(Measurement(value: sample.distanceMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Opaque (not a material) so it never picks up the graph colours behind
        // it, and deliberately not `glassSurface` either: a Chart annotation
        // gives Liquid Glass no backdrop worth sampling, so over the near-white
        // plot area the surface and its text both wash out to the point of
        // being unreadable. Verified on device — this is the one control in the
        // app that has to stay a solid card.
        .background(Self.calloutBackground, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(Self.shadowOpacity), radius: 3, y: 1)
    }

    /// Solid, mode-adaptive callout background.
    private static let calloutBackground: Color = {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }()

    // MARK: Accessibility

    /// Where an increment/decrement swipe puts the tracker, or `nil` at an end
    /// of the trail so VoiceOver plays its "no more" tone rather than
    /// re-announcing the same point.
    private func adjustedDistance(
        _ direction: AccessibilityAdjustmentDirection
    ) -> Double? {
        let total = profile.samples.last?.distanceMeters ?? 0
        guard total > 0 else { return nil }
        let step = total / Double(Self.accessibilityScrubSteps)
        let current = tracker.trackerDistance
        let next = switch direction {
        case .increment: current + step
        case .decrement: current - step
        @unknown default: current
        }
        let clamped = min(max(next, 0), total)
        return clamped == current ? nil : clamped
    }

    /// What the tracker is standing on, as the callout says it visually:
    /// elevation first, then how far along the trail it is. Spelled out in
    /// wide units — "535 meters", not "535 m" — because this is spoken.
    private static func description(
        of sample: ElevationSample?,
        in profile: RouteProfile
    ) -> String {
        guard let sample else { return "No elevation data" }
        let elevation = Measurement(
            value: sample.elevation.rounded(),
            unit: UnitLength.meters
        ).formatted(.measurement(width: .wide, usage: .asProvided))
        let distance = Measurement(
            value: sample.distanceMeters,
            unit: UnitLength.meters
        ).formatted(.measurement(width: .wide, usage: .road))
        guard let fraction = profile.fractionComplete(atDistance: sample.distanceMeters) else {
            return "\(elevation) at \(distance)"
        }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return "\(elevation) at \(distance), \(percent) along the trail"
    }

    /// A y-range that keeps the rendered slope proportional to the real one
    /// (times `verticalExaggeration`), instead of always stretching to fill
    /// the chart — otherwise a 20m rise over 5km and a 200m rise over 500m
    /// would render as the identically dramatic spike.
    ///
    /// Picks the tightest y-span that both (a) fits the real elevation range
    /// and (b) keeps meters-per-point on Y at `1/verticalExaggeration` of
    /// meters-per-point on X, given the measured plot width — capped at
    /// `maxSpanMultiplier` × the real range so a long, flat route doesn't
    /// balloon into an implausible axis. Whichever span is larger wins, so
    /// real elevation data is never clipped — a genuinely steep trail just
    /// ends up using its natural (wider) span, which is exactly what makes
    /// it read as steep.
    private func elevationDomain(_ profile: RouteProfile, plotWidth: CGFloat) -> ClosedRange<Double> {
        guard let range = profile.elevationRange else { return 0...1 }
        let low = range.lowerBound, high = range.upperBound
        let dataSpan = high - low
        guard dataSpan > 0 else { return (low - 10)...(high + 10) }

        // Before the first layout pass reports a real width, fall back to a
        // plain data-fitted range rather than guessing.
        guard plotWidth > 0 else {
            let padding = dataSpan * Self.domainPaddingFraction
            return (low - padding)...(high + padding)
        }

        let totalDistance = max(profile.samples.last?.distanceMeters ?? 1, 1)
        let metersPerPointX = totalDistance / Double(plotWidth)
        let metersPerPointY = metersPerPointX / Self.verticalExaggeration
        let exaggeratedSpan = min(Double(Self.chartHeight) * metersPerPointY, dataSpan * Self.maxSpanMultiplier)

        let span = max(exaggeratedSpan, dataSpan)
        let padding = span * Self.domainPaddingFraction
        let mid = (low + high) / 2
        return (mid - span / 2 - padding)...(mid + span / 2 + padding)
    }
}
