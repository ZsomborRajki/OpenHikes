//
//  VectorTileAreaDetails.swift
//  OpenHikes
//
//  What the vector extras say of an area the basemap has: a wood's leaves, a
//  wetland's kind, a beach's surface, a cemetery's religion, each of which
//  OpenStreetMap Carto picks the area's symbols by and the basemap drops.
//
//  The extras do not send the area again, which for the woods alone made
//  them five times the size. The basemap gives each of its features the id
//  OpenStreetMap does, with whether it is a way or a relation above it, and
//  the extras' `area_details` layer gives the same id with the tag's value
//  as its `kind_detail`. Its own shape is only what carried the id to this
//  tile, cut rough, and is never drawn.
//
//  An area the extras say nothing of is drawn as Carto draws one with no
//  such tag: a wood with the trees of unknown leaves, a wetland with the
//  plain marks. So is every area on a tile whose extras did not arrive.
//

import Foundation

/// The details of one tile's areas, by the basemap's id for each.
nonisolated struct VectorTileAreaDetails: Sendable {
    static let layerName = "area_details"

    private let details: [UInt64: String]

    init(_ tile: MapboxVectorTile) {
        var found: [UInt64: String] = [:]
        for feature in tile.layers[Self.layerName]?.features ?? [] {
            guard let id = feature.id, let detail = feature.string("kind_detail") else { continue }
            found[id] = detail
        }
        details = found
    }

    /// The detail of `feature`: its own `kind_detail`, as the extras' own
    /// areas carry one, or what the extras say of the basemap's area with
    /// its id.
    func detail(of feature: MapboxVectorTile.Feature) -> String? {
        feature.string("kind_detail") ?? feature.id.flatMap { details[$0] }
    }
}
