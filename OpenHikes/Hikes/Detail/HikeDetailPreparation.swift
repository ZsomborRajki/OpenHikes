//
//  HikeDetailPreparation.swift
//  OpenHikes
//
//  The route-sized work behind the hike detail screen: one walk of the route
//  that yields the elevation profile and every stat, off the main actor.
//

import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated struct HikeDetailPreparedContent: Sendable {
    let profile: RouteProfile
    let stats: [Stat]
}

/// The geometry the hike detail screen's route-derived work was built from,
/// and so what its `.task(id:)`s are keyed on.
///
/// The hike's id alone is not enough. *Edit Route* keeps the id and replaces
/// the line — see ``TrailDraftSave`` — and mirroring delivers that edit to a
/// second device while this screen can be open there. Keyed on the id, the
/// elevation profile, the statistics, the follow loop's matcher and the
/// surface lookup all stayed on the old line until the screen was closed.
///
/// The route itself rather than a digest of it. A digest would walk the whole
/// line on every body evaluation; `Array`'s `==` compares storage identity
/// first and stops at the first differing point, so at worst it costs one
/// comparison per point, only when the body is evaluated, and render
/// isolation keeps that off the per-fix path. The distance is here as well
/// because the statistics are built from it and a save sets it on its own.
nonisolated struct HikeDetailRouteKey: Equatable, Sendable {
    let hikeID: UUID
    let route: [RouteCoordinate]
    let distanceMeters: Double

    @MainActor
    init(_ hike: Hike) {
        hikeID = hike.id
        route = hike.route
        distanceMeters = hike.distanceMeters
    }
}

nonisolated enum HikeDetailPreparation {
    /// `@concurrent` rather than a detached task: this stays part of the
    /// caller's task, so `.task(id:)` tearing down the view cancels the
    /// profile build without a hand-written cancellation handler, and the
    /// route-sized work still runs on the concurrent executor.
    ///
    /// One walk, not two. The profile's cumulative index and the statistics'
    /// max speed both need the distance between consecutive points, and that
    /// trigonometry is what a long route costs; the profile hands each segment
    /// to the statistics builder as it computes it. Cancellation is the
    /// profile's, so a torn-down view never builds statistics from a partial
    /// route — the walk throws before ``HikeRouteStatistics/Builder/finish()``
    /// is reached.
    @concurrent
    static func prepare(
        route: [RouteCoordinate],
        distanceMeters: Double
    ) async throws(CancellationError) -> HikeDetailPreparedContent {
        assertOffMainThread(
            "Hike detail route preparation must stay off the main thread"
        )
        // The single route-sized walk behind every number and the elevation
        // chart.
        var statistics = HikeRouteStatistics.Builder(distanceMeters: distanceMeters)
        let profile = try RouteProfile.cancellable(route: route) { point, segmentMeters in
            statistics.consume(point, segmentMeters: segmentMeters)
        }
        return HikeDetailPreparedContent(
            profile: profile,
            stats: makeStats(
                distanceMeters: distanceMeters,
                statistics: statistics.finish()
            )
        )
    }

    private static func makeStats(
        distanceMeters: Double,
        statistics: HikeRouteStatistics
    ) -> [Stat] {
        // The first three are the place card's strip — the same three, in the
        // same order, as the recording screen's — and the rest its list.
        let items: [Stat?] = [
            Stat(
                "Distance",
                Measurement(value: distanceMeters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road)),
                headline: true
            ),
            statistics.duration.map { duration in
                Stat("Duration", HikeFormat.duration(duration), headline: true)
            } ?? estimatedTime(distanceMeters: distanceMeters, statistics: statistics),
            statistics.elevationGain.map { gain in
                Stat("Elevation Gain", HikeFormat.elevation(gain), headline: true)
            },
            statistics.elevationLoss.map { loss in
                Stat("Elevation Loss", HikeFormat.elevation(loss))
            },
            statistics.maxElevation.map { elevation in
                Stat("Max Elevation", HikeFormat.elevation(elevation))
            },
            statistics.minElevation.map { elevation in
                Stat("Min Elevation", HikeFormat.elevation(elevation))
            },
            // Two clocks over one distance, named for the clock rather than
            // left as a bare "Avg Speed" that has always been the elapsed one
            // without saying so. Spelled out on both rows: relabelling only
            // the new one would leave the older row still answering a question
            // it was never measuring.
            statistics.averageSpeed.map { speed in
                Stat("Overall Avg Speed", HikeFormat.speed(speed))
            },
            statistics.movingAverageSpeed.map { speed in
                Stat("Moving Avg Speed", HikeFormat.speed(speed))
            },
            statistics.maxSpeed.map { speed in
                Stat("Max Speed", HikeFormat.speed(speed))
            },
            Stat(
                "Track Points",
                statistics.pointCount.formatted()
            ),
            statistics.inferredDistance.map { inferred in
                // Named for what it is rather than hidden in the distance:
                // the total already includes it, so the honest thing is to say
                // how much of that total the app worked out rather than saw.
                //
                // A distance, and formatted like the *Distance* row above it
                // rather than by the elevation formatter — which is what it
                // used to go through, so a reader looking at "3.1 mi" was told
                // that 412 m of it was inferred.
                Stat(
                    "Inferred Path",
                    inferred.formatted(.measurement(width: .abbreviated, usage: .road))
                )
            },
            statistics.startDate.map { date in
                Stat("Start", formatted(date))
            },
            statistics.endDate.map { date in
                Stat("End", formatted(date))
            },
        ]
        return items.compactMap(\.self)
    }

    /// How long a route with no clock takes to walk, in the slot a clock's
    /// duration would fill — see ``WalkingTimeEstimate``.
    ///
    /// Only where there is no clock: a measured duration always wins, and the
    /// two are never drawn together. Labelled as an estimate, and written the
    /// way the trail maker writes a planned time, so it never passes for a
    /// measurement.
    ///
    /// Only where the route has heights, too. Without them the rule has
    /// nothing to count but the flat, and a flat figure on an alpine route is
    /// out by the factor of two this stat exists to correct — no figure is the
    /// honest answer there, as it is for the climb itself.
    private static func estimatedTime(
        distanceMeters: Double,
        statistics: HikeRouteStatistics
    ) -> Stat? {
        guard distanceMeters > 0,
              let gain = statistics.elevationGain,
              let loss = statistics.elevationLoss else { return nil }
        let seconds = WalkingTimeEstimate.seconds(
            distanceMeters: distanceMeters,
            ascentMeters: gain.converted(to: .meters).value,
            descentMeters: loss.converted(to: .meters).value
        )
        return Stat("Estimated Time", HikeFormat.travelTime(seconds), headline: true)
    }

    private static func formatted(_ date: Date) -> String {
        date.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}
