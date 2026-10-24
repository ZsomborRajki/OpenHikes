//
//  WatchTrailPackagingPauseBudgetTests.swift
//  OpenHikesTests
//
//  A route with more pauses than the watch's point budget can carry (#1023).
//  A GPX import marks the first point of every `<trkseg>` after the first as
//  a pause, and nothing bounds how many segments a file holds, so the phone
//  kept both ends of every one: a 2,000-segment file crossed as 4,648 points
//  and drew about 6,000 polylines on the watch.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

@Suite("Packaging a heavily segmented trail for the watch")
struct WatchTrailPackagingPauseBudgetTests {
    @Test("a route with more pauses than the budget crosses as exactly the budget")
    func pointsComeToTheBudget() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.segmentedInput))

        #expect(package.points.count == WatchTrailPackage.pointBudget)
        #expect(package.pauseIndices.count == WatchTrailPackage.pauseBudget)
        // What the watch's map draws: a casing and a line per walked run, and
        // one line per paused stretch.
        let polylines = 2 * package.walkedRuns.count + package.pausedStretches.count
        #expect(polylines <= 3 * WatchTrailPackage.pauseBudget + 2)
        #expect(package.points.first?.latitude == Fixture.segmentedRoute.first?.latitude)
        #expect(package.points.last?.latitude == Fixture.segmentedRoute.last?.latitude)
    }

    @Test("every pause the package keeps is one leg of the route, and nothing else")
    func eachKeptPauseIsExactlyOneLeg() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.segmentedInput))
        try #require(!package.pauseIndices.isEmpty)

        for resumed in package.pauseIndices {
            let after = try #require(Fixture.routeIndex(of: package.points[resumed]))
            let before = try #require(Fixture.routeIndex(of: package.points[resumed - 1]))
            #expect(before == after - 1, "the pause at \(after) spans more than its own leg")
            #expect(Fixture.segmentedRoute[after].isPauseBoundary)
        }
    }

    /// The breaks a hiker would see as a drive are the long ones; the short
    /// ones are a GPS dropout on the walk itself, where measuring across the
    /// gap is the smaller error.
    @Test("the longest breaks are the ones kept")
    func theLongestBreaksSurvive() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.segmentedInput))
        let kept = try Set(package.pauseIndices.map { try #require(Fixture.routeIndex(of: package.points[$0])) })

        #expect(Fixture.driveStarts.isSubset(of: kept))
    }

    enum Fixture {
        static let baseLatitude = 47.55
        static let longitude = 12.90
        static let latitudeStep = 0.00002
        static let segmentCount = 2000
        static let pointsPerSegment = 10

        /// Segments whose break is a kilometre rather than a few metres.
        static let driveSegments: Set<Int> = [7, 500, 1999]

        /// The route index each drive resumes on.
        static var driveStarts: Set<Int> { Set(driveSegments.map { $0 * pointsPerSegment }) }

        /// 2,000 segments of ten points, each break a short hop except for
        /// ``driveSegments``. Latitude only ever increases, so a kept point
        /// names its own route index.
        static let segmentedRoute: [RouteCoordinate] = {
            var latitude = baseLatitude
            var route: [RouteCoordinate] = []
            for segment in 0..<segmentCount {
                for offset in 0..<pointsPerSegment {
                    let resumes = segment > 0 && offset == 0
                    if resumes { latitude += driveSegments.contains(segment) ? 0.01 : 0.0001 }
                    latitude += latitudeStep
                    route.append(RouteCoordinate(
                        latitude: latitude,
                        longitude: longitude,
                        boundary: resumes ? .paused : nil
                    ))
                }
            }
            return route
        }()

        private static let indexByLatitude: [Double: Int] = Dictionary(
            uniqueKeysWithValues: segmentedRoute.enumerated().map { ($0.element.latitude, $0.offset) }
        )

        static func routeIndex(of point: WatchTrailPoint) -> Int? {
            indexByLatitude[point.latitude]
        }

        /// Built through a real `Hike`, as ``WatchTrailPackagingTests`` builds
        /// its inputs, so the seam is the one the phone uses.
        @MainActor static var segmentedInput: HikeRouteInput {
            let route = segmentedRoute
            let hike = Hike(
                title: "Segmented",
                distanceMeters: RouteProfile(route: route).distances.last ?? 0,
                route: route
            )
            return HikeRouteInput(hike: hike)
        }
    }
}
