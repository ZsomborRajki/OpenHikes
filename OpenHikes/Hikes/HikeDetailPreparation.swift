//
//  HikeDetailPreparation.swift
//  OpenHikes
//
//  The route-sized work behind the hike detail screen: one walk of the route
//  that yields the elevation profile and every stat tile, off the main actor.
//

import Foundation

nonisolated struct HikeDetailPreparedContent: Sendable {
    let profile: RouteProfile
    let stats: [Stat]
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
        // chart. Timed so opening a long hike can be told apart from drawing
        // one that was already prepared.
        let state = RenderSignpost.beginInterval("HikeDetailPrepared")
        defer { RenderSignpost.endInterval("HikeDetailPrepared", state) }
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
        let items: [Stat?] = [
            Stat(
                "Distance",
                Measurement(value: distanceMeters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            ),
            statistics.duration.map { duration in
                Stat("Duration", HikeFormat.duration(duration))
            },
            statistics.elevationGain.map { gain in
                Stat("Elevation Gain", HikeFormat.length(gain))
            },
            statistics.elevationLoss.map { loss in
                Stat("Elevation Loss", HikeFormat.length(loss))
            },
            statistics.maxElevation.map { elevation in
                Stat("Max Elevation", HikeFormat.length(elevation))
            },
            statistics.minElevation.map { elevation in
                Stat("Min Elevation", HikeFormat.length(elevation))
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
                Stat("Inferred Path", HikeFormat.length(inferred))
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

    private static func formatted(_ date: Date) -> String {
        date.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}
