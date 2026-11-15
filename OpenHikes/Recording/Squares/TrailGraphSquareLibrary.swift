//
//  TrailGraphSquareLibrary.swift
//  OpenHikes
//
//  A region of the trail graph answered from the pre-built squares: the one
//  square the region lies in, from this device or in one request, and the
//  graph of every trail in it that crosses the region.
//
//  ``OverpassTrailGraphProvider`` asks this before it asks Overpass, on the
//  terms the day hikes' squares keep (see ``TrailCellLibrary``):
//
//  - ``TrailGraphSquareAnswer/graph(_:)`` is the region's trails, given only
//    when the squares are the whole world. An empty graph means there are no
//    trails there.
//  - ``TrailGraphSquareAnswer/uncovered`` is the squares not reaching the
//    region: none published in this environment, or a set that is only part
//    of the world, whose squares are not read at all.
//  - ``TrailGraphSquareAnswer/unreachable`` is a square that should be
//    readable and was not.
//
//  Either of the last two sends the region to Overpass exactly as it went
//  before there were squares.
//
//  ## One square, many regions
//
//  A square is sixteen of the provider's regions, and a recording asks for
//  the nine around the hiker at once. So a square is fetched once however
//  many regions are waiting on it, the last one read is kept decoded, and
//  every square fetched is kept on disk, in a store of its own.
//
//  ## The same graph as Overpass's
//
//  A region's graph is read from a square exactly as
//  `OverpassTrailGraphDecoding` reads an Overpass answer for the region's box:
//  every way that crosses the box, whole, an edge for each segment between
//  two different nodes that has a length, joined at the nodes' ids. What a
//  square leaves out is the roads, which only the trail maker asks about —
//  see ``TrailGraphSquareGrid`` — and so this is never what the maker reads.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared
import os

/// What the pre-built squares had to say about a region of the trail graph.
nonisolated enum TrailGraphSquareAnswer: Sendable {
    /// The trails that cross the region, which may be none.
    case graph(TrailGraph)
    /// The squares do not reach this region, so nothing is known from them.
    case uncovered
    /// The square the region needs could not be read.
    case unreachable
}

/// The trail graph's pre-built squares, read through a disk cache.
///
/// An actor, unlike the other sets' libraries, because what it holds is
/// shared by the regions asked about at once: the fetch of a square nine of
/// them are waiting on, and the square read last.
actor TrailGraphSquareLibrary {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailGraphSquares")

    /// How many squares are kept on disk.
    ///
    /// A recording's nine regions lie in one to four squares, so this is a
    /// few days of walking. The median square is 5.4 KB and one in a hundred
    /// is over 627 KB; the one around Berchtesgaden is 683 KB and the largest,
    /// over Paris, 6.0 MB — a third more once it is a file here. In `Caches`,
    /// where the system takes the lot back when it wants the room.
    static let maximumFiles = 32

    /// How long a request may go quiet, and take in all, in seconds: the
    /// hiking-routes layer's, because a square is as large as one of its and
    /// is mostly asked for while a recording walks on, with Overpass behind
    /// it if it fails.
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120

    /// Where the files live for an ordinary launch: `Caches`, beside the
    /// other sets' squares.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("TrailGraphSquares", isDirectory: true)
    }

    /// The squares for this launch, read from the public database, or `nil`
    /// for a launch under test, UI tests included, on the terms
    /// ``OpenHikesModel/makeCommunityTransport()`` keeps: there is no sandbox
    /// for a public database, so no suite may fetch from it.
    static func forThisLaunch() -> TrailGraphSquareLibrary? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return TrailGraphSquareLibrary(database: CloudKitTrailCellDatabase(
            manifestRecordName: TrailGraphSquareGrid.manifestRecordName,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
        ))
    }

    /// What reading one square came to.
    nonisolated enum Read: Sendable {
        case square(TrailGraphSquareFile)
        case uncovered
        case unreachable
    }

    private let database: any TrailCellFetching
    private let store: TrailCellStore?
    private var fetches: [String: Task<Read, Never>] = [:]
    private var recent: (name: String, square: TrailGraphSquareFile)?

    /// - Parameter directory: Where fetched squares are kept between
    ///   launches. A suite passes one of its own, and must: the default is
    ///   the app's `Caches`.
    init(
        database: any TrailCellFetching,
        directory: URL? = TrailGraphSquareLibrary.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        store = directory.map { TrailCellStore(directory: $0, maximumFiles: Self.maximumFiles, clock: clock) }
    }

    /// The trails of `region`, or why the squares cannot say.
    func graph(for region: TrailGraphRegion) async -> TrailGraphSquareAnswer {
        guard let square = TrailGraphSquareGrid.square(forRegionX: region.x, y: region.y, zoom: region.zoom) else {
            return .uncovered
        }
        switch await read(TrailGraphSquareGrid.recordName(for: square)) {
        case .square(let file):
            return .graph(Self.graph(of: file, crossing: Self.bounds(of: region)))

        case .uncovered:
            return .uncovered

        case .unreachable:
            return .unreachable
        }
    }

    /// The square named `name`: the one read last, the one on disk, or one
    /// request, shared by every region that asks for it while it is out.
    private func read(_ name: String) async -> Read {
        if let recent, recent.name == name { return .square(recent.square) }
        if let bytes = store?.bytes(ofCellNamed: name), let square = try? TrailGraphSquareFile(decoding: bytes) {
            recent = (name: name, square: square)
            return .square(square)
        }
        let fetch: Task<Read, Never>
        if let running = fetches[name] {
            fetch = running
        } else {
            let source = database
            let keeping = store
            fetch = Task.detached { await Self.fetched(name, from: source, keepingIn: keeping) }
            fetches[name] = fetch
        }
        let read = await fetch.value
        fetches[name] = nil
        if case .square(let square) = read { recent = (name: name, square: square) }
        return read
    }

    /// One square, asked for by name with the manifest beside it, and kept
    /// on disk when it is one the whole world's squares say is there or is
    /// not — see ``TrailCellLibrary`` for why nothing else is kept.
    private static func fetched(
        _ name: String,
        from database: any TrailCellFetching,
        keepingIn store: TrailCellStore?
    ) async -> Read {
        let fetch: TrailCellFetch
        do {
            fetch = try await database.fetch(cellsNamed: [name])
        } catch {
            logger.error("A trail graph square could not be reached: \(error.localizedDescription, privacy: .public)")
            return .unreachable
        }
        switch fetch.manifest {
        case .complete:
            break

        case .absent, .partial:
            return .uncovered

        case .unread:
            return .unreachable
        }
        switch fetch.cells[name] ?? .failed {
        case .found(let bytes):
            guard let square = try? TrailGraphSquareFile(decoding: bytes) else {
                logger.error("Square \(name, privacy: .public) is not a file this build reads.")
                return .unreachable
            }
            store?.save([(name: name, bytes: bytes)])
            return .square(square)

        case .absent:
            // No record, in a set that is the whole world: ground with no
            // trails on it, and worth remembering as such.
            let empty = TrailGraphSquareFile(ways: [])
            store?.save([(name: name, bytes: empty.encoded())])
            return .square(empty)

        case .failed:
            return .unreachable
        }
    }
}

