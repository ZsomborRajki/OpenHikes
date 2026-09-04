//
//  BackgroundTrailTracker+Snapshot.swift
//  OpenHikes
//
//  Preparing what the widget stores, kept out of the tracker's own body: none
//  of it touches the tracker's state, and all of it runs off the main thread.
//
//  Split out for the reason `+SnapshotWriter` was — the tracker's file had
//  reached its length limit — and at the same cost: `BackgroundMatch`,
//  `match(hikeID:in:to:near:heading:timestamp:)` and
//  `buildSnapshotOffMain(from:liveFix:)` are internal rather than private so
//  the fix handler next door can still reach them. Nesting is kept, so they
//  are still only reachable through the tracker.
//

import CoreLocation
import Foundation
import OpenHikesShared
import SwiftData

/// Preparing what the widget stores, kept out of the tracker's own body:
/// none of it touches the tracker's state, and all of it runs off the main
/// thread.
extension BackgroundTrailTracker {
    // Internal rather than private because `SnapshotWriter` names it, and
    // that actor now lives in its own file — the same trade
    // `TrailBasemapRenderer.RenderInput` makes for `Render`.
    nonisolated struct SnapshotInput: Sendable {
        let hikeID: UUID
        let title: String
        let tintHex: String
        let totalDistanceMeters: Double
        let route: [RouteCoordinate]

        init(hike: Hike) {
            hikeID = hike.id
            title = hike.title
            tintHex = hike.tintHex
            totalDistanceMeters = hike.distanceMeters
            route = hike.route
        }
    }

    /// What a live-fix write actually put in the store, so the caller can
    /// decide whether the widget's basemaps need re-rendering without reading
    /// the file back to find out.
    nonisolated struct LiveFixWrite: Sendable {
        let snapshot: SharedTrailSnapshot
        let isNewTrail: Bool
    }

    /// A background fix projected onto its route.
    nonisolated struct BackgroundMatch: Sendable {
        /// The hike the fix was matched against, reduced to values off the
        /// main actor so the write path never has to reach back for it.
        let input: SnapshotInput
        /// Carried so a rebuild of the stored trail doesn't walk the route a
        /// second time to recompute what this pass already has.
        let elevation: RouteElevationSummary
        /// The published position, or `nil` when the fix did not land on the
        /// trail.
        let fix: SharedTrailSnapshot.LiveFix?
        /// Where matching should continue from next time, or `nil` to keep the
        /// existing reference.
        let matchedDistance: Double?
    }

    /// The one hop this type makes off the main actor, and the only place its
    /// off-main work is entered from.
    ///
    /// `@concurrent` rather than `Task.detached`: the work stays inside the
    /// caller's task, so cancelling that task reaches the `Task.isCancelled`
    /// guards in `buildSnapshot` directly. Detached, those guards would read
    /// the *worker's* cancellation state and could never fire — the
    /// cancellation had to be forwarded by hand through a
    /// `withTaskCancellationHandler`, and even then only landed between the
    /// stages rather than inside the route-sized work.
    ///
    /// Its own function so the guarantee has somewhere to be tested at all.
    /// What it prevents is invisible at the call site and expensive in the
    /// field: a `Task {}` started from a method on this `@MainActor` type
    /// looks exactly like `Task.detached` and runs its body on the main
    /// thread — see `CloudSyncCoordinator.offMainThread(_:)`, which exists for
    /// the same reason after that mistake shipped once.
    @concurrent
    nonisolated static func offMainThread<T: Sendable>(
        _ work: @Sendable () -> T
    ) async -> T {
        assertOffMainThread("The widget feed's route and App Group work must stay off the main thread")
        return work()
    }

    /// Reads the tracked hike and projects a background fix onto its route.
    ///
    /// The read belongs here rather than at the call site because it is the
    /// larger half: fetching a five-hour hike materialises its externally
    /// stored route before any of the arithmetic below can start, and that
    /// measured worse than the two O(route points) passes that follow it.
    /// Doing it here is safe rather than clever — `ModelContainer` is
    /// `Sendable`, and the `ModelContext` built from it is created, used and
    /// discarded inside this one call, so neither it nor the non-`Sendable`
    /// `Hike` it vends ever crosses an isolation boundary. Only the
    /// ``SnapshotInput`` of values taken from that hike leaves.
    ///
    /// Returns `nil` when the hike is gone or too short to match against.
    nonisolated static func match(
        hikeID: UUID,
        in container: ModelContainer,
        to coordinate: CLLocationCoordinate2D,
        near referenceDistance: Double?,
        heading: CLLocationDirection?,
        timestamp: Date
    ) -> BackgroundMatch? {
        assertOffMainThread("Reading a hike for the widget feed must stay off the main thread")
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        guard let hike = (try? context.fetch(descriptor))?.first, hike.pointCount > 1 else { return nil }
        let input = SnapshotInput(hike: hike)
        let profile = RouteProfile(route: input.route)
        guard let match = profile.nearestPoint(
                to: coordinate,
                near: referenceDistance,
                heading: heading
              ),
              match.offRouteMeters <= RouteProfile.followMatchThresholdMeters,
              let matched = profile.coordinate(atDistance: match.distanceAlongRoute) else {
            return BackgroundMatch(input: input, elevation: profile.elevation, fix: nil, matchedDistance: nil)
        }
        return BackgroundMatch(
            input: input,
            elevation: profile.elevation,
            fix: SharedTrailSnapshot.LiveFix(
                coordinate: .init(latitude: matched.latitude, longitude: matched.longitude),
                distanceAlongRouteMeters: match.distanceAlongRoute,
                offRouteMeters: match.offRouteMeters,
                timestamp: timestamp,
                elevationMeters: profile.sample(atDistance: match.distanceAlongRoute)?.elevation
            ),
            matchedDistance: match.distanceAlongRoute
        )
    }

    nonisolated static func buildSnapshotOffMain(
        from input: SnapshotInput,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) async -> SharedTrailSnapshot? {
        await offMainThread { buildSnapshot(from: input, liveFix: liveFix) }
    }

    nonisolated private static func buildSnapshot(
        from input: SnapshotInput,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) -> SharedTrailSnapshot? {
        guard !Task.isCancelled else { return nil }
        let profile = RouteProfile(route: input.route)
        guard !Task.isCancelled else { return nil }
        return buildSnapshot(
            from: input,
            elevation: profile.elevation,
            liveFix: liveFix
        )
    }

    /// Internal for the reason ``SnapshotInput`` is: `SnapshotWriter` rebuilds
    /// through it, from its own file.
    nonisolated static func buildSnapshot(
        from input: SnapshotInput,
        elevation: RouteElevationSummary,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) -> SharedTrailSnapshot? {
        guard !Task.isCancelled else { return nil }
        return SharedTrailSnapshot(
            hikeID: input.hikeID,
            title: input.title,
            tintHex: input.tintHex,
            totalDistanceMeters: input.totalDistanceMeters,
            polyline: decimate(input.route) { coordinate in
                SharedTrailSnapshot.CodableCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            },
            elevationLowMeters: elevation.lowMeters,
            elevationHighMeters: elevation.highMeters,
            elevationGainMeters: elevation.gainMeters,
            elevationLossMeters: elevation.lossMeters,
            liveFix: liveFix
        )
    }
}
