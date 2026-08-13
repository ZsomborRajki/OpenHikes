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

import CoreLocation
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

/// A route's bounding box, with longitude treated as the cyclic quantity it is.
///
/// Taken as a plain `min`/`max` interval, a route that crosses the antimeridian
/// comes out spanning almost the entire globe — the long way round, rather than
/// the few kilometres the trail actually covers. So this stores a west edge and
/// an eastward span, and picks whichever of the two arcs through the route's
/// points is shorter. Latitude is bounded and doesn't wrap, so it stays a plain
/// interval.
nonisolated struct TileBoundingBox: Sendable {
    /// Ground metres in one degree of latitude — and, scaled by the cosine of
    /// the latitude, in one degree of longitude. Rough (the earth isn't a
    /// sphere), but this only ever sizes a padding buffer.
    private static let metersPerDegreeLatitude: Double = 111_320
    private static let minimumCosineLatitude: Double = 0.01

    let southLat: Double
    let northLat: Double
    /// West edge, in [-180, 180).
    let westLon: Double
    /// Degrees east from `westLon` to the east edge, in [0, 360].
    let lonSpan: Double

    private init(southLat: Double, northLat: Double, westLon: Double, lonSpan: Double) {
        self.southLat = southLat
        self.northLat = northLat
        self.westLon = westLon
        self.lonSpan = lonSpan
    }

    /// `nil` for an empty route, which has no box to speak of.
    init?(route: [CLLocationCoordinate2D]) {
        guard !route.isEmpty else { return nil }

        var south = 90.0, north = -90.0
        for coordinate in route {
            south = min(south, coordinate.latitude)
            north = max(north, coordinate.latitude)
        }
        southLat = south
        northLat = north

        // The enclosing arc is the complement of the widest gap between
        // neighbouring longitudes around the circle — including the gap that
        // runs through ±180°, which is the one an ordinary route falls in.
        let longitudes = route.map(\.longitude).sorted()
        var gapWest = longitudes[longitudes.count - 1]
        var widestGap = longitudes[0] + 360 - longitudes[longitudes.count - 1]
        for index in 1..<longitudes.count {
            let gap = longitudes[index] - longitudes[index - 1]
            if gap > widestGap {
                widestGap = gap
                gapWest = longitudes[index - 1]
            }
        }
        westLon = Self.normalized(gapWest + widestGap)
        lonSpan = 360 - widestGap
    }

    /// Tile columns the box spans at zoom `z`, as a first column and a count.
    /// The run may pass the last column and continue from zero, so callers must
    /// take each column through ``SlippyTileMath/wrap(_:to:)``.
    func columns(at z: Int) -> (first: Int, count: Int) {
        let n = 1 << z
        // A box within one tile of reaching all the way round is treated as
        // doing so. Past that point the east edge lands back inside the west
        // edge's own column, and the arithmetic below can't tell "the whole
        // world" from "a single column" — it would answer the latter.
        guard lonSpan < 360 - 360 / Double(n) else { return (0, n) }

        let first = SlippyTileMath.wrap(SlippyTileMath.tileX(westLon, z: z), to: n)
        let last = SlippyTileMath.wrap(SlippyTileMath.tileX(Self.normalized(westLon + lonSpan), z: z), to: n)
        var count = last - first + 1
        // The east edge lies west of the west edge in column numbering — the box
        // runs through the antimeridian.
        if count <= 0 { count += n }
        return (first, min(count, n))
    }

    /// Tile rows the box spans at zoom `z`, north to south.
    func rows(at z: Int) -> (first: Int, count: Int) {
        let n = 1 << z
        let top = SlippyTileMath.clamp(SlippyTileMath.tileY(northLat, z: z), to: n)
        let bottom = SlippyTileMath.clamp(SlippyTileMath.tileY(southLat, z: z), to: n)
        return (top, bottom - top + 1)
    }

    /// How many tiles cover the box at zoom `z` — the cost of adding that level,
    /// answered without building any of them.
    func tileCount(at z: Int) -> Int {
        columns(at: z).count * rows(at: z).count
    }

    /// Whether tile `z/x/y` falls inside the box.
    ///
    /// Answered in tile-index space, through the very same ``columns(at:)`` and
    /// ``rows(at:)`` the enumeration uses, so "is this tile in the box?" and
    /// "would this tile be enumerated?" cannot drift apart — and so the
    /// antimeridian is handled once, here, rather than by a second comparison
    /// in degrees that would have to rediscover the wrap.
    ///
    /// Edge-inclusive: a tile that merely clips the box counts, because the
    /// column and row runs are floored from the box's own edges.
    func contains(z: Int, x: Int, y: Int) -> Bool {
        let (firstRow, rowCount) = rows(at: z)
        guard y >= firstRow, y < firstRow + rowCount else { return false }
        let (firstColumn, columnCount) = columns(at: z)
        // Distance east from the first column, the long way round if need be —
        // which is exactly the order the enumeration walks them in.
        return SlippyTileMath.wrap(x - firstColumn, to: 1 << z) < columnCount
    }

    /// The box grown by `meters` on every side — "near this trail" rather than
    /// "on it".
    ///
    /// Longitude degrees shrink toward the poles, so the east–west padding is
    /// scaled by the box's mid-latitude. Padding a cyclic span can only ever
    /// reach the whole way round, never overshoot into a second lap.
    func padded(byMeters meters: CLLocationDistance) -> Self {
        let latitudePadding = meters / Self.metersPerDegreeLatitude
        let midLatitudeRadians = (southLat + northLat) / 2 * .pi / 180
        let cosClamped = max(cos(midLatitudeRadians), Self.minimumCosineLatitude)
        let longitudePadding = meters / (cosClamped * Self.metersPerDegreeLatitude)

        return Self(
            // Clamped to the projection's own domain rather than to ±90: a box
            // padded past the Mercator limit has no more world to include.
            southLat: max(southLat - latitudePadding, -Mercator.latitudeLimit),
            northLat: min(northLat + latitudePadding, Mercator.latitudeLimit),
            westLon: Self.normalized(westLon - longitudePadding),
            lonSpan: min(lonSpan + 2 * longitudePadding, 360)
        )
    }

    private static func normalized(_ longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}
