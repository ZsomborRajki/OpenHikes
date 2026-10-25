//
//  ElevationChartView.swift
//  OpenHikes
//
//  The interactive elevation graph, split out so it only re-renders when its own
//  inputs change — not when unrelated parent state (line width, download progress)
//  moves. `Equatable` (via `.equatable()`) covers `tint`/`profile` changes;
//  `tracker`'s positions are read directly — by ``ElevationChartSpokenPosition``
//  for what the graph speaks, and by ``ElevationChartMarks`` for what it draws
//  — so `Observation` invalidates those two (and only those two) whenever they
//  change, without needing an equality check.
//
//  ## Nothing on a scrub's path runs this body
//
//  A drag event reaches three things: the selection, the tracker it moves, and
//  what the graph speaks for the tracker. None of them is read here. The
//  selection is the marks' own, handed on by ``ElevationScrubRelay``, because
//  a modifier's arguments are evaluated in the body that applies it, so the
//  `onChange(of:)` that used to sit here made the selection an input of this
//  view. The spoken value is read in a modifier of its own, which Observation
//  invalidates in this body's place. Traced with `Scripts/render-trace.sh`
//  over the drag in `AccessibilityLabelUITests`, this body ran twice per
//  selection change while it held both — once for each — and not at all once
//  it held neither.
//
//  ## What moves is drawn apart from what does not
//
//  ``ElevationChartPlot`` draws what stays put — the area, the line, the pause
//  rules and the axes — and ``ElevationChartMarks`` draws what moves over it —
//  the scrub rule, the tracker's point and its callout, the live position — in
//  charts of its own laid over the plot through `chartOverlay`, and takes the
//  finger as well. A scrub step or a fix re-evaluates the marks and leaves the
//  plot, and Swift Charts' work on it, alone.
//
//  The plot is nearly all of the cost: a pass lays out every plotted sample
//  twice, once for the area and once for the line. Neither the vectorized
//  `AreaPlot`/`LinePlot` spellings nor a plainer interpolation made it any
//  cheaper; both were measured. Traced with `Scripts/render-trace.sh` over the
//  drag in `AccessibilityLabelUITests`, Swift Charts' own display took
//  127.6 ms of body time while the graph was one chart, and about 2.5 ms once
//  the plot was left alone, while keeping up with several times as many of the
//  drag's touch events — a Debug build on a simulator, so the ratio is the
//  finding rather than the figures.
//
//  The finger moved with the marks because it had to. A chart that carries a
//  selection and the gesture driving it is laid out again on every drag event,
//  whatever its own body does, so with them on the plot the split saved
//  nothing: the plot's body was skipped and its display ran anyway.
//

import Charts
import OpenHikesData
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
        // Neither a scrub step nor a published fix reaches this body: the
        // marks, the spoken value and the progress row are what follow the
        // tracker. This runs when the graph itself changes — its profile, its
        // tint, its measured width.
        ElevationChartPlot(
            profile: profile,
            tint: tint,
            domain: elevationDomain(profile, plotWidth: plotWidth),
            tracker: tracker,
            onScrub: onScrub,
            onScrubbingChanged: onScrubbingChanged
        )
        .equatable()
        .frame(height: Self.chartHeight)
        // The graph is a selection target with no leaves of its own, so without
        // this it is invisible to VoiceOver and its scrub is unreachable. One
        // element with an adjustable action is the same interaction in the
        // rotor: swipe up/down steps the tracker along the trail and speaks
        // the point it lands on. Everything below has to be applied *after*
        // it, since it replaces the subtree it wraps — including any
        // identifier hung underneath.
        .accessibilityElement()
        // Kept on the chart itself: UI automation taps and scrubs the plot
        // area by coordinate, and there is no leaf inside to hang this on.
        .accessibilityIdentifier("elevation-chart")
        .accessibilityLabel("Elevation profile")
        .modifier(ElevationChartSpokenPosition(profile: profile, tracker: tracker))
        // Reads the tracker inside the action, when a swipe arrives, and not
        // in this body.
        .accessibilityAdjustableAction { direction in
            guard let distance = adjustedDistance(direction) else { return }
            onScrub(distance)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { plotWidth = $0 }
    }

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

