//
//  GPXTrackSplit.swift
//  OpenHikes
//
//  Which of a multi-track file's hikes each of its loose waypoints belongs to.
//
//  A `<wpt>` is a child of `<gpx>`, not of any `<trk>`, so a file with three
//  days in it says nothing about which day the hut was on. The line does: a
//  waypoint belongs to the track it lies on, by the rule a drawn trail's save
//  already uses for its places — within ``TrailPlaceAnchor/touchedOffRouteMeters``
//  of the route (``TrailPlaceOrder``). One that lies on two goes to the nearer;
//  one that lies on none is dropped rather than pinned to a day it was never
//  part of, and the confirmation says how many were. Every place a track takes
//  is kept here: the cap on places is the import's, spent on the tracks the
//  hiker chooses (``GPXImport/placesKept(of:)``).
//
//  "The route" is the ground the track walked: its walked legs and the fixes
//  it recorded. The leg joining two of its `<trkseg>`s is a pause, and a pause
//  is not trail (``RouteBoundary``), so a waypoint lying only on that join
//  lies on no track.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum GPXTrackSplit {
    /// `items`, shared out among `routes`: one list per route, in the order
    /// the routes were given, each in the order the items were.
    static func assign<Item>(
        _ items: [Item],
        at coordinate: (Item) -> CLLocationCoordinate2D,
        to routes: [[RouteCoordinate]]
    ) -> [[Item]] {
        var assigned = Array(repeating: [Item](), count: routes.count)
        guard !items.isEmpty else { return assigned }
        let reaches = routes.map(Reach.init)
        let grids = routes.map(Grid.init)
        for item in items {
            let target = coordinate(item)
            let nearest = routes.indices
                .filter { reaches[$0].mayHold(target) }
                .compactMap { index in grids[index].offRouteMeters(of: target).map { (index, $0) } }
                .min { $0.1 < $1.1 }
            guard let nearest, nearest.1 <= TrailPlaceAnchor.touchedOffRouteMeters else { continue }
            assigned[nearest.0].append(item)
        }
        return assigned
    }

    /// A route's bounding box grown by the touching distance: a waypoint
    /// outside it cannot lie on the route, so the route is not measured for it.
    ///
    /// The measuring is every segment of the route, and without this every
    /// waypoint pays it for every track — a region's download of forty walks
    /// with a few dozen huts marked is tens of millions of projections for
    /// answers that are almost all "a valley away". Checked against the box
    /// first, each waypoint measures only the one or two walks it could be on,
    /// and ``Grid`` then measures only the part of each it could be on.
    ///
    /// Longitude is held unwrapped: each step along the route is taken the
    /// short way, as ``RouteGeometry/project(_:onSegmentFrom:to:)`` takes it,
    /// so a track from 179.99° to -179.99° spans the few hundredths of a degree
    /// it covers rather than the whole globe the long way round — or, read as a
    /// plain `min`/`max`, a span that stops short of the ±180° the line runs
    /// through and refuses a waypoint lying on it. A waypoint is then measured
    /// eastward from the west edge, a turn at most, so one on either side of
    /// the antimeridian lands where it belongs. A route whose grown box reaches
    /// all the way round is always measured.
    ///
    /// The box spans a paused leg's ground as well, because the unwrapping
    /// steps across it. That only lets a waypoint through to the measuring,
    /// which then refuses it.
    private struct Reach {
        private var south = Double.infinity
        private var north = -Double.infinity
        /// The west edge, unwrapped: it may lie past -180°.
        private var west = Double.infinity
        /// Degrees east from `west` to the east edge.
        private var span = 0.0
        private var wraps = false
        /// No points, so nothing lies on it — and no box to build a range from.
        private var isEmpty = true

        init(_ route: [RouteCoordinate]) {
            guard let first = route.first else { return }
            isEmpty = false
            for point in route {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
            }
            var longitude = first.longitude
            var east = longitude
            west = longitude
            for (start, end) in route.adjacentPairs() {
                longitude += RouteGeometry.normalizedLongitudeDelta(end.longitude - start.longitude)
                west = min(west, longitude)
                east = max(east, longitude)
            }
            let longitudeMargin = GPXTrackSplit.longitudeMargin(near: max(abs(south), abs(north)))
            south -= GPXTrackSplit.latitudeMargin
            north += GPXTrackSplit.latitudeMargin
            west -= longitudeMargin
            span = east - west + longitudeMargin
            wraps = span >= 360
        }

        func mayHold(_ coordinate: CLLocationCoordinate2D) -> Bool {
            if isEmpty { return false }
            guard (south...north).contains(coordinate.latitude) else { return false }
            if wraps { return true }
            var eastward = (coordinate.longitude - west).truncatingRemainder(dividingBy: 360)
            if eastward < 0 { eastward += 360 }
            return eastward <= span
        }
    }

    /// The pieces of a route that ``offRouteMeters(of:along:)`` measures —
    /// each walked leg, and each fix with a pause on both sides — filed under
    /// the cells of a grid that their boxes cover, so that a waypoint is
    /// measured against the pieces near it rather than against all of them.
    ///
    /// ``Reach`` turns away the routes a waypoint is nowhere near, and nothing
    /// more: a waypoint that does lie on a track was measured against every
    /// leg of it. A day of 1 Hz fixes is some twenty thousand legs, so ten
    /// thousand waypoints along one were two hundred million projections, and
    /// seconds before the confirmation could appear. Through the grid each
    /// waypoint measures the legs within a cell or two of it.
    ///
    /// The cells are degrees of latitude and of unwrapped longitude, never
    /// metres from an origin: a plane laid at one end of a long route
    /// stretches the other, and a margin measured in it falls short there. A
    /// waypoint is looked up in the cells under its own box, grown by the
    /// touching distance as ``Reach`` grows a route's, but at the waypoint's
    /// latitude. A piece that comes within that distance of it has a point
    /// inside that box, so it is filed under one of those cells. The nearest
    /// piece is therefore measured whenever it is near enough to count, and
    /// the answer is the one measuring every piece gives: the nearer route
    /// wins, and a waypoint goes to one route or to none.
    ///
    /// Measured whole instead, as before:
    /// - a route whose grown box spans half a turn or more, where the short
    ///   way between two of its fixes and the short way to a waypoint need not
    ///   agree, so unwrapped longitude is no frame to file in;
    /// - a piece whose box covers more than ``mostCellsPerPiece`` cells, a leg
    ///   of more than a few hundred metres, which every waypoint the route's
    ///   box admits measures. A recorded track has few, and a route of sparse
    ///   turn points has few pieces of any kind.
    private struct Grid {
        private struct Cell: Hashable {
            let row: Int
            let column: Int
        }

        private let route: [RouteCoordinate]
        /// What is filed: ``GPXTrackSplit/pieces(of:)``, read once.
        private var pieces: [Piece] = []
        /// Each piece, by its place in ``pieces``, under every cell its box
        /// covers.
        private var cells: [Cell: [Int]] = [:]
        /// The pieces too long to file, by their place in ``pieces``.
        private var unfiled: [Int] = []
        /// The first fix's longitude, which the route is unwrapped from.
        private var origin = 0.0
        private var latitudeStep = 0.0
        private var longitudeStep = 0.0
        private var isFiled = false

        init(_ route: [RouteCoordinate]) {
            self.route = route
            guard route.count > 1, let first = route.first else { return }
            origin = first.longitude
            // Unwrapped as ``Reach`` unwraps, a step at a time the short way.
            var longitude = origin
            var longitudes = [longitude]
            longitudes.reserveCapacity(route.count)
            for (start, end) in route.adjacentPairs() {
                longitude += RouteGeometry.normalizedLongitudeDelta(end.longitude - start.longitude)
                longitudes.append(longitude)
            }
            guard let south = route.lazy.map(\.latitude).min(), let north = route.lazy.map(\.latitude).max(),
                  let west = longitudes.min(), let east = longitudes.max() else { return }
            let widest = max(abs(south), abs(north))
            guard east - west + 2 * GPXTrackSplit.longitudeMargin(near: widest) < GPXTrackSplit.halfTurn else {
                return
            }
            latitudeStep = GPXTrackSplit.cellMeters / GPXTrackSplit.metersPerDegree
            longitudeStep = latitudeStep / GPXTrackSplit.cosine(of: (south + north) / 2)
            pieces = GPXTrackSplit.pieces(of: route)
            for (position, piece) in pieces.enumerated() {
                let latitudes = (route[piece.start].latitude, route[piece.end].latitude)
                let rows = Self.cellRange(
                    from: min(latitudes.0, latitudes.1),
                    to: max(latitudes.0, latitudes.1),
                    step: latitudeStep
                )
                let columns = Self.cellRange(
                    from: min(longitudes[piece.start], longitudes[piece.end]),
                    to: max(longitudes[piece.start], longitudes[piece.end]),
                    step: longitudeStep
                )
                guard let rows, let columns, rows.count * columns.count <= Self.mostCellsPerPiece else {
                    unfiled.append(position)
                    continue
                }
                for row in rows {
                    for column in columns {
                        cells[Cell(row: row, column: column), default: []].append(position)
                    }
                }
            }
            isFiled = true
        }

        /// How far `coordinate` is from the nearest piece measured for it —
        /// exactly ``offRouteMeters(of:along:)``'s answer whenever that is
        /// within the touching distance, and otherwise a distance beyond it,
        /// or `nil`.
        ///
        /// For a coordinate the route's ``Reach`` may hold: that is what puts
        /// its longitude within half a turn of the route's own, the frame it is
        /// unwrapped into here.
        func offRouteMeters(of coordinate: CLLocationCoordinate2D) -> Double? {
            guard isFiled, let box = box(around: coordinate) else {
                return GPXTrackSplit.offRouteMeters(of: coordinate, along: route)
            }
            var nearest = Double.infinity
            for position in unfiled {
                nearest = min(nearest, meters(from: coordinate, to: pieces[position]))
            }
            for row in box.rows {
                for column in box.columns {
                    for position in cells[Cell(row: row, column: column)] ?? [] {
                        nearest = min(nearest, meters(from: coordinate, to: pieces[position]))
                    }
                }
            }
            return nearest.isFinite ? nearest : nil
        }

        /// The cells under `coordinate`'s box grown by the touching distance.
        private func box(
            around coordinate: CLLocationCoordinate2D
        ) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
            let margin = (
                latitude: GPXTrackSplit.latitudeMargin,
                longitude: GPXTrackSplit.longitudeMargin(near: coordinate.latitude)
            )
            let longitude = origin + RouteGeometry.normalizedLongitudeDelta(coordinate.longitude - origin)
            guard let rows = Self.cellRange(
                from: coordinate.latitude - margin.latitude,
                to: coordinate.latitude + margin.latitude,
                step: latitudeStep
            ), let columns = Self.cellRange(
                from: longitude - margin.longitude,
                to: longitude + margin.longitude,
                step: longitudeStep
            ) else { return nil }
            return (rows, columns)
        }

        private func meters(from coordinate: CLLocationCoordinate2D, to piece: Piece) -> Double {
            GPXTrackSplit.meters(from: coordinate, to: piece, of: route)
        }

        /// The cells from the one holding `lower` to the one holding `upper`,
        /// or `nil` for a value no cell can hold.
        private static func cellRange(from lower: Double, to upper: Double, step: Double) -> ClosedRange<Int>? {
            let first = (lower / step).rounded(.down)
            let last = (upper / step).rounded(.down)
            guard first.isFinite, last.isFinite, first <= last,
                  first.magnitude < Double(Int32.max), last.magnitude < Double(Int32.max) else { return nil }
            return Int(first)...Int(last)
        }

        /// Four cells by four: a leg up to a few hundred metres long. A longer
        /// one would be filed under a square of cells growing with its length,
        /// most of them nowhere near it.
        private static let mostCellsPerPiece = 16
    }

    /// The touching distance in degrees of latitude, a little over it anywhere.
    private static let latitudeMargin = TrailPlaceAnchor.touchedOffRouteMeters / metersPerDegree

    /// The touching distance in degrees of longitude, a little over it at
    /// every latitude within the touching distance of `latitude` — the widest
    /// of them is the one nearest a pole, and its degree is the shortest.
    private static func longitudeMargin(near latitude: Double) -> Double {
        TrailPlaceAnchor.touchedOffRouteMeters
            / (metersPerDegree * cosine(of: abs(latitude) + latitudeMargin))
    }

    /// The cosine of `latitude`, held short of the pole; the importer refuses
    /// anything past Web Mercator's ~85°, so it never gets that far.
    private static func cosine(of latitude: Double) -> Double {
        cos(min(abs(latitude), steepestLatitude) * .pi / 180)
    }

    /// A little under a degree of latitude's length anywhere, so the
    /// margin it yields is a little over the distance, never under it.
    private static let metersPerDegree = 110_000.0
    /// Where the cosine is held, short of the pole it would reach zero at.
    private static let steepestLatitude = 89.0
    private static let halfTurn = 180.0
    /// A grid cell's side, about twice the touching distance: a waypoint's
    /// grown box covers two or three of them a side, and a 1 Hz track crosses
    /// one in a hundred legs or so.
    private static let cellMeters = 2 * TrailPlaceAnchor.touchedOffRouteMeters

    /// How far `coordinate` is from the nearest of the ground `route` walked,
    /// or `nil` for a route of fewer than two points.
    ///
    /// A leg a pause opened is never measured (#991). In a GPX file that is
    /// the join between two `<trkseg>`s: ground the track did not record, and
    /// not trail, so the saved hike's `RouteProfile` never matches onto it
    /// (see ``RouteBoundary``). Measured, it would hand a waypoint on the join
    /// to a walk that passed kilometres from it.
    ///
    /// Its ends are still fixes the track recorded. One beside a walked leg is
    /// measured as that leg's end; one with a pause on both sides, a
    /// `<trkseg>` of a single point, is one of the ``TrailRuns/loneFixes`` and
    /// is measured as a point, so a waypoint sitting on it still lies on the
    /// track. That is the rule ``RecordedRouteLegs`` holds a photograph to.
    ///
    /// A single point is no route at all: the import leaves a one-point track
    /// out after this split, and a waypoint handed to it would go with it,
    /// uncounted.
    static func offRouteMeters(
        of coordinate: CLLocationCoordinate2D,
        along route: [RouteCoordinate]
    ) -> Double? {
        guard route.count > 1 else { return nil }
        var nearest = Double.infinity
        for piece in pieces(of: route) {
            nearest = min(nearest, meters(from: coordinate, to: piece, of: route))
        }
        return nearest
    }

    /// A stretch of the ground a route walked, as the points it runs between:
    /// a walked leg, or a lone fix alone, whose `start` is its `end`.
    private struct Piece {
        let start: Int
        let end: Int
    }

    /// The pieces of `route` that ``offRouteMeters(of:along:)`` measures, read
    /// off the route's ``TrailRuns``: each of its ``TrailRuns/walkedLegs``,
    /// and each of its ``TrailRuns/loneFixes`` alone. A fix beside a walked
    /// leg is that leg's end, so it is measured with the leg.
    private static func pieces(of route: [RouteCoordinate]) -> [Piece] {
        let runs = route.trailRuns
        return runs.walkedLegs.map { Piece(start: $0, end: $0 + 1) }
            + runs.loneFixes.map { Piece(start: $0, end: $0) }
    }

    /// How far `coordinate` is from `piece` of `route`: from the leg, or from
    /// the fix when the piece is one.
    private static func meters(
        from coordinate: CLLocationCoordinate2D,
        to piece: Piece,
        of route: [RouteCoordinate]
    ) -> Double {
        let end = route[piece.end].clCoordinate
        guard piece.start != piece.end else { return RouteGeometry.distanceMeters(from: coordinate, to: end) }
        return RouteGeometry.project(coordinate, onSegmentFrom: route[piece.start].clCoordinate, to: end).offRouteMeters
    }
}
