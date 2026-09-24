import Algorithms
import CoreLocation
import Foundation
import MapKit
import OpenHikesData
import OpenHikesShared

/// One instance per mode; ordered endpoints never share an answer with another
/// mode or with the reverse journey. Only settled answers enter the bounded cache.
actor DirectionsTrailLegRouter: TrailLegRouting {
    /// One route Apple Maps offered: its line and its own time estimate.
    struct Answer: Equatable, Sendable {
        var coordinates: [RouteCoordinate]
        var travelTime: TimeInterval?
    }

    /// Apple's routes between the two ends, best first. Empty for none.
    typealias Calculate = @Sendable (TrailLegEnds, TrailTravelMode) async throws -> [Answer]

    private let mode: TrailTravelMode
    private let calculate: Calculate
    private var cache = TrailLegAnswerCache()

    init(mode: TrailTravelMode, calculate: @escaping Calculate = DirectionsTrailLegRouter.calculate) {
        precondition(mode != .hiking)
        self.mode = mode
        self.calculate = calculate
    }

    func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[ends] { return cached }
        do {
            let answers = try await calculate(ends, mode)
            try Task.checkCancellation()
            let result = Self.route(along: ends, answers: answers)
            cache.store(result, for: ends)
            return result
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { return nil }
            // *No route* is an answer and is cached; a phone with no signal
            // can be told the same thing by MapKit, and caching that would
            // leave the leg saying so after the signal came back, with no
            // *Try Again* to offer. So the network is asked about first.
            if let mapError = error as? MKError,
               mapError.code == .directionsNotFound || mapError.code == .placemarkNotFound,
               !TrailDirectionsFailure.isOffline(error) {
                return .straight(along: ends, .unmapped(.noDirections))
            }
            return .straight(along: ends, .directionsUnavailable(TrailDirectionsFailure(error)))
        }
    }

    /// MapKit can stop at a road entrance instead of the pin. Keep the chosen
    /// stop, but do not present a substantial unchecked connector as routed.
    ///
    /// The hiking router's own snap radius rather than a figure of its own.
    /// Apple's directions start and end on the nearest road or path, so a stop
    /// put down on a meadow, a car park or a summit is routinely tens of
    /// metres from where the route begins — at ten metres nearly every
    /// walking and cycling leg wore the warning. A hiking leg already joins
    /// its path by a connector this long without saying anything, and one
    /// rule about how far is still *at* the stop is the honest one.
    static let endpointToleranceMeters = OverpassTrailLegRouter.snapRadiusMeters

    /// The first usable answer drawn, the rest offered as alternatives. Every
    /// shape runs from the stop itself to the stop itself, connectors included.
    private static func route(along ends: TrailLegEnds, answers: [Answer]) -> TrailLegRoute {
        let usable = answers.filter { answer in
            answer.coordinates.count > 1
                && answer.coordinates.allSatisfy { point in
                    Mercator.isRepresentable(latitude: point.latitude, longitude: point.longitude)
                }
        }
        guard let best = usable.first,
              let first = best.coordinates.first, let last = best.coordinates.last else {
            return .straight(along: ends, .unmapped(.noDirections))
        }
        let connected = distance(ends.start, first) <= endpointToleranceMeters
            && distance(last, ends.end) <= endpointToleranceMeters
        let paths = usable.map { path(along: ends, $0) }
        return TrailLegRoute(
            coordinates: paths[0].coordinates,
            distanceMeters: paths[0].distanceMeters,
            snap: connected ? .snapped : .unmapped(.endpointOffNetwork),
            travelTime: paths[0].travelTime,
            alternatives: Array(paths.dropFirst())
        )
    }

    private static func path(along ends: TrailLegEnds, _ answer: Answer) -> TrailLegPath {
        let shape = [ends.start] + answer.coordinates + [ends.end]
        let length = shape.adjacentPairs().reduce(0) { $0 + distance($1.0, $1.1) }
        return TrailLegPath(coordinates: shape, distanceMeters: length, travelTime: answer.travelTime)
    }

    private static func distance(_ from: RouteCoordinate, _ to: RouteCoordinate) -> Double {
        RouteGeometry.distanceMeters(
            from: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
            to: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
        )
    }
}

nonisolated extension DirectionsTrailLegRouter {
    /// MKDirections' cancel is designed to interrupt its asynchronous request.
    /// The immutable handle lets the cancellation handler reach that same object.
    private struct Handle: @unchecked Sendable {
        let directions: MKDirections
    }

    static func request(for ends: TrailLegEnds, mode: TrailTravelMode) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            location: CLLocation(latitude: ends.start.latitude, longitude: ends.start.longitude),
            address: nil
        )
        request.destination = MKMapItem(
            location: CLLocation(latitude: ends.end.latitude, longitude: ends.end.longitude),
            address: nil
        )
        request.requestsAlternateRoutes = true
        switch mode {
        case .walking: request.transportType = .walking
        case .cycling: request.transportType = .cycling
        case .driving: request.transportType = .automobile
        case .hiking: preconditionFailure("Hiking uses the trail graph")
        }
        return request
    }

    /// Apple's own limit on alternatives is three routes; this keeps the same.
    private static let maximumRoutes = 3

    @concurrent
    static func calculate(_ ends: TrailLegEnds, mode: TrailTravelMode) async throws -> [Answer] {
        try Task.checkCancellation()
        let handle = Handle(directions: MKDirections(request: request(for: ends, mode: mode)))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response = try await handle.directions.calculate()
            try Task.checkCancellation()
            return response.routes.prefix(maximumRoutes).map { route in
                let line = route.polyline
                var coordinates = [CLLocationCoordinate2D](
                    repeating: kCLLocationCoordinate2DInvalid, count: line.pointCount
                )
                line.getCoordinates(&coordinates, range: NSRange(location: 0, length: line.pointCount))
                return Answer(
                    coordinates: coordinates.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                    travelTime: route.expectedTravelTime
                )
            }
        } onCancel: {
            handle.directions.cancel()
        }
    }
}

/// These messages describe Apple's directions service, never OpenStreetMap.
nonisolated enum TrailDirectionsFailure: Equatable, Sendable {
    case busy
    case offline
    case unavailable

    init(_ error: any Error) {
        if Self.isOffline(error) {
            self = .offline
        } else if (error as? MKError)?.code == .loadingThrottled {
            self = .busy
        } else {
            self = .unavailable
        }
    }

    /// Whether the phone could not reach the network at all.
    ///
    /// Through the underlying error as well as the error itself: MapKit
    /// rarely hands a `URLError` over bare, and reports a lost connection as
    /// one of its own errors with the network's reason underneath.
    static func isOffline(_ error: any Error) -> Bool {
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]
        if let network = error as? URLError, offline.contains(network.code) { return true }
        guard let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error else {
            return false
        }
        return isOffline(underlying)
    }

    var text: String {
        switch self {
        case .offline: String(localized: "Connect to the internet to get Apple Maps directions.")
        case .busy: String(localized: "Apple Maps is busy. Try again later.")
        case .unavailable: String(localized: "Apple Maps directions are unavailable. Try again.")
        }
    }
}
