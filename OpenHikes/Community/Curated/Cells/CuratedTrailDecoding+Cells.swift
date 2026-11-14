//
//  CuratedTrailDecoding+Cells.swift
//  OpenHikes
//
//  Turning pre-built squares into the rows and lines an Overpass answer
//  becomes.
//
//  A ``TrailCellFile`` carries what `out geom` carries — a relation's tags and
//  its member ways, each with its role and its points — so it is read by
//  putting it into the shape that answer decodes to and handing it to the same
//  rules: ``CuratedTrailDecoding/offered(_:)`` decides whether it is a day
//  hike, which of its ways are the route and whether enough of them join to
//  draw. Nothing about a route differs for having come out of a square, and
//  `CuratedTrailSourceTests+Cells` holds the two to one answer.
//
//  What is decided here is the one thing Overpass decided on its own side:
//  **which routes are in the area that was asked about.** A square is a
//  quarter of a degree and a search is the map above the sheet, so most of
//  what a square holds is somewhere else. A route is in the area when one of
//  its ways has a point inside it, or passes through it between two points
//  that are not — the second of which is what a zoomed-in map needs, where a
//  forest road can cross the whole screen without a single vertex on it.
//
//  ## Measured first, and drawn only for the page
//
//  A search keeps a page of what its squares hold, and a wide one holds a
//  great deal more than a page: measured on 2026-11-14, a map two hundred
//  kilometres across over Zürich had 15,306 routes with a way in it. Drawing
//  a route — copying its ways out and matching their ends into one line — is
//  the expensive half of reading it, and drawing all of those to keep the
//  nearest fifty took 2.6 seconds of a Debug build.
//
//  So a route in the area is first only *measured*: a ``CellCandidate`` is
//  the relation, the extent of its points and how far its pin stands from the
//  point the search is sorted outward from. ``trails(nearestOf:limit:)`` puts
//  the candidates in that order and draws the nearest, then the next, and
//  stops when the page is full.
//

import CoreLocation
import Foundation
import OpenHikesData

nonisolated extension CuratedTrailDecoding {
    /// A route of a square that is in a search's area: measured, and not yet
    /// drawn. See this file's header.
    struct CellCandidate {
        let relation: TrailCellFile.Relation
        /// How many of the square's coordinate units make one degree.
        let scale: Double
        /// The extent of the relation's ways, which is the box Overpass would
        /// have answered with: what a square's reader measures a route by —
        /// see ``TrailCellFile``.
        let bounds: Bounds
        /// How far the route's pin stands from the point the search is sorted
        /// outward from, in meters: the measure
        /// ``CuratedTrailSource/listings(near:limit:)`` orders its rows by.
        let distanceMeters: Double
    }

    /// The relations in `cell` that have a way in one of `boxes`, each
    /// measured from `center` and none of them drawn.
    ///
    /// `boxes` are a search's own — see ``CuratedTrailQuery/searchBoxes(for:)``
    /// — so there is one, or two where the search crosses the date line.
    static func candidates(
        in cell: TrailCellFile,
        touching boxes: [CuratedTrailQuery.BoundingBox],
        from center: CLLocationCoordinate2D
    ) -> [CellCandidate] {
        let scale = Double(cell.coordinateScale)
        let areas = boxes.map { CellArea($0, scale: scale) }
        return cell.relations.compactMap { relation in
            // A relation with no point has no extent, and is in no area.
            guard areas.contains(where: { $0.holds(relation) }),
                  let bounds = relation.bounds(scale: scale)
            else { return nil }
            return CellCandidate(
                relation: relation,
                scale: scale,
                bounds: bounds,
                distanceMeters: RouteGeometry.distanceMeters(
                    from: center,
                    to: CuratedTrailQuery.center(of: bounds.box)
                )
            )
        }
    }

    /// The day hikes among `candidates` that stand nearest, each with its
    /// line: nearest first, and no more than `limit` of them.
    static func trails(nearestOf candidates: [CellCandidate], limit: Int) -> [CuratedTrail] {
        drawn(candidates.sorted { $0.distanceMeters < $1.distanceMeters }, limit: limit)
    }

    /// The first `limit` of `candidates` that are day hikes with a line to
    /// draw, in the order they come.
    ///
    /// A candidate past the one that fills the page is never asked for, which
    /// is what keeps a wide search from drawing thousands of lines to keep a
    /// page of them. A sequence rather than an array so that a suite can count
    /// what was asked for.
    static func drawn(_ candidates: some Sequence<CellCandidate>, limit: Int) -> [CuratedTrail] {
        var page: [CuratedTrail] = []
        guard limit > 0 else { return page }
        for candidate in candidates {
            guard let trail = offered(Element(candidate)) else { continue }
            page.append(trail)
            if page.count == limit { break }
        }
        return page
    }
}

// MARK: - A relation, as Overpass would have answered it

