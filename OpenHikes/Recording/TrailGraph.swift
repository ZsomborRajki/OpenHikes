//
//  TrailGraph.swift
//  OpenHikes
//
//  Compact, cacheable OSM walking graph. Ways are split at every OSM node so
//  shared node identifiers naturally become routable junctions.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated struct TrailGraphNode: Codable, Equatable, Hashable, Sendable {
    let id: Int64
    let latitude: Double
    let longitude: Double

    init(id: Int64, coordinate: CLLocationCoordinate2D) {
        self.id = id
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated struct TrailGraphEdgeID: Codable, Equatable, Hashable, Sendable {
    let wayID: Int64
    let segmentIndex: Int
}

nonisolated struct TrailGraphEdge: Codable, Equatable, Hashable, Sendable {
    let id: TrailGraphEdgeID
    let fromNodeID: Int64
    let toNodeID: Int64
    let lengthMeters: Double
    let name: String?
    let hikingRouteName: String?
    let sacScale: String?
    let trailVisibility: String?
    let access: String?
    let surface: String?
    /// OSM `tracktype` (`grade1`…`grade5`), the firmness scale tracks carry
    /// instead of a `surface` tag often enough to be worth keeping.
    let tracktype: String?
    /// OSM `highway`, which is what says whether this is a trail or a road
    /// joining two — see ``TrailGraphHighway``. `nil` on edges decoded before
    /// roads were downloaded, all of which were trails.
    let highway: String?

    var displayName: String? {
        hikingRouteName ?? name
    }

    init(
        id: TrailGraphEdgeID,
        fromNodeID: Int64,
        toNodeID: Int64,
        lengthMeters: Double,
        name: String? = nil,
        hikingRouteName: String? = nil,
        sacScale: String? = nil,
        trailVisibility: String? = nil,
        access: String? = nil,
        surface: String? = nil,
        tracktype: String? = nil,
        highway: String? = nil
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.lengthMeters = lengthMeters
        self.name = name
        self.hikingRouteName = hikingRouteName
        self.sacScale = sacScale
        self.trailVisibility = trailVisibility
        self.access = access
        self.surface = surface
        self.tracktype = tracktype
        self.highway = highway
    }

    var isTrail: Bool {
        TrailGraphHighway.isTrail(highway)
    }
}

nonisolated struct TrailGraph: Codable, Equatable, Sendable {
    let nodes: [TrailGraphNode]
    let edges: [TrailGraphEdge]

    static let empty = Self(nodes: [], edges: [])

    var isEmpty: Bool {
        nodes.isEmpty || edges.isEmpty
    }

    /// Both graphs, each node and edge once: where the two hold the same id,
    /// `other`'s copy, because `keyed(by:)` keeps the last value it meets.
    func merging(_ other: Self) -> Self {
        let nodesByID = chain(nodes, other.nodes).keyed(by: \.id)
        let edgesByID = chain(edges, other.edges).keyed(by: \.id)
        return Self(
            nodes: nodesByID.values.sorted { lhs, rhs in lhs.id < rhs.id },
            edges: edgesByID.values.sorted { lhs, rhs in
                if lhs.id.wayID == rhs.id.wayID { return lhs.id.segmentIndex < rhs.id.segmentIndex }
                return lhs.id.wayID < rhs.id.wayID
            }
        )
    }
}
