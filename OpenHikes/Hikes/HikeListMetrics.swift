//
//  HikeListMetrics.swift
//  OpenHikes
//
//  Working out the figures a library can be sorted by, once, off the screen.
//
//  Climb and descent are not stored on a hike. ``Hike/routeStatistics`` derives
//  them by walking every point of a route, and its own documentation says not
//  to read it from a SwiftUI body — which is exactly what sorting a library by
//  climb would do, for every hike, on every redraw.
//
//  So the first time a hiker asks for one of those orders, this fills the cache
//  on ``HikeLocalState`` in its own context, off the main actor, and the list
//  redraws when it lands. Afterwards the sort reads two `Double`s.
//
//  It runs against a background context rather than the main one for the reason
//  every other sweep here does: it may touch every hike in the library, and a
//  library is as long as a hiker's walking life.
//

import Foundation
import os
import SwiftData

nonisolated enum HikeListMetrics {
    private static let logger = Logger(subsystem: "OpenHikes", category: "HikeListMetrics")

    /// Fills climb and descent for whichever of `hikeIDs` have none.
    ///
    /// Returns whether anything was written, so a caller knows whether a
    /// redraw is worth asking for. Silent on failure: a library that cannot be
    /// measured is a library sorted with those hikes last, which is what a
    /// missing figure already means.
    @discardableResult static func fillElevation(
        for hikeIDs: [UUID],
        in container: ModelContainer
    ) -> Bool {
        guard !hikeIDs.isEmpty else { return false }
        let context = ModelContext(container)
        var wrote = false
        for hikeID in hikeIDs {
            guard let hike = hike(hikeID, in: context) else { continue }
            let totals = ElevationTotals(route: hike.route)
            guard let state = try? HikeLocalState.fetchExisting(for: hikeID, in: context)
                ?? HikeLocalState.forHike(hikeID, in: context) else { continue }
            state.climbMeters = totals.climbMeters
            state.descentMeters = totals.descentMeters
            wrote = true
        }
        guard wrote else { return false }
        do {
            try context.save()
        } catch {
            Self.logger.error(
                "Hike elevation totals could not be cached: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        return true
    }

    private static func hike(_ hikeID: UUID, in context: ModelContext) -> Hike? {
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Climb and descent over a whole route.
    ///
    /// Summed between consecutive points that carry a height rather than taken
    /// as high minus low, which a rolling trail understates by every descent it
    /// makes on the way up — the argument ``SharedTrailSnapshot`` and
    /// `WatchTrailPackaging` both already make. Non-finite heights are skipped
    /// rather than accumulated: one `nan` would poison the total and sort the
    /// hike wherever `nan` happens to compare.
    private struct ElevationTotals {
        let climbMeters: Double
        let descentMeters: Double

        init(route: [RouteCoordinate]) {
            var climb = 0.0
            var descent = 0.0
            var previous: Double?
            for elevation in route.compactMap(\.elevation) where elevation.isFinite {
                defer { previous = elevation }
                guard let last = previous else { continue }
                let change = elevation - last
                if change > 0 { climb += change } else { descent -= change }
            }
            climbMeters = climb
            descentMeters = descent
        }
    }
}
