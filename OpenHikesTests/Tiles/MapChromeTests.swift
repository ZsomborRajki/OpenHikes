//
//  MapChromeTests.swift
//  OpenHikesTests
//
//  The controls over the map take the map's appearance: light over every
//  tile map drawn light at every hour, dark over the OpenHikes map in its
//  dark colors, and the phone's over Apple's maps.
//

@testable import OpenHikes
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("Map chrome")
struct MapChromeTests {
    nonisolated private static let lightMaps = TileProvider.rasterSources.filter { $0 != .openHikesDark }

    @Test("the controls are light over every map drawn light", arguments: lightMaps)
    func lightTiles(provider: TileProvider) {
        #expect(provider.renderedBase.chrome == .light)
    }

    @Test("the controls are dark over the OpenHikes map in its dark colors")
    func darkTiles() {
        #expect(TileProvider.openHikesDark.renderedBase.chrome == .dark)
        #expect(TileProvider.openHikesDark.vectorPalette.isDark)
    }

    @Test("the controls follow the phone over Apple's maps", arguments: [
        TileProvider.appleMaps, TileProvider.appleSatellite,
    ])
    func systemMaps(apple: TileProvider) {
        #expect(apple.renderedBase.chrome == .system)
    }

    /// A map that is not in the catalog is drawn by nobody; its chrome is a
    /// light tile map's, the default every raster source has.
    @Test("tiles of a provider the catalog does not know are taken for a light map")
    func unknownProvider() {
        let source = ActiveTileSource(providerID: "gone", urlTemplate: "https://example.invalid", maximumZ: 1)
        let base = MapBase.tiles(source)
        #expect(base.chrome == .light)
    }

    @Test("each appearance is the map view's override and the color scheme of what is drawn over it")
    func bridges() {
        #expect(MapChrome.light.interfaceStyle == .light)
        #expect(MapChrome.dark.interfaceStyle == .dark)
        #expect(MapChrome.system.interfaceStyle == .unspecified)
        #expect(MapChrome.light.colorScheme == .light)
        #expect(MapChrome.dark.colorScheme == .dark)
        #expect(MapChrome.system.colorScheme == nil)
    }
}
