//
//  CuratedTrailDecoding+Cells.swift
//  OpenHikes
//
//  Turning a pre-built square into the rows and lines an Overpass answer
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

import Foundation

nonisolated extension CuratedTrailDecoding {
    /// The day hikes in `cell` that have a way in one of `boxes`, each with
    /// its line.
    ///
    /// `boxes` are a search's own — see ``CuratedTrailQuery/searchBoxes(for:)``
    /// — so there is one, or two where the search crosses the date line.
    static func trails(
        in cell: TrailCellFile,
        touching boxes: [CuratedTrailQuery.BoundingBox]
    ) -> [CuratedTrail] {
        let scale = Double(cell.coordinateScale)
        let areas = boxes.map { CellArea($0, scale: scale) }
        return cell.relations.compactMap { relation in
            guard areas.contains(where: { $0.holds(relation) }) else { return nil }
            return offered(Element(relation, scale: scale))
        }
    }
}

// MARK: - A relation, as Overpass would have answered it

nonisolated extension CuratedTrailDecoding.Element {
    /// `relation` in the shape an `out geom` answer decodes to.
    ///
    /// The box is the extent of the ways' points, which is what the tool that
    /// wrote the square measured the route by — see ``TrailCellFile``. A
    /// relation with no point has none, and is not offered.
    init(_ relation: TrailCellFile.Relation, scale: Double) {
        type = "relation"
        id = relation.id
        tags = relation.tags
        members = relation.ways.map { CuratedTrailDecoding.Member($0, scale: scale) }
        let points = members.flatMap(\.geometry)
        if let south = points.map(\.lat).min(), let north = points.map(\.lat).max(),
           let west = points.map(\.lon).min(), let east = points.map(\.lon).max() {
            bounds = CuratedTrailDecoding.Bounds(minlat: south, minlon: west, maxlat: north, maxlon: east)
        } else {
            bounds = nil
        }
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
