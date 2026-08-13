//
//  ElevationChartWorkloadTests.swift
//  OpenTrailsTests
//
//  The elevation chart is the app's most expensive view and its most
//  frequently invalidated one — a bad combination that only shows up on long
//  tracks. `ElevationChartView` plots two marks (an `AreaMark` and a
//  `LineMark`, both `catmullRom`-interpolated) per elevation sample, and
//  every sample of the imported GPX is a sample: a 1 Hz five-hour recording
//  is 18,000 points, so 36,000 marks. That view is invalidated on every
//  scrub event (drag frequency) and once a second by auto-follow.
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
@testable import OpenTrails
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

        #expect(abs(range.lowerBound - trueLow) < 1)
        #expect(abs(range.upperBound - trueHigh) < 1)
    }

    /// The x-scale runs `0...samples.last.distanceMeters`, while the tracker
    /// and the live position are placed using `profile.distances`, which
    /// always covers the whole route. If the last plotted sample stops short,
    /// the walker's own position falls outside the chart near the finish.
    @Test("the last plotted sample reaches the end of the route")
    func lastSampleReachesTheEnd() throws {
        let profile = RouteProfile(route: Self.longRoute)
        let totalDistance = try #require(profile.distances.last)
        let lastPlotted = try #require(profile.samples.last).distanceMeters
        #expect(abs(lastPlotted - totalDistance) < 1)
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

    /// `ForEach` diffs the plotted samples by `id`. `ElevationSample.id` is a
    /// fresh `UUID` per instance, so rebuilding the profile for the same
    /// route produces an entirely new set of identities and the chart diffs
    /// as a wholesale replacement rather than a match.
    ///
    /// It isn't free to generate, either: of the 8.2 ms spent building a
    /// 20,000-point profile, 4.6 ms is `UUID()`. The sample's distance is
    /// already a unique, stable key.
    @Test("a sample's identity is stable across rebuilds of the same route")
    func sampleIdentityIsStable() {
        let first = RouteProfile(route: Fixture.ridgeRoute)
        let second = RouteProfile(route: Fixture.ridgeRoute)
        #expect(first.samples.map(\.id) == second.samples.map(\.id))
    }

    // MARK: The view's own equality

    /// `ElevationChartView.==` exists to "catch the parent reconstructing the
    /// view with a genuinely different `tint`/`profile`" — but it compares
    /// only the *counts* of the samples and distances, so two different
    /// trails of the same length are indistinguishable to it, and the chart
    /// keeps drawing the old one.
    ///
    /// Hard to hit today (a pushed detail view is torn down per hike), which
    /// is exactly why it's worth pinning: live recording — the next feature
    /// on the list — changes a profile in place while its length stays put
    /// between two ticks, and this is what would silently freeze the graph.
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
