//
//  AsyncOnceTests.swift
//  OpenHikesTests
//
//  The window this type exists to close: callers that arrive while the first
//  build is still suspended. `CoreLocationTrailRegionMonitor` opened a second
//  `CLMonitor` through it and the app died on launch, so what is asserted here
//  is the build *count*, not just that everyone ends up with a value.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Async once")
struct AsyncOnceTests {
    /// A build that parks until the test lets it finish, and counts how many
    /// times it was entered.
    private actor Builder {
        private(set) var builds = 0
        private var arrived = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        /// Called by the value's build closure.
        func build() async -> Int {
            builds += 1
            await gate()
            return builds
        }

        /// Called by each caller before it asks for the value, so the test can
        /// hold the gate shut until every one of them is on its way in.
        func arrive() {
            arrived += 1
        }

        var arrivedCount: Int { arrived }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }

        private func gate() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    @Test("callers arriving during the first build share it")
    func sharesTheBuildInFlight() async {
        let builder = Builder()
        let once = AsyncOnce { await builder.build() }

        let values = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await builder.arrive()
                    return await once.value
                }
            }

            // The gate stays shut until every caller has announced itself, so
            // the build cannot finish before they are all on their way in.
            // There is still a gap between announcing and reaching the actor,
            // which is why the callers are many rather than two — and a caller
            // that loses that gap arrives after the build instead, which can
            // only make this test pass when it should fail, never the reverse.
            // Run against the check-then-fill version this replaced, all 32
            // get inside the window and 32 builds run, so eight is enough.
            while await builder.arrivedCount < 32 {
                await Task.yield()
            }
            for _ in 0..<8 { await Task.yield() }
            await builder.open()

            var collected: [Int] = []
            for await value in group { collected.append(value) }
            return collected
        }

        #expect(await builder.builds == 1)
        #expect(values.count == 32)
        #expect(values.allSatisfy { $0 == 1 })
    }

    @Test("a caller after the build is finished gets the same value back")
    func reusesTheFinishedBuild() async {
        let builder = Builder()
        await builder.open()
        let once = AsyncOnce { await builder.build() }

        let first = await once.value
        let second = await once.value
        let third = await once.value

        #expect(await builder.builds == 1)
        #expect(first == 1)
        #expect(second == 1)
        #expect(third == 1)
    }

    @Test("a cancelled caller does not cancel the build for the others")
    func survivesACancelledCaller() async {
        let builder = Builder()
        let once = AsyncOnce { await builder.build() }

        let cancelled = Task { await once.value }
        while await builder.builds < 1 {
            await Task.yield()
        }
        cancelled.cancel()

        await builder.open()
        #expect(await once.value == 1)
        #expect(await builder.builds == 1)
    }
}