// MARK: - What it speaks

/// What VoiceOver reads off the graph: the point under the tracker.
///
/// A modifier of its own, because it is the one thing on the graph's own
/// element that reads the tracker. Applied after `.accessibilityElement()`, so
/// the value lands on the element that call creates. A `ViewModifier` is a
/// boundary for the reads in its `body(content:)`, so a tracker write — once
/// per scrub step, once per fix while following — re-runs this and leaves
/// ``ElevationChartView`` alone.
private struct ElevationChartSpokenPosition: ViewModifier {
    let profile: RouteProfile
    /// Tracker/live-follow positions — see ``TrackerState``.
    let tracker: TrackerState

    func body(content: Content) -> some View {
        content.accessibilityValue(
            Self.description(of: profile.sample(atDistance: tracker.trackerDistance), in: profile)
        )
    }

    /// What the tracker is standing on, as the callout says it visually:
    /// elevation first, then how far along the trail it is. Spelled out in
    /// wide units — "535 meters", not "535 m" — because this is spoken.
    private static func description(
        of sample: ElevationSample?,
        in profile: RouteProfile
    ) -> String {
        guard let sample else { return String(localized: "No elevation data") }
        let elevation = HikeFormat.spokenElevation(
            Measurement(value: sample.elevation, unit: UnitLength.meters)
        )
        let distance = Measurement(
            value: sample.distanceMeters,
            unit: UnitLength.meters
        ).formatted(.measurement(width: .wide, usage: .road))
        guard let fraction = profile.fractionComplete(atDistance: sample.distanceMeters) else {
            return String(localized: "\(elevation) at \(distance)")
        }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "\(elevation) at \(distance), \(percent) along the trail")
    }
}

// MARK: - What stays put

/// What stays put on the graph: the area, the line, the pause rules and the
/// axes.
///
/// Evaluated when what it draws changes, and not otherwise — not on a scrub
/// step, and not on a fix. The tracker and the two scrub callbacks are only
/// passed through to ``ElevationChartMarks``.
///
/// **Nothing here may be tied to the selection.** Swift Charts lays a chart
/// out again whenever the selection it carries changes, so `chartXSelection`
/// and the gesture driving it live on the marks' own touch chart, never here.
/// And a `Binding` held as a property makes its holder a reader of the state
/// behind it, so the selection is the marks' own, and this view never holds
/// it — see ``ElevationScrubSelection``.
struct ElevationChartPlot: View, Equatable {
    let profile: RouteProfile
    let tint: Color
    /// The y-scale, which ``ElevationChartView`` derives from the measured
    /// width — see `elevationDomain` there.
    let domain: ClosedRange<Double>
    /// Passed through to ``ElevationChartMarks``, and never read here.
    let tracker: TrackerState
    /// Passed through to ``ElevationChartMarks``, and never called here.
    let onScrub: (Double) -> Void
    /// Passed through to ``ElevationChartMarks``, and never called here.
    let onScrubbingChanged: (Bool) -> Void

    /// Opacity for the area-fill gradient: top (opaque-ish) and bottom (faint).
    ///
    /// The bottom stop was 0.05 until #382: a fade to *nothing* rather than to
    /// a baseline, which read while the sheet's glass supplied a backdrop of
    /// its own and stopped reading on iOS 27 when it thinned. #411 took the
    /// surface #382 added back out, and this stop stays where #382 put it —
    /// it is the half of that change the graph still needs, since a fade to a
    /// baseline is legible over map tiles and a fade to nothing is not.
    private static let areaGradientTopOpacity: Double = 0.45
    private static let areaGradientBottomOpacity: Double = 0.14
    /// Opacity for the pause rules. Fainter than the scrub line: the scrub
    /// line answers a finger and should follow it plainly, while these are
    /// part of the trail's own story and must not compete with the profile
    /// they annotate.
    private static let pauseRuleOpacity: Double = 0.35
    /// Dotted rather than dashed, which is what tells it apart from the scrub
    /// rule above at a glance.
    private static let pauseRuleDash: [CGFloat] = [2, 4]

