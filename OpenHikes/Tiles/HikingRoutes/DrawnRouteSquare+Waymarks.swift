//
//  DrawnRouteSquare+Waymarks.swift
//  OpenHikes
//
//  Where a square's signs stand at a zoom: along each line, every so many
//  tile pixels, and nowhere that would crowd another sign.
//
//  The rules are Waymarked Trails' — see ``HikingRoutesStyle``. Each line is
//  offered a sign for each of its routes, the longest lines first and every
//  line's first sign before any line's second. A sign that would stand
//  within the margin of another, or within the repeat distance of one the
//  same as itself, is moved along its line a few pixels at a time, and left
//  out when no place within the tolerance is clear. That is what puts the
//  signs of routes that share a way in a row along it, and what keeps a
//  valley of short lines from showing one waymark forty times.
//
//  **Placed once for a square and a zoom, not once a tile.** Every tile that
//  shows a sign draws it from the same list, so a sign across the edge of
//  two tiles is the same sign in both. Placed tile by tile, each tile
//  weighed only the signs near it, two neighbours could decide differently,
//  and the map showed half a sign. A square places only the signs that
//  stand on its own ground, so two squares never both place one; they do
//  not see each other's signs, and along a square's edge two may crowd.
//
//  **No deeper than ``deepestPlacementZoom``.** A square is placed whole,
//  on whichever drawing thread asks first, and each zoom deeper doubles the
//  pixels along its lines. The densest detail square of the world's build,
//  in the Ardennes, placed 27,135 signs in 35 ms at zoom 18 and 462,852 in
//  0.59 s at zoom 22, the depth of a phone's deepest tiles, measured in a
//  release build on a Mac. Deeper than that zoom, its places are kept, so
//  the signs stand as far apart on the ground as they do there, and further
//  apart on the screen.
//

import Algorithms
import CoreGraphics
import Foundation
import MapKit
import Synchronization

/// Where one sign stands.
nonisolated struct PlacedWaymark: Sendable {
    /// On the world's own copy, even along a line that runs off its edge.
    let center: MKMapPoint
    /// An index into the square's ``DrawnRouteSquare/signs``.
    let sign: Int
}

/// A square's signs at each zoom it has been drawn at.
///
/// A class so that every copy of a square shares what was worked out, and
/// locked because MapKit draws tiles on several threads at once: the first
/// tile to ask places the signs while the others wait for the same answer.
nonisolated final class WaymarkPlacements: Sendable {
    private let placed = Mutex<[Int: [PlacedWaymark]]>([:])

    func at(_ zoom: Int, place: () -> [PlacedWaymark]) -> [PlacedWaymark] {
        placed.withLock { placed in
            if let found = placed[zoom] { return found }
            let made = place()
            placed[zoom] = made
            return made
        }
    }
}

nonisolated extension DrawnRouteSquare {
    /// The deepest zoom signs are placed for. See this file's header.
    static let deepestPlacementZoom = 18

    /// The square's signs as they stand at `zoom`.
    func waymarks(atZoom zoom: Int) -> [PlacedWaymark] {
        guard !signs.isEmpty else { return [] }
        let placedAt = min(zoom, Self.deepestPlacementZoom)
        return placements.at(placedAt) {
            var placer = WaymarkPlacer(self, zoom: placedAt)
            return placer.place()
        }
    }
}

