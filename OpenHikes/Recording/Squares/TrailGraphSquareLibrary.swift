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
//  The trail maker's graph is read through the same library from a set of
//  its own, laid out a square a region (``Layout/routing``), which the tile
//  server holds with the roads in it: see ``RoutingGraphArchive``.
//
//  The fetch is counted the way the provider counts a region's: it goes on
//  while any region waits on it, and is cancelled when the last one stops
//  waiting, so a recording's Stop ends the request rather than leaving it to
//  run out its timeout. Awaiting a task's value does not pass a cancellation
//  on to the task, which is why the count is kept here. A region given up on
//  starts no request and reads nothing out of a square that arrives.
//
//  A square that could not be read is left for a minute, as the
//  hiking-routes layer leaves one: its regions go to Overpass meanwhile, and
//  a square too large for the signal is not downloaded again from the start
//  for each of the sixteen regions it holds.
//
//  ## As old as the square
//
//  A square is trusted for the thirty days ``OverpassCache`` trusts anything
//  OpenStreetMap said, from when it was fetched. Every answer carries that
//  moment, and the provider keeps a region read out of a square as fetched
//  then, not when the region was read — or a square read on its last day
//  would lend a region thirty more.
//
//  ## The same graph as Overpass's
//
//  A region's graph is read from a square as `OverpassTrailGraphDecoding`
//  reads an Overpass answer for the region's box: every way that crosses the
//  box, whole, an edge for each segment between two different nodes, joined
//  at the nodes' ids. The one difference is a segment with no length, which
//  a square keeps and the decoder leaves out — see
//  ``graph(of:crossing:)``. What the public database's squares leave out is
//  the roads, which only the trail maker asks about — see
//  ``TrailGraphSquareGrid`` — and so the maker reads its own set.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared
import os

