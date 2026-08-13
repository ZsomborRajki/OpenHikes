//
//  HikeDetailWorkloadTests.swift
//  OpenTrailsTests
//
//  Covers the route-sized work performed while opening a hike.
//

import Foundation
@testable import OpenTrails
import Testing

@Suite("Hike detail workload")
struct HikeDetailWorkloadTests {
    private struct ObservedPreparation: Sendable {
        let content: HikeDetailPreparedContent
        let ranOnMainThread: Bool
    }

    @Test("opening a long hike prepares its detail off the main thread")
    func longHikePreparationStaysOffTheMainThread() async throws {
        let pointCount = 18_000
        let route = longRoute(pointCount: pointCount)
        let distanceMeters = 24_000.0

        let observed = try await HikeDetailPreparation.runOffMain {
            () throws(CancellationError) -> ObservedPreparation in
            ObservedPreparation(
                content: try HikeDetailPreparation.prepare(
                    route: route,
                    distanceMeters: distanceMeters
                ),
                ranOnMainThread: Thread.isMainThread
            )
        }

        #expect(!observed.ranOnMainThread)
        #expect(observed.content.profile.coordinates.count == pointCount)
        #expect(
            observed.content.profile.samples.count
                <= RouteProfile.plottedSampleBudget
        )

        let trackPoints = try #require(
            observed.content.stats.first { stat in
                stat.label == "Track Points"
            }
        )
        #expect(trackPoints.value == pointCount.formatted())
        #expect(
            observed.content.stats.contains { stat in
                stat.label == "Elevation Gain"
            }
        )
        #expect(
            observed.content.stats.contains { stat in
                stat.label == "Max Speed"
            }
        )
    }

    private func longRoute(pointCount: Int) -> [RouteCoordinate] {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        return (0..<pointCount).map { index in
            let step = Double(index)
            return RouteCoordinate(
                latitude: 47.63 + step * 1e-5,
                longitude: 12.86 + step * 5e-6,
                elevation: 600 + step * 0.01,
                timestamp: start.addingTimeInterval(step)
            )
        }
    }
}
