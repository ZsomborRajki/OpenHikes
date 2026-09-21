//
//  TrailPointStoreTests.swift
//  OpenHikesTests
//
//  What survives a search, what a refusal can draw from it, and what the
//  directory is allowed to grow to.
//
//  The case this exists for cannot be reached from the screen: three of five
//  first attempts came back `504` the day the feature was measured, and what a
//  hiker sees then is a caption and either an empty map or the places the same
//  valley answered with an hour ago. Which of those depends entirely on this
//  file, and nothing else can say so.
//
//  Every case runs against a directory of its own under the system's temporary
//  one and against a clock it holds, for the reason ``CuratedTrailStoreTests``
//  does: the default directory is the app's own `Caches`, and a suite that used
//  it would be asserting about whatever the last run left behind. The expiry
//  and the eviction would otherwise only be observable by waiting thirty days
//  or by fetching a few thousand elements from a volunteer-run API.
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
/// The on-disk half of what a place search found.
@Suite("Trail point store")
struct TrailPointStoreTests {
    static let centre = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.99)
    static let day: TimeInterval = 24 * 60 * 60
    static let kilometre: Double = 1000
    private static let metresPerDegreeLatitude: Double = 111_320

    /// A directory per case. Removed by the case that made it, so a failure
    /// leaves nothing behind for the next run to read.
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("trail-points-\(UUID().uuidString)")
    }

    /// One element standing `metresNorth` of ``centre``.
    static func found(
        _ id: Int64,
        metresNorth: Double = 0,
        type: String = "node",
        symbol: TrailPlaceSymbol = .water,
        name: String = ""
    ) -> FoundTrailPlace {
        FoundTrailPlace(
            elementType: type,
            elementID: id,
            place: TrailPlace(
                latitude: centre.latitude + metresNorth / metresPerDegreeLatitude,
                longitude: centre.longitude,
                name: name,
                symbol: symbol
            )
        )
    }

    static func area(radiusMeters: Double) -> CommunitySearchArea {
        CommunitySearchArea(coordinate: centre, radiusMeters: radiusMeters)
    }

    static func fileCount(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).count) ?? 0
    }
}
// swiftlint:enable convenience_type

// MARK: - What a refusal can draw

extension TrailPointStoreTests {
    /// The whole point: a valley that answered an hour ago has something to
    /// draw when the next search is refused.
    @Test("a stored place comes back near where it is")
    func aStoredPlaceSurvives() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrailPointStore(directory: directory, clock: { .now })
        let spring = Self.found(1, name: "Kalte Quelle")

        store.save([spring])

        let nearby = store.places(near: Self.area(radiusMeters: Self.kilometre), limit: 10)
        #expect(nearby.map(\.name) == ["Kalte Quelle"])
        #expect(nearby.first?.symbol == .water)
    }

    /// And a place in the next valley is not offered for this one. The store
    /// claims nothing about coverage, but what it hands back still has to be
    /// *near here*.
    @Test("a place outside the area is not offered")
    func aDistantPlaceIsNotOffered() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrailPointStore(directory: directory, clock: { .now })

        store.save([Self.found(1, metresNorth: 20 * Self.kilometre)])

        #expect(store.places(near: Self.area(radiusMeters: Self.kilometre), limit: 10).isEmpty)
    }

    /// Nearest the middle of the map first, which is the only order a
    /// directory of files can be read in — the line decides the rest, later
    /// and elsewhere. See ``TrailPointRanking``.
    @Test("the nearest are offered first, up to the limit")
    func theNearestComeFirst() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrailPointStore(directory: directory, clock: { .now })
        store.save([
            Self.found(1, metresNorth: 3 * Self.kilometre, name: "Far"),
            Self.found(2, metresNorth: Self.kilometre, name: "Near"),
            Self.found(3, metresNorth: 2 * Self.kilometre, name: "Middle"),
        ])

        let nearest = store.places(near: Self.area(radiusMeters: 5 * Self.kilometre), limit: 2)

        #expect(nearest.map(\.name) == ["Near", "Middle"])
    }

    /// Thirty days is the trust and the thirty-first is a re-fetch, for the
    /// reason the curated store gives: a hut that has been demolished should
    /// not be offered for ever.
    @Test("a place past its lifetime is not offered")
    func anExpiredPlaceIsDropped() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = TrailPointStore(directory: directory, clock: clock.read)
        store.save([Self.found(1)])
        let area = Self.area(radiusMeters: Self.kilometre)

        clock.advance(by: TrailPointStore.lifetime - Self.day)
        #expect(!store.places(near: area, limit: 10).isEmpty, "inside the horizon it is still trusted")

        clock.advance(by: Self.day * 2)
        #expect(store.places(near: area, limit: 10).isEmpty)
    }
}

