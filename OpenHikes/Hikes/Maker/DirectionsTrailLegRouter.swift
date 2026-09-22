import CoreLocation
import Foundation
import MapKit
import OpenHikesShared

/// One instance per mode; ordered endpoints never share an answer with another
/// mode or with the reverse journey. Only settled answers enter the bounded cache.
actor DirectionsTrailLegRouter: TrailLegRouting {
    typealias Calculate = @Sendable (TrailLegEnds, TrailTravelMode) async throws -> [RouteCoordinate]

    private let mode: TrailTravelMode
    private let calculate: Calculate
    private var cache: [TrailLegEnds: TrailLegRoute] = [:]
    private var order: [TrailLegEnds] = []

    init(mode: TrailTravelMode, calculate: @escaping Calculate = DirectionsTrailLegRouter.calculate) {
        precondition(mode != .hiking)
        self.mode = mode
        self.calculate = calculate
    }

    func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[ends] { return cached }
        do {
            let coordinates = try await calculate(ends, mode)
            try Task.checkCancellation()
            let result = Self.route(along: ends, coordinates: coordinates)
            if cache.updateValue(result, forKey: ends) == nil { order.append(ends) }
            while order.count > TrailLegMemo.capacity {
                cache.removeValue(forKey: order.removeFirst())
            }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { return nil }
            if let mapError = error as? MKError,
               mapError.code == .directionsNotFound || mapError.code == .placemarkNotFound {
                return .straight(along: ends, .unmapped(.noDirections))
            }
            return .straight(along: ends, .directionsUnavailable(TrailDirectionsFailure(error)))
        }
    }

    /// MapKit can stop at a road entrance instead of the pin. Keep the chosen
    /// stop, but do not present a substantial unchecked connector as routed.
    private static let endpointToleranceMeters = 10.0

    private static func route(along ends: TrailLegEnds, coordinates: [RouteCoordinate]) -> TrailLegRoute {
        guard coordinates.count > 1,
              coordinates.allSatisfy({ Mercator.isRepresentable(latitude: $0.latitude, longitude: $0.longitude) }),
              let first = coordinates.first, let last = coordinates.last else {
            return .straight(along: ends, .unmapped(.noDirections))
        }
        let connected = distance(ends.start, first) <= endpointToleranceMeters
            && distance(last, ends.end) <= endpointToleranceMeters
        let shape = [ends.start] + coordinates + [ends.end]
        let length = zip(shape, shape.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        return TrailLegRoute(
            coordinates: shape,
            distanceMeters: length,
            snap: connected ? .snapped : .unmapped(.endpointOffNetwork)
        )
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
        switch mode {
        case .walking: request.transportType = .walking
        case .cycling: request.transportType = .cycling
        case .driving: request.transportType = .automobile
        case .hiking: preconditionFailure("Hiking uses the trail graph")
        }
        return request
    }

    @concurrent
    static func calculate(_ ends: TrailLegEnds, mode: TrailTravelMode) async throws -> [RouteCoordinate] {
        try Task.checkCancellation()
        let handle = Handle(directions: MKDirections(request: request(for: ends, mode: mode)))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response = try await handle.directions.calculate()
            try Task.checkCancellation()
            guard let route = response.routes.first else { return [] }
            let line = route.polyline
            var coordinates = [CLLocationCoordinate2D](
                repeating: kCLLocationCoordinate2DInvalid, count: line.pointCount
            )
            line.getCoordinates(&coordinates, range: NSRange(location: 0, length: line.pointCount))
            return coordinates.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
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
        if let network = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(network.code) {
            self = .offline
        } else if (error as? MKError)?.code == .loadingThrottled {
            self = .busy
        } else {
            self = .unavailable
        }
    }

    var text: String {
        switch self {
        case .offline: String(localized: "Connect to the internet to get Apple Maps directions.")
        case .busy: String(localized: "Apple Maps is busy. Try again later.")
        case .unavailable: String(localized: "Apple Maps directions are unavailable. Try again.")
        }
    }
}