/// One square's signs being placed at one zoom. Every distance is in tile
/// pixels at that zoom.
nonisolated private struct WaymarkPlacer {
    nonisolated private struct Box {
        let rect: CGRect
        let sign: Int
    }

    /// A cell of the grid the placed signs are found by.
    nonisolated private struct Cell: Hashable {
        let column: Int
        let row: Int
    }

    /// A cell's side: wide enough that a sign and the room around it touch
    /// a handful of cells.
    private static let cellSide: Double = 128
    /// A map point's width in tile pixels at zoom 0 is 2⁻²⁰.
    private static let zoomOfUnitScale: Double = 20

    /// How far a sign is moved along its line from where the spacing puts
    /// it, nearest first.
    private static let shifts: [Double] = {
        let steps = Int(HikingRoutesStyle.positionTolerance / HikingRoutesStyle.positionStep)
        return [0] + (1...max(1, steps)).flatMap { step in
            [Double(step) * HikingRoutesStyle.positionStep, -Double(step) * HikingRoutesStyle.positionStep]
        }
    }()

    private let square: DrawnRouteSquare
    private let rule: WaymarkRule
    /// Tile pixels in a map point.
    private let scale: Double
    private var boxes: [Box] = []
    private var cells: [Cell: [Int]] = [:]
    private var placed: [PlacedWaymark] = []

    init(_ square: DrawnRouteSquare, zoom: Int) {
        self.square = square
        rule = HikingRoutesStyle.waymarkRule(atZoom: zoom)
        scale = pow(2, Double(zoom) - Self.zoomOfUnitScale)
    }

    mutating func place() -> [PlacedWaymark] {
        let shown = square.lines.map { line in
            line.signs.filter { square.signs[$0].network >= rule.minimumNetwork }
        }
        let longestFirst = square.lines.indices
            .filter { !shown[$0].isEmpty }
            .sorted { lhs, rhs in
                let left = square.lines[lhs].length, right = square.lines[rhs].length
                return left != right ? left > right : lhs < rhs
            }
        let most = longestFirst.map { shown[$0].count }.max() ?? 0
        for rank in 0..<most {
            for index in longestFirst where shown[index].count > rank {
                place(shown[index][rank], along: square.lines[index])
            }
        }
        return placed
    }

    /// Offers `line` its signs: one every ``WaymarkRule/spacing``, evenly,
    /// and one in the middle of a line shorter than that.
    private mutating func place(_ sign: Int, along line: DrawnRouteSquare.Line) {
        let length = line.length * scale
        let count = max(1, Int(length / rule.spacing))
        let distances = Self.distances(along: line.points)
        for position in 0..<count {
            let wanted = (Double(position) + 0.5) * length / Double(count)
            for shift in Self.shifts {
                let along = wanted + shift
                guard along >= 0, along <= length else { continue }
                // On the world's own copy, which the square's ground is on: a
                // line across the antimeridian runs off its edge.
                let point = DrawnRouteSquare.onTheWorld(
                    Self.point(at: along / scale, on: line.points, distances: distances)
                )
                if let ground = square.ground, !ground.contains(point) { continue }
                if take(sign, at: point) { break }
            }
        }
    }

    /// Stands `sign` at `point` unless it would crowd one already placed.
    private mutating func take(_ sign: Int, at point: MKMapPoint) -> Bool {
        let size = square.signSizes[sign]
        let rect = CGRect(
            x: point.x * scale - size.width / 2,
            y: point.y * scale - size.height / 2,
            width: size.width,
            height: size.height
        )
        let apart = rect.insetBy(dx: -rule.margin, dy: -rule.margin)
        let alike = rect.insetBy(dx: -rule.repeatDistance, dy: -rule.repeatDistance)
        for cell in Self.cells(touching: alike.union(apart)) {
            for index in cells[cell] ?? [] {
                let other = boxes[index]
                if other.rect.intersects(apart) || (other.sign == sign && other.rect.intersects(alike)) {
                    return false
                }
            }
        }
        for cell in Self.cells(touching: rect) {
            cells[cell, default: []].append(boxes.count)
        }
        boxes.append(Box(rect: rect, sign: sign))
        placed.append(PlacedWaymark(center: point, sign: sign))
        return true
    }

    private static func cells(touching rect: CGRect) -> [Cell] {
        let columns = Int((rect.minX / cellSide).rounded(.down))...Int((rect.maxX / cellSide).rounded(.down))
        let rows = Int((rect.minY / cellSide).rounded(.down))...Int((rect.maxY / cellSide).rounded(.down))
        return product(columns, rows).map { Cell(column: $0, row: $1) }
    }

    /// How far along the line each of its points is, in map points.
    private static func distances(along points: [MKMapPoint]) -> [Double] {
        points.adjacentPairs().reductions(0) { distance, step in
            distance + hypot(step.1.x - step.0.x, step.1.y - step.0.y)
        }
    }

    /// The point `distance` along the line.
    private static func point(at distance: Double, on points: [MKMapPoint], distances: [Double]) -> MKMapPoint {
        // The first point at least `distance` along.
        let next = min(distances.partitioningIndex { $0 >= distance }, distances.count - 1)
        guard next > 0 else { return points[0] }
        let span = distances[next] - distances[next - 1]
        let share = span > 0 ? (distance - distances[next - 1]) / span : 0
        let start = points[next - 1], end = points[next]
        return MKMapPoint(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
    }
}
