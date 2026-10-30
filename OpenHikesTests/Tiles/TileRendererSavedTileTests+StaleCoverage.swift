//
//  TileRendererSavedTileTests+StaleCoverage.swift
//  OpenHikesTests
//
//  The refresh behind saved coverage the map has already drawn as it is.
//  That the copy is drawn first is the parent suite's headline. These are the
//  rules the refresh keeps once it no longer stands between the hiker and the
//  map: it asks a server no more often than the load it replaced did, and
//  never while the policy or a server's own `Retry-After` says not to; one
//  that fails backs off without taking the copy off the screen; and a copy
//  drawn twice still gets one refresh.
//
//  An extension of `TileRendererSavedTileTests` rather than a suite of its
//  own, because `StubTileProtocol`'s response script is process-wide and the
//  parent suite is `.serialized` for exactly that reason, as
//  `TileTransportTests+Deletion.swift` explains.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension TileRendererSavedTileTests {
    /// How a test has the policy refuse a refresh.
    nonisolated enum RefreshRefusal: Sendable, CustomTestStringConvertible {
        case lowDataMode
        case offline

        var conditions: TileNetworkConditions {
            switch self {
            case .lowDataMode: TileNetworkConditions(isOnline: true, isConstrained: true)
            case .offline: TileNetworkConditions(isOnline: false)
            }
        }

        var testDescription: String {
            switch self {
            case .lowDataMode: "in Low Data Mode"
            case .offline: "offline"
            }
        }
    }

    /// A server shedding load, which names how long to stay away: fifteen
    /// minutes, so a backoff floored by it outlasts any test.
    nonisolated static let throttled = StubTileProtocol.Response(
        statusCode: RetryAfterHeader.tooManyRequests,
        data: Data("slow down".utf8),
        headers: [RetryAfterHeader.name: "900"]
    )

    /// One tile of saved coverage a day past its age, on its own renderer
    /// with a gate of its own.
    private func staleTile(
        on stub: StubbedTileCache
    ) throws -> (renderer: CachingTileOverlayRenderer, path: MKTileOverlayPath, key: String) {
        let path = Self.path(0)
        let key = Self.key(for: path)
        try stub.place(in: stub.savedFile(for: key), agedByDays: Self.staleByDays)
        return (renderer(on: stub, gate: TileLoadGate()), path, key)
    }

    /// Waits until the saved copy has been drawn and the refresh behind it has
    /// come to whatever it came to. A refresh is under way from before the
    /// copy is drawn until its outcome is recorded, so the two together are
    /// only true once it has ended.
    private func settleRefresh(of path: MKTileOverlayPath, on renderer: CachingTileOverlayRenderer) async {
        await settleDelegateHop(until: "the saved copy to be drawn and its refresh to end") {
            renderer.redrawCount(at: path) >= 1 && renderer.refreshCounts.underWay == 0
        }
    }

    /// The policy refuses interactive requests offline and in Low Data Mode,
    /// and the refresh is one. It asks nobody, the copy drawn ahead of it
    /// stays on the map, and nothing is recorded against the tile: a refusal
    /// is the app's own, and the policy change that ends it asks again.
    @Test("a refresh the policy refuses asks nobody, and the saved copy stays drawn", arguments: [
        RefreshRefusal.offline, .lowDataMode,
    ])
    func refusedRefreshKeepsTheSavedCopy(refusal: RefreshRefusal) async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        stub.cache.setNetworkConditions(refusal.conditions)
        let (renderer, path, key) = try staleTile(on: stub)
        let savedAt = try Self.modificationDate(of: stub.savedFile(for: key))

        renderer.loadTileForTesting(at: path)
        await settleRefresh(of: path, on: renderer)

        #expect(StubTileProtocol.requestCount == 0, "the refresh asked nobody")
        #expect(stub.cache.memoryImage(forKey: key) != nil, "and the saved copy is still what the map draws")
        #expect(try Self.modificationDate(of: stub.savedFile(for: key)) == savedAt)
        #expect(renderer.refreshCounts.failed == 0, "nothing backs off a refusal")
        #expect(renderer.skipCounts == (failed: 0, suppressed: 0), "and nothing skips the tile")
    }

    /// A server that named its own deadline is not asked again before it,
    /// whoever's request it answered. The refresh is withheld without a
    /// request, and backs off to that deadline so it does not queue for a
    /// slot each time the copy is drawn again.
    @Test("a refresh while a Retry-After stands asks nobody, and backs off to the server's deadline")
    func standingRetryAfterWithholdsTheRefresh() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        let (renderer, path, key) = try staleTile(on: stub)
        let tileURL = try #require(URL(string: "https://tiles.example.invalid/14/8600/5800.png"))
        let rateLimit = try #require(HTTPURLResponse(
            url: tileURL,
            statusCode: RetryAfterHeader.tooManyRequests,
            httpVersion: "HTTP/1.1",
            headerFields: [RetryAfterHeader.name: "900"]
        ))
        stub.cache.recordRetryAdvice(from: rateLimit, forKey: key)
        let serverDeadline = try #require(stub.cache.retryDeadline(forKey: key))

        renderer.loadTileForTesting(at: path)
        await settleRefresh(of: path, on: renderer)

        #expect(StubTileProtocol.requestCount == 0, "the server said fifteen minutes and meant it")
        #expect(stub.cache.memoryImage(forKey: key) != nil, "and the saved copy is drawn while it waits")
        let retryAt = try #require(renderer.refreshRetryTime(at: path), "the refresh backs off")
        #expect(retryAt >= serverDeadline, "no sooner than the server asked")
        #expect(renderer.skipCounts.failed == 0, "without the tile itself being skipped")
    }

    /// The refresh's failure is a server failing, and it backs off like one
    /// — floored, for a 429, by the deadline the server named. It goes to its
    /// own log rather than the one that skips a tile outright, because the
    /// saved copy has to stay drawable while the refresh waits. And it waits
    /// at least the recheck interval, as the load that refreshed before it
    /// drew did: that one served the copy when its refresh failed, and the
    /// copy answered for the interval before anything asked again.
    @Test("a failed refresh keeps the saved copy drawn and backs off", arguments: [
        StubTileProtocol.Response.status(500), Self.throttled,
    ])
    func failedRefreshBacksOff(response: StubTileProtocol.Response) async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: response)
        let (renderer, path, key) = try staleTile(on: stub)
        let savedAt = try Self.modificationDate(of: stub.savedFile(for: key))

        let askedAt = ContinuousClock.now
        renderer.loadTileForTesting(at: path)
        await settleRefresh(of: path, on: renderer)

        #expect(StubTileProtocol.requestCount == 1, "precondition: the refresh was asked for")
        #expect(stub.cache.memoryImage(forKey: key) != nil, "the saved copy is still drawn")
        #expect(try Self.modificationDate(of: stub.savedFile(for: key)) == savedAt, "a failed refresh writes nothing")
        #expect(renderer.refreshCounts.failed == 1, "the refresh backs off")
        let retryAt = try #require(renderer.refreshRetryTime(at: path))
        let recheckAt = askedAt.advanced(by: .seconds(TileCache.staleCoverageRecheckInterval))
        #expect(retryAt >= recheckAt, "no sooner than a failed refresh was ever asked again")
        if let serverDeadline = stub.cache.retryDeadline(forKey: key) {
            #expect(retryAt >= serverDeadline, "no sooner than a server that named a deadline asked")
        }
        #expect(renderer.skipCounts.failed == 0, "and the tile itself is not skipped")
        #expect(renderer.mayAskForTile(at: path), "so the next draw that misses may still read it back")
    }

    /// And the backoff has teeth without costing the map anything. Once the
    /// copy's memory entry lapses, the next draw reads it back and draws it,
    /// and no refresh starts while the backoff stands — a refresh is under
    /// way before the redraw this waits for, so one still running would
    /// show, and one that had ended would have asked. A plain 500, because a
    /// 429 leaves a `Retry-After` in the cache that withholds the request on
    /// its own, and this backoff is the one under test. It lasts the recheck
    /// interval, so it outlasts the test however slowly the machine runs it.
    @Test("a saved copy whose refresh is backing off is drawn again without a request")
    func backedOffRefreshStillDrawsTheCopy() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .status(500))
        let (renderer, path, key) = try staleTile(on: stub)
        renderer.loadTileForTesting(at: path)
        await settleRefresh(of: path, on: renderer)
        #expect(renderer.refreshCounts.failed == 1, "precondition: the refresh failed and is backing off")

        stub.cache.memory.removeAllObjects()
        renderer.loadTileForTesting(at: path)
        await settleDelegateHop(until: "the saved copy to be drawn again") {
            renderer.redrawCount(at: path) == 2
        }

        #expect(stub.cache.memoryImage(forKey: key) != nil, "the saved copy is drawn again")
        #expect(renderer.refreshCounts.underWay == 0, "no second refresh started")
        #expect(StubTileProtocol.requestCount == 1, "and none was asked for")
    }

    /// A refresh can wait behind slow requests for longer than its copy's
    /// memory entry lasts. The draw that misses then reads the copy back,
    /// and that read joins the refresh already queued rather than queueing a
    /// second: one refresh per tile, however often its copy is drawn.
    @Test("a saved copy drawn again while its refresh waits does not ask for a second")
    func copyDrawnAgainJoinsTheQueuedRefresh() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        let slots = await fillEverySlot(of: gate, from: renderer)
        let stale = Self.path(slots)
        let key = Self.key(for: stale)
        try stub.place(in: stub.savedFile(for: key), agedByDays: Self.staleByDays)
        renderer.loadTileForTesting(at: stale)
        await settle { await gate.testState.interactiveWaiters == 1 }
        #expect(await gate.testState.interactiveWaiters == 1, "precondition: the refresh is queued")

        stub.cache.memory.removeAllObjects()
        renderer.loadTileForTesting(at: stale)
        await settleDelegateHop(until: "the saved copy to be drawn again") {
            renderer.redrawCount(at: stale) == 2
        }
        #expect(stub.cache.memoryImage(forKey: key) != nil, "drawn again while its refresh waits")
        #expect(await gate.testState.interactiveWaiters == 1, "beside the queued refresh, not behind a second")
        #expect(renderer.refreshCounts.underWay == 1)

        await drain(gate)
        await settleDelegateHop(until: "the one refresh to land") { renderer.redrawCount(at: stale) == 3 }
        #expect(StubTileProtocol.requestCount == slots + 1, "one refresh request, not two")
        #expect(Self.holdsCurrentTile(stub.cache, forKey: key))
        #expect(renderer.refreshCounts == (underWay: 0, failed: 0))
    }

    /// Drawing saved coverage ahead of its refresh still offers it to
    /// auto-save, as drawing it after the refresh did, so the auto-saved hike
    /// claims the ground it shows even when another hike saved it first.
    @Test("saved coverage drawn ahead of its refresh is still kept for the auto-saved hike")
    func staleCoverageIsOfferedToAutoSave() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        _ = await fillEverySlot(of: gate, from: renderer)

        let route = Fixture.coordinates(Fixture.ridgeRoute)
        let onTrail = MKTileOverlayPath(
            x: SlippyTileMath.tileX(route[2].longitude, z: 14),
            y: SlippyTileMath.tileY(route[2].latitude, z: 14),
            z: 14,
            contentScaleFactor: 2
        )
        let key = Self.key(for: onTrail)
        try stub.place(in: stub.savedFile(for: key), agedByDays: Self.staleByDays)
        let hikeID = UUID()
        stub.store.setActiveHike(id: hikeID, route: route, knownKeys: [])
        renderer.loadTileForTesting(at: onTrail)

        await settleDelegateHop(until: "the saved copy to be drawn") { renderer.redrawCount(at: onTrail) == 1 }
        #expect(stub.store.drainPendingKeys(for: hikeID) == [key], "claimed before its refresh has even asked")
        #expect(stub.isSaved(key))

        await drain(gate)
    }
}
