//
//  SlippyTileMath.swift
//  OpenTrails
//
//  Shared slippy-map (OSM/Google-style) tile math: coordinate <-> tile index
//  conversions used by both the bulk downloader and the auto-save corridor.
//

import Foundation

/// `nonisolated`: used from both main-actor UI code and off-main tile-loading
/// code (``AutoSaveTileStore``, ``TileCache``'s callers).
nonisolated enum SlippyTileMath {
    /// Slippy-map tile column for a longitude at zoom `z`.
    static func tileX(_ lon: Double, z: Int) -> Int {
        Int(floor((lon + 180) / 360 * Double(1 << z)))
    }

    /// Slippy-map tile row for a latitude at zoom `z`.
    static func tileY(_ lat: Double, z: Int) -> Int {
        let r = lat * .pi / 180
        return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * Double(1 << z)))
    }

    static func clamp(_ value: Int, to n: Int) -> Int { min(max(value, 0), n - 1) }

    /// Wraps a tile column into the valid `[0, n)` range. Tile columns are
    /// cyclic (longitude wraps at ±180°), so as the map pans/scrolls
    /// continuously around the world MapKit can hand out columns outside this
    /// range — use this (not `clamp`) for x; `clamp` for y, since latitude is
    /// bounded and doesn't wrap.
    static func wrap(_ value: Int, to n: Int) -> Int { ((value % n) + n) % n }

    /// West-edge longitude of tile column `x` at zoom `z`.
    static func lon(x: Int, z: Int) -> Double {
        Double(x) / Double(1 << z) * 360 - 180
    }

    /// North-edge latitude of tile row `y` at zoom `z`.
    static func lat(y: Int, z: Int) -> Double {
        let n = .pi - 2 * .pi * Double(y) / Double(1 << z)
        return 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
    }
}