nonisolated extension CuratedTrailDecoding.Element {
    /// `candidate`'s relation in the shape an `out geom` answer decodes to,
    /// with the box it was measured by.
    init(_ candidate: CuratedTrailDecoding.CellCandidate) {
        type = "relation"
        id = candidate.relation.id
        tags = candidate.relation.tags
        members = candidate.relation.ways.map { CuratedTrailDecoding.Member($0, scale: candidate.scale) }
        bounds = candidate.bounds
    }
}

nonisolated extension CuratedTrailDecoding.Member {
    init(_ way: TrailCellFile.Way, scale: Double) {
        type = "way"
        role = way.role
        geometry = way.points.map { point in
            CuratedTrailDecoding.GeometryPoint(
                lat: Double(point.latitude) / scale,
                lon: Double(point.longitude) / scale
            )
        }
    }
}

nonisolated private extension TrailCellFile.Relation {
    /// The extent of the ways' points, in degrees, or `nil` for a relation
    /// with no point.
    ///
    /// What the tool that wrote the square measured the route by — see
    /// ``TrailCellFile``. Found in the square's own whole numbers and divided
    /// once, which is the number each point becomes when its way is drawn, so
    /// the box and the line cannot disagree by a rounding.
    func bounds(scale: Double) -> CuratedTrailDecoding.Bounds? {
        var extent: CellExtent?
        for way in ways {
            for point in way.points {
                extent = extent?.reaching(point) ?? CellExtent(southWest: point, northEast: point)
            }
        }
        return extent.map { extent in
            CuratedTrailDecoding.Bounds(
                minlat: Double(extent.southWest.latitude) / scale,
                minlon: Double(extent.southWest.longitude) / scale,
                maxlat: Double(extent.northEast.latitude) / scale,
                maxlon: Double(extent.northEast.longitude) / scale
            )
        }
    }
}

/// The corners of the box around some of a square's points, in its own units.
nonisolated private struct CellExtent {
    var southWest: TrailCellFile.Point
    var northEast: TrailCellFile.Point

    /// This box, grown to hold `point`.
    func reaching(_ point: TrailCellFile.Point) -> Self {
        Self(
            southWest: TrailCellFile.Point(
                latitude: min(southWest.latitude, point.latitude),
                longitude: min(southWest.longitude, point.longitude)
            ),
            northEast: TrailCellFile.Point(
                latitude: max(northEast.latitude, point.latitude),
                longitude: max(northEast.longitude, point.longitude)
            )
        )
    }
}

// MARK: - Which routes are in the area

/// One search box, in a square's own coordinate units.
nonisolated private struct CellArea {
    let south: Double
    let west: Double
    let north: Double
    let east: Double
    /// Half the way round the world, in units: a step between two points
    /// longer than this has crossed the date line rather than the map.
    let halfTurn: Double

    private static let halfTurnDegrees: Double = 180

    init(_ box: CuratedTrailQuery.BoundingBox, scale: Double) {
        south = box.south * scale
        west = box.west * scale
        north = box.north * scale
        east = box.east * scale
        halfTurn = Self.halfTurnDegrees * scale
    }

    /// Whether one of `relation`'s ways — in any role, as Overpass counts a
    /// member — has a point in this box or passes through it.
    func holds(_ relation: TrailCellFile.Relation) -> Bool {
        relation.ways.contains { way in
            guard var previous = way.points.first else { return false }
            if contains(previous) { return true }
            for point in way.points.dropFirst() {
                if contains(point) || crosses(from: previous, to: point) { return true }
                previous = point
            }
            return false
        }
    }

    private func contains(_ point: TrailCellFile.Point) -> Bool {
        let latitude = Double(point.latitude)
        let longitude = Double(point.longitude)
        return latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    /// Whether the straight step between two points outside the box passes
    /// through it: Liang–Barsky, which narrows the stretch of the step that
    /// is inside each edge in turn and answers no as soon as none is left.
    private func crosses(from start: TrailCellFile.Point, to end: TrailCellFile.Point) -> Bool {
        let startLatitude = Double(start.latitude)
        let startLongitude = Double(start.longitude)
        let latitudeStep = Double(end.latitude) - startLatitude
        let longitudeStep = Double(end.longitude) - startLongitude
        guard abs(longitudeStep) < halfTurn else { return false }
        var entry = 0.0
        var exit = 1.0
        let edges = [
            (step: -longitudeStep, room: startLongitude - west),
            (step: longitudeStep, room: east - startLongitude),
            (step: -latitudeStep, room: startLatitude - south),
            (step: latitudeStep, room: north - startLatitude),
        ]
        for edge in edges {
            if edge.step == 0 {
                // Running along this edge's direction: inside it all the way,
                // or outside it all the way.
                if edge.room < 0 { return false }
            } else if edge.step < 0 {
                entry = max(entry, edge.room / edge.step)
            } else {
                exit = min(exit, edge.room / edge.step)
            }
            if entry > exit { return false }
        }
        return true
    }
}
