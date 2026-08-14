//
//  TileTransportTests.swift
//  OpenTrailsTests
//
//  Everything `TileCache` does between "the renderer wants this tile" and
//  "here is an image", with the tile server replaced by a script the test
//  writes (see `StubTileProtocol`) and the two disk tiers moved into a
//  temporary directory.
//
//  This is the layer the rest of the tile suite has to take on trust:
//  `TileCacheTierTests` places files by hand, `TileRetryTests` covers the
//  policy that decides when to ask again, and neither can say what a 500
//  actually does, whether the identifying User-Agent OSM's usage policy
//  requires is really sent, or whether a cache hit really avoids a request.
//
//  Each test owns its own `TileCache` and auto-save store (see `TileSandbox`),
//  so nothing here can disturb — or be disturbed by — any other suite. This
//  one is serialized only because `StubTileProtocol`'s script is process-wide.
//

import Foundation
import MapKit
@testable import OpenTrails
import Testing

@Suite("Tile transport", .serialized)
struct TileTransportTests {
    let key = "osm/14/2638/6357@2.0"

    func url(_ suffix: String = "14/2638/6357.png") -> URL {
        guard let url = URL(string: "https://tiles.example.invalid/\(suffix)") else {
            preconditionFailure("Invalid test URL suffix: \(suffix)")
        }
        return url
    }

    // MARK: What comes back off the wire

    /// The happy path, and the baseline the failure cases are read against:
    /// one request, an image returned, and the bytes filed in the browsing
    /// tier — not the durable one, because nobody asked to keep this.
    @Test("a tile that loads is returned and cached in the browsing tier")
    func successfulFetchIsCachedEphemerally() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        let image = await stub.cache.loadTile(forKey: key, url: url())

