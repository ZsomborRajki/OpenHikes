//
//  PlaceBuild.swift
//  trail-cells
//
//  Turning the places of an OpenStreetMap extract — the summits, springs,
//  huts and viewpoints the app's place searches offer — into one file a square
//  of `PlaceSquareGrid`.
//
//  What is filed is what the app's own Overpass search would have been handed:
//  a node carrying the tag of one of `PlaceSquareFile.kinds`, or a way or a
//  relation carrying the tag of one that is mapped as an area. Named or not,
//  because most of them are not (see `TrailPointQuery.swift`). A way's point is
//  the middle of the box around its nodes, and a relation's the middle of the
//  box around its member ways — what Overpass's `out center` puts on one, less
//  any member nodes, as the day hikes' boxes leave them out. One that runs out
//  of a regional extract is left out rather than placed short.
//
//  **The same extract always gives the same squares.** Places are written by
//  element and id, and nothing in a square depends on the clock, so a square's
//  digest changes exactly when OpenStreetMap's places in it did.
//

import CryptoKit
import Foundation

enum PlaceSquareBuild {
    /// What `build-places` writes in a manifest's `kind`, so `upload` knows
    /// which manifest record it is replacing.
    static let manifestKind = "places"

    struct Summary {
        var nodes = 0
        var ways = 0
        var relations = 0
        /// Ways and relations left out for having no position to put a pin
        /// at.
        var withoutPositions = 0
        var squares = 0
        var bytes = 0
        var largest: (name: String, bytes: Int, places: Int)?

        var places: Int { nodes + ways + relations }
    }

    /// The expressions `osmium tags-filter` is handed, one a line: every kind
    /// of place, as nodes, and as ways and relations for the kinds mapped as
    /// areas.
    ///
    /// Read off `PlaceSquareFile.kinds` rather than spelled in the script, so
    /// the filter and the build cannot disagree about what a place is.
    static var osmiumFilters: [String] {
        var values: [String: [String]] = [:]
        for kind in PlaceSquareFile.kinds {
            values["\(kind.includesAreas ? "nwr" : "n")/\(kind.key)", default: []].append(kind.value)
        }
        return values.keys.sorted().map { filter in
            "\(filter)=\(values[filter, default: []].joined(separator: ","))"
        }
    }

    static func run(_ options: BuildOptions) throws -> Summary {
        guard let nodesPath = options.nodesPath else {
            throw UsageError(description: "--nodes is required.")
        }
        var summary = Summary()
        var filed: [PlaceSquare: [PlaceSquareFile.Place]] = [:]
        func file(_ place: PlaceSquareFile.Place) {
            let scale = Double(PlaceSquareFile.standardCoordinateScale)
            let square = PlaceSquareGrid.square(
                containingLatitude: Double(place.point.latitude) / scale,
                longitude: Double(place.point.longitude) / scale
            )
            filed[square, default: []].append(place)
        }

        let relations = try areaRelations(at: options.relationsPath)
        var memberBoxes: [Int64: Box] = [:]
        let wanted = Set(relations.flatMap(\.wayIDs))
        var waysRead = 0
        var waysWithPositions = 0
        try OPLFile(path: options.waysPath).forEachLine { line in
            guard let way = try OPL.way(line, scale: PlaceSquareFile.standardCoordinateScale, readsTags: true) else {
                return
            }
            waysRead += 1
            let box = way.points.flatMap(Box.init)
            if box != nil { waysWithPositions += 1 }
            if wanted.contains(way.id), let box { memberBoxes[way.id] = box }
            guard PlaceSquareFile.isPlace(.way, tags: way.tags) else { return }
            guard let box else {
                summary.withoutPositions += 1
                return
            }
            file(PlaceSquareFile.Place(element: .way, id: way.id, point: box.center, tags: kept(way.tags)))
            summary.ways += 1
        }
        // Not one way with a position, and ways that lacked them: the file
        // osmium writes when it is not asked for positions — see
        // `TrailCellBuild.ways(at:namedBy:)`.
        if waysWithPositions == 0, waysRead > 0 {
            throw BuildError.waysCarryNoPositions(options.waysPath)
        }

        for relation in relations {
            // Every member way, or no pin: a hut whose outline runs out of
            // the extract would be placed by the part of it that is in.
            let boxes = relation.wayIDs.compactMap { memberBoxes[$0] }
            guard let first = boxes.first, boxes.count == relation.wayIDs.count else {
                summary.withoutPositions += 1
                continue
            }
            let box = boxes.dropFirst().reduce(first) { $0.union($1) }
            file(PlaceSquareFile.Place(element: .relation, id: relation.id, point: box.center, tags: relation.tags))
            summary.relations += 1
        }

        try OPLFile(path: nodesPath).forEachLine { line in
            guard let node = try OPL.node(line, scale: PlaceSquareFile.standardCoordinateScale),
                  PlaceSquareFile.isPlace(.node, tags: node.tags),
                  let point = node.point
            else { return }
            file(PlaceSquareFile.Place(
                element: .node,
                id: node.id,
                point: PlaceSquareFile.Point(latitude: point.latitude, longitude: point.longitude),
                tags: kept(node.tags)
            ))
            summary.nodes += 1
        }

        try TrailCellBuild.prepare(options.outputDirectory)
        let squares = try write(filed, to: options.outputDirectory, summary: &summary)
        try BuildManifest(
            kind: manifestKind,
            generation: PlaceSquareGrid.generation,
            complete: options.coversTheWorld,
            builtAt: Date(),
            osmTimestamp: options.osmTimestamp,
            routeCount: summary.places,
            cells: squares
        )
        .write(to: options.outputDirectory)
        return summary
    }
}

