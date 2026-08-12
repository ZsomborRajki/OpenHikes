//
//  StadiaRecordingMatcher.swift
//  OpenTrails
//
//  Explicitly opt-in, post-recording map matching. Live fixes never leave the
//  device; HikeRecorder invokes this only after Stop and falls back to the
//  on-device result if the request fails.
//

import CoreLocation
import Foundation
import OpenTrailsShared

nonisolated protocol RecordingOnlineMatching: Sendable {
    func match(points: [RecordingPoint]) async throws -> [RouteCoordinate]
}

nonisolated enum RecordingOnlineMatchError: LocalizedError, Equatable,
    Sendable {
    case invalidResponse
    case server(Int)
    case malformedRoute

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The online matcher returned an invalid response."
        case .server(let statusCode):
            "The online matcher returned HTTP \(statusCode)."
        case .malformedRoute:
            "The online matcher returned no usable route."
        }
    }
}

nonisolated struct RecordingOnlineHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

actor StadiaRecordingMatcher: RecordingOnlineMatching {
    typealias Transport = @Sendable (URLRequest) async throws
        -> RecordingOnlineHTTPResponse

    private let apiKey: String
    private let endpoint: URL
    private let transport: Transport

    init(
        apiKey: String,
        endpoint: URL = URL(
            string: "https://api.stadiamaps.com/map_match/v1"
        )!,
        transport: Transport? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(
                for: request
            )
            guard let response = response as? HTTPURLResponse else {
                throw RecordingOnlineMatchError.invalidResponse
            }
            return RecordingOnlineHTTPResponse(
                data: data,
                statusCode: response.statusCode
            )
        }
    }

    func match(
        points: [RecordingPoint]
    ) async throws -> [RouteCoordinate] {
        guard points.count > 1 else {
            throw RecordingOnlineMatchError.malformedRoute
        }
        let request = try Self.request(
            endpoint: endpoint,
            apiKey: apiKey,
            points: points
        )
        let response = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw RecordingOnlineMatchError.server(response.statusCode)
        }
        return try Self.decodeRoute(
            response.data,
            sourcePoints: points
        )
    }

    private nonisolated static func request(
        endpoint: URL,
        apiKey: String,
        points: [RecordingPoint]
    ) throws -> URLRequest {
        struct ShapePoint: Encodable {
            let lat: Double
            let lon: Double
            let time: Int
        }
        struct TraceOptions: Encodable {
            let gpsAccuracy: Double
            let turnPenaltyFactor = 500

            enum CodingKeys: String, CodingKey {
                case gpsAccuracy = "gps_accuracy"
                case turnPenaltyFactor = "turn_penalty_factor"
            }
        }
        struct Body: Encodable {
            let shape: [ShapePoint]
            let costing = "pedestrian"
            let shapeMatch = "map_snap"
            let directionsType = "none"
            let useTimestamps = true
            let traceOptions: TraceOptions

            enum CodingKeys: String, CodingKey {
                case shape
                case costing
                case shapeMatch = "shape_match"
                case directionsType = "directions_type"
                case useTimestamps = "use_timestamps"
                case traceOptions = "trace_options"
            }
        }

        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components?.url else {
            throw RecordingOnlineMatchError.invalidResponse
        }

        let accuracy = points
            .map(\.horizontalAccuracy)
            .filter { $0.isFinite && $0 >= 0 }
        let averageAccuracy = accuracy.isEmpty
            ? 20
            : accuracy.reduce(0, +) / Double(accuracy.count)
        let body = Body(
            shape: points.map {
                ShapePoint(
                    lat: $0.latitude,
                    lon: $0.longitude,
                    time: Int($0.timestamp.timeIntervalSince1970.rounded())
                )
            },
            traceOptions: TraceOptions(
                gpsAccuracy: min(50, max(4, averageAccuracy))
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            TileCache.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private nonisolated static func decodeRoute(
        _ data: Data,
        sourcePoints: [RecordingPoint]
    ) throws -> [RouteCoordinate] {
        struct Response: Decodable {
            struct Trip: Decodable {
                struct Leg: Decodable {
                    let shape: String
                }

                let legs: [Leg]
            }

            let trip: Trip
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RecordingOnlineMatchError.invalidResponse
        }

        var coordinates: [CLLocationCoordinate2D] = []
        for leg in response.trip.legs {
            let decoded = try decodePolyline6(leg.shape)
            if coordinates.isEmpty {
                coordinates.append(contentsOf: decoded)
            } else {
                coordinates.append(contentsOf: decoded.dropFirst())
            }
        }
        guard coordinates.count > 1,
              coordinates.allSatisfy({
                  Mercator.isRepresentable(
                      latitude: $0.latitude,
                      longitude: $0.longitude
                  )
              })
        else {
            throw RecordingOnlineMatchError.malformedRoute
        }
        let sourceCoordinates = sourcePoints.map(\.coordinate)
        let matchedDistance = cumulativeDistances(coordinates).last ?? 0
        let sourceDistance = cumulativeDistances(sourceCoordinates).last ?? 0
        let startTolerance = max(
            100,
            sourcePoints.first.map { $0.horizontalAccuracy * 3 } ?? 100
        )
        let endTolerance = max(
            100,
            sourcePoints.last.map { $0.horizontalAccuracy * 3 } ?? 100
        )
        guard matchedDistance > 0,
              matchedDistance <= sourceDistance * 1.75 + 500,
              RouteGeometry.distanceMeters(
                  from: coordinates[0],
                  to: sourceCoordinates[0]
              ) <= startTolerance,
              RouteGeometry.distanceMeters(
                  from: coordinates[coordinates.count - 1],
                  to: sourceCoordinates[sourceCoordinates.count - 1]
              ) <= endTolerance
        else {
            throw RecordingOnlineMatchError.malformedRoute
        }
        return routeCoordinates(
            along: coordinates,
            sourcePoints: sourcePoints
        )
    }

    private nonisolated static func decodePolyline6(
        _ encoded: String
    ) throws -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var coordinates: [CLLocationCoordinate2D] = []

        func component() throws -> Int {
            var result = 0
            var shift = 0
            while true {
                guard index < bytes.count else {
                    throw RecordingOnlineMatchError.malformedRoute
                }
                let value = Int(bytes[index]) - 63
                index += 1
                guard value >= 0 else {
                    throw RecordingOnlineMatchError.malformedRoute
                }
                result |= (value & 0x1F) << shift
                shift += 5
                guard shift <= 30 else {
                    throw RecordingOnlineMatchError.malformedRoute
                }
                if value < 0x20 { break }
            }
            return (result & 1) == 1
                ? ~(result >> 1)
                : result >> 1
        }

        while index < bytes.count {
            latitude += try component()
            longitude += try component()
            coordinates.append(
                CLLocationCoordinate2D(
                    latitude: Double(latitude) / 1_000_000,
                    longitude: Double(longitude) / 1_000_000
                )
            )
        }
        return coordinates
    }

    private nonisolated static func routeCoordinates(
        along coordinates: [CLLocationCoordinate2D],
        sourcePoints: [RecordingPoint]
    ) -> [RouteCoordinate] {
        let matchedDistances = cumulativeDistances(
            coordinates.map { $0 }
        )
        let sourceDistances = cumulativeDistances(
            sourcePoints.map(\.coordinate)
        )
        let matchedTotal = matchedDistances.last ?? 0
        let sourceTotal = sourceDistances.last ?? 0

        func coordinate(at distance: Double) -> CLLocationCoordinate2D {
            guard coordinates.count > 1 else {
                return coordinates[0]
            }
            var upperIndex = 1
            while upperIndex < matchedDistances.count - 1,
                  matchedDistances[upperIndex] < distance {
                upperIndex += 1
            }
            let lowerIndex = max(0, upperIndex - 1)
            let lowerDistance = matchedDistances[lowerIndex]
            let upperDistance = matchedDistances[upperIndex]
            let fraction = upperDistance > lowerDistance
                ? (distance - lowerDistance)
                    / (upperDistance - lowerDistance)
                : 0
            return RouteGeometry.interpolate(
                from: coordinates[lowerIndex],
                to: coordinates[upperIndex],
                fraction: min(max(fraction, 0), 1)
            )
        }

        var samples = zip(matchedDistances, coordinates).map {
            (distance: $0.0, coordinate: $0.1)
        }
        if matchedTotal > 0, sourceTotal > 0 {
            for index in sourcePoints.indices
            where sourcePoints[index].flags.contains(.nonPedestrian) {
                let distance = matchedTotal
                    * sourceDistances[index] / sourceTotal
                samples.append(
                    (
                        distance: distance,
                        coordinate: coordinate(at: distance)
                    )
                )
            }
        }
        samples.sort { $0.distance < $1.distance }
        var uniqueSamples: [(distance: Double, coordinate: CLLocationCoordinate2D)] = []
        for sample in samples {
            if let previous = uniqueSamples.last,
               abs(previous.distance - sample.distance) <= 0.01 {
                continue
            }
            uniqueSamples.append(sample)
        }

        var sourceIndex = 1
        return uniqueSamples.map { sample in
            let fraction = matchedTotal > 0
                ? sample.distance / matchedTotal
                : 0
            let sourceDistance = sourceTotal * fraction
            while sourceIndex < sourceDistances.count - 1,
                  sourceDistances[sourceIndex] < sourceDistance {
                sourceIndex += 1
            }
            let lowerIndex = max(0, sourceIndex - 1)
            let upperIndex = min(sourceIndex, sourcePoints.count - 1)
            let lowerDistance = sourceDistances[lowerIndex]
            let upperDistance = sourceDistances[upperIndex]
            let localFraction = upperDistance > lowerDistance
                ? (sourceDistance - lowerDistance)
                    / (upperDistance - lowerDistance)
                : 0
            let lower = sourcePoints[lowerIndex]
            let upper = sourcePoints[upperIndex]
            return RouteCoordinate(
                latitude: sample.coordinate.latitude,
                longitude: sample.coordinate.longitude,
                elevation: interpolatedElevation(
                    lower.elevation,
                    upper.elevation,
                    fraction: localFraction
                ),
                timestamp: lower.timestamp.addingTimeInterval(
                    upper.timestamp.timeIntervalSince(lower.timestamp)
                        * localFraction
                ),
                motion: lower.flags.contains(.nonPedestrian)
                    || upper.flags.contains(.nonPedestrian)
                    ? .nonPedestrian
                    : nil
            )
        }
    }

    private nonisolated static func cumulativeDistances(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var result = [0.0]
        result.reserveCapacity(coordinates.count)
        for index in 1..<coordinates.count {
            result.append(
                result[index - 1]
                    + RouteGeometry.distanceMeters(
                        from: coordinates[index - 1],
                        to: coordinates[index]
                    )
            )
        }
        return result
    }

    private nonisolated static func interpolatedElevation(
        _ lower: Double?,
        _ upper: Double?,
        fraction: Double
    ) -> Double? {
        switch (lower, upper) {
        case let (.some(lower), .some(upper)):
            lower + (upper - lower) * fraction
        case let (.some(value), .none), let (.none, .some(value)):
            value
        case (.none, .none):
            nil
        }
    }
}
