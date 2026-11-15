//
//  OverpassTrailGraphDecoding.swift
//  OpenHikes
//
//  Turns an Overpass JSON response into a `TrailGraph`. Split from
//  `OverpassTrailGraphProvider.swift` to keep that file under the length
//  limit; every symbol here is `nonisolated static` and touches no actor
//  state, which is what makes the split free.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared

// MARK: - Static helpers

extension OverpassTrailGraphProvider {
    nonisolated static func decodeGraph(from data: Data) throws -> TrailGraph {
        // The remark is read before anything is built out of the elements. An
        // aborted query answers `200` with valid JSON and an empty `elements`,
        // and a graph built from that is an empty graph — which this provider
        // would then write to its cache as *this tile has no trails in it* and
        // keep for the life of the entry, with nothing anywhere to say the tile
        // was never really read. See ``OverpassRequest/decode(_:from:)``.
        let response = try OverpassRequest.decode(OverpassResponse.self, from: data)

        let elementsByKey = buildElementIndex(from: response.elements)
        let nodeCoordinates = extractNodeCoordinates(from: response.elements)
        let hikingRouteNames = extractHikingRouteNames(from: elementsByKey)
        let (graphNodes, edges) = buildGraphEdges(
            from: elementsByKey,
            nodeCoordinates: nodeCoordinates,
            hikingRouteNames: hikingRouteNames
        )

        return TrailGraph(
            nodes: graphNodes.values.sorted { lhs, rhs in lhs.id < rhs.id },
            edges: edges.sorted { lhs, rhs in
                if lhs.id.wayID == rhs.id.wayID { return lhs.id.segmentIndex < rhs.id.segmentIndex }
                return lhs.id.wayID < rhs.id.wayID
            }
        )
    }

    /// The `highway` values kept: trails, and the roads that join them. Which
    /// of those a question may use is ``TrailMatcherGraphIndex``'s to decide,
    /// not the decoder's — see ``TrailGraphHighway``.
    static let allowedHighways = Set(TrailGraphHighway.all)

    nonisolated static func buildElementIndex(
        from elements: [OverpassElement]
    ) -> [String: OverpassElement] {
        elements.keyed(by: { "\($0.type)/\($0.id)" })
    }

    nonisolated static func extractNodeCoordinates(
        from elements: [OverpassElement]
    ) -> [Int64: CLLocationCoordinate2D] {
        var nodeCoordinates: [Int64: CLLocationCoordinate2D] = [:]
        for element in elements where element.type == "node" {
            guard let lat = element.lat,
                  let lon = element.lon,
                  Mercator.isRepresentable(latitude: lat, longitude: lon) else { continue }
            nodeCoordinates[element.id] = CLLocationCoordinate2D(
                latitude: lat,
                longitude: lon
            )
        }
        return nodeCoordinates
    }

    nonisolated static func extractHikingRouteNames(
        from elementsByKey: [String: OverpassElement]
    ) -> [Int64: String] {
        // The rule is the trail graph squares' too, written once where the
        // tool that builds them can compile it — see ``TrailGraphSquareFile``.
        var hikingRouteNames: [Int64: String] = [:]
        for element in elementsByKey.values where element.type == "relation" {
            guard let name = TrailGraphSquareFile.hikingRouteName(element.tags) else { continue }
            for member in element.members where member.type == "way" {
                hikingRouteNames[member.ref] = TrailGraphSquareFile.hikingRouteName(
                    of: [hikingRouteNames[member.ref], name].compactMap(\.self)
                )
            }
        }
        return hikingRouteNames
    }

    nonisolated static func buildGraphEdges(
        from elementsByKey: [String: OverpassElement],
        nodeCoordinates: [Int64: CLLocationCoordinate2D],
        hikingRouteNames: [Int64: String]
    ) -> (nodes: [Int64: TrailGraphNode], edges: [TrailGraphEdge]) {
        var graphNodes: [Int64: TrailGraphNode] = [:]
        var edges: [TrailGraphEdge] = []
        for element in elementsByKey.values where element.type == "way" {
            guard let highway = element.tags["highway"],
                  allowedHighways.contains(highway),
                  element.nodes.count > 1,
                  permitsWalking(element.tags) else { continue }

            let nodeIDs = element.nodes
            for (index, (fromID, toID)) in nodeIDs.adjacentPairs().enumerated() {
                guard fromID != toID,
                      let from = nodeCoordinates[fromID],
                      let to = nodeCoordinates[toID] else { continue }
                let length = RouteGeometry.distanceMeters(from: from, to: to)
                guard length.isFinite, length > 0 else { continue }
                graphNodes[fromID] = TrailGraphNode(id: fromID, coordinate: from)
                graphNodes[toID] = TrailGraphNode(id: toID, coordinate: to)
                edges.append(
                    TrailGraphEdge(
                        id: TrailGraphEdgeID(wayID: element.id, segmentIndex: index),
                        fromNodeID: fromID,
                        toNodeID: toID,
                        lengthMeters: length,
                        name: element.tags["name"],
                        hikingRouteName: hikingRouteNames[element.id],
                        sacScale: element.tags["sac_scale"],
                        trailVisibility: element.tags["trail_visibility"],
                        access: element.tags["access"],
                        surface: element.tags["surface"],
                        tracktype: element.tags["tracktype"],
                        highway: highway
                    )
                )
            }
        }
        return (graphNodes, edges)
    }

    /// The squares' rule, so a trail is walkable or not whichever brought
    /// it — see ``TrailGraphSquareFile/permitsWalking(_:)``.
    nonisolated static func permitsWalking(
        _ tags: [String: String]
    ) -> Bool {
        TrailGraphSquareFile.permitsWalking(tags)
    }
}
