//
//  TrailMatcherGraphIndex+EdgeGrid.swift
//  OpenHikes
//
//  Uniform spatial grid for fast candidate edge lookup.
//

import CoreLocation
import Foundation

nonisolated extension TrailMatcherGraphIndex {
    /// A uniform grid over the graph's edges, so a fix is projected
    /// against the segments near it rather than against every segment in
    /// the region.
    struct EdgeGrid {
        private static let cellSizeMeters = 200.0
        private static let marginMeters = 2.0
        private static let maximumEdgeReachMeters = 400.0

        private struct Cell: Hashable {
            let x: Int32
            let y: Int32
        }

        private let origin: CLLocationCoordinate2D
        private let cells: [Cell: [Int]]
        private let reachMeters: Double
        private let alwaysScanned: [Int]

        init(endpoints: [EdgeEndpoints]) {
            guard let first = endpoints.first else {
                origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
                cells = [:]
                reachMeters = 0
                alwaysScanned = []
                return
            }

            let gridOrigin = first.start
            var cellMap: [Cell: [Int]] = [:]
            var longEdges: [Int] = []
            var reach = 0.0

            for (edgeIdx, endpoint) in endpoints.enumerated() {
                let startOffset = RouteGeometry.localOffset(
                    from: gridOrigin,
                    to: endpoint.start
                )
                let endOffset = RouteGeometry.localOffset(
                    from: gridOrigin,
                    to: endpoint.end
                )
                let midpointX = (startOffset.x + endOffset.x) / 2
                let midpointY = (startOffset.y + endOffset.y) / 2
                let halfLength = hypot(
                    endOffset.x - startOffset.x,
                    endOffset.y - startOffset.y
                ) / 2
                guard halfLength <= Self.maximumEdgeReachMeters,
                      let cell = Self.cell(x: midpointX, y: midpointY) else {
                    longEdges.append(edgeIdx)
                    continue
                }
                reach = max(reach, halfLength)
                cellMap[cell, default: []].append(edgeIdx)
            }

            origin = gridOrigin
            cells = cellMap
            alwaysScanned = longEdges
            reachMeters = reach
        }

        private static func cell(x: Double, y: Double) -> Cell? {
            let cellX = (x / cellSizeMeters).rounded(.down)
            let cellY = (y / cellSizeMeters).rounded(.down)
            guard cellX.isFinite, cellY.isFinite,
                  cellX.magnitude < Double(Int32.max),
                  cellY.magnitude < Double(Int32.max) else { return nil }
            return Cell(x: Int32(cellX), y: Int32(cellY))
        }

        func forEachEdge(
            near coordinate: CLLocationCoordinate2D,
            within radius: Double,
            _ body: (Int) -> Void
        ) {
            for index in alwaysScanned { body(index) }
            guard !cells.isEmpty else { return }
            let centre = RouteGeometry.localOffset(from: origin, to: coordinate)
            let expanded = radius + reachMeters + Self.marginMeters
            guard let minimum = Self.cell(
                x: centre.x - expanded,
                y: centre.y - expanded
            ), let maximum = Self.cell(
                x: centre.x + expanded,
                y: centre.y + expanded
            ) else { return }
            for x in minimum.x...maximum.x {
                for y in minimum.y...maximum.y {
                    guard let bucket = cells[Cell(x: x, y: y)] else { continue }
                    for index in bucket { body(index) }
                }
            }
        }
    }
}
