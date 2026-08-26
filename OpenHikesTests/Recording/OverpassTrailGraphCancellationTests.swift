//
//  OverpassTrailGraphCancellationTests.swift
//  OpenHikesTests
//
//  What happens to a shared Overpass download when one of the callers waiting
//  on it gives up. Split from `OverpassTrailGraphProviderTests.swift` so
//  neither suite outgrows the type-body limit.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// A transport that holds every request open until it is explicitly released,
/// and counts how many were abandoned by cancellation on the way.
///
/// It waits on a continuation rather than on a clock. An earlier version polled
/// with `Task.sleep` and gave up after a fixed number of polls by *returning
/// the payload*, which meant a loaded machine — a full-bundle run with suites
/// in parallel — could finish the download before the test cancelled it, and
/// the cancellation assertions would fail for reasons that had nothing to do
/// with cancellation. A test gate must never silently succeed. With no timer at
/// all, `completedCount` can only move when `release()` is called, whatever the
/// machine is doing; the `.timeLimit` on each test is what bounds a genuinely
/// broken cancellation path.
private actor GatedOverpassTransport {
    static let successStatusCode = 200

    private(set) var startedCount = 0
    private(set) var cancelledCount = 0
    private(set) var completedCount = 0
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeSuspending: Set<UUID> = []
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    /// Lets every in-flight request, and every later one, complete.
    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    func respond() async throws -> OverpassHTTPResponse {
        startedCount += 1
        do {
            try await waitForRelease()
        } catch {
            cancelledCount += 1
            throw error
        }
        completedCount += 1
        return OverpassHTTPResponse(
            data: payload,
            statusCode: Self.successStatusCode,
            headers: [:]
        )
    }

    private func waitForRelease() async throws {
        guard !isReleased else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else if cancelledBeforeSuspending.remove(id) != nil
                    || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// `onCancel` is nonisolated, so it can land here before `waitForRelease`
    /// has stored its continuation. Recording the id covers that ordering:
    /// the continuation body then throws instead of suspending forever.
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            cancelledBeforeSuspending.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
    }
}

@Suite("Overpass trail graph cancellation")
struct OverpassTrailGraphCancellationTests {
    private static let pollInterval = Duration.milliseconds(5)
    private static let waitBudget = Duration.seconds(10)

    @Test(
        "cancelling the last waiter stops the download and caches nothing",
        .timeLimit(.minutes(1))
    )
    func cancellationStopsTheDownload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trail-graph-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = GatedOverpassTransport(
            payload: Data(OverpassGraphFixture.alpineRoute.utf8)
        )
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            transport: { _ in try await transport.respond() }
        )
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        let region = try #require(provider.region(containing: coordinate))

        let prefetch = Task { try await provider.prefetch(around: coordinate) }
        try await waitFor { await transport.startedCount == 1 }
        try await waitFor { await provider.waiterCount(for: region) == 1 }

        prefetch.cancel()
        let result = await prefetch.result
        try await waitFor { await transport.cancelledCount == 1 }

        #expect(throws: (any Error).self) { try result.get() }
        #expect(await transport.completedCount == 0)
        #expect(await provider.waiterCount(for: region) == 0)
        // The write and the cache trim behind it are what used to run after
        // the walker stopped recording; nothing reached the disk at all.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(await provider.hasCompleteCachedGraph(covering: [coordinate]) == false)
    }

    @Test(
        "one caller giving up leaves the other's shared download running",
        .timeLimit(.minutes(1))
    )
    func cancellationIsReferenceCounted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trail-graph-shared-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = GatedOverpassTransport(
            payload: Data(OverpassGraphFixture.alpineRoute.utf8)
        )
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            transport: { _ in try await transport.respond() }
        )
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        let region = try #require(provider.region(containing: coordinate))

        let abandoned = Task { try await provider.prefetch(around: coordinate) }
        let kept = Task { try await provider.prefetch(around: coordinate) }
        try await waitFor { await provider.waiterCount(for: region) == 2 }

        abandoned.cancel()
        try await waitFor { await provider.waiterCount(for: region) == 1 }
        await transport.release()
        try await kept.value

        #expect(await transport.startedCount == 1)
        #expect(await transport.cancelledCount == 0)
        #expect(await transport.completedCount == 1)
        let graph = try await provider.cachedGraph(covering: [coordinate])
        #expect(graph?.edges.count == 1)
    }

    /// Polls `condition` against a wall-clock deadline rather than for a fixed
    /// number of iterations, for the reason `SettleSupport.swift` gives: a poll
    /// count buys an amount of progress that depends on machine load, so under
    /// a full-bundle run it expires early and reports a timeout as a fake
    /// assertion failure.
    private func waitFor(
        _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + Self.waitBudget
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: Self.pollInterval)
        }
        Issue.record("Timed out waiting for a condition.", sourceLocation: sourceLocation)
    }
}
