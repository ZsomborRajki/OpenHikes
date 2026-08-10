//
//  SlippyTileMath.swift
//  OpenTrails
//
//  Shared slippy-map (OSM/Google-style) tile math: coordinate <-> tile index
//  conversions used by both the bulk downloader and the auto-save corridor.
//
//  The projection itself lives in `Mercator` (OpenTrailsShared), shared with
//  the widget's basemap registration — a tile index is just unit Mercator
//  scaled by the zoom level's tile count and floored, so there's no reason
//  for a second copy of the `tan`/`log` to exist here.
//

import Foundation
import OpenTrailsShared

/// `nonisolated`: used from both main-actor UI code and off-main tile-loading
/// code (``AutoSaveTileStore``, ``TileCache``'s callers).
nonisolated enum SlippyTileMath {
    /// Slippy-map tile column for a longitude at zoom `z`.
    static func tileX(_ lon: Double, z: Int) -> Int {
        Int(floor(Mercator.unitX(longitude: lon) * Double(1 << z)))
    }

    /// Slippy-map tile row for a latitude at zoom `z`.
    static func tileY(_ lat: Double, z: Int) -> Int {
        Int(floor(Mercator.unitY(latitude: lat) * Double(1 << z)))
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
        Mercator.longitude(unitX: Double(x) / Double(1 << z))
    }

    /// North-edge latitude of tile row `y` at zoom `z`.
    static func lat(y: Int, z: Int) -> Double {
        Mercator.latitude(unitY: Double(y) / Double(1 << z))
    }
}
