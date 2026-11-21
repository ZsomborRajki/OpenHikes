//
//  VectorTileAreaDetails.swift
//  OpenHikesVectorTiles
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
//  The extras also say which of the basemap's forests is none. The basemap
//  files the boundary of a forest the United States Forest Service or its
//  like administers, a protected area of class 6, under the kind it files a
//  mapped forest under, so a National Forest was filled as woodland from
//  edge to edge, with trees over its tundra and its towns. OpenStreetMap
//  Carto draws such a boundary as a border and nothing more. The extras
//  outline the same element in their `protected_areas` layer, under the id
//  Planetiler gives one, so a forest whose element is among those is the
//  boundary, and is left to that outline (``isBoundary(_:)``).
//

import Foundation

/// The details of one tile's areas, by the basemap's id for each.
struct VectorTileAreaDetails: Sendable {
    static let layerName = "area_details"
    /// The basemap's kind for a mapped forest, and for the boundary of an
    /// administered one.
    static let forestKind = "forest"

    private let details: [UInt64: String]
    /// The areas the extras outline as protected, by the basemap's id for
    /// each.
    private let protected: Set<UInt64>

    init(_ tile: MapboxVectorTile) {
        var found: [UInt64: String] = [:]
        for feature in tile.layers[Self.layerName]?.features ?? [] {
            guard let id = feature.id, let detail = feature.string("kind_detail") else { continue }
            found[id] = detail
        }
        details = found
        protected = Set(
            (tile.layers[VectorTileRasterizer.protectedAreasLayer]?.features ?? [])
                .compactMap { $0.id.flatMap(Self.basemapID(ofExtras:)) }
        )
    }

    /// The detail of `feature`: its own `kind_detail`, as the extras' own
    /// areas carry one, or what the extras say of the basemap's area with
    /// its id.
    func detail(of feature: MapboxVectorTile.Feature) -> String? {
        feature.string("kind_detail") ?? feature.id.flatMap { details[$0] }
    }

    /// Whether `feature` is the boundary of a protected area that the
    /// basemap filed as a forest: one of its forests whose element the
    /// extras outline as protected. Not filled and given no trees, on a tile
    /// whose extras arrived with the outline; without them it is drawn as
    /// the forest the basemap says it is.
    func isBoundary(_ feature: MapboxVectorTile.Feature) -> Bool {
        guard !feature.isFromExtras, feature.string("kind") == Self.forestKind, let id = feature.id else {
            return false
        }
        return protected.contains(id)
    }

    /// The basemap's id for the element one of the extras' features was cut
    /// from, where the extras' schema gives the feature no id of its own.
    /// Planetiler then gives it the element's OpenStreetMap id times ten,
    /// plus 1 for a node, 2 for a way and 3 for a relation; the basemap
    /// gives the element the same id with the 1, 2 or 3 written above it.
    static func basemapID(ofExtras id: UInt64) -> UInt64? {
        let (element, type) = id.quotientAndRemainder(dividingBy: 10)
        guard (1...3).contains(type), element < 1 << elementTypeShift else { return nil }
        return type << elementTypeShift | element
    }

    /// The bit the basemap writes an element's type from.
    private static let elementTypeShift: UInt64 = 44
}
