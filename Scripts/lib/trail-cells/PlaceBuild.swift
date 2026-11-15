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
//  because most of them are not (see `TrailPointQuery.swift`). A way's box is
//  the box around its nodes, and a relation's the box around its member nodes
//  and ways, which are what Overpass measures `out center` from and finds one
//  by; member relations count for neither. One that runs out of a regional
//  extract is left out rather than placed short.
//
//  **A place is filed under every square its box touches**, so a search that
//  reads the squares its own boxes touch finds every place reaching into them,
//  as Overpass would. See `PlaceSquareGrid` for how few that is.
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
        /// Places left out for having no position to put a pin at.
        var withoutPositions = 0
        /// Places filed under more than one square, because their box
        /// reaches over a square's edge.
        var acrossSquares = 0
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
            let squares = PlaceSquareGrid.squares(covering: TrailCellBounds(
                south: Double(place.box.south) / scale,
                west: Double(place.box.west) / scale,
                north: Double(place.box.north) / scale,
                east: Double(place.box.east) / scale
            ))
            for square in squares {
                filed[square, default: []].append(place)
            }
            if squares.count > 1 { summary.acrossSquares += 1 }
        }

        let relations = try areaRelations(at: options.relationsPath)
        var memberWays: [Int64: PlaceSquareFile.Box] = [:]
        let wantedWays = Set(relations.flatMap(\.wayIDs))
        var waysRead = 0
        var waysWithPositions = 0
        try OPLFile(path: options.waysPath).forEachLine { line in
            guard let way = try OPL.way(line, scale: PlaceSquareFile.standardCoordinateScale, readsTags: true) else {
                return
            }
            waysRead += 1
            let box = way.points.flatMap(PlaceSquareFile.Box.init)
            if box != nil { waysWithPositions += 1 }
            if wantedWays.contains(way.id), let box { memberWays[way.id] = box }
            guard PlaceSquareFile.isPlace(.way, tags: way.tags) else { return }
            guard let box else {
                summary.withoutPositions += 1
                return
            }
            file(PlaceSquareFile.Place(element: .way, id: way.id, box: box, tags: kept(way.tags)))
            summary.ways += 1
        }
        // Not one way with a position, and ways that lacked them: the file
        // osmium writes when it is not asked for positions — see
        // `TrailCellBuild.ways(at:namedBy:)`.
        if waysWithPositions == 0, waysRead > 0 {
            throw BuildError.waysCarryNoPositions(options.waysPath)
        }

        // The places that are nodes, and every node a relation names, which
        // the script asks osmium to keep though most have no tags.
        let wantedNodes = Set(relations.flatMap(\.nodeIDs))
        var memberNodes: [Int64: PlaceSquareFile.Box] = [:]
        try OPLFile(path: nodesPath).forEachLine { line in
            guard let node = try OPL.node(line, scale: PlaceSquareFile.standardCoordinateScale) else { return }
            let point = node.point.map(PlaceSquareFile.Box.init)
            if let point, wantedNodes.contains(node.id) { memberNodes[node.id] = point }
            guard PlaceSquareFile.isPlace(.node, tags: node.tags) else { return }
            guard let point else {
                summary.withoutPositions += 1
                return
            }
            file(PlaceSquareFile.Place(element: .node, id: node.id, box: point, tags: kept(node.tags)))
            summary.nodes += 1
        }

        for relation in relations {
            // Every member node and way, or no pin: a hut whose outline runs
            // out of the extract would be placed by the part of it that is in.
            let boxes = relation.wayIDs.compactMap { memberWays[$0] }
                + relation.nodeIDs.compactMap { memberNodes[$0] }
            guard let first = boxes.first, boxes.count == relation.wayIDs.count + relation.nodeIDs.count else {
                summary.withoutPositions += 1
                continue
            }
            let box = boxes.dropFirst().reduce(first) { $0.union($1) }
            file(PlaceSquareFile.Place(element: .relation, id: relation.id, box: box, tags: relation.tags))
            summary.relations += 1
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
    /// A relation that is a place, with the members its box is measured
    /// from.
    struct AreaRelation {
        var id: Int64
        var tags: [String: String]
        var wayIDs: [Int64]
        var nodeIDs: [Int64]
    }

    /// The relations that are places. osmium hands over every member of a
    /// matching relation too, relations among them, whatever they are, so
    /// the tags are asked about again here.
    static func areaRelations(at path: String) throws -> [AreaRelation] {
        var kept: [AreaRelation] = []
        try OPLFile(path: path).forEachLine { line in
            guard let relation = try OPL.relation(line),
                  PlaceSquareFile.isPlace(.relation, tags: relation.tags)
            else { return }
            kept.append(AreaRelation(
                id: relation.id,
                tags: Self.kept(relation.tags),
                wayIDs: relation.members.filter { $0.kind == UInt8(ascii: "w") }.map(\.ref),
                nodeIDs: relation.members.filter { $0.kind == UInt8(ascii: "n") }.map(\.ref)
            ))
        }
        return kept
    }

    /// The tags of `tags` a square keeps.
    static func kept(_ tags: [String: String]) -> [String: String] {
        tags.filter { PlaceSquareFile.keptTagKeys.contains($0.key) }
    }

}

private extension PlaceSquareFile.Box {
    /// A node's box, from the point osmium wrote.
    init(_ point: TrailCellFile.Point) {
        self.init(PlaceSquareFile.Point(latitude: point.latitude, longitude: point.longitude))
    }

    /// The box around a way's nodes, or `nil` for a way with none.
    init?(_ points: [TrailCellFile.Point]) {
        guard let first = points.first else { return nil }
        self = points.dropFirst().reduce(Self(first)) { $0.union(Self($1)) }
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
