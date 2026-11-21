//
//  StubbedTileCache.swift
//  OpenHikesTests
//
//  The app's half of `StubTileProtocol`, which is in
//  `OpenHikesVectorTilesTestSupport` because the vector tile package's own
//  suites script a server with it too: the PNG a raster server answers with,
//  and a tile cache whose transport is the stub.
//

import Foundation
@testable import OpenHikes
import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport

nonisolated extension StubTileProtocol.Response {
    /// A real, decodable PNG — what a tile server actually sends.
    static func tile(statusCode: Int = 200, headers: [String: String] = [:]) -> Self {
        Self(statusCode: statusCode, data: TileStore.tileData, headers: headers)
    }
}

/// A ``TileSandbox`` whose transport is this scripted `URLProtocol`, so a test
/// owns everything the cache can see: its two directories, its auto-save
/// store, and every response it gets back.
struct StubbedTileCache {
    let sandbox: TileSandbox

    var cache: TileCache { sandbox.cache }
    var store: AutoSaveTileStore { sandbox.store }

    init(
        reachable: Bool = true,
        mutationKeyLimit: Int = TileCache.mutationKeyVersionLimit,
        vectorSources: [String: VectorTileSource] = [:],
        vectorArchives: VectorTileArchives? = nil,
        power: PowerState = PowerState(),
        countryArchives: OfflineCountryArchives? = nil
    ) {
        StubTileProtocol.reset()
        sandbox = TileSandbox(
            reachable: reachable,
            sessionConfiguration: StubTileProtocol.sessionConfiguration(),
            mutationKeyLimit: mutationKeyLimit,
            vectorSources: vectorSources,
            vectorArchives: vectorArchives,
            power: power,
            countryArchives: countryArchives
        )
    }

    func browsedFile(for key: String) -> URL { sandbox.browsedFile(for: key) }
    func savedFile(for key: String) -> URL { sandbox.savedFile(for: key) }
    func isBrowsed(_ key: String) -> Bool { sandbox.isBrowsed(key) }
    func isSaved(_ key: String) -> Bool { sandbox.isSaved(key) }

    /// Puts a tile in a tier directly, as a previous session would have left it.
    func place(in file: URL, agedByDays days: Double = 0) throws {
        try sandbox.place(in: file, agedByDays: days)
    }

    /// Clears the process-wide response script. The directories go with the
    /// sandbox when it falls out of scope.
    func tearDown() {
        StubTileProtocol.reset()
    }
}
