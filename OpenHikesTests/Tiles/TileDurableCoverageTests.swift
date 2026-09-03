//
//  TileDurableCoverageTests.swift
//  OpenHikesTests
//
//  What happens to a saved map once it is more than seven days old.
//
//  It used to be deleted. `TileCache.tileExpirationInterval` was one fixed TTL
//  with no notion of tier, so the launch sweep took durable tiles along with
//  cached ones, and any lookup that beat the sweep to it deleted the file
//  before `loadTile` had reached the line that asks whether the phone is even
//  online. A walker who downloaded a map the week before a trip could open the
//  hike on the trail, out of signal, and get nothing — while the hike went on
//  showing an `Offline tiles` row for bytes that were gone.
//
//  The rule these tests pin is that age decides when to *refresh* durable
//  coverage, never when to drop it: the saved copy is drawn whenever a refresh
//  is refused or fails, and is only ever replaced by bytes that have actually
//  arrived. The browsing tier is unchanged and still expires outright —
//  `OfflineStorageAccountingTests+Reclaiming` owns that half.
//
//  `.serialized` for the same reason `TileTransportTests` is: `StubTileProtocol`
//  scripts responses through process-wide state, so two tests scripting it at
//  once would answer each other's requests.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Durable tile coverage", .serialized)
struct TileDurableCoverageTests {
    private static let staleByDays: Double = 8

    private static func key(_ index: Int) -> String {
        "osm/15/\(9500 + index)/14600@2.0"
    }

    private static func url(_ index: Int) -> URL {
        guard let url = URL(string: "https://tiles.example.invalid/15/\(9500 + index)/14600.png") else {
            preconditionFailure("Invalid test URL for tile \(index)")
        }
        return url
    }

