//
//  WatchTrailPaths.swift
//  OpenHikesShared
//
//  The footpaths *around* a trail, so the wrist map shows a network rather
//  than one line in a void.
//
//  ## Why this exists at all
//
//  Apple's basemap is thin where hiking happens, and on watchOS there is no way
//  to put a better one under it: `MKTileOverlay`, `MKTileOverlayRenderer` and
//  `MKMapView` are all `API_UNAVAILABLE(watchos)`, so OpenTopoMap and every
//  other tile source are out at any price. What *can* be drawn is `MapContent`,
//  and a polyline is `MapContent`. So the paths come across as geometry and the
//  watch draws them itself.
//
//  ## Why this is not the tile transfer that was refused
//
//  A rendered basemap is hundreds of kilobytes of picture per trail, at one
//  zoom, of one patch of ground. This is a few hundred *coordinates*: it scales
//  with how many paths are near the route rather than with how many pixels the
//  screen has, it stays correct at every zoom, and it is capped — see
//  ``pointBudget``. The objection was to the cost and the fixedness of an
//  image, and neither survives the change of representation.
//
//  ## Why it is its own message
//
//  The trail's own line must never wait for this. The network may need an
//  Overpass request, which is a volunteer-run service that is sometimes slow
//  and sometimes rate-limited, and a hiker at a trailhead wants the route drawn
//  now. So ``WatchTrailPackage`` goes as soon as it is built and this follows
//  whenever it can — or never, which is a map with one line on it, exactly what
//  the watch drew before.
//

import Foundation

/// The walking paths near one trail, as lines to draw under it.
public struct WatchTrailPaths: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    /// How many coordinates in total may cross for one trail.
    ///
    /// The budget is over the *whole* network rather than per path, because
    /// what costs a transfer is the total and what a hiker notices is whether
    /// the junction ahead is drawn. A dense valley spends it on many short
    /// ways; open moorland spends it on a few long ones. Sized beside
    /// ``WatchTrailPackage/pointBudget``: the network is context for the route
    /// and should not cost more than twice the route itself.
    public static let pointBudget = 1600

    /// How far from the route a path has to be before it stops being context.
    ///
    /// A hiker reads a map to answer "what is that turning" and "where does
    /// this fork go", and both are questions about ground they can see from
    /// the trail. Everything beyond this is another walk's map, and it would
    /// spend the budget the junctions need.
    public static let corridorMeters = 400.0

    public let schemaVersion: Int

    /// The trail these belong to, so a watch can refuse a network that arrived
    /// after the hiker moved on to another trail.
    public var hikeID: UUID
    /// One line per way, already thinned. Two points at least, or it is a
    /// place rather than a path and nothing would be drawn for it.
    public var paths: [[SharedTrailSnapshot.CodableCoordinate]]
    public var sentAt: Date

    public init(
        hikeID: UUID,
        paths: [[SharedTrailSnapshot.CodableCoordinate]],
        sentAt: Date = .now
    ) {
        self.hikeID = hikeID
        self.paths = paths
        self.sentAt = sentAt
        schemaVersion = Self.currentSchemaVersion
    }

    /// Whether there is anything here worth drawing.
    public var isDrawable: Bool { paths.contains { $0.count > 1 } }

    /// How many coordinates this carries, which is what the budget counts.
    public var pointCount: Int { paths.reduce(0) { $0 + $1.count } }
}
