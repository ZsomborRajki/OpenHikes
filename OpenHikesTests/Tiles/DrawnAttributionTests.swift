//
//  DrawnAttributionTests.swift
//  OpenHikesTests
//
//  What the credit line says when the hiking-route layer is drawn over a
//  map: every party either of them is owed, each once, the map's first and
//  in the map's own spelling.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Drawn attribution")
struct DrawnAttributionTests {
    private let layer = TileLayer.waymarkedHiking.attribution

    @Test("with no layer the map's credits are unchanged", arguments: TileProvider.all)
    func noLayerLeavesTheMapsCredits(provider: TileProvider) {
        #expect(TileAttribution.drawn(base: provider.attribution, layer: nil) == provider.attribution)
    }

    @Test("nothing to credit is nothing to draw")
    func neitherIsNil() {
        #expect(TileAttribution.drawn(base: nil, layer: nil) == nil)
    }

    /// OpenStreetMap is credited by the map and by the layer, under the same
    /// licence link. Named twice would be one party credited twice.
    @Test("over OpenStreetMap, OpenStreetMap is credited once and first")
    func openStreetMapIsNotRepeated() throws {
        let drawn = try #require(TileAttribution.drawn(
            base: TileProvider.openStreetMap.attribution,
            layer: layer
        ))
        #expect(drawn.credits.map(\.title) == ["OpenStreetMap", "Waymarked Trails"])
    }

    /// Thunderforest's terms require "Data ©" beside its own "Maps ©", so
    /// the map's spelling of the OpenStreetMap credit is the one kept.
    @Test("over Thunderforest, its own spelling of the OpenStreetMap credit is kept")
    func providersSpellingWins() throws {
        let drawn = try #require(TileAttribution.drawn(
            base: TileProvider.thunderforestOutdoors.attribution,
            layer: layer
        ))
        #expect(drawn.credits == [.thunderforest, .openStreetMapData, .waymarkedTrails])
    }

    /// MapKit's own **Legal** link credits Apple; the line on the map carries
    /// only what the app must link itself.
    @Test("over Apple's map, only the layer's linked credits are drawn")
    func appleIsLeftToMapKit() throws {
        let drawn = try #require(TileAttribution.drawn(
            base: TileProvider.appleMaps.attribution,
            layer: layer
        ))
        #expect(drawn == layer)
        #expect(drawn.hasLinks, "a line with links is a line that is shown")
    }

    @Test("every map keeps all of its own credits under the layer", arguments: TileProvider.rasterSources)
    func noProviderCreditIsDropped(provider: TileProvider) throws {
        let drawn = try #require(TileAttribution.drawn(base: provider.attribution, layer: layer))
        #expect(Array(drawn.credits.prefix(provider.attribution.credits.count)) == provider.attribution.credits)
        #expect(drawn.credits.contains(.waymarkedTrails))
    }
}
