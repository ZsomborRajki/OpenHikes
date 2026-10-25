//
//  RouteHeightSamplesPauseTests.swift
//  OpenHikesTests
//
//  Heights read at two hundred points and written on all of them, on a route
//  with a pause in it (#1032).
//
//  A paused leg is not trail (see ``RouteBoundary``): whatever carried the
//  hiker across it — a cable car, a bus, a night in a hut — rose by however
//  much it rose, and none of that was walked. Interpolated straight across
//  the pause, the transfer's rise was spread over the walked points either
//  side of it, and level ground beside a cable car climbed at the cable
//  car's grade: into the hike's climb, its chart and its *Elevation* colours,
//  and saved onto the stored route. The source is a stub: the real one is
//  billed.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Route height samples across a pause")
struct RouteHeightSamplesPauseTests {
    nonisolated private enum Valley {
        static let south = 47.6
        static let longitude = 12.86
        /// About twenty-five metres north.
        static let spacing = 0.000225
        /// The level valley the walk starts along.
        static let floorMeters = 600.0
        /// The level ridge the cable car leaves the hiker on.
        static let ridgeMeters = 1600.0
        /// About a kilometre north, carried.
        static let transfer = 0.009
        /// About a hundred metres of ridge.
        static let ridgeSpacing = 0.0009
        /// Anything north of here is the ridge.
        static let ridgeFrom = south + 400 * spacing
    }

    /// The issue's reproduction: a GPX with no `<ele>` and two `<trkseg>`s —
    /// 397 points along a level valley, then the top of a cable car and a
    /// hundred metres of level ridge.
    private static let route: [RouteCoordinate] = {
        let valley = (0..<397).map { index in
            RouteCoordinate(latitude: Valley.south + Double(index) * Valley.spacing, longitude: Valley.longitude)
        }
        let top = Valley.south + 396 * Valley.spacing + Valley.transfer
        let ridge = [
            RouteCoordinate(latitude: top, longitude: Valley.longitude, boundary: .paused),
            RouteCoordinate(latitude: top + Valley.ridgeSpacing, longitude: Valley.longitude),
        ]
        return valley + ridge
    }()

    /// Answers the way Stadia does, one height per point asked about, from
    /// the valley and the ridge.
    nonisolated private struct ValleySource: CuratedElevationSourcing {
        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
            coordinates.map { $0.latitude < Valley.ridgeFrom ? Valley.floorMeters : Valley.ridgeMeters }
        }
    }

    /// The ends come out of the two hundred rather than on top of them, as
    /// the privacy policy's figure needs. `CuratedElevationPauseBudgetTests`
    /// holds the limit for routes with more pauses.
    @Test("both ends of a paused leg are asked about, within the request's two hundred")
    func pauseEndsAreSampled() {
        let indexes = CuratedElevationRequest.sampleIndexes(of: Self.route)

        #expect(Self.route.count > CuratedElevationRequest.maximumShapePoints, "precondition: the route is sampled")
        #expect(indexes.contains(396) && indexes.contains(397), "the last walked point and the pause's end")
        #expect(indexes.count == CuratedElevationRequest.maximumShapePoints, "the limit, and no more")
        #expect(indexes == indexes.sorted() && Set(indexes).count == indexes.count, "ascending, once each")
        #expect(indexes.first == 0 && indexes.last == Self.route.count - 1, "both ends of the route")
    }

    @Test("level ground either side of a cable car stays level")
    func levelGroundStaysLevel() async {
        let filled = await ValleySource().filled(Self.route)

        for (index, point) in filled.enumerated() {
            let expected = index < 397 ? Valley.floorMeters : Valley.ridgeMeters
            #expect(point.elevation == expected, "point \(index)")
        }
        #expect(RouteProfile(route: filled).elevation.gainMeters == 0, "the transfer is not climb")
        let runs = RouteSteepness.runs(route: filled)
        #expect(!runs.isEmpty, "precondition: the line is coloured")
        #expect(runs.allSatisfy { $0.shade == RouteShade.scale[0] }, "and level in every stretch, the ridge's too")
    }

    @Test("the sampled heights add up to no climb across the pause")
    func summaryLeavesTheTransferOut() async throws {
        let samples = try #require(await ValleySource().samples(of: Self.route))

        #expect(samples.summary.gainMeters == 0)
    }

    /// The rule itself, for a set of readings that does not have both ends of
    /// every pause — one of them not a number, say. A walked stretch keeps
    /// the reading nearest it on its own side, and a stretch with no reading
    /// of its own is given none.
    @Test("a reading never reaches across a pause")
    func readingsStayOnTheirOwnSide() {
        var line = (0..<7).map { index in
            RouteCoordinate(latitude: Valley.south + Double(index) * Valley.spacing, longitude: Valley.longitude)
        }
        line[2].boundary = .paused
        line[4].boundary = .paused
        let samples = RouteHeightSamples(
            routePointCount: line.count,
            indexes: [0, 6],
            coordinates: [line[0], line[6]],
            heights: [Valley.floorMeters, Valley.ridgeMeters]
        )

        let heights = samples.interpolating(line).map(\.elevation)

        #expect(heights == [600, 600, nil, nil, 1600, 1600, 1600])
    }

    /// A pause right beside a reading: the leg it opens is the first after
    /// the reading or the last before the next one (#1035). Each reading
    /// still holds its own side, and nothing on the far side of the pause.
    @Test("a reading beside a pause holds its own side and nothing past it")
    func readingsBesideAPause() {
        func heights(pausedAt pause: Int) -> [Double?] {
            var line = (0..<5).map { index in
                RouteCoordinate(latitude: Valley.south + Double(index) * Valley.spacing, longitude: Valley.longitude)
            }
            line[pause].boundary = .paused
            let samples = RouteHeightSamples(
                routePointCount: line.count,
                indexes: [0, 4],
                coordinates: [line[0], line[4]],
                heights: [Valley.floorMeters, Valley.ridgeMeters]
            )
            return samples.interpolating(line).map(\.elevation)
        }

        #expect(heights(pausedAt: 1) == [600, 1600, 1600, 1600, 1600], "the pause leaves the first reading")
        #expect(heights(pausedAt: 4) == [600, 600, 600, 600, 1600], "the pause arrives at the second")
    }

    /// A pause named on the first point has nothing before it to have been
    /// paused across, so it has no ends to read, and the route is asked
    /// about exactly as one with no pause is.
    @Test("a pause named on the first point adds nothing to the request")
    func pauseOnTheFirstPointIsNotSampled() {
        var line = Self.route
        line[0].boundary = .paused
        line[397].boundary = nil

        #expect(
            CuratedElevationRequest.sampleIndexes(of: line)
                == CuratedElevationRequest.sampleIndexes(count: line.count)
        )
    }
}
