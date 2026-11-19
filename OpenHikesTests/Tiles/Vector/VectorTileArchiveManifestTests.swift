//
//  VectorTileArchiveManifestTests.swift
//  OpenHikesTests
//
//  The tile server's manifest, as this build reads it: the first basemap of
//  the schema it draws, the first extras of a generation it knows, and only
//  names that are an archive on that server. And the bundled one, which is
//  what a launch draws from until it has read the server's.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile archive manifest")
struct VectorTileArchiveManifestTests {
    // swiftlint:disable:next force_unwrapping
    private let server = URL(string: "https://tiles.example.invalid/")!
    private let schema = OfflineCountryManifest.readableSchema
    private let generation = VectorTileArchiveManifest.extrasGeneration

    @Test("the bundled manifest names a basemap and extras on the OpenHikes tile server")
    func bundledManifest() throws {
        let manifest = try #require(VectorTileArchiveManifest.bundled)
        let source = try #require(manifest.source(on: VectorTileArchives.server))

        #expect(source.archiveURL.host() == "tiles.openhikes.app")
        #expect(source.extras != nil)
        #expect(VectorTileSource.openHikesPlanet == source)
        #expect(TileProvider.openStreetMap.vectorSource == source)
    }

    @Test("the first basemap of the schema this build draws is drawn, with the first extras of a generation it knows")
    func firstDrawnIsDrawn() throws {
        let manifest = VectorTileArchiveManifest(
            version: VectorTileArchiveManifest.currentVersion,
            revision: 4,
            basemaps: [
                .init(name: "planet-20270101", schema: schema + 1, maximumZoom: 15),
                .init(name: "planet-20261201", schema: schema, maximumZoom: 15),
                .init(name: "planet-20261117", schema: schema, maximumZoom: 14),
            ],
            extras: [
                .init(name: "extras-20270101", generation: generation + 1, minimumZoom: 4),
                .init(name: "extras-20261201", generation: generation, minimumZoom: 6),
            ]
        )

        let source = try #require(manifest.source(on: server))

        #expect(source.archiveURL.absoluteString == "https://tiles.example.invalid/planet-20261201")
        #expect(source.maximumZ == 15)
        #expect(source.extras?.archiveURL.absoluteString == "https://tiles.example.invalid/extras-20261201")
        #expect(source.extras?.minimumZ == 6)
    }

    /// An earlier generation only lacks what later ones added, so it is
    /// drawn, and a basemap is drawn without extras where none are listed.
    @Test("an earlier generation of the extras is drawn, and with none the basemap is drawn alone")
    func earlierOrNoExtras() throws {
        var manifest = VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-20261117")
        manifest.extras = [.init(name: "extras-20261117", generation: 1, minimumZoom: 13)]

        #expect(try #require(manifest.source(on: server)).extras?.minimumZ == 13)
        manifest.extras = []
        let alone = try #require(manifest.source(on: server))
        #expect(alone.extras == nil)
        #expect(alone.archiveURL.lastPathComponent == "planet-20261117")
    }

    @Test("another version, or no basemap this build draws, names nothing")
    func namesNothing() {
        var manifest = VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-20261117", extras: "extras-1")
        manifest.version += 1
        #expect(manifest.source(on: server) == nil)

        manifest = .fixture(revision: 1, basemap: "planet-20261117")
        manifest.basemaps[0].schema += 1
        #expect(manifest.source(on: server) == nil)

        manifest = .fixture(revision: 1, basemap: "planet-20261117")
        manifest.basemaps[0].maximumZoom = 31
        #expect(manifest.source(on: server) == nil)
    }

    /// A name off the network becomes a path on the tile server, and must
    /// not step out of it.
    @Test("an archive's name is letters, digits and single hyphens", arguments: [
        ("planet-20261117", true),
        ("extras-20261119", true),
        ("planet", true),
        ("", false),
        ("Planet-20261117", false),
        ("planet--20261117", false),
        ("-planet", false),
        ("planet-", false),
        ("../planet", false),
        ("countries/manifest", false),
        ("planet.json", false),
        ("plänet", false),
        (String(repeating: "a", count: 65), false),
    ])
    func archiveNames(name: String, isArchive: Bool) {
        #expect(VectorTileArchiveManifest.isArchiveName(name) == isArchive)
    }

    @Test("a listed name that is not an archive's is passed over for the next")
    func unsafeNameIsPassedOver() throws {
        var manifest = VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-20261117", extras: "extras-1")
        manifest.basemaps.insert(.init(name: "../elsewhere", schema: schema, maximumZoom: 15), at: 0)
        manifest.extras.insert(.init(name: "Extras", generation: generation, minimumZoom: 4), at: 0)

        let source = try #require(manifest.source(on: server))

        #expect(source.archiveURL.lastPathComponent == "planet-20261117")
        #expect(source.extras?.archiveURL.lastPathComponent == "extras-1")
    }
}