    /// When the bytes on disk were last written. The whole question these tests
    /// ask is whether a file was left alone, replaced, or unlinked, and the
    /// modification date is what separates the first two — a refreshed tile has
    /// the same name and very nearly the same size as the one it replaced.
    private static func modificationDate(of file: URL) throws -> Date {
        try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        )
    }

    /// Whether `file` carries `date` as its fetch time, to the second.
    ///
    /// Not `==`: the date is written through `setAttributes` and read back
    /// through a different API than the one that wrote it, and a comparison
    /// that fails on the last bit of a `TimeInterval` would be testing
    /// Foundation rather than which of two files was kept. A second is far
    /// finer than the seven days the answer turns on.
    private static func isDated(_ file: URL, like date: Date) throws -> Bool {
        try abs(modificationDate(of: file).timeIntervalSince(date)) < 1
    }

    /// A sandbox holding one piece of saved coverage that went stale a day past
    /// its TTL, with the transport scripted by the caller.
    private static func sandboxWithStaleCoverage(
        _ index: Int = 0,
        reachable: Bool = true
    ) throws -> StubbedTileCache {
        let stub = StubbedTileCache(reachable: reachable)
        try stub.place(in: stub.savedFile(for: key(index)), agedByDays: staleByDays)
        return stub
    }

    // MARK: - Offline, which is what the download was for

    /// The headline. No signal, coverage a week old, and the walker gets their
    /// map — the tile is drawn from the durable tier and is still there
    /// afterwards.
    ///
    /// The load must not even reach for the network: it is offline, and asking
    /// is what used to unlink the file on the way past.
    @Test("stale saved coverage is drawn offline, and survives being drawn")
    func staleCoverageIsServedOffline() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)
        let file = stub.savedFile(for: key)
        let before = try Self.modificationDate(of: file)

        let image = await stub.cache.loadTile(forKey: key, url: Self.url(0))

        #expect(image != nil, "a week-old map of the same valley is still a map of that valley")
        #expect(stub.isSaved(key), "and the bytes the hike claims are still on disk")
        #expect(try Self.modificationDate(of: file) == before, "nothing rewrote them")
        #expect(StubTileProtocol.requestCount == 0, "offline, so no request was even attempted")
    }

    /// Drawing it once must not consume it. A pan back and forth over the same
    /// ground asks for the same tiles again, and every one of those draws has
    /// to answer the same way.
    @Test("stale saved coverage can be drawn again and again")
    func staleCoverageSurvivesRepeatedDraws() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)

        for pass in 1...3 {
            let image = await stub.cache.loadTile(forKey: key, url: Self.url(0))
            #expect(image != nil, "draw \(pass) found the saved tile")
        }
        #expect(stub.isSaved(key))
    }

    /// Served coverage has to reach the memory tier, because that is the only
    /// thing `draw` paints from: a tile reported as loaded that the next draw
    /// pass misses is a draw/load loop with nothing ever on screen.
    ///
    /// It is admitted marked as stale, so the ordinary TTL — which would throw
    /// it straight back out — is not what decides its fate.
    @Test("served coverage reaches the memory tier the map draws from")
    func staleCoverageIsDrawable() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)

        #expect(await stub.cache.loadTile(forKey: key, url: Self.url(0)) != nil)

        #expect(
            stub.cache.memoryImage(forKey: key) != nil,
            "the draw pass that asked for this tile has to be able to paint it"
        )
    }

    /// And it is only admitted for a while. The entry is what damps the draw
    /// loop; expiring it is what stops the first stale draw of a session
    /// standing as the answer for the rest of it, so a walker who regains
    /// signal gets fresh ground without restarting the app.
    ///
    /// Driven by a reference date rather than by waiting: a memory entry's age
    /// is when it was cached, which nothing on disk can backdate.
    @Test("a served stale entry is dropped again so the refresh is retried")
    func staleMemoryEntryExpiresForRecheck() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)
        #expect(await stub.cache.loadTile(forKey: key, url: Self.url(0)) != nil)

        let pastRecheck = Date(timeIntervalSinceNow: TileCache.staleCoverageRecheckInterval + 60)

        #expect(stub.cache.memoryImage(forKey: key, referenceDate: pastRecheck) == nil)
        #expect(
            stub.cache.memoryImage(forKey: key) == nil,
            "and the lookup evicts it, rather than only declining to return it"
        )
        #expect(stub.isSaved(key), "the saved bytes are untouched by any of that")
    }

    // MARK: - Online, where the point is to refresh rather than to serve stale

    /// The refresh lands, so the saved copy is replaced — in the durable tier,
    /// where the hike is counting on it, and not as a browsing-tier copy the OS
    /// is free to reclaim.
    ///
    /// Checked by modification date: the file is rewritten, so its date moves
    /// off the eight-day-old one the test placed.
    @Test("a successful refresh replaces the saved bytes in place")
    func successfulRefreshReplacesSavedBytes() async throws {
        let stub = try Self.sandboxWithStaleCoverage()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        let key = Self.key(0)
        let file = stub.savedFile(for: key)
        let placed = try Self.modificationDate(of: file)

        let image = await stub.cache.loadTile(forKey: key, url: Self.url(0))

        #expect(image != nil)
        #expect(StubTileProtocol.requestCount == 1, "stale coverage is refreshed, not simply served")
        #expect(stub.isSaved(key), "and the replacement stays durable")
        #expect(!stub.isBrowsed(key), "a refreshed durable tile must not reappear as reclaimable cache")
        #expect(try Self.modificationDate(of: file) > placed, "the bytes were replaced")
    }

    /// The case the issue turns on: the request was allowed and still didn't
    /// produce anything. A timeout on a bar of signal, a 500, a captive portal.
    ///
    /// The old code had already deleted the file by this point, so the walker
    /// lost coverage they had by being *nearly* online — worse than being
    /// offline outright. Nothing is unlinked until replacement bytes exist.
    @Test("a failed refresh leaves the saved bytes intact and still draws them")
    func failedRefreshKeepsSavedBytes() async throws {
        let stub = try Self.sandboxWithStaleCoverage()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .status(500))
        let key = Self.key(0)
        let file = stub.savedFile(for: key)
        let placed = try Self.modificationDate(of: file)

        let image = await stub.cache.loadTile(forKey: key, url: Self.url(0))

        #expect(StubTileProtocol.requestCount == 1, "precondition: the refresh was attempted")
        #expect(image != nil, "the walker keeps the map they saved")
        #expect(stub.isSaved(key))
        #expect(try Self.modificationDate(of: file) == placed, "a failed refresh writes nothing")
    }

    /// A 200 carrying a captive portal's login page is a failure that looks
    /// like a success all the way down to the decoder. It must not be allowed
    /// to overwrite coverage either.
    @Test("an undecodable response does not overwrite saved coverage")
    func undecodableRefreshKeepsSavedBytes() async throws {
        let stub = try Self.sandboxWithStaleCoverage()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .undecodable())
        let key = Self.key(0)
        let file = stub.savedFile(for: key)
        let placed = try Self.modificationDate(of: file)

        let image = await stub.cache.loadTile(forKey: key, url: Self.url(0))

        #expect(image != nil, "the saved tile is the usable one here, not the response")
        #expect(try Self.modificationDate(of: file) == placed)
    }

    // MARK: - What serving stale coverage must not cost

    /// Serving the saved copy reports `.loaded`, which is a *success* to the
    /// renderer: it clears the failure log and never records the deadline the
    /// server named. So the deadline has to be honoured before the request is
    /// made, or the recheck five minutes later goes back to a server that asked
    /// for fifteen — the request pattern `Retry-After` exists to stop, aimed at
    /// the community-funded infrastructure it exists to protect.
    @Test("a standing Retry-After is honoured even while stale coverage is drawn")
    func retryAfterOutlivesTheStaleRecheck() async throws {
        let stub = try Self.sandboxWithStaleCoverage()
        defer { stub.tearDown() }
        let key = Self.key(0)
        StubTileProtocol.alwaysRespond(
            with: .init(
                statusCode: RetryAfterHeader.tooManyRequests,
                data: Data("slow down".utf8),
                headers: [RetryAfterHeader.name: "900"]
            )
        )

        #expect(await stub.cache.loadTile(forKey: key, url: Self.url(0)) != nil)
        #expect(StubTileProtocol.requestCount == 1, "precondition: the refresh was attempted once")
        #expect(stub.cache.retryDeadline(forKey: key) != nil, "precondition: the server named a deadline")

        // What a redraw past the recheck window does. The memory entry is gone
        // by then, so this is the load that used to go back to the server.
        stub.cache.memory.removeAllObjects()
        let image = await stub.cache.loadTile(forKey: key, url: Self.url(0))

        #expect(StubTileProtocol.requestCount == 1, "the server said fifteen minutes and meant it")
        #expect(image != nil, "and the walker still gets the map they saved while it waits")
    }

    /// Regaining signal has to reach the tiles already on screen. The renderer
    /// answers the unblock notification with a redraw, and a redraw reads the
    /// memory tier first — so coverage admitted while offline has to stop
    /// answering there, or a map nobody pans stays a week old with nothing
    /// scheduled to ask again.
    @Test("stale coverage stops answering from memory once fetching is unblocked")
    func reconnectRetiresServedStaleCoverage() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)
        #expect(await stub.cache.loadTile(forKey: key, url: Self.url(0)) != nil)
        #expect(stub.cache.memoryImage(forKey: key) != nil, "precondition: it was drawn")

        stub.cache.setReachable(true)

        #expect(
            stub.cache.memoryImage(forKey: key) == nil,
            "the next draw has to go back down to the load path, not repaint the offline answer"
        )
        #expect(stub.isSaved(key), "retiring the memory entry does not touch the saved bytes")
    }

    /// The duplicate an older build could leave: the same key in both tiers.
    /// Now that durable coverage is never dropped for age, "durable wins" over
    /// one of those means deleting the only fresh tile on the device and
    /// keeping the week-old one. The newer bytes are the coverage.
    @Test("a browsing copy newer than its durable twin is promoted, not discarded")
    func promoteKeepsTheNewerDuplicate() async throws {
        let stub = try Self.sandboxWithStaleCoverage()
        defer { stub.tearDown() }
        let key = Self.key(0)
        let browsed = stub.browsedFile(for: key)
        try stub.place(in: browsed, agedByDays: 1)
        let browsedAt = try Self.modificationDate(of: browsed)

        let cache = stub.cache
        let saved = await offMain { cache.promoteCachedTile(forKey: key) }

        #expect(saved, "the key is durable either way")
        #expect(!stub.isBrowsed(key), "and only one file is left behind")
        #expect(
            try Self.isDated(stub.savedFile(for: key), like: browsedAt),
            "the day-old bytes are the ones kept, dated as they were fetched"
        )
    }

    /// And the launch sweep applies the same rule, or it would undo the above
    /// at the next launch — its duplicate branch is what heals installs that
    /// have one, so it is the branch that most has to get this right.
    @Test("the launch sweep keeps the newer duplicate too")
    func launchSweepKeepsTheNewerDuplicate() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)
        let browsed = stub.browsedFile(for: key)
        try stub.place(in: browsed, agedByDays: 1)
        let browsedAt = try Self.modificationDate(of: browsed)
        let cache = stub.cache

        let removed = await offMain { cache.removeExpiredTiles() }

        #expect(removed == 1, "the browsing tier is one file lighter either way")
        #expect(stub.isSaved(key))
        #expect(!stub.isBrowsed(key))
        #expect(try Self.isDated(stub.savedFile(for: key), like: browsedAt))
    }

    /// The other direction is unchanged: identical bytes, durable newer or the
    /// same age, and the browsing copy is simply dropped.
    @Test("an older browsing duplicate is still discarded")
    func promoteDiscardsTheOlderDuplicate() async throws {
        let stub = try Self.sandboxWithStaleCoverage()
        defer { stub.tearDown() }
        let key = Self.key(0)
        try stub.place(in: stub.browsedFile(for: key), agedByDays: Self.staleByDays + 1)
        let savedAt = try Self.modificationDate(of: stub.savedFile(for: key))
        let cache = stub.cache

        #expect(await offMain { cache.promoteCachedTile(forKey: key) })

        #expect(!stub.isBrowsed(key))
        #expect(try Self.modificationDate(of: stub.savedFile(for: key)) == savedAt, "nothing rewrote the saved copy")
    }

    // MARK: - What the hike's manifest is allowed to promise

    /// The accounting half of the same promise. A hike sheet's `Offline tiles`
    /// row measures the bytes its claimed keys actually occupy, so coverage
    /// deleted by the launch sweep used to make that row shrink to nothing
    /// without anything having asked the walker.
    @Test("saved coverage still measures after the launch sweep has run")
    func claimedBytesSurviveTheLaunchSweep() async throws {
        let stub = try Self.sandboxWithStaleCoverage(reachable: false)
        defer { stub.tearDown() }
        let key = Self.key(0)
        let cache = stub.cache

        let removed = await offMain { cache.removeExpiredTiles() }
        #expect(removed == 0, "there is nothing in the browsing tier, and coverage is not swept")

        let measured = try await offMain { try cache.bytes(forKeys: [key]) }
        #expect(measured == TileStore.tileByteCount, "the hike's row still describes bytes that exist")
    }
}
