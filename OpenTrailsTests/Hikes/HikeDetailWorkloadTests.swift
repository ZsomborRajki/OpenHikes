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
    @Test("opening a long hike prepares its detail off the main thread")
    func longHikePreparationStaysOffTheMainThread() async throws {
        let pointCount = 18_000
        let route = longRoute(pointCount: pointCount)
        let distanceMeters = 24_000.0

        // `prepare` is `@concurrent` and asserts it is off the main thread, so
        // awaiting it from this main-actor-isolated suite is the check: a hop
        // back onto main would trap inside the call.
        let content = try await HikeDetailPreparation.prepare(
            route: route,
            distanceMeters: distanceMeters
        )

        #expect(content.profile.coordinates.count == pointCount)
        #expect(
            content.profile.samples.count
                <= RouteProfile.plottedSampleBudget
        )

        let trackPoints = try #require(
            content.stats.first { stat in
                stat.label == "Track Points"
            }
        )
        #expect(trackPoints.value == pointCount.formatted())
        #expect(
            content.stats.contains { stat in
                stat.label == "Elevation Gain"
            }
        )
        #expect(
            content.stats.contains { stat in
                stat.label == "Max Speed"
            }
        )
    }

    @Test("cancelling an offline-storage measurement cancels its worker")
    func storageMeasurementCancellationPropagates() async {
        let sandbox = TileSandbox()
        let route = longRoute(pointCount: 50_000)
        let keys = (0..<50_000).map { "missing/\($0)" }
        let measurement = Task {
            try await OfflineStorageMeasurement.measure(
                route: route,
                offlineDownloads: [],
                autoSavedTileKeys: keys,
                cache: sandbox.cache
            )
        }

        await Task.yield()
        measurement.cancel()

        do {
            _ = try await measurement.value
            Issue.record("The cancelled storage worker ran to completion.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
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