// MARK: - Reading the extract

private extension PlaceSquareBuild {
    /// A relation that is a place, with the ways its point is measured from.
    struct AreaRelation {
        var id: Int64
        var tags: [String: String]
        var wayIDs: [Int64]
    }

    /// The relations that are places. osmium hands over the relations a
    /// matching one is a member of too, whatever they are, so the tags are
    /// asked about again here.
    static func areaRelations(at path: String) throws -> [AreaRelation] {
        var kept: [AreaRelation] = []
        try OPLFile(path: path).forEachLine { line in
            guard let relation = try OPL.relation(line),
                  PlaceSquareFile.isPlace(.relation, tags: relation.tags)
            else { return }
            kept.append(AreaRelation(
                id: relation.id,
                tags: Self.kept(relation.tags),
                wayIDs: relation.members.filter { $0.kind == UInt8(ascii: "w") }.map(\.ref)
            ))
        }
        return kept
    }

    /// The tags of `tags` a square keeps.
    static func kept(_ tags: [String: String]) -> [String: String] {
        tags.filter { PlaceSquareFile.keptTagKeys.contains($0.key) }
    }

    /// The box around some points, in coordinate units.
    ///
    /// The plain minimum and maximum, as Overpass computes one: a hut does not
    /// straddle the date line.
    struct Box {
        var south: Int32
        var west: Int32
        var north: Int32
        var east: Int32

        init?(_ points: [TrailCellFile.Point]) {
            guard let first = points.first else { return nil }
            south = first.latitude
            north = first.latitude
            west = first.longitude
            east = first.longitude
            for point in points.dropFirst() {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
                west = min(west, point.longitude)
                east = max(east, point.longitude)
            }
        }

        var center: PlaceSquareFile.Point {
            PlaceSquareFile.Point(
                latitude: Int32((Int64(south) + Int64(north)) / 2),
                longitude: Int32((Int64(west) + Int64(east)) / 2)
            )
        }

        func union(_ other: Box) -> Box {
            var box = self
            box.south = min(south, other.south)
            box.north = max(north, other.north)
            box.west = min(west, other.west)
            box.east = max(east, other.east)
            return box
        }
    }
}

// MARK: - Writing

private extension PlaceSquareBuild {
    static func write(
        _ filed: [PlaceSquare: [PlaceSquareFile.Place]],
        to directory: URL,
        summary: inout Summary
    ) throws -> [BuildManifest.Cell] {
        var squares: [BuildManifest.Cell] = []
        for (square, places) in filed {
            let name = PlaceSquareGrid.recordName(for: square)
            let file = PlaceSquareFile(places: places)
            let bytes = file.encoded()
            guard bytes.count <= TrailCellBuild.maximumCellBytes else {
                throw BuildError.cellTooLarge(name: name, bytes: bytes.count)
            }
            try bytes.write(to: BuildManifest.cellFile(named: name, in: directory), options: .atomic)
            let digest = SHA256.hash(data: file.encodedBody()).map { String(format: "%02x", $0) }.joined()
            squares.append(BuildManifest.Cell(name: name, digest: digest, bytes: bytes.count, routes: places.count))
            summary.bytes += bytes.count
            if bytes.count > summary.largest?.bytes ?? 0 {
                summary.largest = (name: name, bytes: bytes.count, places: places.count)
            }
        }
        summary.squares = squares.count
        return squares.sorted { $0.name < $1.name }
    }
}
