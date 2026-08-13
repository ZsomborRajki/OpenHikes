//
//  ElevationChartView.swift
//  OpenTrails
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
    /// Symbol sizes for the "my location" live-dot: outer white halo and inner blue fill.
    private static let liveHaloSymbolSize: CGFloat = 170
    private static let liveFillSymbolSize: CGFloat = 110
    /// Opacity for the callout shadow.
    private static let shadowOpacity: Double = 0.15
    /// Padding fraction applied to elevation domain so data never hugs the axis edges.
    private static let domainPaddingFraction: Double = 0.15

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
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tint == rhs.tint && lhs.profile.samples == rhs.profile.samples
    }

    var body: some View {
        let domain = elevationDomain(profile, plotWidth: plotWidth)
        let trackerSample = profile.sample(atDistance: tracker.trackerDistance)
        let liveSample = tracker.liveTrackerDistance.flatMap { profile.sample(atDistance: $0) }
        Chart {
            routeMarks(domain: domain)
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

    @ChartContentBuilder
    private func routeMarks(domain: ClosedRange<Double>) -> some ChartContent {
        ForEach(profile.samples) { sample in
            AreaMark(
                x: .value("Distance", sample.distanceMeters),
                yStart: .value("Base", domain.lowerBound),
                yEnd: .value("Elevation", sample.elevation)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(Self.areaGradientTopOpacity), tint.opacity(Self.areaGradientBottomOpacity)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Distance", sample.distanceMeters),
                y: .value("Elevation", sample.elevation)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 2))
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
        // Opaque (not a material) so it never picks up the graph colours behind it.
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