// MARK: - One file per element

extension TrailPointStoreTests {
    /// **The same spring is the same row across searches.** Keyed by the OSM
    /// element rather than by a fresh `UUID`, a second search replaces the
    /// file it wrote the first time instead of offering the hiker the same
    /// hut twice.
    @Test("a second search replaces an element rather than duplicating it")
    func anElementIsStoredOnce() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrailPointStore(directory: directory, clock: { .now })

        store.save([Self.found(1, name: "Spring")])
        store.save([Self.found(1, name: "Kalte Quelle")])

        let nearby = store.places(near: Self.area(radiusMeters: Self.kilometre), limit: 10)
        #expect(nearby.map(\.name) == ["Kalte Quelle"], "the newer reading wins")
        #expect(Self.fileCount(in: directory) == 1)
    }

    /// A node and a way with the same number are two different things in two
    /// different places, so the type is part of the name.
    @Test("a node and a way with one id are two places")
    func theTypeIsPartOfTheName() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrailPointStore(directory: directory, clock: { .now })

        store.save([
            Self.found(1, type: "node", name: "Spring"),
            Self.found(1, type: "way", name: "Hut"),
        ])

        #expect(Self.fileCount(in: directory) == 2)
    }

    /// The element type comes off the wire, and a value carrying a separator
    /// would be a path this app writes wherever it was told to.
    @Test("an element type that is a path cannot become one")
    func aPathLikeTypeIsSanitised() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrailPointStore(directory: directory, clock: { .now })

        store.save([Self.found(1, type: "../../etc/node")])

        #expect(Self.fileCount(in: directory) == 1, "it is still written, and written here")
        #expect(
            !store.places(near: Self.area(radiusMeters: Self.kilometre), limit: 10).isEmpty,
            "and it is still readable"
        )
    }
}

// MARK: - Keeping the directory bounded

extension TrailPointStoreTests {
    /// A search is hundreds of elements, so a few valleys would grow this
    /// without bound — and what it drops has to be what nobody has looked at.
    ///
    /// The first batch shares one instant deliberately: the claim worth making
    /// is that the directory holds its ceiling and that the *newest* files
    /// survived, not which of a thousand simultaneous writes lost.
    @Test("the directory is trimmed to its ceiling, oldest first")
    func theDirectoryIsTrimmed() {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = TrailPointStore(directory: directory, clock: clock.read)
        let overflow = 5

        store.save((0..<TrailPointStore.maximumFiles).map { index in
            Self.found(Int64(index), metresNorth: Self.kilometre)
        })
        #expect(Self.fileCount(in: directory) == TrailPointStore.maximumFiles)

        for index in 0..<overflow {
            clock.advance(by: 1)
            store.save([
                Self.found(
                    Int64(TrailPointStore.maximumFiles + index),
                    name: "Newest \(index)"
                ),
            ])
        }

        #expect(Self.fileCount(in: directory) == TrailPointStore.maximumFiles)
        let nearest = store.places(near: Self.area(radiusMeters: Self.kilometre / 2), limit: overflow)
        #expect(
            nearest.count == overflow,
            "the five written last are the five closest, and all of them survived"
        )
    }
}
