//
//  OverpassFileStoreTests.swift
//  OpenHikesTests
//
//  What a directory of Overpass answers makes of a file that is not one of
//  its own: the staged half of an `.atomic` write.
//
//  On iOS 27 and macOS, `Data.write(to:options: .atomic)` stages its bytes in
//  a sibling named `<name>.sb-<hex>-<random>` and then renames it into place,
//  and that sibling is not hidden. A listing taken while a save is under way
//  sees it, and one taken after a save was killed before its rename sees it
//  for good. Neither moment can be reached on cue from a real write, so each
//  case lays the sibling down by hand, named the way the system names it, and
//  dates it on the clock the store is given.
//
//  The store is driven directly, with an entry type of this suite's own and a
//  ceiling of a few files, rather than through ``TrailPointStore`` or
//  ``CuratedTrailStore``: what is asserted is the directory's behavior, which
//  every store built on it shares, and a ceiling of twelve hundred would be
//  twelve hundred writes to reach. Every case runs against a directory of its
//  own under the system's temporary one, for the reason those stores' suites
//  give.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

// The body holds only fixtures; every test is in one of the extensions below.
// A caseless enum is what `convenience_type` normally asks for and is not
// available here — Swift Testing attaches a suite to a type it can
// instantiate.
// swiftlint:disable convenience_type
/// How an Overpass cache's directory treats a staged file beside its own.
@Suite("Overpass file store staging")
struct OverpassFileStoreTests {
    static let center = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.99)
    static let radiusMeters: Double = 1000
    /// What the system appends to a file's name while it stages a write of it.
    static let stagingSuffix = ".sb-5f3e2a1c-Qx7Lm2"

    /// The smallest thing a store can keep: a name, standing at ``center``.
    ///
    /// Internal rather than private for the reason ``CuratedTrailStore``'s
    /// `StoredTrail` is: a `private` generic argument crashes Swift 6.4's
    /// IRGen.
    nonisolated struct Spot: OverpassFileEntry {
        let fetchedAt: Date
        let value: String
    }

    /// A directory per case. Removed by the case that made it, so a failure
    /// leaves nothing behind for the next run to read.
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("overpass-files-\(UUID().uuidString)")
    }

    static func store(
        in directory: URL,
        clock: TestClock,
        keeping maximumFiles: Int = 10
    ) -> OverpassFileStore<Spot> {
        OverpassFileStore(directory: directory, maximumFiles: maximumFiles, clock: clock.read)
    }

    /// Lays a whole copy of `name`'s file down beside it, under the name an
    /// `.atomic` write stages it as, last written at `date`.
    @discardableResult static func stage(_ name: String, in directory: URL, at date: Date) throws -> URL {
        let file = directory.appendingPathComponent("\(name).json")
        let staged = directory.appendingPathComponent("\(name).json\(stagingSuffix)")
        try FileManager.default.copyItem(at: file, to: staged)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: staged.path)
        return staged
    }

    /// Every stored value within reach of ``center``.
    static func offered(by store: OverpassFileStore<Spot>) -> [String] {
        let here = center
        return store.values(
            near: CommunitySearchArea(coordinate: here, radiusMeters: radiusMeters),
            limit: 10
        ) { _ in here }
    }
}
// swiftlint:enable convenience_type

// MARK: - Reading

extension OverpassFileStoreTests {
    /// A whole file staged and not yet renamed decodes as well as the one it
    /// is about to replace, so a listing that opened it would hand the same
    /// value back twice.
    @Test("a staged copy of a file is not offered beside it")
    func aStagedCopyIsNotOffered() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = Self.store(in: directory, clock: clock)
        store.save([(name: "spring", value: "Kalte Quelle")])
        try Self.stage("spring", in: directory, at: clock.now)

        #expect(Self.offered(by: store) == ["Kalte Quelle"])
    }
}

// MARK: - The trim

extension OverpassFileStoreTests {
    /// The ceiling is a number of stored answers. Counting a staged file
    /// toward it, a directory holding exactly as many as it may would drop
    /// the oldest of them on a save that added nothing.
    @Test("a staged file does not count toward the ceiling")
    func aStagedFileIsNotCounted() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = Self.store(in: directory, clock: clock, keeping: 2)
        store.save([(name: "spring", value: "Kalte Quelle")])
        clock.advance(by: 1)
        store.save([(name: "hut", value: "Kärlingerhaus")])
        clock.advance(by: 1)
        try Self.stage("hut", in: directory, at: clock.now)

        clock.advance(by: 1)
        store.save([(name: "hut", value: "Kärlingerhaus")])

        #expect(store.value(named: "spring") == "Kalte Quelle", "two answers fit a ceiling of two")
    }

    /// A save killed between its write and its rename leaves the staged file
    /// behind for good, and nothing that reads the store would ever open it
    /// again. One written a moment ago may still be renamed into place, so
    /// it stays: what tells the two apart is how long ago each was written.
    @Test("a staged file a killed save left goes at the next save, and a fresh one stays")
    func aLeftoverStagedFileIsSwept() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = Self.store(in: directory, clock: clock)
        store.save([(name: "spring", value: "Kalte Quelle"), (name: "hut", value: "Kärlingerhaus")])
        let leftover = try Self.stage("spring", in: directory, at: clock.now)
        clock.advance(by: OverpassCache.stagedWriteLifetime + 1)
        let inFlight = try Self.stage("hut", in: directory, at: clock.now)

        store.save([(name: "bench", value: "Rastbank")])

        #expect(!FileManager.default.fileExists(atPath: leftover.path), "the leftover is deleted")
        #expect(FileManager.default.fileExists(atPath: inFlight.path), "a write still under way is not")
        #expect(Self.offered(by: store).sorted() == ["Kalte Quelle", "Kärlingerhaus", "Rastbank"])
    }
}
