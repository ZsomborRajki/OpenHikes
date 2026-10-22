//
//  PauseClimbTests.swift
//  OpenHikesTests
//
//  The rise across a pause is not ground the hiker walked.
//
//  A recording that was paused and resumed somewhere else — a lift, a car, a
//  night in a hut — resumes at a different height, and the first fix after it
//  is not a step up from the last one before it. The watch has always ended its
//  elevation run there. The phone counts climb in five places — the live
//  readout, the saved hike's statistics, the profile behind the chart, the
//  library's cached figure and the trail sent to the watch — and each of them
//  fed `ElevationAccumulator` straight across the pause (#910). These pin all
//  five against the same walk, and the phone against the watch, since agreeing
//  is the claim.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

@Suite("Climb across a pause on the phone")
struct PauseClimbTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A kilometre of pause between the two halves, however it is climbed.
    private static let lift: [Double?] = [100, 110, 1110, 1120]

    /// One fix per height, a minute and about a hundred metres apart. Each
    /// index in `resumed` is the first fix after an hour's pause, flagged
    /// `.resumed` the way the recorder writes it.
    private func walk(
        _ heights: [Double?],
        resumingAt resumed: Set<Int> = []
    ) -> [RecordingPoint] {
        var seconds: TimeInterval = 0
        return heights.indices.map { index in
            if index > 0 { seconds += resumed.contains(index) ? 3660 : 60 }
            return RecordingPoint(
                latitude: 47.63 + Double(index) * 0.001,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(seconds),
                horizontalAccuracy: 8,
                elevation: heights[index],
                flags: resumed.contains(index) ? .resumed : []
            )
        }
    }

    private func saved(
        _ heights: [Double?],
        resumingAt resumed: Set<Int>
    ) throws -> PreparedRecording {
        try RecordingPreparation.prepare(
            points: walk(heights, resumingAt: resumed),
            startedAt: start
        )
    }

    private func liveAccumulator(
        _ heights: [Double?],
        resumingAt resumed: Set<Int>
    ) -> RecordingDistanceAccumulator {
        var accumulator = RecordingDistanceAccumulator()
        for point in walk(heights, resumingAt: resumed) {
            accumulator.append(point)
        }
        return accumulator
    }

    @Test("the live climb ends its run at a pause")
    func liveClimbEndsAtAPause() throws {
        let accumulator = liveAccumulator(Self.lift, resumingAt: [2])

        #expect(try #require(accumulator.elevationGainMeters) == 20)
        #expect(try #require(accumulator.elevationLossMeters) == 0)
    }

    @Test("the live descent ends its run at a pause too")
    func liveDescentEndsAtAPause() throws {
        let accumulator = liveAccumulator([1110, 1100, 100, 90], resumingAt: [2])

        #expect(try #require(accumulator.elevationLossMeters) == 20)
        #expect(try #require(accumulator.elevationGainMeters) == 0)
    }

    @Test("a fix with no height beside the pause does not bridge it")
    func aMissingHeightDoesNotBridgeAPause() throws {
        let heights: [Double?] = [100, 110, nil, 1120, 1130]
        let atTheResume = liveAccumulator(heights, resumingAt: [2])
        let beforeTheResume = liveAccumulator(heights, resumingAt: [3])

        #expect(try #require(atTheResume.elevationGainMeters) == 20)
        #expect(try #require(beforeTheResume.elevationGainMeters) == 20)
    }

    @Test("a saved recording's statistics end the run at the pause it saved")
    func savedStatisticsEndAtAPause() throws {
        let prepared = try saved(Self.lift, resumingAt: [2])
        let statistics = HikeRouteStatistics(
            distanceMeters: prepared.distanceMeters,
            route: prepared.route
        )

        #expect(statistics.elevationGain?.value == 20)
        #expect(statistics.elevationLoss?.value == 0)
    }

    @Test("the profile behind the chart ends the run at the pause")
    func profileEndsAtAPause() throws {
        let prepared = try saved(Self.lift, resumingAt: [2])
        let profile = RouteProfile(route: prepared.route)

        #expect(profile.pauseDistances.count == 1)
        #expect(profile.elevation.gainMeters == 20)
        #expect(profile.elevation.lossMeters == 0)
    }

    @Test("the phone counts a paused walk's climb the way the watch does")
    func phoneAndWatchAgree() {
        let walks: [(heights: [Double?], resumed: Set<Int>)] = [
            (Self.lift, [2]),
            ([1110, 1100, 100, 90], [2]),
            ([100, 110, nil, 1120, 1130], [2]),
            ([100, 110, nil, 1120, 1130], [3]),
        ]

        for (heights, resumed) in walks {
            let phone = liveAccumulator(heights, resumingAt: resumed)
            var watch = WatchWalkAccumulator()
            for point in walk(heights, resumingAt: resumed) {
                if point.flags.contains(.resumed) { watch.pause() }
                let kept = watch.accept(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    timestamp: point.timestamp,
                    horizontalAccuracy: point.horizontalAccuracy,
                    elevationMeters: point.elevation
                )
                #expect(kept)
            }

            #expect(
                phone.elevationGainMeters == watch.elevationGainMeters,
                "gain over \(heights) resuming at \(resumed)"
            )
            #expect(
                phone.elevationLossMeters == watch.elevationLossMeters,
                "loss over \(heights) resuming at \(resumed)"
            )
        }
    }

    @Test("the library's cached climb ends its run at the pause")
    func libraryFigureEndsAtAPause() throws {
        let prepared = try saved(Self.lift, resumingAt: [2])
        let container = try Fixture.modelContainer()
        let context = ModelContext(container)
        let hike = Fixture.hike(in: context, title: "Lift", route: prepared.route)
        try context.save()

        _ = HikeListMetrics.fillElevation(for: [hike.id], in: container)

        let cached = try #require(refetchedHike(hike.id, in: container))
        #expect(cached.climbMeters == 20)
        #expect(cached.descentMeters == 0)
    }

    @Test("the trail sent to the watch ends its climb's run at the pause")
    func watchTrailEndsAtAPause() async throws {
        let prepared = try saved(Self.lift, resumingAt: [2])
        let hike = Hike(
            title: "Lift",
            distanceMeters: prepared.distanceMeters,
            route: prepared.route
        )

        let package = try #require(
            await WatchTrailPackaging.package(from: HikeRouteInput(hike: hike))
        )

        #expect(package.elevationGainMeters == 20)
        #expect(package.elevationLossMeters == 0)
    }

    private func refetchedHike(_ hikeID: UUID, in container: ModelContainer) -> Hike? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