/// What the pre-built squares had to say about a region of the trail graph.
nonisolated enum TrailGraphSquareAnswer: Sendable {
    /// The trails that cross the region, which may be none, and when the
    /// square they were read out of was fetched.
    case graph(TrailGraph, fetchedAt: Date)
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
    /// How long a square that could not be read is left before it is asked
    /// for again, in seconds: ``HikingRouteSquares/failedRetry``, for the
    /// same reason.
    static let failedRetry: TimeInterval = HikingRouteSquares.failedRetry

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
        case square(TrailGraphSquareFile, fetchedAt: Date)
        case uncovered
        case unreachable
    }

    /// The square read last, and when it was fetched.
    private struct Recent {
        let name: String
        let square: TrailGraphSquareFile
        let fetchedAt: Date
    }

    /// One square's request, and the regions waiting on it.
    private struct SquareFetch {
        let id: UUID
        let task: Task<Read, Never>
        var waiters: Set<UUID>
    }

    /// Which square answers for a region, and what it is called.
    nonisolated struct Layout: Sendable {
        /// The zoom of the slippy-map tiles a square is.
        var squareZoom: Int
        var name: @Sendable (TrailGraphSquare) -> String

        /// The trail graph's squares in the public database.
        static let trails = Layout(squareZoom: TrailGraphSquareGrid.squareZoom) { square in
            TrailGraphSquareGrid.recordName(for: square)
        }

        /// The trail maker's, on the tile server: a square is a region.
        static let routing = Layout(squareZoom: RoutingGraphArchive.zoom) { tile in
            RoutingGraphArchive.squareName(for: tile)
        }
    }

    private let database: any TrailCellFetching
    private let layout: Layout
    private let store: TrailCellStore?
    private let clock: @Sendable () -> Date
    private var fetches: [String: SquareFetch] = [:]
    private var recent: Recent?
    /// The squares that could not be read, and until when they are left.
    private var failedUntil: [String: Date] = [:]

    /// - Parameter directory: Where fetched squares are kept between
    ///   launches. A suite passes one of its own, and must: the default is
    ///   the app's `Caches`.
    init(
        database: any TrailCellFetching,
        layout: Layout = .trails,
        directory: URL? = TrailGraphSquareLibrary.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.layout = layout
        self.clock = clock
        store = directory.map { TrailCellStore(directory: $0, maximumFiles: Self.maximumFiles, clock: clock) }
    }

    /// The trails of `region`, or why the squares cannot say.
    func graph(for region: TrailGraphRegion) async -> TrailGraphSquareAnswer {
        guard let square = TrailGraphSquareGrid.square(
            forRegionX: region.x,
            y: region.y,
            zoom: region.zoom,
            squareZoom: layout.squareZoom
        ) else {
            return .uncovered
        }
        switch await read(layout.name(square)) {
        case let .square(file, fetchedAt):
            // Read for nobody otherwise, and a large square's read is the
            // costly part of a region.
            guard !Task.isCancelled else { return .unreachable }
            return .graph(Self.graph(of: file, crossing: Self.bounds(of: region)), fetchedAt: fetchedAt)

        case .uncovered:
            return .uncovered

        case .unreachable:
            return .unreachable
        }
    }

    /// How many regions are waiting on the request for the square named
    /// `name`.
    ///
    /// A test seam, as ``OverpassTrailGraphProvider/waiterCount(for:)`` is:
    /// the count is what keeps one region giving up from cancelling another's
    /// square, and nothing else shows it. Nothing in the app reads it.
    func waiterCount(forSquareNamed name: String) -> Int {
        fetches[name]?.waiters.count ?? 0
    }

    /// The square named `name`: the one read last, the one on disk, or one
    /// request, shared by every region that asks for it while it is out.
    private func read(_ name: String) async -> Read {
        // Held to the same thirty days as the file it was read from, or a
        // long launch would go on answering from it after the file expired.
        if let recent, recent.name == name {
            if clock().timeIntervalSince(recent.fetchedAt) <= OverpassCache.lifetime {
                return .square(recent.square, fetchedAt: recent.fetchedAt)
            }
            self.recent = nil
        }
        if let kept = store?.cell(named: name), let square = try? TrailGraphSquareFile(decoding: kept.bytes) {
            recent = Recent(name: name, square: square, fetchedAt: kept.fetchedAt)
            return .square(square, fetchedAt: kept.fetchedAt)
        }
        let fetch: SquareFetch
        if let running = fetches[name] {
            fetch = running
        } else {
            guard !Task.isCancelled, !hasFailedRecently(name) else { return .unreachable }
            fetch = beginFetch(name)
        }
        let fetchID = fetch.id
        let waiter = UUID()
        fetches[name]?.waiters.insert(waiter)
        let read = await withTaskCancellationHandler {
            await fetch.task.value
        } onCancel: {
            // Synchronous wherever the cancellation landed, so it hops; the
            // claim it drops was made before this region suspended.
            Task { await self.stopWaiting(waiter, on: name, fetchID: fetchID) }
        }
        // Finished, so whichever region comes back first lets it go.
        if fetches[name]?.id == fetchID { fetches[name] = nil }
        switch read {
        case let .square(square, fetchedAt):
            recent = Recent(name: name, square: square, fetchedAt: fetchedAt)

        case .unreachable where !fetch.task.isCancelled:
            // A request nobody wanted any more did not fail.
            let now = clock()
            failedUntil = failedUntil.filter { $0.value > now }
            failedUntil[name] = now.addingTimeInterval(Self.failedRetry)

        case .unreachable, .uncovered:
            break
        }
        return read
    }

    /// Whether the square named `name` could not be read less than
    /// ``failedRetry`` ago.
    private func hasFailedRecently(_ name: String) -> Bool {
        guard let until = failedUntil[name] else { return false }
        guard until > clock() else {
            failedUntil[name] = nil
            return false
        }
        return true
    }

    private func beginFetch(_ name: String) -> SquareFetch {
        let source = database
        let keeping = store
        let stamping = clock
        let fetch = SquareFetch(
            id: UUID(),
            task: Task.detached { await Self.fetched(name, from: source, keepingIn: keeping, clock: stamping) },
            waiters: []
        )
        fetches[name] = fetch
        return fetch
    }

    /// One region giving up on a square: its claim goes, and the request with
    /// it once no other region is waiting.
    private func stopWaiting(_ waiter: UUID, on name: String, fetchID: UUID) {
        guard var fetch = fetches[name], fetch.id == fetchID else { return }
        fetch.waiters.remove(waiter)
        guard fetch.waiters.isEmpty else {
            fetches[name] = fetch
            return
        }
        fetches[name] = nil
        fetch.task.cancel()
    }

    /// One square, asked for by name with the manifest beside it, and kept
    /// on disk when it is one the whole world's squares say is there or is
    /// not — see ``TrailCellLibrary`` for why nothing else is kept. A request
    /// cancelled because no region waits on it any more keeps nothing.
    private static func fetched(
        _ name: String,
        from database: any TrailCellFetching,
        keepingIn store: TrailCellStore?,
        clock: @Sendable () -> Date
    ) async -> Read {
        let fetch: TrailCellFetch
        do {
            fetch = try await database.fetch(cellsNamed: [name])
        } catch {
            if !Task.isCancelled {
                logger.error(
                    "A trail graph square could not be reached: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .unreachable
        }
        guard !Task.isCancelled else { return .unreachable }
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
            return .square(square, fetchedAt: clock())

        case .absent:
            // No record, in a set that is the whole world: ground with no
            // trails on it, and worth remembering as such.
            let empty = TrailGraphSquareFile(ways: [])
            store?.save([(name: name, bytes: empty.encoded())])
            return .square(empty, fetchedAt: clock())

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
    ///
    /// Except that a segment with no length is kept. A square holds positions
    /// to a millionth of a degree (``TrailGraphSquareFile/standardCoordinateScale``),
    /// so two of a way's nodes a few centimetres apart can be one point here,
    /// and leaving out the segment between them, as the decoder leaves out
    /// one with no length, would cut the trail in two at it: 330 of 75
    /// million segments, in two samples of the planet's trails. A square
    /// cannot tell those from the rarer nodes OpenStreetMap itself has on one
    /// spot, which the decoder leaves out, so it keeps those too; either way
    /// the trail stays joined where OpenStreetMap joins it.
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
                guard length.isFinite else { continue }
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
    /// is a region's own few kilometres, with the step read the short way
    /// round, as the tool files a way by it
    /// (``TrailGraphSquareGrid/turn(fromLongitude:to:)``): a step from 179.9°
    /// to −179.9° crosses the regions at both edges of the map, whose squares
    /// hold it, and none at Greenwich.
    static func crosses(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, _ bounds: Bounds) -> Bool {
        let deltaY = end.latitude - start.latitude
        let turn = TrailGraphSquareGrid.turn(fromLongitude: start.longitude, to: end.longitude)
        guard turn != 0 else {
            return clips(from: start, deltaX: end.longitude - start.longitude, deltaY: deltaY, bounds)
        }
        // Read the short way, the step runs on past ±180° from either end,
        // and a region stands on the map once: one on its start's side meets
        // it running on from the start, and one on its end's side running
        // back from the end.
        let deltaX = end.longitude + turn - start.longitude
        return clips(from: start, deltaX: deltaX, deltaY: deltaY, bounds)
            || clips(from: end, deltaX: -deltaX, deltaY: -deltaY, bounds)
    }

    /// Whether the segment that runs `deltaX` east and `deltaY` north from
    /// `start` touches `bounds`.
    private static func clips(
        from start: CLLocationCoordinate2D,
        deltaX: Double,
        deltaY: Double,
        _ bounds: Bounds
    ) -> Bool {
        // Liang–Barsky: clip the segment's parameter to each of the box's
        // four sides in turn, and it crosses when something is left.
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
