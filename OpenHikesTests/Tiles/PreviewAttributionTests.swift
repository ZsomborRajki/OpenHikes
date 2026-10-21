//
//  PreviewAttributionTests.swift
//  OpenHikesTests
//
//  What Settings' credit line says under the map cards: the selected map's
//  credits as the map draws them, then every other source a card shows
//  imagery from, each party once.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Preview attribution")
struct PreviewAttributionTests {
    private static let cards = TileProvider.all.map(\.attribution)

    private static func footer(selected: TileProvider) throws -> TileAttribution {
        try #require(TileAttribution.drawn(base: selected.attribution, layer: nil)).including(previews: cards)
    }

    /// A sixth map arriving in the catalog gets a card, so it has to arrive
    /// credited too — whichever map is selected when its card is drawn.
    @Test("every card's provider is credited, whichever map is selected", arguments: TileProvider.all)
    func everyCardIsCredited(selected: TileProvider) throws {
        let footer = try Self.footer(selected: selected)
        for credit in TileProvider.all.flatMap(\.attribution.credits) {
            #expect(
                footer.credits.contains { $0.url == credit.url && ($0.url != nil || $0.title == credit.title) },
                "\(credit.plainText) is drawn on a card and not credited under \(selected.name)"
            )
        }
    }

    @Test("the selected map's parties lead in the map's order", arguments: TileProvider.all)
    func selectedMapLeads(selected: TileProvider) throws {
        let drawn = try #require(TileAttribution.drawn(base: selected.attribution, layer: nil))
        let footer = drawn.including(previews: Self.cards)
        let leading = Array(footer.credits.prefix(drawn.credits.count))
        #expect(leading.map(\.url) == drawn.credits.map(\.url))
        #expect(leading.map(\.compactTitle) == drawn.credits.map(\.compactTitle))
    }

    /// Four raster maps credit OpenStreetMap between them, and both Apple
    /// entries credit Apple; named once each, the line is the six parties.
    @Test("over OpenStreetMap, each party is named once")
    func eachPartyOnce() throws {
        let footer = try Self.footer(selected: .openStreetMap)
        #expect(footer.credits.map(\.title) == [
            "OpenStreetMap contributors", "Apple", "Stadia Maps", "OpenMapTiles", "Stamen Design", "Thunderforest",
        ])
    }

    /// Thunderforest's terms require "Data ©" beside its own "Maps ©", so a
    /// card that credits OpenStreetMap as plain `©` does not replace it.
    @Test("over Thunderforest, its own spelling of the OpenStreetMap credit is kept")
    func providersSpellingWins() throws {
        let footer = try Self.footer(selected: .thunderforestOutdoors)
        #expect(footer.credits.contains(.openStreetMapData))
        #expect(!footer.credits.contains(.openStreetMap))
    }

    @Test(
        "Thunderforest's preview keeps its data credit under every map and layer",
        arguments: TileProvider.all,
        [false, true]
    )
    func thunderforestPreviewKeepsDataCredit(selected: TileProvider, showsHikingRoutes: Bool) throws {
        let drawn = try #require(TileAttribution.drawn(
            base: selected.attribution,
            layer: TileLayer.shown(isOn: showsHikingRoutes)?.attribution
        ))
        let footer = drawn.including(previews: Self.cards)
        let dataCredits = footer.credits.filter { $0.url == TileAttribution.Credit.openStreetMapData.url }
        #expect(dataCredits == [.openStreetMapData])
        #expect(footer.credits.contains(.waymarkedTrails) == showsHikingRoutes)
        #expect(footer.credits.filter { $0 == .apple }.count == 1)
    }

    @Test(
        "without Thunderforest imagery the shorter OpenStreetMap credit is kept",
        arguments: TileProvider.all.filter { $0 != .thunderforestOutdoors }
    )
    func noThunderforestLeavesTheShorterCredit(selected: TileProvider) throws {
        let availableCards = TileProvider.all.filter { $0 != .thunderforestOutdoors }.map(\.attribution)
        let drawn = try #require(TileAttribution.drawn(base: selected.attribution, layer: nil))
        let footer = drawn.including(previews: availableCards)
        #expect(footer.credits.contains(.openStreetMap))
        #expect(!footer.credits.contains(.openStreetMapData))
        #expect(!footer.credits.contains(.thunderforest))
    }

    @Test("with no cards drawn the credits are unchanged", arguments: TileProvider.all)
    func noPreviewsLeavesTheCredits(provider: TileProvider) {
        #expect(provider.attribution.including(previews: []) == provider.attribution)
    }
}
