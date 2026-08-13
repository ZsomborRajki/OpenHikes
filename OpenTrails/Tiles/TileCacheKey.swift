//
//  TileCacheKey.swift
//  OpenTrails
//

import CoreGraphics

nonisolated enum TileCacheKey {
    static func path(
        z: Int,
        x: Int,
        y: Int,
        scale: CGFloat
    ) -> String {
        "\(z)/\(x)/\(y)@\(scale)"
    }

    static func namespaced(
        providerID: String,
        z: Int,
        x: Int,
        y: Int,
        scale: CGFloat
    ) -> String {
        "\(providerID)/\(path(z: z, x: x, y: y, scale: scale))"
    }
}
