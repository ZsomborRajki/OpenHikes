//
//  TileLayerTests.swift
//  OpenHikesTests
//
//  The hiking-route layer as a catalog entry: which zooms it is drawn at, who
//  it credits, and the thing it must never be — a choice of base map.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile layers")
struct TileLayerTests {
    private let layer = TileLayer.hikingRoutes

    @Test("the layer is drawn from the shallowest zoom its squares are filed for")
    func zoomFloor() {
        #expect(layer.minimumZ == RouteSquareLevel.minimumZoom)
        #expect(RouteSquareLevel.level(forZoom: layer.minimumZ) != nil)
        #expect(RouteSquareLevel.level(forZoom: layer.minimumZ - 1) == nil)
    }

    /// A layer is not a map. In `TileProvider.all` it would be offered as a
    /// card, behind the paywall rules, and as a source a bulk download could
    /// be built from.
    @Test("the layer is not a base map, and no base map shares its name")
    func layerIsNotAProvider() {
        let providerIDs = Set(TileProvider.all.map(\.id))
        #expect(!providerIDs.contains(layer.id))
        #expect(!providerIDs.contains { $0.hasPrefix(layer.id) || layer.id.hasPrefix($0) })
    }

    /// The squares are OpenStreetMap's data, drawn by the app, so its credit
    /// is the one owed — linked to the copyright page, as every one is.
    @Test("the layer credits OpenStreetMap, linked")
    func layerCredits() {
        #expect(layer.attribution.credits == [.openStreetMap])
        #expect(layer.attribution.credits.allSatisfy { $0.url != nil })
    }

    @Test("the switch is off by default, and the layer follows it")
    func layerFollowsTheSwitch() {
        #expect(!SettingsDefault.showsHikingRoutes)
        #expect(TileLayer.shown(isOn: false) == nil)
        #expect(TileLayer.shown(isOn: true) == layer)
    }
}
