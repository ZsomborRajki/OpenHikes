//
//  TileLoadResult.swift
//  OpenHikes
//
//  Preserves the difference between a failed tile request and one suppressed
//  by network policy as the load crosses from the cache to the renderer.
//

import Foundation

/// Why an uncached tile load did or did not produce an image.
nonisolated enum TileLoadDisposition: Sendable {
    case failed
    case loaded
    case suppressed
}

/// The image returned by a tile load, plus the distinction the renderer needs
/// between a request that failed and one network policy never allowed.
nonisolated enum TileLoadResult: @unchecked Sendable {
    case failed
    case loaded(TileImage)
    case suppressed

    var image: TileImage? {
        guard case let .loaded(image) = self else { return nil }
        return image
    }

    var disposition: TileLoadDisposition {
        switch self {
        case .failed: .failed
        case .loaded: .loaded
        case .suppressed: .suppressed
        }
    }
}

nonisolated extension TileCache {
    /// Loads a tile for display while hiding the renderer-only policy result.
    @concurrent
    @discardableResult func loadTile(
        forKey key: String,
        url: URL,
        purpose: TileFetchPurpose = .interactive
    ) async -> TileImage? {
        await loadTileResult(forKey: key, url: url, purpose: purpose).image
    }
}
