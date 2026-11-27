//
//  CuratedElevationTests.swift
//  OpenHikesTests
//
//  The heights a curated route has to be given, since OpenStreetMap has none.
//
//  What is asserted here is what any source's answer goes through: which
//  points are asked about, how the heights land on a line, and what a failure
//  costs the screen. Where the heights come from — the elevation squares — is
//  ``ElevationSquareLibraryTests``'; every case below hands in a source of its
//  own.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Synchronization
import Testing

@Suite("Curated elevation")
struct CuratedElevationTests {
    /// Far enough that a moved point is a different place by any reading.
    private static let aLongWayOff = 0.01

    private static func route(_ count: Int) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.0005,
                longitude: 12.86,
                elevation: nil
            )
        }
    }

    /// A source that answers with the heights a case gives it, or throws, and
    /// counts how often it was asked.
    nonisolated private final class StubSource: CuratedElevationSourcing, @unchecked Sendable {
        private struct State {
            var asked = 0
            var heights: [Double] = []
            var failure: CuratedElevationFailure?
        }

        private let state = Mutex(State())

        var asked: Int { state.withLock(\.asked) }

        init(heights: [Double] = [], failure: CuratedElevationFailure? = nil) {
            state.withLock { current in
                current.heights = heights
                current.failure = failure
            }
        }

        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
            let (heights, failure) = state.withLock { current in
                current.asked += 1
                return (current.heights, current.failure)
            }
            if let failure { throw failure }
            return heights
        }
    }

    // MARK: Which points are asked about

    /// A route shorter than the ceiling is asked about whole — no sampling, no
    /// interpolation, one height per point of the line that is drawn.
    @Test("a short route is asked about point by point")
    func shortRouteIsAskedWhole() {
        #expect(CuratedElevationRequest.sampleIndexes(count: 5, limit: 200) == [0, 1, 2, 3, 4])
    }

    /// And a long one is thinned to the ceiling, keeping both ends: the
    /// trailhead's height and the finish's are where a hiker reads a profile
    /// from, and a series that stops short draws a chart whose x-axis
    /// disagrees with the route's own length.
    @Test("a long route is thinned to the ceiling, ends included")
    func longRouteKeepsItsEnds() {
        let indexes = CuratedElevationRequest.sampleIndexes(count: 2000, limit: 200)

        #expect(indexes.count == 200)
        #expect(indexes.first == 0)
        #expect(indexes.last == 1999)
        #expect(indexes == indexes.sorted(), "a profile is read left to right")
        #expect(Set(indexes).count == indexes.count, "a point asked about twice is a height read twice")
    }

    @Test("a route with no points asks about nothing")
    func emptyRouteAsksNothing() {
        #expect(CuratedElevationRequest.sampleIndexes(count: 0).isEmpty)
    }

    // MARK: Filling a route

    @Test("the heights land on the points they were asked about")
    func routeIsFilled() async {
        let source = StubSource(heights: [600, 620, 640, 660, 680])

        let filled = await source.filled(Self.route(5))

        #expect(filled.map(\.elevation) == [600, 620, 640, 660, 680])
        #expect(filled.map(\.latitude) == Self.route(5).map(\.latitude), "the line itself is untouched")
        #expect(source.asked == 1, "one route, one question")
    }

    /// A failure costs the chart and nothing else. The hike is a line, a
    /// length, a surface and a difficulty before it is a profile, and all four
    /// are already in hand by the time this is asked.
    @Test(
        "a source that cannot answer leaves the route exactly as it came",
        arguments: [CuratedElevationFailure.uncovered, .unreachable, .tooLong]
    )
    func failedSourceKeepsTheRoute(_ failure: CuratedElevationFailure) async {
        let source = StubSource(failure: failure)

        let filled = await source.filled(Self.route(4))

        #expect(filled.allSatisfy { $0.elevation == nil })
        #expect(filled.count == 4)
    }

    // MARK: What was measured, and which line it is about

    /// The heights are kept with the points they were read at, so a caller
    /// that comes back later can tell whether they are still about its line.
    ///
    /// This is the half the trail maker needs and the curated screen does not:
    /// a curated route is opened once and never edited, while a drawing moves
    /// under the answer.
    @Test("samples describe the route they were read for")
    func samplesDescribeTheirRoute() async throws {
        let source = StubSource(heights: [600, 620, 640])
        let route = Self.route(3)

        let samples = try #require(await source.samples(of: route))

        #expect(samples.describes(route))
        #expect(samples.interpolating(route).compactMap(\.elevation) == [600, 620, 640])
    }

    /// And a line that has changed under them is refused rather than filled
    /// approximately.
    ///
    /// The failure this forbids is silent and entirely plausible on screen: a
    /// leg that snapped while the save alert was open lengthens the route, so
    /// every sampled index moves and a height read on a summit is written on
    /// to a point in a valley.
    @Test("samples refuse a line that has changed under them")
    func samplesRefuseAChangedRoute() async throws {
        let source = StubSource(heights: [600, 620, 640])

        let samples = try #require(await source.samples(of: Self.route(3)))
        let longer = Self.route(4)

        #expect(!samples.describes(longer), "four points is a different question")
        #expect(samples.interpolating(longer).allSatisfy { $0.elevation == nil })
    }

    /// A route the same length whose points have moved is refused too — the
    /// count is the cheap half of the check and not the whole of it.
    @Test("samples refuse a line whose points have moved")
    func samplesRefuseAMovedRoute() async throws {
        let source = StubSource(heights: [600, 620, 640])

        let samples = try #require(await source.samples(of: Self.route(3)))
        var moved = Self.route(3)
        moved[1].latitude += Self.aLongWayOff

        #expect(!samples.describes(moved))
        #expect(samples.interpolating(moved).allSatisfy { $0.elevation == nil })
    }

    /// The map measures steepness from these, and a window closes at any
    /// point without a height — so every point between two readings needs
    /// one, placed by how far along the line it is.
    @Test("interpolating puts a height on every point between two readings")
    func interpolatingFillsBetweenReadings() throws {
        let route = Self.route(5)
        let samples = RouteHeightSamples(
            routePointCount: 5,
            indexes: [0, 4],
            coordinates: [route[0], route[4]],
            heights: [600, 640]
        )

        let heights = samples.interpolating(route).map(\.elevation)

        // The points are evenly spaced, so the heights are too.
        let expected: [Double] = [600, 610, 620, 630, 640]
        for (filled, wanted) in zip(heights, expected) {
            let height = try #require(filled)
            #expect(height.isApproximatelyEqual(to: wanted, absoluteTolerance: 0.01))
        }
        let other = samples.interpolating(Self.route(6))
        #expect(!other.contains { $0.elevation != nil }, "a different line is left alone")
    }

    /// A reading that is not a number is a point on ground whose heights are
    /// withheld, and no grade is drawn towards it: the readings either side
    /// keep their own points, and nothing between them and it gets a height
    /// nobody measured.
    @Test("interpolating draws nothing towards a reading that is not a number")
    func interpolatingStopsAtNonFiniteReadings() {
        let route = Self.route(5)
        let samples = RouteHeightSamples(
            routePointCount: 5,
            indexes: [0, 2, 4],
            coordinates: [route[0], route[2], route[4]],
            heights: [600, .nan, 640]
        )

        #expect(samples.interpolating(route).map(\.elevation) == [600, nil, nil, nil, 640])
    }

    /// And the answer a source gives over such ground is no answer: a line
    /// that crosses it, or lies wholly on it, gets no profile rather than one
    /// joined across ground nobody measured, and nothing for a caller to save.
    @Test(
        "a line over ground with no heights has no profile",
        arguments: [[600, .nan, 640], [.nan, .nan, .nan]] as [[Double]]
    )
    func withheldGroundHasNoProfile(_ heights: [Double]) async {
        let source = StubSource(heights: heights)

        #expect(await source.samples(of: Self.route(3)) == nil)
        #expect(await source.filled(Self.route(3)).allSatisfy { $0.elevation == nil })
        #expect(source.asked == 2, "asked, and declined, each time")
    }

    /// The source a launch gets when it must not ask — a suite, or a UI test
    /// with no curated scenario.
    @Test("the dormant source answers nothing")
    func dormantSourceAnswersNothing() async {
        await #expect(throws: CuratedElevationFailure.uncovered) {
            try await DormantElevationSource().heights(at: [
                CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            ])
        }
    }
}