    /// The x-scale all three charts share: the route from its start to its
    /// last plotted sample.
    static func distanceDomain(of profile: RouteProfile) -> ClosedRange<Double> {
        0...(profile.samples.last?.distanceMeters ?? 1)
    }

    // Everything this body draws comes from these four, compared as
    // ``ElevationChartView/==(_:_:)`` compares them — the samples in full, and
    // the pauses beside them. What moves on the graph is left out: the tracker
    // reaches ``ElevationChartMarks`` through Observation, and the selection
    // never reaches this view at all. So are the callbacks, as
    // ``ElevationChartView`` leaves its own out: a skipped pass keeps the ones
    // the last pass that ran was handed, which call the same parent.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tint == rhs.tint
            && lhs.domain == rhs.domain
            && lhs.profile.samples == rhs.profile.samples
            && lhs.profile.pauseDistances == rhs.profile.pauseDistances
    }

    var body: some View {
        // No surface behind the plot, deliberately. #382 put one here so the
        // grid lines and axis labels had something to be read against on
        // iOS 27's thinner glass; #411 took it back out, because a card in the
        // middle of a sheet that is otherwise glass reads as a panel stuck on
        // top of the page rather than as part of it. The graph is glass.
        //
        // What stays from #382 is the half that does not need a card: the area
        // fill ends at a baseline rather than fading to nothing — see
        // ``areaGradientBottomOpacity`` — which is legible over map tiles
        // whatever is behind it. The scrub callout keeps its own surface, as it
        // always had one: a `Chart` annotation gives Liquid Glass no backdrop
        // worth sampling, and that is a different problem from this one.
        Chart {
            routeMarks()
            pauseMarks()
        }
        .chartXScale(domain: Self.distanceDomain(of: profile))
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
        // The y axis reads in the reader's own unit, like the x axis two
        // blocks up. The scale stays in metres — the samples are metres and so
        // is the scrub — so a US tick lands on 1,640 ft rather than a round
        // figure. A label in the wrong unit beside an x axis in the right one
        // is the worse of the two.
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(HikeFormat.elevation(
                            Measurement(value: meters, unit: UnitLength.meters)
                        ))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            // The proxy is read here and not handed on: Swift Charts runs this
            // again with a new one whenever the chart moves on screen — see
            // ``ElevationChartMarks/==(_:_:)``.
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    ElevationChartMarks(
                        plot: geometry[plotFrame],
                        profile: profile,
                        tint: tint,
                        domain: domain,
                        tracker: tracker,
                        onScrub: onScrub,
                        onScrubbingChanged: onScrubbingChanged
                    )
                    .equatable()
                }
            }
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
    /// go through here.
    ///
    /// Drawing order is unchanged. Swift Charts groups marks into series
    /// before it draws, so "every area, then every line" and "each sample's
    /// area then its line" are the same picture — and it is the one the line
    /// has to be on top of.
    @ChartContentBuilder
    private func routeMarks() -> some ChartContent {
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

    /// Where the hiker stopped recording, as a rule through the profile.
    ///
    /// A rule rather than a break in the line. The paused leg is no distance
    /// (see ``RouteBoundary``), so the two recorded pieces meet at one point on
    /// the x-axis and the line steps there from the height before the pause to
    /// the height after it; the rule says why it steps. Drawn under the
    /// tracker, which lives on the chart laid over this one, so a scrub
    /// landing on a pause draws over it rather than under.
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
}

