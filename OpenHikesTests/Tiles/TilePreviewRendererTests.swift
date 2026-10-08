//
//  TilePreviewRendererTests.swift
//  OpenHikesTests
//
//  The compositor behind a Settings map card: four tiles from the cache into
//  one square, or nothing at all — a card with a hole in it reads as a broken
//  map, where the placeholder reads as "not loaded yet".
//

import Foundation
@testable import OpenHikes
import Testing
import UIKit

@Suite("Map card compositing")
@MainActor
struct TilePreviewRendererTests {
    private let frame = TilePreviewFrame(around: TilePreviewFrame.fallbackCoordinate)
    private let source = TilePreviewSource(.openStreetMap, apiKey: nil)

    /// What the map already drew is what the card shows: every tile is a
    /// cache hit here, and the sandbox is offline so nothing else could be.
    @Test("four cached tiles make a square twice a tile wide")
    func cachedBlockComposites() async throws {
        let sandbox = TileSandbox(reachable: false)
        for tile in frame.tiles {
            try sandbox.browse(key: try #require(source.cacheKey(for: tile)))
        }

        let image = try #require(await TilePreviewRenderer.composite(source, in: frame, cache: sandbox.cache))
        let tile = try #require(Fixture.tileImage().flatMap { UIImage(data: $0.pngData() ?? Data()) })
        let tileSide = tile.size.width * tile.scale
        #expect(image.size.width * image.scale == 2 * tileSide)
        #expect(image.size.height * image.scale == 2 * tileSide)
    }

    /// Offline with one tile missing: no card, rather than three quarters of one.
    @Test("a block missing a tile draws nothing")
    func partialBlockIsNil() async throws {
        let sandbox = TileSandbox(reachable: false)
        for tile in frame.tiles.dropLast() {
            try sandbox.browse(key: try #require(source.cacheKey(for: tile)))
        }

        #expect(await TilePreviewRenderer.composite(source, in: frame, cache: sandbox.cache) == nil)
    }

    /// A source with no key never reaches the cache at all.
    @Test("an unavailable source draws nothing")
    func unavailableIsNil() async {
        let sandbox = TileSandbox(reachable: false)
        let image = await TilePreviewRenderer.image(
            for: .unavailable,
            in: frame,
            style: .light,
            side: 96,
            cache: sandbox.cache
        )
        #expect(image == nil)
    }
}
