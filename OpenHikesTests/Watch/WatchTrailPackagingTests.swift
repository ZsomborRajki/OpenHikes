//
//  WatchTrailPackagingTests.swift
//  OpenHikesTests
//
//  What a hike looks like once it has been made small enough for a watch.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import Testing

@Suite("Packaging a trail for the watch")
struct WatchTrailPackagingTests {
    @Test("a long route is decimated to the budget, endpoints intact")
    func aLongRouteIsBounded() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.longInput))

        #expect(package.points.count == WatchTrailPackage.pointBudget)
        #expect(package.points.first?.latitude == Fixture.longRoute.first?.latitude)
        #expect(package.points.last?.latitude == Fixture.longRoute.last?.latitude)
    }

    @Test("the same hike packaged again is nothing new to a watch that holds it")
    func repackagingIsNotResent() async throws {
        // What the phone does when a watch asks again for a trail it holds —
        // issue #694. Packaging has to be deterministic for this to hold, or
        // every re-ask would resend the whole line.
        // One input, read once: each read of the fixture is a new hike.
        let input = Fixture.longInput
        let held = try #require(await WatchTrailPackaging.package(from: input))
        let again = try #require(await WatchTrailPackaging.package(from: input))
        let crossed = try WatchLink.trailPackage(from: WatchLink.message(held))

        #expect(!WatchTrailRequest(hikeID: held.hikeID, holding: crossed).needs(again))
    }

    @Test("a short route crosses whole")
    func aShortRouteIsNotTouched() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.shortInput))

        #expect(package.points.count == Fixture.shortRoute.count)
    }

    @Test("each kept point carries its own height, not a neighbour's")
    func elevationsLineUpWithTheirPoints() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.longInput))

        // The route's elevation is a strict function of its latitude, so a
        // point whose height belongs to a different point is detectable
        // without knowing which indices the stride picked.
        for point in package.points {
            let expected = Fixture.elevation(atLatitude: point.latitude)
            let actual = try #require(point.elevationMeters)
            #expect(actual.isApproximatelyEqual(to: expected, absoluteTolerance: 0.001))
        }
    }

    @Test("the trail's length is the hike's own figure, not the shortened line's")
    func lengthIsTheHikesOwn() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.longInput))

        #expect(package.totalDistanceMeters == Fixture.longInput.totalDistanceMeters)
        // And the line really is shorter, which is what makes that matter:
        // measuring against what was sent would tell a hiker the trail is
        // shorter than the phone says it is.
        var tracker = WatchRouteTracker(package)
        let last = try #require(package.points.last)
        let end = tracker.advance(latitude: last.latitude, longitude: last.longitude)
        let atEnd = try #require(end)
        #expect(atEnd.fractionComplete > 0.99)
    }

    @Test("climb and descent are measured before the route is shortened")
    func totalsAreMeasuredOnTheWholeRoute() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.sawtoothInput))

        // Every one of the fifty little rises is a metre, and every one of the
        // fifty dips is a metre. A budget-sized decimation of this route drops
        // most of them; measuring after it would report a fraction of the
        // climb a hiker actually does.
        let gain = try #require(package.elevationGainMeters)
        #expect(gain.isApproximatelyEqual(to: Fixture.sawtoothGainMeters, absoluteTolerance: 0.001))
        let loss = try #require(package.elevationLossMeters)
        #expect(loss.isApproximatelyEqual(to: Fixture.sawtoothLossMeters, absoluteTolerance: 0.001))
    }

    @Test("a route with one point is a place, and is not sent")
    func onePointIsNotSent() async {
        let package = await WatchTrailPackaging.package(from: Fixture.singlePointInput)

        #expect(package == nil)
    }

    @Test("a route with no heights says so rather than reporting no climb")
    func absentElevationsStayAbsent() async throws {
        let package = try #require(await WatchTrailPackaging.package(from: Fixture.flatlessInput))

        #expect(package.elevationGainMeters == nil)
        #expect(package.elevationLossMeters == nil)
        #expect(package.points.allSatisfy { $0.elevationMeters == nil })
    }

    enum Fixture {
        static let baseLatitude = 47.55
        static let longitude = 12.90
        static let latitudeStep = 0.00002
        static let elevationPerDegree = 100_000.0

        /// Height as a strict function of latitude, so a misaligned elevation
        /// is detectable without knowing the stride.
        static func elevation(atLatitude latitude: Double) -> Double {
            (latitude - baseLatitude) * elevationPerDegree + 600
        }

        static let longRoute: [RouteCoordinate] = (0..<5000).map { step in
            let latitude = baseLatitude + Double(step) * latitudeStep
            return RouteCoordinate(
                latitude: latitude,
                longitude: longitude,
                elevation: elevation(atLatitude: latitude)
            )
        }

        static let shortRoute: [RouteCoordinate] = (0..<10).map { step in
            let latitude = baseLatitude + Double(step) * latitudeStep
            return RouteCoordinate(
                latitude: latitude,
                longitude: longitude,
                elevation: elevation(atLatitude: latitude)
            )
        }

        /// Fifty one-metre rises and fifty one-metre dips over a route long
        /// enough that decimation throws most of them away.
        static let sawtoothRoute: [RouteCoordinate] = (0..<5000).map { step in
            RouteCoordinate(
                latitude: baseLatitude + Double(step) * latitudeStep,
                longitude: longitude,
                elevation: 600 + (step.isMultiple(of: 2) ? 0 : 1)
            )
        }

        static let sawtoothGainMeters = 2500.0
        static let sawtoothLossMeters = 2499.0

        static let flatlessRoute: [RouteCoordinate] = (0..<10).map { step in
            RouteCoordinate(
                latitude: baseLatitude + Double(step) * latitudeStep,
                longitude: longitude
            )
        }

        @MainActor
        static var longInput: HikeRouteInput { input(route: longRoute) }
        @MainActor
        static var shortInput: HikeRouteInput { input(route: shortRoute) }
        @MainActor
        static var sawtoothInput: HikeRouteInput { input(route: sawtoothRoute) }
        @MainActor
        static var flatlessInput: HikeRouteInput { input(route: flatlessRoute) }
        @MainActor
        static var singlePointInput: HikeRouteInput {
            input(route: [RouteCoordinate(latitude: baseLatitude, longitude: longitude)])
        }

        /// Built through a real `Hike`, because reading a model on the main
        /// actor is what `HikeRouteInput` exists to be: a fixture that bypassed it
        /// would not exercise the seam.
        @MainActor
        private static func input(route: [RouteCoordinate]) -> HikeRouteInput {
            let profile = RouteProfile(route: route)
            let hike = Hike(
                title: "Packaged",
                distanceMeters: profile.distances.last ?? 0,
                route: route
            )
            return HikeRouteInput(hike: hike)
        }
    }
}
