//
//  OverpassTrailGraphDecoding.swift
//  OpenHikes
//
//  Turns an Overpass JSON response into a `TrailGraph`. Split from
//  `OverpassTrailGraphProvider.swift` to keep that file under the length
//  limit; every symbol here is `nonisolated static` and touches no actor
//  state, which is what makes the split free.
//

import CoreLocation
import Foundation
import OpenHikesShared

// MARK: - Static helpers

extension OverpassTrailGraphProvider {
    nonisolated static func decodeGraph(from data: Data) throws -> TrailGraph {
        let response: OverpassResponse
        do {
            response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        } catch {
            throw TrailGraphProviderError.malformedGraph(
                error.localizedDescription
            )
        }

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

    /// The `highway` values this app treats as walkable trail. Everything
    /// outside it is road, and drawing a hiker onto one would be worse than
    /// leaving the trace alone.
    static let allowedHighways: Set<String> = [
        "path", "footway", "track", "bridleway", "steps", "cycleway",
        "via_ferrata",
    ]

    nonisolated static func buildElementIndex(
        from elements: [OverpassElement]
    ) -> [String: OverpassElement] {
        var index: [String: OverpassElement] = [:]
        for element in elements {
            index["\(element.type)/\(element.id)"] = element
        }
        return index
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
        var hikingRouteNames: [Int64: String] = [:]
        for element in elementsByKey.values where element.type == "relation" {
            guard element.tags["route"] == "hiking",
                  let name = element.tags["name"] ?? element.tags["ref"] else { continue }
            for member in element.members where member.type == "way" {
                if let existing = hikingRouteNames[member.ref] {
                    hikingRouteNames[member.ref] = min(existing, name)
                } else {
                    hikingRouteNames[member.ref] = name
                }
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
            for index in 0..<(nodeIDs.count - 1) {
                let fromID = nodeIDs[index]
                let toID = nodeIDs[index + 1]
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
                        tracktype: element.tags["tracktype"]
                    )
                )
            }
        }
        return (graphNodes, edges)
    }

    nonisolated static func permitsWalking(
        _ tags: [String: String]
    ) -> Bool {
        if let foot = tags["foot"], foot == "no" || foot == "private" { return false }
        guard let access = tags["access"],
              access == "no" || access == "private" else { return true }
        return ["yes", "designated", "permissive"].contains(tags["foot"])
    }
}
