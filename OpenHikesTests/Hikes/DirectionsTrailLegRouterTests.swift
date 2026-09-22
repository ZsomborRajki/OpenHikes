import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Apple Maps trail legs")
struct DirectionsTrailLegRouterTests {
    private static let ends = TrailLegEnds(
        start: RouteCoordinate(latitude: 47.50, longitude: 19.04),
        end: RouteCoordinate(latitude: 47.51, longitude: 19.05)
    )

    @Test("requests use the chosen transport and ordered stops", arguments: [
        TrailTravelMode.walking, .cycling, .driving,
    ])
    func requestMode(_ mode: TrailTravelMode) {
        let request = DirectionsTrailLegRouter.request(for: Self.ends, mode: mode)
        let expected: MKDirectionsTransportType = switch mode {
        case .walking: .walking
        case .cycling: .cycling
        case .driving: .automobile
        case .hiking: .any
        }
        #expect(request.transportType == expected)
        #expect(request.source?.location.coordinate.latitude == Self.ends.start.latitude)
        #expect(request.destination?.location.coordinate.longitude == Self.ends.end.longitude)
        #expect(request.requestsAlternateRoutes)
    }

    @Test("the routed shape and its measured length are kept")
    func geometry() async throws {
        let bend = RouteCoordinate(latitude: 47.50, longitude: 19.05)
        let router = DirectionsTrailLegRouter(mode: .walking) { ends, _ in
            [.init(coordinates: [ends.start, bend, ends.end], travelTime: 600)]
        }
        let route = try #require(await router.route(Self.ends))
        #expect(route.snap == .snapped)
        #expect(route.coordinates.contains(bend))
        #expect(route.distanceMeters > Self.ends.straightDistanceMeters)
        #expect(route.travelTime == 600)
        #expect(route.alternatives.isEmpty)
    }

    @Test("Apple's other routes are offered beside the first, each with its own time")
    func alternatives() async throws {
        let east = RouteCoordinate(latitude: 47.50, longitude: 19.05)
        let north = RouteCoordinate(latitude: 47.51, longitude: 19.04)
        let router = DirectionsTrailLegRouter(mode: .driving) { ends, _ in
            [
                .init(coordinates: [ends.start, east, ends.end], travelTime: 300),
                .init(coordinates: [ends.start, north, ends.end], travelTime: 420),
            ]
        }
        let route = try #require(await router.route(Self.ends))
        #expect(route.coordinates.contains(east))
        #expect(route.alternatives.count == 1)
        let alternative = try #require(route.alternatives.first)
        #expect(alternative.coordinates.contains(north))
        #expect(alternative.coordinates.first == Self.ends.start)
        #expect(alternative.coordinates.last == Self.ends.end)
        #expect(alternative.travelTime == 420)
    }

    @Test("unchecked access from a stop is visibly degraded")
    func accessConnector() async throws {
        let router = DirectionsTrailLegRouter(mode: .driving) { ends, _ in
            [.init(coordinates: [RouteCoordinate(latitude: 47.505, longitude: 19.045), ends.end])]
        }
        let route = try #require(await router.route(Self.ends))
        #expect(route.snap == .unmapped(.endpointOffNetwork))
        #expect(route.snap.isDegraded)
        #expect(route.coordinates.first == Self.ends.start)
        #expect(route.coordinates.last == Self.ends.end)
    }

    @Test("a missing route is an answer rather than a service refusal")
    func noRoute() async throws {
        let router = DirectionsTrailLegRouter(mode: .cycling) { _, _ in
            throw MKError(.directionsNotFound)
        }
        let route = try #require(await router.route(Self.ends))
        #expect(route.snap == .unmapped(.noDirections))
        #expect(!route.snap.isRetryable)
        #expect(route.coordinates == Self.ends.straightCoordinates)
    }

    @Test("offline and throttled directions say which service refused")
    func serviceFailures() async throws {
        let offline = DirectionsTrailLegRouter(mode: .walking) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let busy = DirectionsTrailLegRouter(mode: .cycling) { _, _ in
            throw MKError(.loadingThrottled)
        }
        #expect(await offline.route(Self.ends)?.snap == .directionsUnavailable(.offline))
        let route = try #require(await busy.route(Self.ends))
        #expect(route.snap == .directionsUnavailable(.busy))
        #expect(route.snap.isRetryable)
        #expect(route.snap.notice?.text.contains("Apple Maps") == true)
    }

    @Test("cache preserves direction and does not remember refusals")
    func cacheAndRetry() async {
        let calls = Calls()
        let router = DirectionsTrailLegRouter(mode: .driving) { ends, _ in
            try await calls.calculate(ends)
        }
        #expect(await router.route(Self.ends)?.snap.isRetryable == true)
        #expect(await router.route(Self.ends)?.snap == .snapped)
        _ = await router.route(Self.ends)
        _ = await router.route(Self.ends.flipped)
        #expect(await calls.count == 3)
    }

    @Test("invalid geometry cannot become a snapped route")
    func invalidGeometry() async {
        let router = DirectionsTrailLegRouter(mode: .walking) { ends, _ in
            [.init(coordinates: [ends.start, RouteCoordinate(latitude: .nan, longitude: 19)])]
        }
        #expect(await router.route(Self.ends)?.snap == .unmapped(.noDirections))
    }

    @Test("cancellation never becomes an unavailable-route warning")
    func cancellation() async {
        let router = DirectionsTrailLegRouter(mode: .walking) { _, _ in throw CancellationError() }
        #expect(await router.route(Self.ends) == nil)
    }

    @Test("a transport that answers after cancellation cannot publish or cache its route")
    func lateTransportAnswer() async {
        let gate = CalculationGate()
        let router = DirectionsTrailLegRouter(mode: .cycling) { ends, _ in
            await gate.calculate(ends)
        }
        let request = Task { await router.route(Self.ends) }
        await gate.waitUntilStarted()
        request.cancel()
        await gate.release()
        #expect(await request.value == nil)
        #expect(await router.route(Self.ends)?.snap == .snapped)
        #expect(await gate.count == 2)
    }

    private actor CalculationGate {
        var count = 0
        private var waiting: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func calculate(_ ends: TrailLegEnds) async -> [DirectionsTrailLegRouter.Answer] {
            count += 1
            if count == 1 {
                await withCheckedContinuation { continuation in
                    waiting = continuation
                    started?.resume()
                    started = nil
                }
            }
            return [.init(coordinates: ends.straightCoordinates)]
        }

        func waitUntilStarted() async {
            guard waiting == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }
    }

    private actor Calls {
        var count = 0

        func calculate(_ ends: TrailLegEnds) throws -> [DirectionsTrailLegRouter.Answer] {
            count += 1
            if count == 1 { throw URLError(.notConnectedToInternet) }
            return [.init(coordinates: ends.straightCoordinates)]
        }
    }
}
