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
///
/// Conformance is declared below rather than here, because which form is
/// honest depends on the platform — `UIImage` is declared `NS_SWIFT_SENDABLE`
/// and `NSImage` is not.
nonisolated enum TileLoadResult {
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

#if canImport(UIKit)
// Checked: the compiler reads the associated value rather than taking an
// `@unchecked` at its word.
extension TileLoadResult: Sendable {}
#elseif canImport(AppKit)
// Unchecked on the argument the case has always rested on: the tile is decoded
// before it is wrapped and never written to again. Nothing builds this today.
extension TileLoadResult: @unchecked Sendable {}
#endif

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
