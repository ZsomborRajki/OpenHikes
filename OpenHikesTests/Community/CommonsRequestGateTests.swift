//
//  CommonsRequestGateTests.swift
//  OpenHikesTests
//
//  One Commons Action API request at a time, from the whole app: a request
//  waits for the one in flight, in the order they came; a failure lets the
//  next one through; and two different Commons callers built on one gate
//  wait for each other. See ``CommonsRequestGate``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Commons request gate", .timeLimit(.minutes(1)))
struct CommonsRequestGateTests {
    /// A request held mid-flight until ``release()``.
    nonisolated private final class Hold: Sendable {
        private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)

        var isHolding: Bool { held.withLock { $0 != nil } }

        func wait() async {
            await withCheckedContinuation { continuation in
                held.withLock { $0 = continuation }
            }
        }

        func release() {
            held.withLock { continuation in
                continuation?.resume()
                continuation = nil
            }
        }
    }

    /// What happened, in the order it did.
    nonisolated private final class Events: Sendable {
        private let list = Mutex<[String]>([])

        var all: [String] { list.withLock { $0 } }

        func note(_ event: String) { list.withLock { $0.append(event) } }
    }

    private struct Refused: Error {}

    /// Waits until `count` requests wait at `gate` — an actor's contents need
    /// an `await`, which a settle's condition cannot make, so this is the
    /// loop `settlePollTick()` is shared for.
    private static func waitUntil(
        _ gate: CommonsRequestGate,
        holds count: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.waitingCount < count {
            guard ContinuousClock.now < deadline, await settlePollTick() else {
                Issue.record("Timed out waiting for \(count) requests at the gate", sourceLocation: sourceLocation)
                return
            }
        }
    }

    @Test("a request waits for the one in flight, and they go in the order they came")
    func requestsGoOneAtATime() async throws {
        let gate = CommonsRequestGate()
        let hold = Hold()
        let events = Events()

        async let first: Void = gate.run {
            events.note("first starts")
            await hold.wait()
            events.note("first ends")
        }
        await settleDelegateHop(until: "the first request is out") { hold.isHolding }
        async let second: Void = gate.run { events.note("second") }
        await Self.waitUntil(gate, holds: 1)
        async let third: Void = gate.run { events.note("third") }
        await Self.waitUntil(gate, holds: 2)
        hold.release()
        _ = try await (first, second, third)

        #expect(events.all == ["first starts", "first ends", "second", "third"])
    }

    @Test("a request that fails lets the next one through")
    func failureLetsTheNextThrough() async throws {
        let gate = CommonsRequestGate()

        await #expect(throws: Refused.self) {
            try await gate.run { throw Refused() }
        }
        #expect(try await gate.run { "answered" } == "answered")
    }

    @Test("a saved copy downloaded again and an area's photographs wait for each other")
    func callersShareOneGate() async throws {
        let gate = CommonsRequestGate()
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport, gate: gate)
        let searches = Events()
        let source = WikimediaCommonsSource(
            transport: { request in
                searches.note(request.url?.absoluteString ?? "")
                return (Data(#"{"batchcomplete":true,"query":{"geosearch":[]}}"#.utf8), 200)
            },
            pause: { _ in /* never busy */ },
            gate: gate
        )
        let area = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0),
            radiusMeters: 1500
        )
        let copy = try #require(CommonsCopy(CommonsRefetchStub.copy(of: "Lac_glacier.jpg")))

        async let restored = refetch.picture(of: copy)
        await settleDelegateHop(until: "the refetch's question is out") { commons.isHoldingQuestion }
        async let found = source.photos(in: area, avoiding: [], downloadingInto: FileManager.default.temporaryDirectory)
        await Self.waitUntil(gate, holds: 1)
        #expect(searches.all.isEmpty, "the area's search waits for the question out before it")
        commons.answerHeldQuestion()

        #expect(await restored == .picture(CommonsRefetchStub.thumbnail))
        #expect(try await found.isEmpty)
        #expect(searches.all.count == 1)
    }
}
