//
//  CuratedTrailStoreTests.swift
//  OpenHikesTests
//
//  What survives a launch, what expires, and what the directory is allowed to
//  grow to.
//
//  Every case here runs against a directory of its own under the system's
//  temporary one and against a clock the case holds, for the reason every
//  other cache suite in this repository does — see *Deliberate test seams* in
//  the instructions. The default directory is the app's own `Caches`, and a
//  suite that used it would be asserting about whatever the last run left
//  behind.
//
//  The expiry and the eviction are the two that would otherwise only be
//  observable by waiting thirty days or by downloading two hundred routes from
//  a volunteer-run API.
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
/// The on-disk half of the curated cache.
@Suite("Curated trail store")
struct CuratedTrailStoreTests {
    private static let centre = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.99)
    private static let metresPerDegreeLatitude: Double = 111_320
    private static let day: TimeInterval = 24 * 60 * 60

    /// A directory per case. Removed by the case that made it, so a failure
    /// leaves nothing behind for the next run to read.
    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curated-store-\(UUID().uuidString)")
    }

    /// A route whose box — and so whose pin — stands `metresNorth` of
    /// ``centre``.
    private static func trail(_ relationID: Int64, metresNorth: Double) -> CuratedTrail {
        let halfSpan = 0.004
        let latitude = centre.latitude + metresNorth / metresPerDegreeLatitude
        let box = CuratedTrailQuery.BoundingBox(
            south: latitude - halfSpan,
            west: centre.longitude - halfSpan,
            north: latitude + halfSpan,
            east: centre.longitude + halfSpan
        )
        return CuratedTrail(
            relationID: relationID,
            name: "Relation \(relationID)",
            tags: ["route": "hiking", "name": "Relation \(relationID)"],
            box: box,
            route: [
                RouteCoordinate(latitude: box.south, longitude: box.west),
                RouteCoordinate(latitude: box.north, longitude: box.east),
            ]
        )
    }

    private static func area(radiusMeters: Double) -> CommunitySearchArea {
        CommunitySearchArea(coordinate: centre, radiusMeters: radiusMeters)
    }
}
// swiftlint:enable convenience_type

// MARK: - Surviving a launch

extension CuratedTrailStoreTests {
    /// The whole point: a route downloaded once is not downloaded again, and
    /// the line is what makes that worth doing — 420 KB to 1.4 MB a page.
    @Test("a stored route comes back whole")
    func aStoredRouteSurvives() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CuratedTrailStore(directory: directory, clock: { .now })
        let trail = Self.trail(4_811_001, metresNorth: 0)

        store.save(trail)

        #expect(store.trail(of: trail.relationID) == trail)
    }

    /// A relation nobody has asked about is not an error and not an empty
    /// route — it is nothing, and the caller goes to Overpass.
    @Test("a relation that was never stored answers nothing")
    func anUnknownRelationIsNil() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CuratedTrailStore(directory: directory, clock: { .now })

        #expect(store.trail(of: 4_811_001) == nil)
    }

    /// Thirty days is the trust, and the thirty-first is a re-download. OSM's
    /// geometry moves when somebody maps a re-route, and a cache with no
    /// horizon would draw the old line for good.
    @Test("a route past its lifetime is not answered with")
    func anExpiredRouteIsDropped() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = CuratedTrailStore(directory: directory, clock: clock.read)
        store.save(Self.trail(4_811_001, metresNorth: 0))

        clock.advance(by: CuratedTrailStore.lifetime - Self.day)
        #expect(store.trail(of: 4_811_001) != nil, "inside the horizon it is still trusted")

        clock.advance(by: Self.day * 2)
        #expect(store.trail(of: 4_811_001) == nil)
    }
}

// MARK: - Keeping the directory bounded

extension CuratedTrailStoreTests {
    /// A long browse must not grow the cache without bound, and what it drops
    /// must be what nobody is looking at. The clock is what makes the order
    /// assertable at all: written in one turn, these files would share a
    /// modification date to the resolution of the file system.
    @Test("the directory is trimmed to its ceiling, oldest first")
    func theDirectoryIsTrimmed() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = CuratedTrailStore(directory: directory, clock: clock.read)
        let overflow = 5
        for index in 0..<(CuratedTrailStore.maximumFiles + overflow) {
            clock.advance(by: 1)
            store.save(Self.trail(Int64(4_811_001 + index), metresNorth: 0))
        }

