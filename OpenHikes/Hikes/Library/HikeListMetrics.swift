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
//  So the first time a hiker asks for an elevation order, this measures the
//  routes in its own context, off the main actor. It publishes the resulting
//  figures through the main context, where the sidecar's other writers live.
//  A second writing context cannot see a first tile claim still pending there,
//  and would insert a second sidecar whose empty claims hide the real ones.
//  Afterwards the sort reads two `Double`s.
//
//  It runs against a background context rather than the main one for the reason
//  every other sweep here does: it may touch every hike in the library, and a
//  library is as long as a hiker's walking life.
//

import Foundation
import OpenHikesData
import OpenHikesShared
import os
import SwiftData

nonisolated enum HikeListMetrics {
    private static let logger = Logger(subsystem: "OpenHikes", category: "HikeListMetrics")

    struct ElevationMeasurement: Sendable {
        let hikeID: UUID
        let climbMeters: Double
        let descentMeters: Double
    }

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
    @MainActor
    @discardableResult static func fillElevation(
        for hikeIDs: [UUID],
        in container: ModelContainer
    ) async -> Bool {
        let measurements = await measureElevation(for: hikeIDs, in: container)
        return cacheElevation(measurements, in: container)
    }

    /// Reads and walks routes away from the UI, without creating or writing
    /// any sidecar. Only the figures travel back: publication must not read a
    /// route on the main actor.
    @concurrent
    static func measureElevation(
        for hikeIDs: [UUID],
        in container: ModelContainer
    ) async -> [ElevationMeasurement] {
        guard !hikeIDs.isEmpty else { return [] }
        let context = ModelContext(container)
        var measurements: [ElevationMeasurement] = []
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
            measurements.append(ElevationMeasurement(
                hikeID: hikeID,
                climbMeters: totals.gainMeters,
                descentMeters: totals.lossMeters
            ))
        }
        return measurements
    }

    /// The one publication boundary, on the same context as pending tile
    /// claims and the rest of the UI's local state.
    ///
    /// It reads no route. Comparing each measured line with this context's
    /// copy would decode the library on the main actor, and a decoded route
    /// stays resident in this context afterwards. So an edit that lands while
    /// the routes are being measured can still publish figures for the line
    /// before it, as the sweep always could.
    @MainActor
    @discardableResult static func cacheElevation(
        _ measurements: [ElevationMeasurement],
        in container: ModelContainer,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        let context = container.mainContext
        var changes: [CacheChange] = []
        for measurement in measurements {
            guard let hike = hike(measurement.hikeID, in: context), !hike.isDeleted else { continue }
            do {
                let existing = try HikeLocalState.fetchExisting(for: hike.id, in: context)
                let state = existing ?? HikeLocalState(hikeID: hike.id)
                if existing == nil { context.insert(state) }
                changes.append(CacheChange(state: state, inserted: existing == nil))
                state.climbMeters = measurement.climbMeters
                state.descentMeters = measurement.descentMeters
            } catch {
                Self.logger.error("Hike elevation cache lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !changes.isEmpty else { return false }
        do {
            try save(context)
        } catch {
            // This context also owns user edits. Undo only this publication;
            // rolling the context back would discard unrelated pending work.
            for change in changes.reversed() { change.undo(in: context) }
            Self.logger.error(
                "Hike elevation totals could not be cached: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        return true
    }

    @MainActor
    private struct CacheChange {
        let state: HikeLocalState
        let inserted: Bool
        let climbMeters: Double?
        let descentMeters: Double?

        init(state: HikeLocalState, inserted: Bool) {
            self.state = state
            self.inserted = inserted
            climbMeters = state.climbMeters
            descentMeters = state.descentMeters
        }

        func undo(in context: ModelContext) {
            if inserted {
                context.delete(state)
            } else {
                state.climbMeters = climbMeters
                state.descentMeters = descentMeters
            }
        }
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
    /// there too, so one `nan` cannot poison a total, and a pause ends the
    /// run — the hiker may have been carried a thousand metres up between the
    /// two points either side of it, and that is not a climb.
    private static func elevationTotals(of route: [RouteCoordinate]) -> ElevationAccumulator {
        var accumulator = ElevationAccumulator()
        for coordinate in route { accumulator.record(coordinate) }
        return accumulator
    }
}
