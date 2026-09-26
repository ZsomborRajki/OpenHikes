//
//  ElevationChartWorkloadTests.swift
//  OpenHikesTests
//
//  The elevation chart is the app's most expensive view and its most
//  frequently invalidated one — a bad combination that only shows up on long
//  tracks. `ElevationChartView` plots two marks (an `AreaMark` and a
//  `LineMark`, both `catmullRom`-interpolated) per elevation sample, and
//  left unthinned every point of an imported GPX would be one: a 1 Hz
//  five-hour recording is 18,000 points, so 36,000 marks. That view is
//  invalidated on every scrub event (drag frequency) and about once a second
//  by auto-follow.
//
//  Rendering it through `ImageRenderer` at 390×200 pt, on this machine's
//  Simulator (subtract ~0.2 ms of renderer overhead):
//
//      200 samples ...... 19 ms
//      1,000 samples .... 74 ms
//      5,000 samples .... 349 ms
//      20,000 samples .. 1,369 ms
//
//  A frame is 16 ms. So the tests here fix a budget on how much the chart is
//  asked to draw, and — just as importantly — pin the properties any
//  downsampling has to keep, because the chart's axes are derived from the
//  plotted samples: drop the wrong point and the trail's peak ends up
//  outside the y-scale, or the live tracker sits past the end of the x-scale.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftUI
import Testing

@Suite("Elevation chart workload")
struct ElevationChartWorkloadTests {
    /// A plausible recorded hike: one point a second for five hours, with
    /// real relief.
    static let longRoute: [RouteCoordinate] = (0..<18_000).map { step -> RouteCoordinate in
        let t = Double(step)
        return RouteCoordinate(
            latitude: 47.63 + t * 1e-5,
            longitude: 12.86 + t * 5e-6,
            elevation: 600 + 300 * sin(t / 2000) + 20 * sin(t / 37),
            timestamp: Date(timeIntervalSince1970: 1_750_000_000 + t)
        )
    }

    /// One plotted point per two device pixels is already past what a 390 pt
    /// chart can show at 3×; beyond that, every extra sample is cost with no
    /// picture to go with it.
    static let plottedSampleBudget = 500

