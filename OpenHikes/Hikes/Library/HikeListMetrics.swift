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
//  So the first time a hiker asks for an elevation order, this reads and
//  measures routes in its own context, off the main actor. It publishes the
//  resulting figures through the main context, where the sidecar's other
//  writers live.
//  A second writing context cannot see a first tile claim still pending there,
//  and would insert a second sidecar whose empty claims hide the real ones.
//  A route fingerprint kept beside the figures includes heights and pauses,
//  so an edit arriving from another device cannot keep its old local relief.
//  Afterwards the sort reads two `Double`s. Noticing a new line belongs to
//  the list's task, never its body: see `HikeListMetrics+Observation.swift`.
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
        let climbMeters: Double?
        let descentMeters: Double?
        let revision: String
    }

    private struct RouteInput {
        let hikeID: UUID
        let route: [RouteCoordinate]
    }

    /// Validates climb and descent against the current route for `hikeIDs`.
    ///
    /// Returns whether anything was written, so a caller knows whether a
    /// redraw is worth asking for. Silent on failure: a library that cannot be
    /// measured is a library sorted with those hikes last, which is what a
    /// missing figure already means.
    ///
    /// Matching complete caches are reused. A route with no usable change
    /// stays missing rather than being called flat; if it replaced a measured
    /// route, the old figures are cleared without touching other local state.
    @MainActor
    @discardableResult static func fillElevation(
        for hikeIDs: [UUID],
        in container: ModelContainer
    ) async -> Bool {
        let measurements = await measureElevation(for: hikeIDs, in: container)
        guard !Task.isCancelled else { return false }
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
        return hikeIDs.compactMap { hikeID in
            guard !Task.isCancelled, let hike = hike(hikeID, in: context) else { return nil }
            return measurement(for: RouteInput(hikeID: hikeID, route: hike.route), in: context)
        }
    }

    private static func measurement(for input: RouteInput, in context: ModelContext) -> ElevationMeasurement? {
        let revision = elevationRevision(of: input.route)
        let state = try? HikeLocalState.fetchExisting(for: input.hikeID, in: context)
        if state?.elevationRouteRevision == revision, state?.climbMeters != nil, state?.descentMeters != nil {
            return nil
        }
        let totals = elevationTotals(of: input.route)
        // A missing height is not a flat route. An existing obsolete figure
        // must still be cleared; an unmeasured route needs no new sidecar.
        guard totals.hasChange || state?.climbMeters != nil || state?.descentMeters != nil else { return nil }
        return ElevationMeasurement(
            hikeID: input.hikeID,
            climbMeters: totals.hasChange ? totals.gainMeters : nil,
            descentMeters: totals.hasChange ? totals.lossMeters : nil,
            revision: revision
        )
    }

    /// Stable across launches, unlike Swift's randomized `Hasher`. The
    /// presence tag distinguishes a missing height from a measured zero.
    private static func elevationRevision(of route: [RouteCoordinate]) -> String {
        var hasher = StableHasher()
        for point in route {
            hasher.combine(point.latitude)
            hasher.combine(point.longitude)
            if let height = point.elevation {
                hasher.combine("height")
                hasher.combine(height)
            } else {
                hasher.combine("missing")
            }
            hasher.combine(point.isPauseBoundary ? "pause" : "walk")
        }
        return String(hasher.value, radix: 16)
    }

    /// The one publication boundary, on the same context as pending tile
    /// claims and the rest of the UI's local state.
    ///
    /// It reads no route. Comparing each measured line with this context's
    /// copy would decode the library on the main actor, and a decoded route
    /// stays resident in this context afterwards. An edit that lands while
    /// the routes are being measured can publish figures for the line before
    /// it, but they carry that line's revision, so the next validation
    /// measures again. The list's task asks what was written or saved while
    /// it measured before it publishes, and drops those figures: see
    /// `HikeListMetrics+Observation.swift`.
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
                if let existing,
                   existing.elevationRouteRevision == measurement.revision,
                   existing.climbMeters == measurement.climbMeters,
                   existing.descentMeters == measurement.descentMeters { continue }
                let state = existing ?? HikeLocalState(hikeID: hike.id)
                if existing == nil { context.insert(state) }
                changes.append(CacheChange(state: state, inserted: existing == nil))
                state.climbMeters = measurement.climbMeters
                state.descentMeters = measurement.descentMeters
                state.elevationRouteRevision = measurement.revision
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
        let revision: String?

        init(state: HikeLocalState, inserted: Bool) {
            self.state = state
            self.inserted = inserted
            climbMeters = state.climbMeters
            descentMeters = state.descentMeters
            revision = state.elevationRouteRevision
        }

        func undo(in context: ModelContext) {
            if inserted {
                context.delete(state)
            } else {
                state.climbMeters = climbMeters
                state.descentMeters = descentMeters
                state.elevationRouteRevision = revision
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
