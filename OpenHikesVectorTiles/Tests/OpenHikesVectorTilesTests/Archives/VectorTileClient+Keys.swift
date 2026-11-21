//
//  VectorTileClient+Keys.swift
//  OpenHikesVectorTilesTests
//
//  A tile written the way the app's cache keys one, so a suite states a tile
//  in one string.
//

import Foundation
@testable import OpenHikesVectorTiles
import Testing

extension VectorTileClient {
    /// The tile `key` names as `<provider>/<z>/<x>/<y>`, drawn for that
    /// provider. A key of another shape is the suite's mistake.
    func drawing(forKey key: String) async -> Drawing {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        let numbers = parts.dropFirst().compactMap { Int($0) }
        guard let providerID = parts.first, parts.count == keyParts, numbers.count == keyParts - 1 else {
            Issue.record("\(key) is not <provider>/<z>/<x>/<y>")
            return .fallBack
        }
        return await drawing(
            of: VectorTileAddress(z: numbers[0], x: numbers[1], y: numbers[2]),
            for: String(providerID)
        )
    }

    private var keyParts: Int { 4 }
}
