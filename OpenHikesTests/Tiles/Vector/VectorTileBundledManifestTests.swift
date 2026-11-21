//
//  VectorTileBundledManifestTests.swift
//  OpenHikesTests
//
//  The app's half of the vector map, held to the package that draws it
//  (`OpenHikesVectorTiles`): the manifest this build bundles names archives
//  the package draws, on the OpenHikes tile server, and the package's point
//  table, icons and patterns are in the app that was built. The package's
//  own suites run on the Mac, where they cannot see what an app carries.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
@testable import OpenHikesVectorTiles
import Testing

@Suite("Vector tiles: the app's manifest and the package's resources")
struct VectorTileBundledManifestTests {
    @Test("the bundled manifest names a basemap and extras on the OpenHikes tile server")
    func bundledManifest() throws {
        let manifest = try #require(VectorTileArchiveManifest.bundled)
        let source = try #require(manifest.source(on: VectorTileArchives.server))

        #expect(source.archiveURL.host() == "tiles.openhikes.app")
        #expect(source.extras != nil)
        #expect(VectorTileSource.openHikesPlanet == source)
        #expect(TileProvider.openStreetMap.vectorSource == source)
    }

    /// A package's resources ride in a bundle of their own, which a build
    /// that left it out would only show as a map with no points on it.
    @Test("the package's point table, icons and patterns are in the app")
    func packageResources() {
        let side: CGFloat = 16
        let icons = CatalogIcons.shared

        #expect(!VectorTilePointStyle.bundled.source.isEmpty, "the table was read, not the empty one stood in")
        #expect(icons.image(asset: "carto-amenity-bench", fill: nil, size: CGSize(width: side, height: side)) != nil)
        #expect(icons.pattern(asset: VectorTilePatterns.assetPrefix + "wetland", unit: 1) != nil)
    }
}
