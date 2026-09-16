//
//  HikePhotoTests.swift
//  OpenHikesTests
//
//  The metadata side: what a `Hike` does with the photos attached to it, and
//  what the pill's controller does when two screens overlap.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike photos")
struct HikePhotoTests {
    private static let baseTimestamp: TimeInterval = 1_750_000_000
    private static let minute: TimeInterval = 60
    private static let latitude: Double = 47.63
    private static let longitude: Double = 12.86

    private static func photo(minutesIn offset: Double) -> HikePhoto {
        HikePhoto(
            capturedAt: Date(timeIntervalSince1970: baseTimestamp + offset * minute)
        )
    }

    @Test("a hike starts with no photos and says so")
    func startsEmpty() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(hike.hasPhotos == false)
        #expect(hike.orderedPhotos.isEmpty)
    }

    @Test("photos read back oldest first regardless of the order they arrived")
    func ordersByCaptureTime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        // An import hands several assets over at once and in no useful order,
        // which is exactly the case `orderedPhotos` exists for.
        let later = Self.photo(minutesIn: 30)
        let earlier = Self.photo(minutesIn: 5)
        hike.addPhoto(later)
        hike.addPhoto(earlier)

        #expect(hike.orderedPhotos.map(\.id) == [earlier.id, later.id])
    }

    @Test("two photos captured in the same instant still have a stable order")
    func tiesBreakDeterministically() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let first = Self.photo(minutesIn: 0)
        let second = Self.photo(minutesIn: 0)
        hike.addPhoto(first)
        hike.addPhoto(second)

        // Whatever the order is, asking twice has to give the same answer —
        // the viewer's "next" button pages through this array.
        let firstPass = hike.orderedPhotos.map(\.id)
        let secondPass = hike.orderedPhotos.map(\.id)
        #expect(firstPass == secondPass)
        let expected = [first, second]
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map(\.id)
        #expect(hike.orderedPhotos.map(\.id) == expected)
    }

    @Test("adding the same photo twice adds it once")
    func addIsIdempotent() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = Self.photo(minutesIn: 0)

        hike.addPhoto(photo)
        hike.addPhoto(photo)

        #expect(hike.photos.count == 1)
    }

    @Test("removing a photo hands it back so its files can be deleted")
    func removeReturnsThePhoto() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = Self.photo(minutesIn: 0)
        hike.addPhoto(photo)

        let removed = hike.removePhoto(id: photo.id)

        #expect(removed?.id == photo.id)
        #expect(hike.hasPhotos == false)
    }

    @Test("removing a photo that isn't there reports nothing to delete")
    func removeUnknownReturnsNil() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(hike.removePhoto(id: UUID()) == nil)
    }

    @Test("an anchored photo keeps the coordinate it was pinned to")
    func anchorRoundTrips() {
        let coordinate = CLLocationCoordinate2D(
            latitude: Self.latitude,
            longitude: Self.longitude
        )
        let photo = HikePhoto(coordinate: coordinate)

        #expect(photo.isAnchored)
        #expect(photo.coordinate?.latitude == coordinate.latitude)
        #expect(photo.coordinate?.longitude == coordinate.longitude)
    }

    @Test("the file name carries the format the bytes really were")
    func fileNameUsesStoredExtension() {
        let photo = HikePhoto(pathExtension: "heic")

        #expect(photo.fileName == "\(photo.id.uuidString).heic")
        // The thumbnail is re-derivable, so it is always JPEG regardless —
        // under the extension `ImageDataFormat.detect(in:)` gives JPEG bytes,
        // which is `jpeg` rather than `jpg`. The two must not drift: one is
        // what a thumbnail is written as, the other is what it is looked up
        // by.
        #expect(photo.thumbnailFileName == "\(photo.id.uuidString).jpeg")
        #expect(ImageDataFormat.jpeg.pathExtension == "jpeg")
    }
}