// MARK: - Reading a region out of a square

nonisolated extension TrailGraphSquareLibrary {
    /// A box in degrees.
    struct Bounds: Equatable, Sendable {
        var south: Double
        var west: Double
        var north: Double
        var east: Double
    }

    /// The box of a region of the graph — the box the provider asks Overpass
    /// about.
    static func bounds(of region: TrailGraphRegion) -> Bounds {
        Bounds(
            south: SlippyTileMath.lat(y: region.y + 1, z: region.zoom),
            west: SlippyTileMath.lon(x: region.x, z: region.zoom),
            north: SlippyTileMath.lat(y: region.y, z: region.zoom),
            east: SlippyTileMath.lon(x: region.x + 1, z: region.zoom)
        )
    }

    /// The graph of every way of `square` that crosses `bounds`, whole, read
    /// as `OverpassTrailGraphDecoding` reads an Overpass answer: an edge for
    /// each segment between two nodes, numbered by its place in the way.
    static func graph(of square: TrailGraphSquareFile, crossing bounds: Bounds) -> TrailGraph {
        let scale = Double(square.coordinateScale)
        var nodes: [Int64: TrailGraphNode] = [:]
        var edges: [TrailGraphEdge] = []
        for way in square.ways {
            let coordinates = way.nodes.map { node in
                CLLocationCoordinate2D(
                    latitude: Double(node.latitude) / scale,
                    longitude: Double(node.longitude) / scale
                )
            }
            guard coordinates.adjacentPairs().contains(where: { crosses(from: $0, to: $1, bounds) }) else { continue }
            for (index, ((from, fromCoordinate), (to, toCoordinate)))
                in zip(way.nodes, coordinates).adjacentPairs().enumerated() {
                guard from.id != to.id,
                      Mercator.isRepresentable(latitude: fromCoordinate.latitude, longitude: fromCoordinate.longitude),
                      Mercator.isRepresentable(latitude: toCoordinate.latitude, longitude: toCoordinate.longitude)
                else { continue }
                let length = RouteGeometry.distanceMeters(from: fromCoordinate, to: toCoordinate)
                guard length.isFinite, length > 0 else { continue }
                nodes[from.id] = TrailGraphNode(id: from.id, coordinate: fromCoordinate)
                nodes[to.id] = TrailGraphNode(id: to.id, coordinate: toCoordinate)
                edges.append(TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: way.id, segmentIndex: index),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: length,
                    name: way.tags[.name],
                    hikingRouteName: way.tags[.hikingRoute],
                    sacScale: way.tags[.sacScale],
                    trailVisibility: way.tags[.trailVisibility],
                    access: way.tags[.access],
                    surface: way.tags[.surface],
                    tracktype: way.tags[.tracktype],
                    highway: way.highway
                ))
            }
        }
        return TrailGraph(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: edges.sorted { lhs, rhs in
                if lhs.id.wayID == rhs.id.wayID { return lhs.id.segmentIndex < rhs.id.segmentIndex }
                return lhs.id.wayID < rhs.id.wayID
            }
        )
    }

    /// Whether the segment from `start` to `end` touches `bounds`, edges
    /// included: Overpass's box finds a way by any segment that crosses it,
    /// not only by a node inside. The plane of latitude and longitude, which
    /// is a region's own few kilometres; a segment across the antimeridian is
    /// not one a region is crossed by.
    static func crosses(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, _ bounds: Bounds) -> Bool {
        // Liang–Barsky: clip the segment's parameter to each of the box's
        // four sides in turn, and it crosses when something is left.
        let deltaX = end.longitude - start.longitude
        let deltaY = end.latitude - start.latitude
        let sides = [
            (-deltaX, start.longitude - bounds.west),
            (deltaX, bounds.east - start.longitude),
            (-deltaY, start.latitude - bounds.south),
            (deltaY, bounds.north - start.latitude),
        ]
        var entering = 0.0
        var leaving = 1.0
        for (direction, distance) in sides {
            if direction == 0 {
                guard distance >= 0 else { return false }
                continue
            }
            let crossing = distance / direction
            if direction < 0 {
                entering = max(entering, crossing)
            } else {
                leaving = min(leaving, crossing)
            }
            guard entering <= leaving else { return false }
        }
        return true
    }
}
