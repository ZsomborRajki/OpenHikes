//
//  OrderedHikePhotosTests.swift
//  OpenHikesTests
//
//  The gallery's order, sorted once and kept while nothing that decides it
//  moves: a page turned or a question opened is a body pass that reads it
//  again, and must not sort the hike again. A photograph added or removed,
//  or one whose time sync changed, is a new order.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Ordered hike photos")
struct OrderedHikePhotosTests {
    private static let baseTimestamp: TimeInterval = 1_750_000_000
    private static let minute: TimeInterval = 60

    private static func photo(minutesIn offset: Double) -> HikePhoto {
        HikePhoto(capturedAt: Date(timeIntervalSince1970: baseTimestamp + offset * minute))
    }

    /// A hike with photographs taken 30, 5 and 15 minutes in, added in that
    /// order.
    private static func hike() throws -> (Hike, [HikePhoto]) {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photos = [photo(minutesIn: 30), photo(minutesIn: 5), photo(minutesIn: 15)]
        for photo in photos { hike.addPhoto(photo) }
        return (hike, photos)
    }

    @Test("the order is the hike's own, and reading it again sorts nothing")
    func readsWithoutSorting() throws {
        let (hike, photos) = try Self.hike()
        let ordering = OrderedHikePhotos()

        let first = ordering.photos(of: hike)
        let second = ordering.photos(of: hike)
        let third = ordering.photos(of: hike)

        #expect(first.map(\.id) == hike.orderedPhotos.map(\.id))
        #expect(first.map(\.id) == [photos[1].id, photos[2].id, photos[0].id])
        #expect(second.map(\.id) == first.map(\.id))
        #expect(third.map(\.id) == first.map(\.id))
        #expect(ordering.sorts == 1)
    }

    @Test("a photograph's place in the order is read without a search")
    func positions() throws {
        let (hike, photos) = try Self.hike()
        let ordering = OrderedHikePhotos()
        _ = ordering.photos(of: hike)

        #expect(ordering.index(of: photos[1].id) == 0)
        #expect(ordering.index(of: photos[2].id) == 1)
        #expect(ordering.index(of: photos[0].id) == 2)
        #expect(ordering.index(of: nil) == nil)
        #expect(ordering.index(of: UUID()) == nil)
    }

    @Test("a photograph added is a new order")
    func added() throws {
        let (hike, _) = try Self.hike()
        let ordering = OrderedHikePhotos()
        _ = ordering.photos(of: hike)
        let earliest = Self.photo(minutesIn: 1)

        hike.addPhoto(earliest)
        let after = ordering.photos(of: hike)

        #expect(ordering.sorts == 2)
        #expect(after.first?.id == earliest.id)
        #expect(ordering.index(of: earliest.id) == 0)
    }

    @Test("a photograph removed is a new order, without it")
    func removed() throws {
        let (hike, photos) = try Self.hike()
        let ordering = OrderedHikePhotos()
        _ = ordering.photos(of: hike)

        hike.removePhoto(id: photos[2].id)
        let after = ordering.photos(of: hike)

        #expect(ordering.sorts == 2)
        #expect(after.map(\.id) == [photos[1].id, photos[0].id])
        #expect(ordering.index(of: photos[2].id) == nil)
        #expect(ordering.index(of: photos[0].id) == 1)
    }

    /// What sync can bring: the same photograph, taken at another time.
    @Test("a photograph whose time changed is a new order")
    func redated() throws {
        let (hike, photos) = try Self.hike()
        let ordering = OrderedHikePhotos()
        _ = ordering.photos(of: hike)

        let index = try #require(hike.photos.firstIndex { $0.id == photos[0].id })
        hike.photos[index].capturedAt = Date(timeIntervalSince1970: Self.baseTimestamp)
        let after = ordering.photos(of: hike)

        #expect(ordering.sorts == 2)
        #expect(after.map(\.id) == [photos[0].id, photos[1].id, photos[2].id])
    }

    /// A photograph is a value: one kept past a change would draw the old
    /// one, so any change hands out the photograph as it is now.
    @Test("a photograph changed in another way is handed out as it is now")
    func changedOtherwise() throws {
        let (hike, photos) = try Self.hike()
        let ordering = OrderedHikePhotos()
        _ = ordering.photos(of: hike)
        let place = UUID()

        hike.filePhoto(id: photos[2].id, underPlace: place)
        let after = ordering.photos(of: hike)

        #expect(after.first { $0.id == photos[2].id }?.placeID == place)
        #expect(after.map(\.id) == [photos[1].id, photos[2].id, photos[0].id])
    }

    @Test("an empty hike is an empty order, and sorts nothing")
    func empty() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let ordering = OrderedHikePhotos()

        #expect(ordering.photos(of: hike).isEmpty)
        #expect(ordering.sorts == 0)
    }
}
