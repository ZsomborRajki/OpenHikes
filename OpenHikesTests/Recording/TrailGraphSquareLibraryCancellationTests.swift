//
//  TrailGraphSquareLibraryCancellationTests.swift
//  OpenHikesTests
//
//  What happens to the request for a square when the regions waiting on it
//  give up: the last one to leave ends it, and one leaving while another
//  still waits does not. The square's half of
//  `OverpassTrailGraphCancellationTests.swift`, whose gate this one copies:
//  a request held open on a continuation until the case lets it go, never on
//  a clock, so a loaded machine cannot finish it first.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Holds every request open until ``release()``, and counts the ones
/// cancelled on the way.
private actor SquareRequestGate {
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0
    private(set) var completedCount = 0
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeSuspending: Set<UUID> = []

    /// Lets every request out, and every later one through.
    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    func pass() async throws {
        startedCount += 1
        do {
            try await waitForRelease()
        } catch {
            cancelledCount += 1
            throw error
        }
        completedCount += 1
    }

    private func waitForRelease() async throws {
        guard !isReleased else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else if cancelledBeforeSuspending.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// For the ordering `GatedOverpassTransport.cancelWaiter(_:)` covers: a
    /// cancellation that lands before the continuation is stored.
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            cancelledBeforeSuspending.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
    }
}

/// A database holding one square, whose every request waits at the gate.
nonisolated private final class GatedTrailCellDatabase: TrailCellFetching, Sendable {
    let gate = SquareRequestGate()
    private let name: String
    private let cell: TrailCellFetch.Cell

    init(holding cell: TrailCellFetch.Cell, as name: String) {
        self.cell = cell
        self.name = name
    }

    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch {
        try await gate.pass()
        var cells: [String: TrailCellFetch.Cell] = [:]
        for asked in names {
            cells[asked] = asked == name ? cell : .absent
        }
        return TrailCellFetch(manifest: .complete, cells: cells)
    }
}

@Suite("Trail graph square library cancellation")
struct TrailGraphSquareLibraryCancellationTests {
    private static let pollInterval = Duration.milliseconds(5)
    private static let waitBudget = Duration.seconds(10)

    /// Two regions of the square `TrailGraphSquareLibraryTests.squareName`.
    private static let region = TrailGraphSquareLibraryTests.region
    private static let nextRegion = TrailGraphRegion(zoom: 12, x: 2193, y: 1430)

    private static func makeDatabase() -> GatedTrailCellDatabase {
        GatedTrailCellDatabase(
            holding: TrailGraphSquareLibraryTests.found([TrailGraphSquareLibraryTests.localPath]),
            as: TrailGraphSquareLibraryTests.squareName
        )
    }

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("graph-square-cancel-\(UUID().uuidString)")
    }

    @Test("the last region giving up on a square ends its request, and keeps nothing", .timeLimit(.minutes(1)))
    func theLastRegionEndsTheRequest() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = Self.makeDatabase()
        let library = TrailGraphSquareLibrary(database: database, directory: directory)
        let name = TrailGraphSquareLibraryTests.squareName

        let asking = Task { await library.graph(for: Self.region) }
        try await waitFor("the request") { await database.gate.startedCount == 1 }
        try await waitFor("the region to wait") { await library.waiterCount(forSquareNamed: name) == 1 }

        asking.cancel()
        try await waitFor("the request to hear of it") { await database.gate.cancelledCount == 1 }
        // Lets a request that did not hear of it finish, so a broken run
        // fails below rather than waiting on it for good.
        await database.gate.release()
        let answer = await asking.value

        guard case .unreachable = answer else {
            Issue.record("a region that gave up was answered: \(answer)")
            return
        }
        #expect(await database.gate.completedCount == 0)
        #expect(await library.waiterCount(forSquareNamed: name) == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing was kept")
    }

    @Test("a region giving up leaves the request running for another still waiting", .timeLimit(.minutes(1)))
    func anotherRegionKeepsTheRequest() async throws {
        let database = Self.makeDatabase()
        let library = TrailGraphSquareLibrary(database: database, directory: nil)
        let name = TrailGraphSquareLibraryTests.squareName

        let abandoned = Task { await library.graph(for: Self.region) }
        let kept = Task { await library.graph(for: Self.nextRegion) }
        try await waitFor("both regions to wait") { await library.waiterCount(forSquareNamed: name) == 2 }

        abandoned.cancel()
        try await waitFor("the one to leave") { await library.waiterCount(forSquareNamed: name) == 1 }
        await database.gate.release()
        let answer = await kept.value
        _ = await abandoned.value

        guard case .graph = answer else {
            Issue.record("the region still waiting was not answered: \(answer)")
            return
        }
        #expect(await database.gate.cancelledCount == 0)
        #expect(await database.gate.completedCount == 1)
    }

    /// What the reference count is for: Stop cancels a recording's
    /// prefetches, and the region's task cancelled under them has to reach
    /// the square's request.
    @Test("stopping a provider's prefetch ends the request for its square", .timeLimit(.minutes(1)))
    func aStoppedPrefetchEndsTheRequest() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = Self.makeDatabase()
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            squares: TrailGraphSquareLibrary(database: database, directory: nil),
            transport: { _ in
                Issue.record("a region given up on asked Overpass")
                throw URLError(.cancelled)
            }
        )
        let hut = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)

        let prefetch = Task { try await provider.prefetch(around: hut) }
        try await waitFor("the request") { await database.gate.startedCount == 1 }

        prefetch.cancel()
        try await waitFor("the request to hear of it") { await database.gate.cancelledCount == 1 }
        await database.gate.release()
        let result = await prefetch.result

        #expect(throws: (any Error).self) { try result.get() }
        #expect(await database.gate.completedCount == 0)
        #expect(await provider.hasCompleteCachedGraph(covering: [hut]) == false)
    }

    /// Polls an actor-isolated condition against a wall-clock budget, for the
    /// reason `OverpassTrailGraphCancellationTests.waitFor` gives.
    private func waitFor(
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + Self.waitBudget
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: Self.pollInterval)
        }
        Issue.record("Timed out waiting for \(description).", sourceLocation: sourceLocation)
    }
}