/// The finger's selection, held where no view above the marks can come to
/// depend on it, and handed on to the parent from inside a SwiftUI update.
///
/// Each place the selection lived before re-ran a view on every drag event:
///
/// - A binding to ``ElevationChartView``'s own state would have to be held by
///   ``ElevationChartPlot`` to pass it on, and a `Binding` held as a property
///   re-runs its holder on every write through it, equatable, equal and unread
///   as the holder is (`ElevationChartLayersTests`).
/// - A `Double?` in ``ElevationChartView``'s `@State`, handed on by an
///   `onChange(of:)` there, made the selection an input of that view's body,
///   because a modifier's arguments are evaluated in the body that applies it.
///
/// So ``ElevationChartMarks`` keeps it in a `@State` that is never
/// reassigned, and it has two halves:
///
/// - ``distance`` is what the touch chart's binding answers. It is ignored by
///   Observation, because Swift Charts reads it through the binding while it
///   updates its own display, where a tracked read would tie the display to
///   every write.
/// - ``handedOn`` is the same value, tracked, and read by
///   ``ElevationScrubRelay`` alone, whose `onChange(of:)` moves the tracker.
///
/// The second half is what an `onChange` buys and a binding's setter does not.
/// Moving the tracker straight from the setter — during the gesture, outside
/// any update — doubled Swift Charts' display passes, from about two per
/// selection change to about four, measured with `Scripts/render-trace.sh`.
/// Moved from an `onChange`, it lands in the update the selection already
/// causes, and the count is back to two.
@Observable
final class ElevationScrubSelection {
    /// What the touch chart's binding reads back.
    @ObservationIgnored private(set) var distance: Double?
    /// What ``ElevationScrubRelay`` hands on to the parent.
    private(set) var handedOn: Double?

    /// Takes a write through the touch chart's binding. `@Observable` drops a
    /// write of the value already there, so a selection written twice reaches
    /// the relay once, as an `onChange(of:)` would have heard it.
    func select(_ distance: Double?) {
        self.distance = distance
        handedOn = distance
    }
}

/// Hands the selection on to the parent: while a finger is down, the tracker
/// follows it, and the parent hears the scrub start and end.
///
/// A view of its own, under the marks, because an `onChange(of:)` makes what
/// it watches an input of the view that applies it. On the marks that would
/// cost them a second pass per drag event — one for the selection, one for the
/// tracker it moves, measured at both, with Swift Charts' display passes
/// tripled — and on ``ElevationChartView`` it was the pass #1038 took out.
/// Here it costs a view that draws nothing.
private struct ElevationScrubRelay: View {
    let scrub: ElevationScrubSelection
    let onScrub: (Double) -> Void
    let onScrubbingChanged: (Bool) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: scrub.handedOn) { _, distance in
                // While scrubbing, move the persistent tracker; keep it put on
                // release.
                onScrubbingChanged(distance != nil)
                guard let distance else { return }
                onScrub(distance)
            }
    }
}

// MARK: - What moves

/// What moves on the graph — the scrub rule, the tracker's point and its
/// callout, the live position — and the finger that moves it, as two charts
/// laid over ``ElevationChartPlot``. The one layer of the graph that reads the
/// tracker (``ElevationChartSpokenPosition`` reads it too, for what it speaks)
/// and the one that owns the selection, which ``ElevationScrubRelay`` hands
/// on: re-evaluated on every scrub step and every fix, and cheap, because
/// neither of its charts has a series to lay out.
///
/// **The drawn chart** covers the plot's whole frame, axes included, and its
/// scales are padded onto the plot area beneath it. That keeps the callout
/// clamping against the edges it always did: `.fit(to: .chart)` means this
/// chart's bounds, which are the plot's. The y-scale's padding starts at the
/// bottom edge, where its values start. The scrub rule spans the y-domain
/// explicitly, because a rule with no span runs the height of its own chart's
/// plot area, and this chart's would run on through the x-axis labels. It
/// takes no touches. Rendered beside the single chart it replaced, at the
/// start, middle and end of a trail on a simulator, everything it draws lands
/// within a third of a point of where that chart drew it.
///
/// **The touch chart** has no marks and covers exactly the plot area, so a
/// touch lands where it always did — on the plot, not on the axis labels,
/// where a vertical drag still scrolls the sheet — and is reported in the same
/// coordinates. Laid over the plot area with the same x-domain, it selects the
/// same distance at every position as the plot did, past either end included.
struct ElevationChartMarks: View, Equatable {
    /// Where the plot area sits, in this view's own space.
    let plot: CGRect
    let profile: RouteProfile
    let tint: Color
    let domain: ClosedRange<Double>
    let tracker: TrackerState
    let onScrub: (Double) -> Void
    let onScrubbingChanged: (Bool) -> Void

