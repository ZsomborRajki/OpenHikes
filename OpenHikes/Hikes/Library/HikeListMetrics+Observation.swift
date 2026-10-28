//
//  HikeListMetrics+Observation.swift
//  OpenHikes
//
//  A Hilliest list keeps observing its routes for the lifetime of its task.
//  A count/sort key cannot notice an incoming edit to the same hike, and the
//  sending device's editor cannot invalidate this device's local sidecar.
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
