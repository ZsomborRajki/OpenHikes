//
//  VectorTileArchivesTests.swift
//  OpenHikesTests
//
//  What the vector providers are drawn from, as the tile server's manifest
//  moves it: which manifest a launch starts from, what a read moves and
//  keeps for the next launch, which tiles are drawn again after a move or a
//  launch in another language, and how often the manifest is read. The
//  manifest is a stub's, the clock is one the test moves, and what is kept
//  goes to a directory of the test's.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Vector tile archives")
struct VectorTileArchivesTests {
    // swiftlint:disable:next force_unwrapping
    private let server = URL(string: "https://tiles.example.invalid/")!
    private let bundled = VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-a", extras: "extras-a")
    private let newer = VectorTileArchiveManifest.fixture(revision: 2, basemap: "planet-b", extras: "extras-b")

    private func source(of manifest: VectorTileArchiveManifest) throws -> VectorTileSource {
        try #require(manifest.source(on: server))
    }

    private static func hoursAgo(_ hours: Double) -> Date { Date(timeIntervalSinceNow: -hours * 3600) }

    /// A directory of the test's own for what is kept, removed after `body`.
    private func withFile(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vector-archives-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.appending(path: "kept.json"))
    }

    /// What a launch in `language` at `date` draws from the bundled manifest,
    /// keeping it in `file`, reading `manifests` where the network `mayAsk`.
    private func launch(
        in language: String,
        at date: Date,
        keepingIn file: URL,
        manifests: StubVectorTileManifests? = nil,
        mayAsk: @escaping @Sendable () -> Bool = { true }
    ) throws -> VectorTileArchives {
        try #require(VectorTileArchives(
            providerIDs: ["osm"],
            bundled: bundled,
            manifests: manifests,
            file: file,
            language: language,
            server: server,
            mayAsk: mayAsk,
            launchedAt: date
        ))
    }

    // MARK: A launch

    /// An earlier build drew from names of its own, and nothing says which,
    /// so a first launch redraws what it finds.
    @Test("a first launch draws from the bundled manifest, from the launch on")
    func firstLaunch() throws {
        let launch = Self.hoursAgo(1)
        let start = try #require(
            VectorTileArchives.start(bundled: bundled, kept: nil, server: server, language: "en", at: launch)
        )

        #expect(start.manifest == bundled)
        #expect(start.source == (try source(of: bundled)))
        #expect(start.since == launch)
    }

    @Test("a launch draws from the kept manifest where it is as new as the bundled one, and keeps its time")
    func keptManifestWins() throws {
        let earlier = Self.hoursAgo(5)
        for kept in [newer, VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-c")] {
            let record = VectorTileArchives.Kept(
                manifest: kept, source: try source(of: kept), since: earlier, language: "en"
            )
            let start = try #require(
                VectorTileArchives.start(bundled: bundled, kept: record, server: server, language: "en", at: .now)
            )

            #expect(start.manifest == kept)
            #expect(start.since == earlier)
        }
    }

    /// A build can bundle a manifest newer than the one a device last read,
    /// and one it cannot draw from at all.
    @Test("a launch moves to the bundled manifest where the kept one is older, or names nothing it draws")
    func bundledManifestWins() throws {
        let launch = Self.hoursAgo(1)
        var unreadable = VectorTileArchiveManifest.fixture(revision: 9, basemap: "planet-z")
        unreadable.basemaps[0].schema += 1
        let older = VectorTileArchiveManifest.fixture(revision: 0, basemap: "planet-0")
        for kept in [older, unreadable] {
            let record = VectorTileArchives.Kept(
                manifest: kept, source: try source(of: older), since: .distantPast, language: "en"
            )
            let start = try #require(
                VectorTileArchives.start(bundled: bundled, kept: record, server: server, language: "en", at: launch)
            )

            #expect(start.manifest == bundled)
            #expect(start.since == launch, "it moved")
        }
    }

    /// The names are drawn in the app's language, which the cache's key says
    /// nothing of, and which changes only between launches.
    @Test("a launch in another language keeps the archives, and moves from the launch on")
    func otherLanguageMoves() throws {
        let launch = Self.hoursAgo(1)
        let record = VectorTileArchives.Kept(
            manifest: newer, source: try source(of: newer), since: Self.hoursAgo(5), language: "de"
        )
        let start = try #require(
            VectorTileArchives.start(bundled: bundled, kept: record, server: server, language: "fr", at: launch)
        )

        #expect(start.manifest == newer)
        #expect(start.source == (try source(of: newer)))
        #expect(start.language == "fr")
        #expect(start.since == launch)
    }

    /// Written at the launch rather than at the next read of the manifest,
    /// which a device offline or in Low Data Mode does not make: every launch
    /// would otherwise move, and draw everything again.
    @Test("a launch keeps what it draws from at once, so the next one in the same language moves nothing")
    func launchKeepsItsStart() async throws {
        try await withFile { file in
            _ = try launch(in: "de", at: Self.hoursAgo(4), keepingIn: file)
            let again = try launch(in: "de", at: Self.hoursAgo(3), keepingIn: file)
            #expect(!again.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(3.5)), "drawn in the same language")

            let switched = try launch(in: "fr", at: Self.hoursAgo(2), keepingIn: file)
            #expect(switched.language == "fr")
            #expect(switched.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(2.5)), "drawn in German")
            #expect(!switched.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(1.5)), "drawn since")
            #expect(!switched.redraws("stadia_outdoors/14/1/1", drawnAt: Self.hoursAgo(2.5)), "not drawn from these")

            let relaunched = try launch(in: "fr", at: Self.hoursAgo(1), keepingIn: file)
            #expect(relaunched.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(2.5)), "the move is kept")
            #expect(!relaunched.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(1.5)))
        }
    }

    /// A write that fails leaves the record before it on disk, and a switch
    /// back to that record's language would take every tile drawn in the
    /// other one since for current. So it is written again by the next read
    /// the app comes to the front for, of the same manifest, or one the
    /// network refuses, as a device offline makes.
    @Test(
        "a launch whose record could not be written writes it at the next read, so a switch back redraws",
        arguments: [true, false]
    )
    func failedWriteIsMadeAgain(networkAllowed: Bool) async throws {
        try await withFile { file in
            let directory = file.deletingLastPathComponent()
            let manager = FileManager.default
            _ = try launch(in: "de", at: Self.hoursAgo(4), keepingIn: file)
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

            let manifests = StubVectorTileManifests(bundled)
            let french = try launch(
                in: "fr", at: Self.hoursAgo(3), keepingIn: file, manifests: manifests, mayAsk: { networkAllowed }
            )
            french.adopt(bundled)
            #expect(VectorTileArchives.Kept.read(from: file)?.language == "de", "precondition: no write lands")
            #expect(french.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(3.5)), "drawn in French from the launch")

            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            await french.refresh()?.value
            #expect(manifests.reads == (networkAllowed ? 1 : 0))
            #expect(VectorTileArchives.Kept.read(from: file)?.language == "fr")

            let german = try launch(in: "de", at: Self.hoursAgo(1), keepingIn: file)
            #expect(german.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(2)), "drawn in French")
        }
    }

    /// A move kept for later than the launch was made by a clock set back
    /// since. Kept, it would turn away every tile drawn until the clock
    /// caught up with it.
    @Test("a kept move later than the launch is made again from the launch")
    func moveFromAheadOfTheClock() throws {
        let launch = Self.hoursAgo(1)
        let record = VectorTileArchives.Kept(
            manifest: bundled, source: try source(of: bundled), since: Self.hoursAgo(-24), language: "en"
        )
        let start = try #require(
            VectorTileArchives.start(bundled: bundled, kept: record, server: server, language: "en", at: launch)
        )

        #expect(start.since == launch)
    }

    /// Set back during a launch below the move it made: the move is made
    /// again from then, once, or every copy drawn until the clock caught up
    /// would be turned away, and drawn again at every look.
    @Test("a move later than the clock is made again from it, once, so copies drawn since are current")
    func moveAheadOfTheClockDuringALaunch() async throws {
        try await withFile { file in
            let archives = try launch(in: "en", at: Date(timeIntervalSinceNow: 3600), keepingIn: file)
            let setBack = Date()

            #expect(archives.redraws("osm/14/1/1", drawnAt: setBack - 60, now: setBack), "drawn before")
            #expect(!archives.redraws("osm/14/1/1", drawnAt: setBack, now: setBack))
            #expect(!archives.redraws("osm/14/1/1", drawnAt: setBack + 30, now: setBack + 60), "drawn since")
            #expect(archives.redraws("osm/14/1/1", drawnAt: setBack - 60, now: setBack + 60), "still drawn before")
        }
    }

    /// A copy stored later than now was stored before the clock was set
    /// back, by archives or in a language nothing says.
    @Test("a copy stored later than now is drawn again, whenever the providers moved")
    func copyFromAheadOfTheClock() throws {
        let archives = VectorTileArchives(sources: ["osm": try source(of: bundled)], language: "en", server: server)
        let now = Date()

        #expect(archives.redraws("osm/14/1/1", drawnAt: now.addingTimeInterval(3600), now: now))
        #expect(!archives.redraws("osm/14/1/1", drawnAt: now.addingTimeInterval(-3600), now: now))
        #expect(!archives.redraws("stadia_outdoors/14/1/1", drawnAt: now.addingTimeInterval(3600), now: now))
    }

    // MARK: A read

    @Test("a read of a newer manifest moves every provider, redraws what was drawn before, and is kept")
    func readMovesAndKeeps() async throws {
        try await withFile { file in
            let moves = Mutex(0)
            let launched = VectorTileArchives(
                providerIDs: ["osm", "other"],
                bundled: bundled,
                manifests: StubVectorTileManifests(newer),
                file: file,
                server: server,
                didMove: { moves.withLock { $0 += 1 } },
                launchedAt: Self.hoursAgo(3)
            )
            let archives = try #require(launched)
            #expect(archives.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(2)) == false, "precondition")

            #expect(await archives.moved(from: try source(of: bundled), for: "osm"))

            #expect(archives.source(for: "osm") == (try source(of: newer)))
            #expect(archives.source(for: "other") == (try source(of: newer)))
            #expect(archives.source(for: "stadia_outdoors") == nil)
            #expect(moves.withLock { $0 } == 1)
            #expect(archives.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(1)))
            #expect(!archives.redraws("osm/14/1/1", drawnAt: Date()), "drawn since")
            #expect(!archives.redraws("stadia_outdoors/14/1/1", drawnAt: Self.hoursAgo(1)))

            let relaunched = try #require(VectorTileArchives(
                providerIDs: ["osm"], bundled: bundled, manifests: nil, file: file, server: server
            ))
            #expect(relaunched.source(for: "osm") == (try source(of: newer)))
            #expect(relaunched.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(1)), "the move is kept with it")
        }
    }

    /// Every publish raises the revision, so a lower one is a cache or a
    /// mirror that has not caught up.
    @Test("a manifest older than the one drawn from moves nothing")
    func olderManifestMovesNothing() async throws {
        let manifests = StubVectorTileManifests(bundled)
        let archives = VectorTileArchives(sources: ["osm": try source(of: newer)], server: server, manifests: manifests)
        archives.adopt(newer)

        #expect(await archives.moved(from: try source(of: newer), for: "osm") == false)
        #expect(manifests.reads == 1)
        #expect(archives.source(for: "osm") == (try source(of: newer)))
    }

    @Test("a manifest naming what is drawn already moves nothing, and redraws nothing")
    func sameArchivesMoveNothing() async throws {
        var republished = bundled
        republished.revision = 5
        let archives = try #require(VectorTileArchives(
            providerIDs: ["osm"],
            bundled: bundled,
            manifests: StubVectorTileManifests(republished),
            file: nil,
            server: server,
            launchedAt: Self.hoursAgo(3)
        ))

        #expect(await archives.moved(from: try source(of: bundled), for: "osm") == false)
        #expect(!archives.redraws("osm/14/1/1", drawnAt: Self.hoursAgo(2)))
    }

    // MARK: How often

    /// A manifest that still names a retired archive is not mended by asking
    /// again at once, and a read that has already moved on needs no other.
    @Test("a retired archive reads the manifest once a minute at most, and not at all once a read moved on")
    func retiredArchiveReads() async throws {
        let clock = SteppingClock()
        let manifests = StubVectorTileManifests(bundled)
        let old = try source(of: bundled)
        let archives = VectorTileArchives(
            sources: ["osm": old], server: server, manifests: manifests, now: { clock.now }
        )

        #expect(await archives.moved(from: old, for: "osm") == false)
        #expect(await archives.moved(from: old, for: "osm") == false)
        #expect(manifests.reads == 1, "within the minute")

        manifests.answer(with: newer)
        clock.advance(by: VectorTileArchives.retiredReadInterval + .seconds(1))
        #expect(await archives.moved(from: old, for: "osm"))
        #expect(await archives.moved(from: old, for: "osm"))
        #expect(manifests.reads == 2, "the second already knew")
    }

    @Test("the app coming to the front reads the manifest once an hour")
    func foregroundReads() async throws {
        let clock = SteppingClock()
        let manifests = StubVectorTileManifests(newer)
        let archives = VectorTileArchives(
            sources: ["osm": try source(of: bundled)], server: server, manifests: manifests, now: { clock.now }
        )

        await archives.refresh()?.value
        #expect(manifests.reads == 1)
        #expect(archives.source(for: "osm") == (try source(of: newer)))

        clock.advance(by: VectorTileArchives.readInterval - .seconds(1))
        #expect(archives.refresh() == nil)
        clock.advance(by: .seconds(2))
        await archives.refresh()?.value
        #expect(manifests.reads == 2)
    }

    /// A read the network refused was not made: the next reason to read
    /// asks, rather than waiting out an interval for nothing.
    @Test("a read the network refuses asks nothing, and the next reason to read asks")
    func refusedReadIsNotCounted() async throws {
        let allowed = Mutex(false)
        let manifests = StubVectorTileManifests(newer)
        let launched = VectorTileArchives(
            providerIDs: ["osm"],
            bundled: bundled,
            manifests: manifests,
            file: nil,
            server: server,
            mayAsk: { allowed.withLock { $0 } }
        )
        let archives = try #require(launched)

        await archives.refresh()?.value
        #expect(manifests.reads == 0)

        allowed.withLock { $0 = true }
        await archives.refresh()?.value
        #expect(manifests.reads == 1)
        #expect(archives.source(for: "osm") == (try source(of: newer)))
    }
}

/// A clock that moves only when the test says.
nonisolated private final class SteppingClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}
