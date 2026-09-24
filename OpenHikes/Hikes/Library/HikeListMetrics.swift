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
import OpenHikesData
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
    ///
    /// A hike whose route carries no heights is measured again every time an
    /// elevation order is chosen, because nothing is written for it and so it
    /// is still missing next time. That is the honest cost of not inventing a
    /// third state to remember "measured, and there was nothing there": the
    /// sweep is off the main actor, and the alternative is a zero the sort
    /// would read as a flat walk.
    @discardableResult static func fillElevation(
        for hikeIDs: [UUID],
        in container: ModelContainer
    ) -> Bool {
        guard !hikeIDs.isEmpty else { return false }
        let context = ModelContext(container)
        var wrote = false
        for hikeID in hikeIDs {
            guard let hike = hike(hikeID, in: context) else { continue }
            let totals = elevationTotals(of: hike.route)
            // A route carrying no heights, or one, is left unmeasured rather
            // than filed as flat — see ``ElevationAccumulator/hasChange``.
            // The accumulator's zero is the absence of a reading, and
            // ``HikeListSort`` is built on the distinction: a missing figure
            // sorts last, while zero is a claim that the walk was level. A
            // GPX imported without `<ele>` has not made that claim.
            guard totals.hasChange else { continue }
            guard let state = try? HikeLocalState.fetchExisting(for: hikeID, in: context)
                ?? HikeLocalState.forHike(hikeID, in: context) else { continue }
            state.climbMeters = totals.gainMeters
            state.descentMeters = totals.lossMeters
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

    /// Climb and descent over a whole route, measured the way the rest of the
    /// app measures them.
    ///
    /// ``ElevationAccumulator`` rather than a fold of its own, and the
    /// difference is not cosmetic. It counts a climb in *runs*, behind a three
    /// metre reversal deadband, because summing `max(delta, 0)` integrates
    /// sensor noise in one direction forever: a raw GPX wandering a metre or
    /// two either side of level piles up hundreds of metres of climb it never
    /// had, and the longer the route the more wrong the figure. A library
    /// sorted on that would put a flat, noisy track above a mountain day, and
    /// the cached number would disagree with the one the hike's own detail
    /// screen draws — which is the whole reason that deadband lives in the
    /// accumulator and not at a call site. Non-finite heights are skipped
    /// there too, so one `nan` cannot poison a total.
    private static func elevationTotals(of route: [RouteCoordinate]) -> ElevationAccumulator {
        var accumulator = ElevationAccumulator()
        for coordinate in route { accumulator.record(coordinate.elevation) }
        return accumulator
    }
}