        #expect(image != nil)
        #expect(StubTileProtocol.requestCount == 1)
        #expect(stub.isBrowsed(key), "a tile fetched to draw the map is the OS's to reclaim")
        #expect(!stub.isSaved(key), "and is not offline coverage")
        #expect(stub.cache.memoryImage(forKey: key) != nil, "and is in memory for the next draw pass")
    }

    /// A tile server error must not be mistaken for a tile. This is the case
    /// `TileRetryTests` schedules a retry for — here it's the half that says
    /// there is something to retry.
    @Test("a server error yields no tile and caches nothing", arguments: [404, 429, 500, 503])
    func serverErrorsAreRefused(status: Int) async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .status(status))

        let image = await stub.cache.loadTile(forKey: key, url: url())

        #expect(image == nil, "HTTP \(status) is not a tile")
        #expect(!stub.isBrowsed(key), "and an error body must never be written as one")
        #expect(!stub.isSaved(key))
        #expect(stub.cache.memoryImage(forKey: key) == nil)
    }

    /// A 200 whose body isn't an image — a captive portal's login page, an
    /// HTML rate-limit notice, a truncated download. Caching it would put a
    /// permanently undecodable file under a key that then looks populated.
    @Test("a 200 that isn't an image is refused")
    func undecodableBodyIsRefused() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .undecodable())

        let image = await stub.cache.loadTile(forKey: key, url: url())

        #expect(image == nil)
        #expect(!stub.isBrowsed(key))
        #expect(stub.cache.memoryImage(forKey: key) == nil)
    }

    /// `fetchTile` refuses a response it can't read a status code from before
    /// it looks at anything else.
    @Test("a response that isn't HTTP is refused")
    func nonHTTPResponseIsRefused() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: Response.nonHTTPTile)

        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(!stub.isBrowsed(key))
    }

    /// A transport-level failure — no route, DNS, TLS, timeout — is a miss,
    /// not a crash and not an empty tile.
    @Test("a transport failure is a miss")
    func transportFailureIsAMiss() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: Response(failure: URLError(.timedOut)))

        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(!stub.isBrowsed(key))
    }

    /// OpenStreetMap's tile usage policy requires a User-Agent that identifies
    /// the application; sending the default one is grounds for being blocked.
    /// Pinned on the request URLSession actually produced, not on the string
    /// the configuration was handed.
    @Test("every tile request identifies the app, as OSM's policy requires")
    func requestsCarryTheIdentifyingUserAgent() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        await stub.cache.loadTile(forKey: key, url: url())
        await stub.cache.saveTileDurably(forKey: "osm/14/2638/6358@2.0", url: url("14/2638/6358.png"))

        #expect(StubTileProtocol.requests.count == 2, "precondition: both paths reached the network")
        for request in StubTileProtocol.requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent)
        }
    }

    // MARK: Which tier answers

    /// Memory first. A tile already decoded is never re-read, let alone
    /// re-fetched — this is the check that runs on the draw path.
    @Test("a tile in memory is served without touching the network")
    func memoryHitMakesNoRequest() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        await stub.cache.loadTile(forKey: key, url: url())
        #expect(StubTileProtocol.requestCount == 1)

        await stub.cache.loadTile(forKey: key, url: url())
        #expect(StubTileProtocol.requestCount == 1, "the second draw pass must not re-request it")
    }

    /// Then the browsing tier, then the durable one. A hike's saved map has to
    /// work with no signal at all, so a durable tile must answer without a
    /// request even on a cold memory cache.
    @Test("a tile on disk is served without a request", arguments: [false, true])
    func diskHitMakesNoRequest(durable: Bool) async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        // Nothing scripted: any request at all fails the test loudly.
        try stub.place(key, in: durable ? stub.savedFile(for: key) : stub.browsedFile(for: key))

        let image = await stub.cache.loadTile(forKey: key, url: url())

        #expect(image != nil, "the tile is on disk; offline is exactly when this matters")
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// The seven-day TTL OSM's policy asks for, applied on read: an expired
    /// tile is neither shown nor kept, and the fetch that replaces it is a
    /// real one.
    @Test("an expired tile is refetched rather than served")
    func expiredTileIsRefetched() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        try stub.place(key, in: stub.browsedFile(for: key), agedByDays: 8)
        StubTileProtocol.alwaysRespond(with: .tile())

        let image = await stub.cache.loadTile(forKey: key, url: url())

        #expect(image != nil)
        #expect(StubTileProtocol.requestCount == 1, "past its TTL, the cached copy is not an answer")
        #expect(stub.isBrowsed(key), "and the fresh one takes its place")
    }

    /// A tile just inside the TTL is still good — the boundary the test above
    /// is only meaningful against.
    @Test("a tile inside its TTL is still served from disk")
    func freshTileIsNotRefetched() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        try stub.place(key, in: stub.browsedFile(for: key), agedByDays: 6)

        #expect(await stub.cache.loadTile(forKey: key, url: url()) != nil)
        #expect(StubTileProtocol.requestCount == 0)
    }

    // MARK: The download path

    /// A bulk download fetches into durable storage directly. `Caches` is the
    /// first thing the OS purges under storage pressure, and coverage the user
    /// explicitly asked for cannot live there.
    @Test("a download writes to durable storage, not the browsing cache")
    func downloadWritesDurably() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        let saved = await stub.cache.saveTileDurably(forKey: key, url: url())

        #expect(saved)
        #expect(stub.isSaved(key))
        #expect(!stub.isBrowsed(key), "a download must not land where the OS can reclaim it")
    }

    /// A download reports honestly when the tile never arrived, so the
    /// manifest only ever claims tiles that are really on disk.
    @Test("a download that fails saves nothing and says so")
    func failedDownloadReportsFailure() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .status(500))

        #expect(await stub.cache.saveTileDurably(forKey: key, url: url()) == false)
        #expect(!stub.isSaved(key))
    }

    /// A tile already browsed is promoted rather than re-fetched — the tile
    /// server is asked for each tile once, not once per tier.
    @Test("a download promotes an already-browsed tile instead of refetching it")
    func downloadPromotesRatherThanRefetching() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        try stub.place(key, in: stub.browsedFile(for: key))

        #expect(await stub.cache.saveTileDurably(forKey: key, url: url()))
        #expect(StubTileProtocol.requestCount == 0, "the bytes were already here")
        #expect(stub.isSaved(key))
    }

    // MARK: Offline and reconnect

    /// Offline, a tile that isn't cached fails without a request at all —
    /// otherwise every visible tile fires a doomed load on every draw pass.
    @Test("offline, an uncached tile fails without a request")
    func offlineShortCircuits() async {
        let stub = StubbedTileCache(reachable: false)
        defer { stub.tearDown() }

        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(await stub.cache.saveTileDurably(forKey: key, url: url()) == false)
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// …but a tile that *is* cached still works offline. This is the whole
    /// point of the feature.
    @Test("offline, a saved tile is still served")
    func offlineStillServesSavedTiles() async throws {
        let stub = StubbedTileCache(reachable: false)
        defer { stub.tearDown() }
        try stub.place(key, in: stub.savedFile(for: key))

        #expect(await stub.cache.loadTile(forKey: key, url: url()) != nil)
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// Coming back online tells every registered renderer, which is what
    /// clears their failure logs and redraws. Without this the map stays full
    /// of holes until something else forces a draw pass.
    @Test("reconnecting notifies renderers so they can retry")
    func reconnectNotifiesObservers() async throws {
        let stub = StubbedTileCache(reachable: false)
        defer { stub.tearDown() }

        final class Listener: TileCacheObserver, @unchecked Sendable {
            var reconnects = 0

            func tileCacheDidReconnect() { reconnects += 1 }
        }

        let listener = Listener()
        stub.cache.addObserver(listener)

        stub.cache.setReachable(true)
        // The notification hops to the main queue before touching renderers.
        try await Task.sleep(for: .milliseconds(120))
        #expect(listener.reconnects == 1)

        // Only the offline→online edge counts; staying online says nothing.
        stub.cache.setReachable(true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(listener.reconnects == 1)
    }

    /// And the requests really do resume, rather than the flag flipping while
    /// the short-circuit stays in place.
    @Test("reconnecting lets requests through again")
    func reconnectResumesRequests() async {
        let stub = StubbedTileCache(reachable: false)
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(StubTileProtocol.requestCount == 0)

        stub.cache.setReachable(true)
        #expect(await stub.cache.loadTile(forKey: key, url: url()) != nil)
        #expect(StubTileProtocol.requestCount == 1)
    }

    // MARK: Deduplication

    /// The map's fetch and a bulk download's fetch for the same tile go
    /// through different entry points — `loadTile` and `saveTileDurably` —
    /// and `TileCache`'s in-flight set is what collapses them onto one
    /// request. Without it, downloading the area you are currently looking at
    /// asks the tile server for every tile twice, doubling the request load on
    /// providers whose usage policies are the reason this app has an auto-save
    /// mechanism at all.
    @Test("the map and a download don't ask for the same tile twice")
    func concurrentFetchesAreDeduplicated() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        // Held open so the two really do overlap rather than the second
        // finding the first already finished and filed.
        StubTileProtocol.setDelay(.milliseconds(150))

        async let browsed = stub.cache.loadTile(forKey: key, url: url())
        async let downloaded = stub.cache.saveTileDurably(forKey: key, url: url())
        let (image, saved) = await (browsed, downloaded)

        #expect(image != nil, "the map still gets its tile")
        #expect(saved, "and the download still gets its coverage")
        #expect(StubTileProtocol.requestCount == 1, "one tile, one request")
    }

    /// Sharing a fetch must not mean sharing a filing decision: the download
    /// needs its tile where the OS can't reclaim it, and the map's concurrent
    /// load must not leave a second copy of the same bytes in the browsing
    /// tier. The two writes are ordered only by chance, so this is checked from
    /// the outcome rather than by reasoning about which landed first.
    @Test("a shared fetch still leaves exactly one file, in the durable tier")
    func deduplicatedFetchStillFilesDurably() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        StubTileProtocol.setDelay(.milliseconds(150))

        async let browsed = stub.cache.loadTile(forKey: key, url: url())
        async let downloaded = stub.cache.saveTileDurably(forKey: key, url: url())
        _ = await (browsed, downloaded)

        #expect(stub.isSaved(key), "the download's requirement is the stronger one")
        #expect(!stub.isBrowsed(key), "and the map's copy isn't left beside it")
    }

    /// A finished fetch releases its key. If the in-flight entry leaked, every
    /// later request for that tile would be answered from a task that already
    /// completed — which for a tile that *failed* would pin the failure
    /// permanently, with no reconnect or retry able to shift it.
    ///
    /// The second request here is the correct count: the point is that the
    /// cache goes back to the network at all once the first round is over.
    @Test("a key is fetchable again once its in-flight fetch is done")
    func inFlightEntriesAreReleased() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        // The first attempt fails, so nothing is cached to answer the second.
        StubTileProtocol.alwaysRespond(with: .status(500))
        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(StubTileProtocol.requestCount == 1)

        StubTileProtocol.alwaysRespond(with: .tile())
        #expect(
            await stub.cache.loadTile(forKey: key, url: url()) != nil,
            "a retry after a failure must reach the network, not a spent task"
        )
        #expect(StubTileProtocol.requestCount == 2)
    }

    @Test("removing a key invalidates its in-flight fetch")
    func removalWinsAgainstInFlightFetch() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        StubTileProtocol.setDelay(.milliseconds(150))

        let cache = stub.cache
        let load = Task {
            await cache.loadTile(forKey: key, url: url())
        }
        await StubTileProtocol.waitForRequest()

        await offMain {
            cache.removeTiles(forKeys: [key])
        }
        let image = await load.value

        #expect(image == nil)
        #expect(!stub.isBrowsed(key))
        #expect(!stub.isSaved(key))
        #expect(cache.memoryImage(forKey: key) == nil)
    }

    @Test("same-key callers share the first in-flight URL")
    func sameKeyDifferentURLUsesFirstRequest() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        StubTileProtocol.setDelay(.milliseconds(150))
        let firstURL = url("first.png")
        let secondURL = url("second.png")

        let first = Task {
            await stub.cache.loadTile(forKey: key, url: firstURL)
        }
        await StubTileProtocol.waitForRequest()
        async let second = stub.cache.loadTile(
            forKey: key,
            url: secondURL
        )
        let (firstImage, secondImage) = await (first.value, second)

        #expect(firstImage != nil)
        #expect(secondImage != nil)
        #expect(StubTileProtocol.requestCount == 1)
        #expect(StubTileProtocol.requests.first?.url == firstURL)
    }

    // MARK: The overlay's contract with the renderer

    /// `CachingTileOverlayRenderer` decides whether to record a failure — and
    /// so whether to schedule a retry — purely from what `cacheTile` returns.
    /// These two pin that return value against real responses, which is the
    /// join `TileRetryTests` takes on trust.
    @Test("the overlay reports a loaded tile to the renderer")
    func overlayReportsSuccess() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        let overlay = TileOverlay(
            providerID: "osm",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: stub.cache,
            autoSaveStore: stub.store
        )
        let path = MKTileOverlayPath(x: 9500, y: 14_600, z: 15, contentScaleFactor: 2)

        let loaded = await offMain { await overlay.cacheTile(at: path) }
        #expect(loaded, "a loaded tile clears the renderer's backoff for that key")
        #expect(StubTileProtocol.requestCount == 1)
    }

    @Test("the overlay reports a failed tile to the renderer")
    func overlayReportsFailure() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .status(500))

        let overlay = TileOverlay(
            providerID: "osm",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: stub.cache,
            autoSaveStore: stub.store
        )
        let path = MKTileOverlayPath(x: 9500, y: 14_600, z: 15, contentScaleFactor: 2)

        let loaded = await offMain { await overlay.cacheTile(at: path) }
        #expect(!loaded, "a 500 is what makes the renderer record a failure and schedule a retry")
    }
}

private typealias Response = StubTileProtocol.Response

private extension StubTileProtocol.Response {
    /// A 200 delivered with a plain `URLResponse` — no status code to read.
    static var nonHTTPTile: Self {
        Self(data: TileStore.tileData, isHTTP: false)
    }
}

/// Runs an async body off the main thread. The tile pipeline asserts it isn't
/// on main; `offMain` in `TestSupport` takes a synchronous closure, and
/// `cacheTile` is `async`.
///
/// `@concurrent` rather than `Task.detached`, matching its `TestSupport` twin:
/// the body stays inside the test's own task, so a cancelled test cancels the
/// work it is waiting on.
@concurrent
private func offMain<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
    await work()
}
