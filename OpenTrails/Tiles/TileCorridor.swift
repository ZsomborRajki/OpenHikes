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
///
/// Thin by design. This used to keep its own padded `min`/`max` box, which read
/// longitude as a plain interval — so a trail crossing the antimeridian got a
/// corridor spanning the entire globe, and auto-save would then claim tiles
/// browsed anywhere in that latitude band as belonging to the trail. Both the
/// wrap and the padding now live in ``TileBoundingBox``, which the bulk
/// downloader already enumerates through, so the two sides of the offline
/// story agree on what "near the route" means.
nonisolated struct TileCorridor: Sendable {
    /// `nil` for an empty route: nowhere to be near, so nothing is near it.
    private let box: TileBoundingBox?

    init(route: [CLLocationCoordinate2D], bufferMeters: CLLocationDistance) {
        box = TileBoundingBox(route: route)?.padded(byMeters: bufferMeters)
    }

    /// Whether tile `z/x/y` overlaps the padded bounding box at all (edge tiles
    /// included, not just tiles whose center falls inside it).
    func overlaps(z: Int, x: Int, y: Int) -> Bool {
        box?.contains(z: z, x: x, y: y) ?? false
    }
}