        let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(files?.count == CuratedTrailStore.maximumFiles)
        #expect(store.trail(of: 4_811_001) == nil, "the first written is the first dropped")
        #expect(
            store.trail(of: Int64(4_811_000 + CuratedTrailStore.maximumFiles + overflow)) != nil,
            "the newest is kept"
        )
    }

    /// Least recently *used*, which is the claim the re-stamp on a read makes
    /// true. Without it the routes a hiker keeps coming back to would be the
    /// oldest files in the directory and the first trim would take exactly
    /// those.
    @Test("reading a route keeps it out of the eviction window")
    func readingKeepsARouteAlive() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = CuratedTrailStore(directory: directory, clock: clock.read)
        let favourite: Int64 = 4_811_001
        store.save(Self.trail(favourite, metresNorth: 0))
        for index in 1..<CuratedTrailStore.maximumFiles {
            clock.advance(by: 1)
            store.save(Self.trail(Int64(4_811_001 + index), metresNorth: 0))
        }

        // Read it, then fill the directory past its ceiling.
        clock.advance(by: 1)
        #expect(store.trail(of: favourite) != nil)
        let overflow = 5
        for index in 0..<overflow {
            clock.advance(by: 1)
            store.save(Self.trail(Int64(4_812_001 + index), metresNorth: 0))
        }

        #expect(store.trail(of: favourite) != nil)
    }
}

// MARK: - What is already here, near there

extension CuratedTrailStoreTests {
    /// What a refused search draws. Ordered like every other curated answer —
    /// nearest first — so the rows the limit keeps are the ones worth keeping.
    @Test("stored routes near an area come back nearest first")
    func storedRoutesAnswerByDistance() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CuratedTrailStore(directory: directory, clock: { .now })
        store.save(Self.trail(4_811_003, metresNorth: 3000))
        store.save(Self.trail(4_811_001, metresNorth: 1000))
        store.save(Self.trail(4_811_002, metresNorth: 2000))

        let near = store.trails(near: Self.area(radiusMeters: 20_000), limit: 25)

        #expect(near.map(\.relationID) == [4_811_001, 4_811_002, 4_811_003])
    }

    /// The area is a claim about *where*, and a cache full of the Alps must
    /// not answer a search in Scotland with them — the failure
    /// ``CuratedTrailSource/lastArea`` exists against, one layer down.
    @Test("a route outside the area is left out")
    func routesOutsideTheAreaAreLeftOut() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CuratedTrailStore(directory: directory, clock: { .now })
        store.save(Self.trail(4_811_001, metresNorth: 1000))
        store.save(Self.trail(4_811_009, metresNorth: 90_000))

        let near = store.trails(near: Self.area(radiusMeters: 20_000), limit: 25)

        #expect(near.map(\.relationID) == [4_811_001])
    }

    /// The limit is a page, and this path is reached when something has
    /// already failed — it is not the moment to hand back four hundred rows.
    @Test("the limit is honoured")
    func theLimitIsHonoured() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CuratedTrailStore(directory: directory, clock: { .now })
        for index in 0..<10 {
            store.save(Self.trail(Int64(4_811_001 + index), metresNorth: Double(index + 1) * 100))
        }

        let near = store.trails(near: Self.area(radiusMeters: 20_000), limit: 3)

        #expect(near.count == 3)
    }

    /// An expired file is not a stale answer either, on the path that reads
    /// every file rather than one.
    @Test("an expired route is not offered to a refused search")
    func expiredRoutesAreNotOffered() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = CuratedTrailStore(directory: directory, clock: clock.read)
        store.save(Self.trail(4_811_001, metresNorth: 1000))

        clock.advance(by: CuratedTrailStore.lifetime + Self.day)

        #expect(store.trails(near: Self.area(radiusMeters: 20_000), limit: 25).isEmpty)
    }

    /// A directory that was never written to is an empty answer rather than a
    /// failure: this is the state of every launch before the first search.
    @Test("an empty cache answers with nothing")
    func anEmptyCacheAnswersWithNothing() {
        let store = CuratedTrailStore(directory: Self.scratch(), clock: { .now })

        #expect(store.trails(near: Self.area(radiusMeters: 20_000), limit: 25).isEmpty)
    }
}
