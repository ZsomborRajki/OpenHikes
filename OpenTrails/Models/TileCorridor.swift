//
//  TileCorridor.swift
//  OpenTrails
//
//  A route's bounding box padded by a fixed buffer, used to keep auto-saved
//  tiles scoped to "near this trail" rather than wherever the map happens to
//  be panned while auto-save is on.
//

import CoreLocation

/// `nonisolated`: constructed and queried from ``AutoSaveTileStore``, which runs
/// off the main actor.
nonisolated struct TileCorridor: Sendable {
    private let minLat: Double
    private let maxLat: Double
    private let minLon: Double
    private let maxLon: Double

    init(route: [CLLocationCoordinate2D], bufferMeters: CLLocationDistance) {
        guard !route.isEmpty else {
            minLat = 0; maxLat = 0; minLon = 0; maxLon = 0
            return
        }

        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in route {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        // Rough meters-per-degree padding; longitude degrees shrink toward the
        // poles, so scale by the corridor's mid-latitude.
        let latPad = bufferMeters / 111_320
        let midLatRad = (minLat + maxLat) / 2 * .pi / 180
        let lonPad = bufferMeters / (max(cos(midLatRad), 0.01) * 111_320)

        self.minLat = minLat - latPad
        self.maxLat = maxLat + latPad
        self.minLon = minLon - lonPad
        self.maxLon = maxLon + lonPad
    }

    /// Whether tile `z/x/y` overlaps the padded bounding box at all (edge tiles
    /// included, not just tiles whose center falls inside it).
    func overlaps(z: Int, x: Int, y: Int) -> Bool {
        let tileMinLon = SlippyTileMath.lon(x: x, z: z)
        let tileMaxLon = SlippyTileMath.lon(x: x + 1, z: z)
        let tileMaxLat = SlippyTileMath.lat(y: y, z: z)
        let tileMinLat = SlippyTileMath.lat(y: y + 1, z: z)
        return tileMinLon <= maxLon && tileMaxLon >= minLon && tileMinLat <= maxLat && tileMaxLat >= minLat
    }
}
