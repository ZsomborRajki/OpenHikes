//
//  TileLayerTests.swift
//  OpenHikesTests
//
//  The hiking-route layer as a catalog entry: what it asks the server for,
//  at which zooms, who it credits, and the things it must never be — a
//  choice of base map, or something a bulk download can reach.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile layers")
struct TileLayerTests {
    private let layer = TileLayer.waymarkedHiking

    @Test("the hiking layer asks Waymarked Trails' tile server for its hiking theme")
    func templateNamesTheHikingTheme() throws {
        let url = try #require(URL(string: layer.urlTemplate))
        #expect(url.scheme == "https")
        #expect(url.host() == "tile.waymarkedtrails.org")
        #expect(layer.urlTemplate.hasSuffix("/hiking/{z}/{x}/{y}.png"))
        #expect(!layer.urlTemplate.contains("{key}"), "the layer is keyless")
    }

    /// The server answers z18 and 404s z19, so anything deeper is overzoomed;
    /// the floor keeps the layer from being fetched where nobody walks.
    @Test("the layer is drawn only at hiking zooms, up to the server's deepest")
    func zoomRange() {
        #expect(layer.maximumZ == 18)
        #expect(layer.minimumZ > 0)
        #expect(layer.minimumZ < layer.maximumZ)
    }

    /// A layer is not a map. In `TileProvider.all` it would be offered as a
    /// card, behind the paywall rules, and — the one with consequences for a
    /// volunteer's server — as a source a bulk download could be built from.
    @Test("no layer is also a base map, and no base map shares a layer's namespace")
    func layersAreNotProviders() {
        let providerIDs = Set(TileProvider.all.map(\.id))
        for entry in TileLayer.all {
            #expect(!providerIDs.contains(entry.id))
            #expect(!providerIDs.contains { $0.hasPrefix(entry.id) || entry.id.hasPrefix($0) })
        }
    }

    /// A download plan is built from an ``ActiveTileSource``, and a source
    /// whose id is the layer's resolves to no provider — so it falls to the
    /// default, which forbids bulk downloads. The layer cannot be reached
    /// by that path even by mistake.
    @Test("a source carrying the layer's id cannot be bulk-downloaded")
    func layerHasNoBulkDownloadPath() {
        let source = ActiveTileSource(
            providerID: layer.id,
            urlTemplate: layer.urlTemplate,
            maximumZ: layer.maximumZ
        )
        #expect(!source.permitsBulkDownload)
    }

    /// The overlay's licence asks that "the OpenStreetMap project and this
    /// site are mentioned" — both, and both linked.
    @Test("the layer credits Waymarked Trails and OpenStreetMap, each linked")
    func layerCredits() {
        let hosts = layer.attribution.credits.compactMap { $0.url?.host() }
        #expect(hosts.contains("hiking.waymarkedtrails.org"))
        #expect(hosts.contains("www.openstreetmap.org"))
        #expect(layer.attribution.credits.allSatisfy { $0.url != nil })
    }

    /// Its tiles land on disk under its own id, and the durable-tier
    /// bookkeeping has to be able to say whose they are.
    @Test("a saved layer tile is attributed to the layer")
    func diskNamesResolveToTheLayer() {
        #expect(TileCache.providerID(forDiskName: "waymarked_hiking_14_8800_5700") == layer.id)
        #expect(TileCache.durableByteLimit(forProviderID: layer.id) == nil)
    }

    @Test("the switch is off by default, and the layer follows it")
    func selectionFollowsTheSwitch() throws {
        let suite = "TileLayerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!SettingsDefault.showsHikingRoutes)
        #expect(TileLayer.selected(in: defaults) == nil)

        defaults.set(true, forKey: SettingsKey.showsHikingRoutes)
        #expect(TileLayer.selected(in: defaults) == .waymarkedHiking)
    }
}