    /// The headline: a long track hands Swift Charts tens of thousands of
    /// marks, on the main thread, on every scrub event.
    @Test("a long track's chart stays inside a drawable budget")
    func longTrackIsDownsampledForDrawing() {
        let profile = RouteProfile(route: Self.longRoute)
        #expect(
            profile.samples.count <= Self.plottedSampleBudget,
            "the chart plots 2 marks per sample and is rebuilt at drag frequency"
        )
    }

    /// Short tracks must be left alone — a 6-point walk should draw its 6
    /// real points, not a resampled approximation of them.
    @Test("a short track is plotted in full")
    func shortTrackIsUntouched() {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        #expect(profile.samples.count == Fixture.ridgeRoute.count)
    }

    // MARK: What any downsampling has to preserve

    /// `ElevationChartView.elevationDomain` derives the y-scale from
    /// `profile.elevationRange`, which is computed from the plotted samples.
    /// A stride-based decimation can easily step over the summit, and then
    /// the drawn line runs off the top of its own chart.
    @Test("the plotted samples still carry the route's high and low points")
    func extremesSurviveInThePlottedSamples() throws {
        let profile = RouteProfile(route: Self.longRoute)
        let trueElevations = Self.longRoute.compactMap(\.elevation)
        let trueLow = try #require(trueElevations.min())
        let trueHigh = try #require(trueElevations.max())
        let range = try #require(profile.elevationRange)

        #expect(range.lowerBound.isApproximatelyEqual(to: trueLow, absoluteTolerance: 1))
        #expect(range.upperBound.isApproximatelyEqual(to: trueHigh, absoluteTolerance: 1))
    }

    /// The same guarantee for the population it was not holding for: a hike
    /// stored before `GPXImport` refused a non-finite `<ele>`, or synced from
    /// a device on an older build.
    ///
    /// The buckets seed both bounds with their first sample and displace them
    /// by comparison, and every comparison against a NaN is false — so a
    /// bucket whose first sample was poisoned kept it and dropped the summit
    /// that was actually walked, on a chart whose y-scale is derived from what
    /// survives. `elevationRange` then filtered the NaN back out, so the
    /// number on screen came from a series the peak was no longer in and
    /// nothing looked wrong.
    @Test("a non-finite height does not cost its bucket the summit")
    func nonFiniteHeightsDoNotDisplaceExtremes() throws {
        // Every 500th point, which puts one at or near the head of a bucket
        // whichever way the interior divides.
        var poisoned = Self.longRoute
        for index in stride(from: 0, to: poisoned.count, by: 500) {
            poisoned[index].elevation = index.isMultiple(of: 1000) ? .nan : .infinity
        }
        let profile = RouteProfile(route: poisoned)
        let trueElevations = poisoned.compactMap(\.elevation).filter(\.isFinite)
        let trueLow = try #require(trueElevations.min())
        let trueHigh = try #require(trueElevations.max())

        // Bound first: a key path handed to `allSatisfy` reads as throwing
        // inside an `#expect` expansion.
        let everySampleIsFinite = profile.samples.allSatisfy(\.elevation.isFinite)
        #expect(everySampleIsFinite, "none of them reach the chart")
        let range = try #require(profile.elevationRange)
        #expect(range.lowerBound.isApproximatelyEqual(to: trueLow, absoluteTolerance: 1))
        #expect(
            range.upperBound.isApproximatelyEqual(to: trueHigh, absoluteTolerance: 1),
            "the summit is still in the series the axis is built from"
        )
    }

    /// `ElevationChartView.==` exists so the body stops re-evaluating when
    /// nothing it draws has changed, and the file documents that body as
    /// rebuilt at drag frequency during a scrub. `ElevationSample` is a
    /// synthesized `Equatable` over two `Double`s and `nan != nan`, so for a
    /// hike carrying one the comparison could never hold — the guard returned
    /// `false` on every pass, on the one screen it was written to protect.
    @Test("the chart's equality holds for a hike that carried a non-finite height")
    func equalityHoldsForARouteWithNonFiniteHeights() {
        let tracker = TrackerState()
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600),
            RouteCoordinate(latitude: 47.64, longitude: 12.86, elevation: .nan),
            RouteCoordinate(latitude: 47.65, longitude: 12.86, elevation: 700),
        ]
        let profile = RouteProfile(route: route)
        let first = ElevationChartView(profile: profile, tint: .green, tracker: tracker) { _ in /* no-op */ }
        let second = ElevationChartView(
            profile: RouteProfile(route: route),
            tint: .green,
            tracker: tracker
        ) { _ in /* no-op */ }

        #expect(first == second, "an identical chart must compare equal, or the body is rebuilt for nothing")
    }

    /// The x-scale runs `0...samples.last.distanceMeters`, while the tracker
    /// and the live position are placed using `profile.distances`, which
    /// always covers the whole route. If the last plotted sample stops short,
    /// the hiker's own position falls outside the chart near the finish.
    @Test("the last plotted sample reaches the end of the route")
    func lastSampleReachesTheEnd() throws {
        let profile = RouteProfile(route: Self.longRoute)
        let totalDistance = try #require(profile.distances.last)
        let lastPlotted = try #require(profile.samples.last).distanceMeters
        #expect(lastPlotted.isApproximatelyEqual(to: totalDistance, absoluteTolerance: 1))
    }

    @Test("the first plotted sample starts at the beginning of the route")
    func firstSampleStartsAtZero() throws {
        let profile = RouteProfile(route: Self.longRoute)
        #expect(try #require(profile.samples.first).distanceMeters == 0)
    }

    /// Charts plots in the order given; an out-of-order sample draws a line
    /// back across the trail.
    @Test("plotted samples ascend by distance")
    func plottedSamplesAscend() {
        let profile = RouteProfile(route: Self.longRoute)
        for (previous, next) in zip(profile.samples, profile.samples.dropFirst()) {
            #expect(next.distanceMeters > previous.distanceMeters)
        }
    }

    /// Scrubbing resolves the callout through `sample(atDistance:)`, so
    /// whatever is plotted has to stay answerable across the whole route.
    @Test("every distance along the route still resolves to a plotted sample")
    func scrubbingResolvesEverywhere() throws {
        let profile = RouteProfile(route: Self.longRoute)
        let total = try #require(profile.distances.last)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let sample = try #require(profile.sample(atDistance: total * fraction))
            #expect(sample.distanceMeters >= 0)
            #expect(sample.distanceMeters <= total + 1)
        }
    }

    // MARK: Identity

    /// `ForEach` diffs the plotted samples by `id`, and `ElevationSample.id`
    /// is the sample's own `distanceMeters` — unique within a profile and
    /// identical across rebuilds, so redrawing the same route diffs as a match
    /// rather than a wholesale replacement. A per-instance `UUID` would give
    /// neither, and would be allocated per sample besides.
    @Test("a sample's identity is stable across rebuilds of the same route")
    func sampleIdentityIsStable() {
        let first = RouteProfile(route: Fixture.ridgeRoute)
        let second = RouteProfile(route: Fixture.ridgeRoute)
        #expect(first.samples.map(\.id) == second.samples.map(\.id))
    }

    // MARK: The view's own equality

    /// `ElevationChartView.==` catches the parent reconstructing the view with
    /// a genuinely different `tint` or `profile`. It compares the plotted
    /// samples by value rather than by count, so two trails of the same length
    /// are told apart — an equality that only counted them would leave the
    /// chart drawing the old one while a profile changed in place underneath
    /// it, which is what a live recording would do between two ticks.
    @Test("equality distinguishes two different trails of the same length")
    func equalityCatchesADifferentProfile() {
        let tracker = TrackerState()
        let alpine = Fixture.ridgeRoute.map { coord in
            RouteCoordinate(
                latitude: coord.latitude + 10,
                longitude: coord.longitude + 10,
                elevation: (coord.elevation ?? 0) + 500
            )
        }
        let a = ElevationChartView(
            profile: RouteProfile(route: Fixture.ridgeRoute),
            tint: .green,
            tracker: tracker
        ) { _ in /* no-op */ }
        let b = ElevationChartView(
            profile: RouteProfile(route: alpine),
            tint: .green,
            tracker: tracker
        ) { _ in /* no-op */ }
        #expect(a != b, "same number of points, entirely different trail")
    }

    /// The deliberate half of that equality: tracker movement reaches the
    /// chart through Observation, never through this comparison, so it must
    /// not be part of it.
    @Test("equality ignores the tracker, and catches tint and length")
    func equalityIgnoresTheTracker() {
        let tracker = TrackerState()
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let base = ElevationChartView(profile: profile, tint: .green, tracker: tracker) { _ in /* no-op */ }

        tracker.trackerDistance = 500
        tracker.liveTrackerDistance = 250
        #expect(base == ElevationChartView(profile: profile, tint: .green, tracker: tracker) { _ in /* no-op */ })

        #expect(base != ElevationChartView(profile: profile, tint: .red, tracker: tracker) { _ in /* no-op */ })
        #expect(base != ElevationChartView(
            profile: RouteProfile(route: Array(Fixture.ridgeRoute.dropLast())),
            tint: .green,
            tracker: tracker
        ) { _ in /* no-op */ })
    }
}