    /// The selection under the finger — see ``ElevationScrubSelection``.
    /// Never reassigned, so it never invalidates.
    @State private var scrub = ElevationScrubSelection()

    /// Whether a finger is currently on the plot area.
    ///
    /// `@GestureState` rather than `@State` because it is what makes the
    /// release path *total*: SwiftUI resets it when a gesture is cancelled as
    /// well as when it completes, while `onEnded` is delivered only on the
    /// completed one. A selection left standing is not a cosmetic leak — it
    /// reads upward as a scrub that never ended, which pins `isScrubbing`
    /// true in `HikeDetailView` and stops ``FollowInteractionPolicy`` handing
    /// the tracker and the map pin back to auto-follow for the life of the
    /// screen.
    @GestureState private var isTouchingChart = false

    /// Opacity for the scrub rule line.
    private static let ruleOpacity: Double = 0.4
    /// Symbol sizes for the "my location" live-dot: outer white halo and inner blue fill.
    private static let liveHaloSymbolSize: CGFloat = 170
    private static let liveFillSymbolSize: CGFloat = 110
    /// Opacity for the callout shadow.
    private static let shadowOpacity: Double = 0.15

    // What the marks draw and where, compared as ``ElevationChartPlot``
    // compares its own: the samples in full, the scales, and the plot area's
    // frame. The tracker is left out, as it is there — the same instance every
    // time, whose moves reach this body through Observation — and so are the
    // callbacks, for the reason the plot gives.
    //
    // The plot area arrives as a frame rather than as the `ChartProxy` it is
    // read from, because Swift Charts runs `chartOverlay` again, with a new
    // proxy, whenever the chart moves on screen. A proxy compares unequal
    // every time, so the marks ran on every frame of a scroll down the hike's
    // card or a drag of the sheet, about 140 times a swipe, and laid out both
    // of their charts again for a picture that had not changed. The frame, in
    // this view's own space, stays where it is.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.plot == rhs.plot
            && lhs.tint == rhs.tint
            && lhs.domain == rhs.domain
            && lhs.profile.samples == rhs.profile.samples
    }

    var body: some View {
        let trackerSample = profile.sample(atDistance: tracker.trackerDistance)
        let liveSample = tracker.liveTrackerDistance.flatMap { profile.sample(atDistance: $0) }
        let selection = Binding(
            get: { scrub.distance },
            set: { scrub.select($0) }
        )
        GeometryReader { geometry in
            drawnChart(tracker: trackerSample, live: liveSample, size: geometry.size)
            touchChart(selection: selection)
                .frame(width: plot.width, height: plot.height)
                .position(x: plot.midX, y: plot.midY)
        }
        // The cancellation half of the reset in ``touchChart(selection:)`` —
        // see ``isTouchingChart``.
        .onChange(of: isTouchingChart) { _, touching in
            guard !touching else { return }
            selection.wrappedValue = nil
        }
        .background {
            ElevationScrubRelay(scrub: scrub, onScrub: onScrub, onScrubbingChanged: onScrubbingChanged)
        }
    }

    /// The scrub rule, the tracker's point and its callout, and the live
    /// position, scaled onto the plot area beneath.
    private func drawnChart(
        tracker trackerSample: ElevationSample?,
        live liveSample: ElevationSample?,
        size: CGSize
    ) -> some View {
        Chart {
            trackerMarks(sample: trackerSample)
            liveMarks(sample: liveSample)
        }
        .chartXScale(
            domain: ElevationChartPlot.distanceDomain(of: profile),
            range: .plotDimension(startPadding: plot.minX, endPadding: size.width - plot.maxX)
        )
        .chartYScale(
            domain: domain,
            range: .plotDimension(startPadding: size.height - plot.maxY, endPadding: plot.minY)
        )
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .allowsHitTesting(false)
    }

    /// The plot area's twin, which takes the finger.
    ///
    /// Its data is empty rather than its builder: an empty `Chart {}` needs
    /// the iOS 27 SDK, and the CodeQL job still builds with Xcode 26.6 — see
    /// *CI* in AGENTS.md.
    private func touchChart(selection: Binding<Double?>) -> some View {
        Chart([ElevationSample]()) { sample in
            PointMark(
                x: .value("Distance", sample.distanceMeters),
                y: .value("Elevation", sample.elevation)
            )
        }
        .chartXSelection(value: selection)
        // Swift Charts' own selection gesture resolves nothing until the touch
        // has lasted roughly a tenth of a second — measured on iOS 26.5 as
        // between 0.08 s and 0.10 s, with a moving touch engaging it at once —
        // so a brisk tap lands and lifts having selected nothing. Starting at
        // touch-down is what puts a tap and a drag on the same selection path,
        // and it is the response a scrubber is expected to have. See #206.
        .chartGesture { chart in
            DragGesture(minimumDistance: 0)
                .updating($isTouchingChart) { _, touching, _ in touching = true }
                .onChanged { chart.selectXValue(at: $0.location.x) }
                // The ordinary release. A cancelled one never arrives here and
                // is caught by `isTouchingChart` instead; both clear, and
                // clearing twice costs nothing because the relay hears only a
                // real change.
                .onEnded { _ in selection.wrappedValue = nil }
        }
        .chartXScale(domain: ElevationChartPlot.distanceDomain(of: profile))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    @ChartContentBuilder
    private func trackerMarks(sample: ElevationSample?) -> some ChartContent {
        if let sample {
            RuleMark(
                x: .value("Distance", sample.distanceMeters),
                yStart: .value("Elevation", domain.lowerBound),
                yEnd: .value("Elevation", domain.upperBound)
            )
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
            Text(HikeFormat.elevation(Measurement(value: sample.elevation, unit: .meters)))
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
        // being unreadable. Verified on device.
        //
        // The same surface the plot area itself now carries, one layer up, so
        // the callout reads as a card lifted off the graph rather than as a
        // second colour — see ``Color/contentSurface``, where the argument this
        // comment used to make on its own now lives.
        .background(.contentSurface, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(Self.shadowOpacity), radius: 3, y: 1)
    }
}

// MARK: - Empty state

/// What stands in for the graph when a hike in the library carries no
/// elevations.
///
/// Split from ``HikeElevationPlaceholder`` for the reason the chart itself is
/// split from ``HikeElevationChart``: the tint is an observable read on the
/// hike's own screen, and the wrapper is what absorbs it.
///
/// **One caller, and a `message` parameter anyway.** The community preview used
/// to draw this too, with wording of its own; it now draws nothing at all when
/// a route has no heights, because every curated trail has none and a
/// permanent card saying so is worse than an absent section — see
/// ``CommunityHikeView/elevationSection``. The parameter stays because the
/// wording is the reason the split existed: *no elevation data in this file*
/// names a thing the hiker has, and any second caller will by definition be
/// looking at something else.
struct ElevationPlaceholderView: View {
    private static let tintOpacity = 0.12
    private static let height: CGFloat = 180
    private static let cornerRadius: CGFloat = 16

    let tint: Color
    let message: LocalizedStringKey
    /// A second line in the tint, for a card that is also a button — see
    /// ``ElevationProPrompt``.
    var action: LocalizedStringKey?

    var body: some View {
        ZStack {
            // The surface first and the tint over it, rather than the tint
            // alone. A twelve-percent wash was a tinted card while the sheet's
            // glass stood behind it and is a tinted *map* now — see
            // ``Color/contentSurface``. The tint's own opacity is unchanged:
            // what it needed was something to be twelve percent of.
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color.contentSurface)
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(tint.opacity(Self.tintOpacity))
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let action {
                    Text(action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .frame(height: Self.height)
    }
}
