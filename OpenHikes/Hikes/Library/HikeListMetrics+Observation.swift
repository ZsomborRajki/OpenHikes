//
//  HikeListMetrics+Observation.swift
//  OpenHikes
//
//  A Hilliest list keeps observing its routes for the lifetime of its task,
//  so a route written through the main context while the list is up (heights
//  filled in, a recording finished, an edit that overtook a measurement) is
//  validated at once. A key of the sort and the hike IDs cannot notice that.
//
//  A write through another context is not caught here. A sibling context's
//  save was measured not to notify the main context's hike, even after a
//  fetch had refreshed its route, so an edit received from another device is
//  validated the next time the list's task starts.
//
//  The dependency is registered through the model's generated access method,
//  without asking for its externally stored route value. The worker reads,
//  hashes and measures those routes in its own background context, while the
//  sort itself keeps reading only its cached scalar figures.
//

import Foundation
import OpenHikesData
import SwiftData

nonisolated extension HikeListMetrics {
    @MainActor
    static func routeChangeIDs(for hikes: [Hike]) -> [UUID] {
        hikes.map { hike in
            hike.trackRouteChanges()
            return hike.id
        }
    }

    @MainActor
    static func observeElevation(
        in hikes: [Hike],
        container: ModelContainer,
        didChange: @MainActor () -> Void
    ) async {
        for await hikeIDs in observedValues({ routeChangeIDs(for: hikes) }) {
            let changed = await fillElevation(for: hikeIDs, in: container)
            guard !Task.isCancelled else { return }
            if changed { didChange() }
        }
    }
}
