//
//  TrailGraph.swift
//  OpenHikes
//
//  Compact, cacheable OSM walking graph. Ways are split at every OSM node so
//  shared node identifiers naturally become routable junctions.
//

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
    /// instead of a `surface` tag often enough to be worth keeping: it raises
    /// surface coverage by about seven points on a typical alpine region.
    ///
    /// Written after ``surface`` and decoded with the synthesized optional
    /// decoding, so a graph cached before this property existed still loads
    /// (as `nil`) rather than failing and forcing a refetch.
    let tracktype: String?

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
        tracktype: String? = nil
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
    }
}

nonisolated struct TrailGraph: Codable, Equatable, Sendable {
    let nodes: [TrailGraphNode]
    let edges: [TrailGraphEdge]

    static let empty = Self(nodes: [], edges: [])

    var isEmpty: Bool {
        nodes.isEmpty || edges.isEmpty
    }

    func merging(_ other: Self) -> Self {
        var nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in other.nodes {
            nodesByID[node.id] = node
        }

        var edgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
        for edge in other.edges {
            edgesByID[edge.id] = edge
        }

        return Self(
            nodes: nodesByID.values.sorted { lhs, rhs in lhs.id < rhs.id },
            edges: edgesByID.values.sorted { lhs, rhs in
                if lhs.id.wayID == rhs.id.wayID { return lhs.id.segmentIndex < rhs.id.segmentIndex }
                return lhs.id.wayID < rhs.id.wayID
            }
        )
    }
}
