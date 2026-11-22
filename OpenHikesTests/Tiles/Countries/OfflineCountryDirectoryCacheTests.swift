//
//  OfflineCountryDirectoryCacheTests.swift
//  OpenHikesTests
//
//  The directory *Offline Maps* is read from, prepared off the main actor
//  and kept (#1536): prepared again only when the list's revision or the
//  hiker's position changes, the last one kept while the next is measured,
//  and one measured from a list or a position since passed over never put
//  on screen.
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
    private typealias Key = OfflineCountryDirectoryCache.Key
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

    /// Prepares the directory of `offered` at the list's revision `catalog`,
    /// as the list's task does, with the model holding that revision still
    /// unless `isCurrent` says otherwise.
    private func prepare(
        _ cache: OfflineCountryDirectoryCache,
        catalog: Int,
        _ offered: [Country],
        installed: [String: OfflineCountryStore.Record] = [:],
        near: CLLocationCoordinate2D? = nil,
        isCurrent: () -> Bool = { true }
    ) async {
        await cache.prepare(
            Key(catalog: catalog, near: near),
            from: Source(offered: offered, installed: installed, near: near),
            isCurrent: isCurrent
        )
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

    @Test("the directory is prepared when the list's revision or the position changes, and kept otherwise")
    func keptAcrossPasses() async {
        let cache = OfflineCountryDirectoryCache()

        await prepare(cache, catalog: 1, [austria, slovenia])
        await prepare(cache, catalog: 1, [austria, slovenia])
        #expect(cache.builds == 1)

        await prepare(cache, catalog: 1, [austria, slovenia], near: ljubljana)
        await prepare(cache, catalog: 1, [austria, slovenia], near: ljubljana)
        #expect(cache.builds == 2)
        #expect(cache.directory?.hasPosition == true)
        #expect(cache.shown == Key(catalog: 1, near: ljubljana))

        var newer = slovenia
        newer.build = "20270101"
        await prepare(cache, catalog: 2, [austria, newer], near: ljubljana)
        #expect(cache.builds == 3)
        #expect(cache.directory?.entries.map(\.country) == [austria, newer])
    }

    /// The server can correct a name without cutting the area again, the
    /// list's revision moves for it, and the rows and the search read the
    /// areas the directory kept.
    @Test("a list off the server that renames an area at the same build is named and found by the new name")
    func renamedAtTheSameBuild() async throws {
        let cache = OfflineCountryDirectoryCache()
        var misspelled = california
        misspelled.names = ["en": "Californa"]

        await prepare(cache, catalog: 1, [austria, misspelled])
        await prepare(cache, catalog: 2, [austria, california])

        #expect(cache.builds == 2)
        let refreshed = try #require(cache.directory)
        #expect(refreshed.entries.map(\.country) == [austria, california])
        #expect(refreshed.areas(matching: "California") == [california])
    }

    @Test("an area downloaded and no longer offered is still listed")
    func keepsWhatIsNoLongerOffered() async throws {
        let cache = OfflineCountryDirectoryCache()
        let installed = ["ES": OfflineCountryStore.Record(country: spain, installedAt: .now)]

        await prepare(cache, catalog: 1, [austria, slovenia], installed: installed)

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

        await prepare(cache, catalog: 1, [austria, slovenia], near: ljubljana)

        #expect(log.ranOnMainThread == [false])
        #expect(cache.directory?.hasPosition == true)
    }

    // MARK: - While the next is measured

    @Test("the directory on screen stays there while the next is measured")
    func keepsTheLastWhileMeasuring() async {
        let gate = TestGate()
        let cache = cache(holding: { $0.offered.count == 3 }, at: gate)
        await prepare(cache, catalog: 1, [austria, slovenia])

        let refresh = Task { await prepare(cache, catalog: 2, [austria, slovenia, spain]) }
        await settleDelegateHop(until: "the new list to be measuring") { gate.isHolding }
        #expect(cache.directory?.entries.map(\.country) == [austria, slovenia])
        #expect(cache.shown == Key(catalog: 1, near: nil))

        gate.open()
        await refresh.value
        #expect(cache.directory?.entries.map(\.country) == [austria, slovenia, spain])
        #expect(cache.builds == 2)
    }

    /// The list comes up before the hiker's position is read, and the
    /// position is read as it does; the order measured with no position must
    /// not land over the one measured with it.
    @Test("a directory measured for a key since passed over is never put on screen")
    func supersededMeasuringIsDropped() async {
        let gate = TestGate()
        let cache = cache(holding: { $0.near == nil }, at: gate)

        let opening = Task { await prepare(cache, catalog: 1, [austria, slovenia]) }
        await settleDelegateHop(until: "the list with no position to be measuring") { gate.isHolding }
        await prepare(cache, catalog: 1, [austria, slovenia], near: ljubljana)
        #expect(cache.directory?.hasPosition == true)

        gate.open()
        await opening.value
        #expect(cache.directory?.hasPosition == true)
        #expect(cache.builds == 1)
    }

    /// The model's list can change after the task read it and before the
    /// body runs again to key a new task: a refresh landing, or an area
    /// downloaded, while the old list is measured.
    @Test("a directory measured from a list the model has moved on from is never put on screen")
    func outdatedMeasuringIsDropped() async {
        let cache = OfflineCountryDirectoryCache()

        await prepare(cache, catalog: 1, [austria, slovenia], isCurrent: { false })

        #expect(cache.directory == nil)
        #expect(cache.builds == 0)
    }

    @Test("a measuring whose task is cancelled is never put on screen, and the next task measures again")
    func cancelledMeasuringIsDropped() async {
        let gate = TestGate()
        let cache = cache(holding: { _ in true }, at: gate)

        let gone = Task { await prepare(cache, catalog: 1, [austria, slovenia]) }
        await settleDelegateHop(until: "the list to be measuring") { gate.isHolding }
        gone.cancel()
        gate.open()
        await gone.value
        #expect(cache.directory == nil)
        #expect(cache.builds == 0)

        await prepare(cache, catalog: 1, [austria, slovenia])
        #expect(cache.directory?.entries.map(\.country) == [austria, slovenia])
        #expect(cache.builds == 1)
    }

    /// A turn of the phone builds the list again in the other host, which
    /// asks for the key the first already drew when the hiker has not moved.
    @Test("a key already on screen is not measured again")
    func shownKeyIsNotMeasuredAgain() async {
        let log = ThreadLog()
        let cache = OfflineCountryDirectoryCache { source in
            log.note()
            return OfflineCountryDirectory.Measured(from: source)
        }

        await prepare(cache, catalog: 1, [austria, slovenia], near: ljubljana)
        await prepare(cache, catalog: 1, [austria, slovenia], near: ljubljana)

        #expect(log.ranOnMainThread.count == 1)
    }
}

// swiftlint:enable no_magic_numbers
