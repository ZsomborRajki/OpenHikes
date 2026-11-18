//
//  PreviewAttributionTests.swift
//  OpenHikesTests
//
//  What the credit line along the foot of *Map Modes* says: the selected
//  map's credits as the map draws them, then every other source the sheet
//  shows a picture of — the cards, and the *Hiking Routes* pictures — each
//  party once.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Preview attribution")
struct PreviewAttributionTests {
    private static func footer(selected: TileProvider, showsHikingRoutes: Bool = false) -> TileAttribution {
        TileAttribution.mapModes(selected: selected, showsHikingRoutes: showsHikingRoutes, cards: TileProvider.all)
    }

    /// A sixth map arriving in the catalog gets a card, so it has to arrive
    /// credited too — whichever map is selected when its card is drawn.
    @Test("every card's provider is credited, whichever map is selected", arguments: TileProvider.all)
    func everyCardIsCredited(selected: TileProvider) {
        let footer = Self.footer(selected: selected)
        for credit in TileProvider.all.flatMap(\.attribution.credits) {
            #expect(
                footer.credits.contains { $0.url == credit.url && ($0.url != nil || $0.title == credit.title) },
                "\(credit.plainText) is drawn on a card and not credited under \(selected.name)"
            )
        }
    }

    @Test("the selected map's parties lead in the map's order", arguments: TileProvider.all, [false, true])
    func selectedMapLeads(selected: TileProvider, showsHikingRoutes: Bool) throws {
        let drawn = try #require(TileAttribution.drawn(
            base: selected.attribution,
            layer: TileLayer.shown(isOn: showsHikingRoutes)?.attribution
        ))
        let footer = Self.footer(selected: selected, showsHikingRoutes: showsHikingRoutes)
        let leading = Array(footer.credits.prefix(drawn.credits.count))
        #expect(leading.map(\.url) == drawn.credits.map(\.url))
        #expect(leading.map(\.compactTitle) == drawn.credits.map(\.compactTitle))
    }

    /// Five raster maps and the routes' pictures credit OpenStreetMap
    /// between them, and both Apple entries credit Apple; named once each,
    /// with the landcover OpenStreetMap's own map draws, the line is the
    /// seven parties.
    @Test("over OpenStreetMap, each party is named once")
    func eachPartyOnce() {
        let footer = Self.footer(selected: .openStreetMap)
        #expect(footer.credits.map(\.title) == [
            "OpenStreetMap contributors", "ESA WorldCover", "Apple", "Stadia Maps", "OpenMapTiles", "Stamen Design",
            "Thunderforest",
        ])
    }

    /// The *Hiking Routes* pictures are OpenStreetMap's map, one with the
    /// layer over it, whichever of the two is chosen: so with no card drawn
    /// at all, under Apple's map, the line still credits OpenStreetMap, once.
    @Test("the routes' pictures are credited once, with the layer on or off", arguments: [false, true])
    func routesPicturesAreCredited(showsHikingRoutes: Bool) {
        let footer = TileAttribution.mapModes(selected: .appleMaps, showsHikingRoutes: showsHikingRoutes, cards: [])
        let openStreetMap = footer.credits.filter { $0.url == TileAttribution.Credit.openStreetMap.url }
        #expect(openStreetMap == [.openStreetMap])
    }

    /// A card with no key is not drawn, so it is not credited.
    @Test("a card that is not drawn is not credited")
    func undrawnCardIsNotCredited() {
        let footer = TileAttribution.mapModes(
            selected: .openStreetMap,
            showsHikingRoutes: false,
            cards: TileProvider.all.filter { !$0.requiresPaidAccess }
        )
        #expect(!footer.credits.contains(.thunderforest))
    }

    /// Thunderforest's terms require "Data ©" beside its own "Maps ©", so a
    /// card that credits OpenStreetMap as plain `©` does not replace it.
    @Test("over Thunderforest, its own spelling of the OpenStreetMap credit is kept")
    func providersSpellingWins() {
        let footer = Self.footer(selected: .thunderforestOutdoors)
        #expect(footer.credits.contains(.openStreetMapData))
        #expect(!footer.credits.contains(.openStreetMap))
    }

    @Test(
        "Thunderforest's preview keeps its data credit under every map and layer",
        arguments: TileProvider.all,
        [false, true]
    )
    func thunderforestPreviewKeepsDataCredit(selected: TileProvider, showsHikingRoutes: Bool) {
        let footer = Self.footer(selected: selected, showsHikingRoutes: showsHikingRoutes)
        let dataCredits = footer.credits.filter { $0.url == TileAttribution.Credit.openStreetMapData.url }
        #expect(dataCredits == [.openStreetMapData])
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
