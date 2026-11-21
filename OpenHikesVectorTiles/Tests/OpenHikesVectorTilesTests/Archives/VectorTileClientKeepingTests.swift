//
//  VectorTileClientKeepingTests.swift
//  OpenHikesVectorTilesTests
//
//  How many archive tiles the vector client keeps for the tiles drawn from
//  them, and which it lets go first, with the tile server replaced by
//  `StubTileProtocol`. Out of `VectorTileClientTests.swift`, which is at the
//  length the linter allows. One of `VectorTileServerSuites`, because the
//  stub's script is process-wide.
//

import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import Testing

extension VectorTileServerSuites {
@Suite("Vector tile client keeping", .serialized)
struct VectorTileClientKeepingTests {
    // swiftlint:disable:next force_unwrapping
    private let archive = URL(string: "https://tiles.example.invalid/planet")!

    /// Every answer is the archive's that it has nothing at the tile, which
    /// is kept as a tile is and falls back without anything to draw.
    @Test("archive tiles are kept up to a limit, the one fetched first let go first")
    func keepsTheNewest() async {
        StubTileProtocol.reset()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(statusCode: 204))
        let client = VectorTileClient(
            archives: VectorTileArchives(sources: ["osm": VectorTileSource(archiveURL: archive, maximumZ: 15)]),
            session: URLSession(configuration: StubTileProtocol.sessionConfiguration()),
            language: "en",
            height: VectorTileFixture.height
        )
        let limit = VectorTileClient.keptArchiveTiles

        for column in 0...limit {
            #expect(await client.drawing(forKey: "osm/15/\(column)/0") == .fallBack)
        }

        #expect(StubTileProtocol.requestCount == limit + 1)
        #expect(!client.isAskingOrHolding(tile(column: 0)), "the first fetched goes once one more is kept")
        #expect(client.isAskingOrHolding(tile(column: 1)))
        #expect(client.isAskingOrHolding(tile(column: limit)))
    }

    private func tile(column: Int) -> URL {
        archive.appending(path: "15/\(column)/0.mvt")
    }
    }
}
