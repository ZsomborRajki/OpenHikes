//
//  OfflineCountryDirectoryCacheTests.swift
//  OpenHikesTests
//
//  The directory *Offline Maps* is read from, prepared off the main actor
//  and kept (#1536): prepared again only when the list or the hiker's
//  position changes, the last one kept while the next is measured, and one
//  measured from a list or a position since passed over never put on screen.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

// swiftlint:disable no_magic_numbers

@MainActor
@Suite("Offline countries: the directory prepared and kept")
struct OfflineCountryDirectoryCacheTests {
    private typealias Country = OfflineCountryManifest.Country
    private typealias Source = OfflineCountryDirectory.Source

    /// Which threads the measuring ran on, one entry a call.
    nonisolated final class ThreadLog: Sendable {
        private let threads = Mutex<[Bool]>([])

        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func note() { threads.withLock { $0.append(Thread.isMainThread) } }
    }

    private let slovenia = OfflineCountryFixture.country(bytes: Data(count: 10))
    private let austria = OfflineCountryFixture.northernCountry(bytes: Data(count: 30))
    private let spain = OfflineCountryFixture.country(bytes: Data(count: 40), id: "ES")
    private let california = OfflineCountryFixture.country(
        bytes: Data(count: 50), id: "US-CA", group: "US", names: ["en": "California"]
    )
    private let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5)

    private func source(_ offered: [Country], near: CLLocationCoordinate2D? = nil) -> Source {
        Source(offered: offered, installed: [:], near: near)
    }

    /// Notes `source` as the list's body does, and prepares it as the
    /// list's task does.
    private func prepare(_ cache: OfflineCountryDirectoryCache, _ source: Source) async {
        await cache.prepare(cache.revision(for: source))
    }

    /// A cache whose measuring of what `isHeld` picks waits at `gate`.
    private func cache(
        holding isHeld: @escaping @Sendable (Source) -> Bool,
        at gate: TestGate
    ) -> OfflineCountryDirectoryCache {
        OfflineCountryDirectoryCache { source in
            if isHeld(source) { await gate.wait() }
            return OfflineCountryDirectory.Measured(from: source)
        }
    }

    // MARK: - Kept across passes

    @Test("the directory is prepared when the list or the position changes, and kept otherwise")
    func keptAcrossPasses() async {
        let cache = OfflineCountryDirectoryCache()

        await prepare(cache, source([austria, slovenia]))
        await prepare(cache, source([austria, slovenia]))
        #expect(cache.builds == 1)

        await prepare(cache, source([austria, slovenia], near: ljubljana))
        await prepare(cache, source([austria, slovenia], near: ljubljana))
        #expect(cache.builds == 2)
        #expect(cache.directory?.hasPosition == true)

        var newer = slovenia
        newer.build = "20270101"
        await prepare(cache, source([austria, newer], near: ljubljana))
        #expect(cache.builds == 3)
    }

    /// The list's task is keyed on the revision, so a revision that does not
    /// move is a task that is not put in hand again.
    @Test("an equal list off the server is the same revision")
    func equalListIsTheSameRevision() {
        let cache = OfflineCountryDirectoryCache()

        let first = cache.revision(for: source([austria, slovenia]))
        #expect(cache.revision(for: source([austria, slovenia])) == first)
        #expect(cache.revision(for: source([austria, slovenia], near: ljubljana)) == first + 1)
    }

    /// The server can correct a name without cutting the area again, and the
    /// rows and the search read the areas the directory kept.
    @Test("a list off the server that renames an area at the same build is named and found by the new name")
    func renamedAtTheSameBuild() async throws {
        let cache = OfflineCountryDirectoryCache()
        var misspelled = california
        misspelled.names = ["en": "Californa"]

        await prepare(cache, source([austria, misspelled]))
        await prepare(cache, source([austria, california]))

        #expect(cache.builds == 2)
        let refreshed = try #require(cache.directory)
        #expect(refreshed.entries.map(\.country) == [austria, california])
        #expect(refreshed.areas(matching: "California") == [california])
    }

    @Test("an area downloaded and no longer offered is still listed")
    func keepsWhatIsNoLongerOffered() async throws {
        let cache = OfflineCountryDirectoryCache()
        let installed = ["ES": OfflineCountryStore.Record(country: spain, installedAt: .now)]

        await prepare(cache, Source(offered: [austria, slovenia], installed: installed, near: nil))

        let listed = try #require(cache.directory)
        #expect(listed.entries.map(\.country) == [austria, slovenia, spain])
        #expect(listed.entries.map(\.fullName) == ["Austria", "Slovenia", "Spain"])
    }

    // MARK: - Off the main actor

    @Test("the directory is measured off the main actor")
    func measuredOffTheMainActor() async {
        let log = ThreadLog()
        let cache = OfflineCountryDirectoryCache { source in
            log.note()
            return OfflineCountryDirectory.Measured(from: source)
        }

        await prepare(cache, source([austria, slovenia], near: ljubljana))

        #expect(log.ranOnMainThread == [false])
        #expect(cache.directory?.hasPosition == true)
    }

    // MARK: - While the next is measured

    @Test("the directory on screen stays there while the next is measured")
    func keepsTheLastWhileMeasuring() async {
        let gate = TestGate()
        let cache = cache(holding: { $0.offered.count == 3 }, at: gate)
        await prepare(cache, source([austria, slovenia]))

        let refresh = Task { await prepare(cache, source([austria, slovenia, spain])) }
        await settleDelegateHop(until: "the new list to be measuring") { gate.isHolding }
        #expect(cache.directory?.entries.map(\.country) == [austria, slovenia])

        gate.open()
        await refresh.value
        #expect(cache.directory?.entries.map(\.country) == [austria, slovenia, spain])
        #expect(cache.builds == 2)
    }

    /// The list comes up before the hiker's position is read, and the
    /// position is read as it does; the order measured with no position must
    /// not land over the one measured with it.
    @Test("a directory measured from what the list is no longer made from is never put on screen")
    func supersededMeasuringIsDropped() async {
        let gate = TestGate()
        let cache = cache(holding: { $0.near == nil }, at: gate)

        let opening = Task { await prepare(cache, source([austria, slovenia])) }
        await settleDelegateHop(until: "the list with no position to be measuring") { gate.isHolding }
        await prepare(cache, source([austria, slovenia], near: ljubljana))
        #expect(cache.directory?.hasPosition == true)

        gate.open()
        await opening.value
        #expect(cache.directory?.hasPosition == true)
        #expect(cache.builds == 1)
    }

    @Test("a measuring whose task is cancelled is never put on screen, and the next task measures again")
    func cancelledMeasuringIsDropped() async {
        let gate = TestGate()
        let cache = cache(holding: { _ in true }, at: gate)
        let revision = cache.revision(for: source([austria, slovenia]))

        let gone = Task { await cache.prepare(revision) }
        await settleDelegateHop(until: "the list to be measuring") { gate.isHolding }
        gone.cancel()
        gate.open()
        await gone.value
        #expect(cache.directory == nil)
        #expect(cache.builds == 0)

        await cache.prepare(revision)
        #expect(cache.directory?.entries.map(\.country) == [austria, slovenia])
        #expect(cache.builds == 1)
    }
}

// swiftlint:enable no_magic_numbers
