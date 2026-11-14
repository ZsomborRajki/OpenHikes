//
//  DrawnRouteSquare+Waymarks.swift
//  OpenHikes
//
//  Where along each route its signs stand: every so many metres of the
//  route's ways in the square, starting half that far in, so a route has a
//  sign wherever the map shows a stretch of it and a short spur still gets
//  one.
//
//  A route's ways are walked in the order the square holds them, which is not
//  the order a hiker meets them, so the spacing is a density rather than a
//  promise — what it buys is signs along the whole of a route without
//  assembling it, which this layer never does.
//

import Foundation
import MapKit

nonisolated extension DrawnRouteSquare {
    /// How far apart one route's signs stand, in metres, at `level`, or `nil`
    /// for a level drawn too far out for a sign to be read.
    static func signSpacingMeters(at level: RouteSquareLevel) -> Double? {
        switch level {
        case .overview, .region: nil
        case .area: areaSignSpacingMeters
        case .detail: detailSignSpacingMeters
        }
    }

    private static let areaSignSpacingMeters: Double = 5000
    private static let detailSignSpacingMeters: Double = 2000
    private static let metersPerDegreeLatitude: Double = 110_540
    private static let metersPerDegreeLongitude: Double = 111_320

    /// Every route's signs in `file`, the most important network's first and
    /// then by relation, so every tile weighs them in the same order.
    static func waymarks(in file: RouteSquareFile, spacingMeters spacing: Double?) -> [Waymark] {
        guard let spacing else { return [] }
        var linesOfRoute: [Int: [Int]] = [:]
        for (index, line) in file.lines.enumerated() {
            for route in line.routes {
                linesOfRoute[route, default: []].append(index)
            }
        }
        let scale = Double(file.coordinateScale)
        var marks: [Waymark] = []
        for (routeIndex, route) in file.routes.enumerated() {
            guard let sign = WaymarkSign(tags: route.tags), let lines = linesOfRoute[routeIndex] else { continue }
            let network = RouteNetwork(tag: route.tags["network"])
            let size = sign.size
            var next = spacing / 2
            var walked = 0.0
            for lineIndex in lines {
                let points = file.lines[lineIndex].points.map { point in
                    (latitude: Double(point.latitude) / scale, longitude: Double(point.longitude) / scale)
                }
                for (start, end) in zip(points, points.dropFirst()) {
                    let length = meters(from: start, to: end)
                    while walked + length >= next, length > 0 {
                        let along = (next - walked) / length
                        let point = MKMapPoint(CLLocationCoordinate2D(
                            latitude: start.latitude + (end.latitude - start.latitude) * along,
                            longitude: start.longitude + (end.longitude - start.longitude) * along
                        ))
                        marks.append(Waymark(point: point, sign: sign, size: size, network: network, routeID: route.id))
                        next += spacing
                    }
                    walked += length
                }
            }
        }
        return marks.sorted { lhs, rhs in
            lhs.network != rhs.network ? lhs.network > rhs.network : lhs.routeID < rhs.routeID
        }
    }

    /// The ground between two nearby points, on a flat projection: at the
    /// length of one segment of a way, the difference from the sphere is
    /// nothing a sign's spacing would show.
    private static func meters(
        from start: (latitude: Double, longitude: Double),
        to end: (latitude: Double, longitude: Double)
    ) -> Double {
        let dx = (end.longitude - start.longitude) * metersPerDegreeLongitude * cos(start.latitude * .pi / 180)
        let dy = (end.latitude - start.latitude) * metersPerDegreeLatitude
        return (dx * dx + dy * dy).squareRoot()
    }
}
