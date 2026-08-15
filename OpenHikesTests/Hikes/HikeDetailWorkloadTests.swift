//
//  HikeDetailWorkloadTests.swift
//  OpenHikesTests
//
//  Covers the route-sized work performed while opening a hike.
//

import Foundation
@testable import OpenHikes
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

    /// The profile and the statistics used to be built by two independent
    /// walks of the route, each computing its own distance between every pair
    /// of consecutive points. The profile now hands each segment it measures
    /// to the statistics builder, so a hike is walked once — and this is what
    /// says so: one callback per point, no more.
    @Test("the profile walk visits each point exactly once")
    func profileWalkIsASinglePass() throws {
        let route = longRoute(pointCount: 1200)
        var visited: [Double] = []
        let profile = try RouteProfile.cancellable(route: route) { _, segmentMeters in
            visited.append(segmentMeters)
        }

        #expect(visited.count == route.count)
        #expect(visited.first == 0, "the first point has no predecessor to measure from")
        // Each reported segment is the step in the profile's own cumulative
        // index, which is the whole point of sharing it.
        for index in 1..<route.count {
            let step = profile.distances[index] - profile.distances[index - 1]
            #expect(abs(visited[index] - step) < 1e-9)
        }
    }

    /// Sharing the distances must not change a single number. The statistics
    /// built through the shared walk are compared against the ones built by a
    /// walk that measures its own segments, on a route carrying the awkward
    /// cases the stats have to decline: a point with no elevation, and a point
    /// with no timestamp — which also costs its successor a speed.
    @Test("shared-walk statistics match a standalone walk")
    func sharedWalkMatchesStandaloneWalk() async throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.860, elevation: 600, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.861, elevation: 640, timestamp: at(10)),
            RouteCoordinate(latitude: 47.632, longitude: 12.862, elevation: nil, timestamp: at(20)),
            RouteCoordinate(latitude: 47.633, longitude: 12.863, elevation: 610, timestamp: nil),
            // Its predecessor carries no timestamp, so this segment has no
            // elapsed time to divide by and contributes no speed.
            RouteCoordinate(latitude: 47.634, longitude: 12.864, elevation: 660, timestamp: at(20)),
            RouteCoordinate(latitude: 47.640, longitude: 12.870, elevation: 700, timestamp: at(320)),
        ]
        let distanceMeters = 1234.5

        let standalone = HikeRouteStatistics(
            distanceMeters: distanceMeters,
            route: route
        )
        let prepared = try await HikeDetailPreparation.prepare(
            route: route,
            distanceMeters: distanceMeters
        )

        let expected = [
            "Duration": standalone.duration.map(HikeFormat.duration),
            "Elevation Gain": standalone.elevationGain.map(HikeFormat.length),
            "Elevation Loss": standalone.elevationLoss.map(HikeFormat.length),
            "Max Elevation": standalone.maxElevation.map(HikeFormat.length),
            "Min Elevation": standalone.minElevation.map(HikeFormat.length),
            "Avg Speed": standalone.averageSpeed.map(HikeFormat.speed),
            "Max Speed": standalone.maxSpeed.map(HikeFormat.speed),
        ]
        for (label, value) in expected {
            let stat = prepared.stats.first { stat in stat.label == label }
            #expect(
                stat?.value == value,
                "\(label) differs between the shared walk and a standalone one"
            )
        }

        #expect(
            standalone.maxSpeed != nil,
            "the fixture has a fastest segment, so the comparison above has to have something to compare"
        )
        #expect(prepared.profile.coordinates.count == route.count)
    }

    /// Cancellation still belongs to the walk, and the walk is now the
    /// profile's. A hike closed mid-preparation must produce nothing at all
    /// rather than statistics for the prefix that happened to be visited.
    @Test("cancelling preparation throws instead of returning a partial hike")
    func cancellingPreparationThrows() async {
        let route = longRoute(pointCount: 400_000)
        let preparation = Task {
            try await HikeDetailPreparation.prepare(
                route: route,
                distanceMeters: 500_000
            )
        }

        // Cancelled without suspending first. The task body inherits this
        // test's main-actor context, so it cannot begin until the test yields
        // — and a `Task.yield()` here handed a loaded CI runner long enough to
        // walk all 400,000 points before `cancel()` landed, which failed the
        // test for doing its job too quickly.
        preparation.cancel()

        do {
            _ = try await preparation.value
            Issue.record("The cancelled preparation ran to completion.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
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

        // Cancelled before the first suspension, for the reason above.
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
