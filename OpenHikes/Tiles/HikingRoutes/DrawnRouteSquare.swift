//
//  DrawnRouteSquare.swift
//  OpenHikes
//
//  One square of the hiking-routes layer, ready to stroke: its lines in map
//  points, each with its bounding rectangle, and joined end to end.
//
//  **Joined, because OpenStreetMap cuts a route into many short ways.** A
//  square holds each way once — see ``RouteSquareFile`` — and a route is
//  dozens of them, split at every junction and bridge. Stroked one way at a
//  time, the overview square over the Alps was 105,663 lines of two points
//  each, every one a subpath with two round caps, twice over for the casing:
//  a zoom-7 tile took 6.9 seconds to draw on a simulator, and every overlay
//  on the map, the base map's tiles included, waited behind it. Ways that
//  meet end to end in the same network are joined here, once, as a square is
//  read — the ends are the same OpenStreetMap node, and simplification keeps
//  ends, so they meet exactly.
//

import CoreLocation
import Foundation
import MapKit

nonisolated struct DrawnRouteSquare: Sendable {
    nonisolated struct Line: Sendable {
        let network: RouteNetwork
        let points: [MKMapPoint]
        let bounds: MKMapRect
    }

    let lines: [Line]
    /// Every line's points, counted: what a square costs to hold.
    let pointCount: Int

    static let empty = Self(lines: [], pointCount: 0)

    private init(lines: [Line], pointCount: Int) {
        self.lines = lines
        self.pointCount = pointCount
    }

    /// The file's lines, joined end to end within each network, in map
    /// points.
    init(_ file: RouteSquareFile) {
        let scale = Double(file.coordinateScale)
        var count = 0
        var drawn: [Line] = []
        let byNetwork = Dictionary(grouping: file.lines.filter { $0.points.count > 1 }, by: \.network)
        for network in RouteNetwork.leastImportantFirst {
            for run in Self.joined(byNetwork[network]?.map(\.points) ?? []) {
                let points = run.map { point in
                    MKMapPoint(CLLocationCoordinate2D(
                        latitude: Double(point.latitude) / scale,
                        longitude: Double(point.longitude) / scale
                    ))
                }
                count += points.count
                drawn.append(Line(network: network, points: points, bounds: Self.bounds(of: points)))
            }
        }
        lines = drawn
        pointCount = count
    }

    /// `runs` joined wherever one ends where another starts or ends, each run
    /// used once. A junction of three keeps going along one of them, and the
    /// third starts a line of its own.
    static func joined(_ runs: [[RouteSquareFile.Point]]) -> [[RouteSquareFile.Point]] {
        var touching: [RouteSquareFile.Point: [Int]] = [:]
        for (index, run) in runs.enumerated() {
            guard let first = run.first, let last = run.last else { continue }
            touching[first, default: []].append(index)
            touching[last, default: []].append(index)
        }
        var used = [Bool](repeating: false, count: runs.count)
        // The unused run touching `end`, turned to start there, or none.
        func take(from end: RouteSquareFile.Point) -> [RouteSquareFile.Point] {
            for index in touching[end] ?? [] where !used[index] {
                used[index] = true
                return runs[index].first == end ? runs[index] : runs[index].reversed()
            }
            return []
        }
        var joined: [[RouteSquareFile.Point]] = []
        for start in runs.indices where !used[start] {
            used[start] = true
            var line = runs[start]
            while let end = line.last {
                let next = take(from: end)
                guard !next.isEmpty else { break }
                line.append(contentsOf: next.dropFirst())
            }
            while let end = line.first {
                let previous = take(from: end)
                guard !previous.isEmpty else { break }
                line = Array(previous.reversed().dropLast()) + line
            }
            joined.append(line)
        }
        return joined
    }

    private static func bounds(of points: [MKMapPoint]) -> MKMapRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
