//
//  DisplayedRoute+Prepared.swift
//  OpenHikesTests
//
//  The selected route as the map is handed it once its projection has
//  landed. The projection is made off the main actor from the selection's
//  change handler (see `DisplayedRouteCoordinateCache`), so a suite that only
//  wants the answer asks a cache of its own and waits for it.
//

@testable import OpenHikes
import OpenHikesData

extension DisplayedRoute {
    static func prepared(for hike: Hike) async -> Self? {
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: hike)
        await cache.preparation?.value
        return forSelection(hike, cache: cache)
    }
}
