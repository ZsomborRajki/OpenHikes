//
//  HikePlaceStagedPhotoTests.swift
//  OpenHikesTests
//
//  A photograph *Add Place* held until the place existed, filed at *Add*:
//  under the new place, at the place's own spot, through the same importer
//  every photograph takes. The *Places Around Trail* card files through the
//  same helper the moment a picture arrives, so its picks are held to the
//  same contract here.
//
//  A picked picture keeps the moment it was taken, read out of its own bytes
//  the way the pill's picker reads it (#1188): filed by *Add* minutes or days
//  later, it is still the photograph it was, and ``HikePhoto/capturedAt`` is
//  what orders the gallery, groups a walk's share card and dates its exported
//  waypoint. The place stays the only word on where it is pinned.
//

import CoreLocation
import Foundation
import ImageIO
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite("Add Place's held photographs")
struct HikePlaceStagedPhotoTests {
    private static let route = [
        RouteCoordinate(latitude: 47.60, longitude: 12.98),
        RouteCoordinate(latitude: 47.62, longitude: 12.98),
    ]
    private static let spot = CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98)
    /// On the line but a long way along it from ``spot``: where the pill's
    /// picker would snap a camera that stood here, had the place not said
    /// otherwise.
    private static let elsewhereOnTheTrail = CLLocationCoordinate2D(latitude: 47.602, longitude: 12.98)

    /// Nepal's offset, far from any zone these suites are run in: a reader
    /// that ignored the file's own offset and read the wall clock in the
    /// device's zone would land hours away from ``takenAt``.
    nonisolated private static let wallClock = "2020:06:15 16:15:00"
    nonisolated private static let offset = "+05:45"
    private static let takenAt = Date(timeIntervalSince1970: 1_592_217_000) // 2020-06-15T10:30:00Z

    /// A small JPEG, drawn here rather than through ``HikePhotoStore/encode(_:)``,
    /// which asserts it is off the main actor these tests run on.
    nonisolated private static func jpeg() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
        #else
        return Data()
        #endif
    }

    /// The same picture as a camera writes it: its wall clock with the offset
    /// beside it, and a GPS block when the camera had a position.
    nonisolated private static func exifJPEG(cameraAt camera: CLLocationCoordinate2D? = nil) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(jpeg() as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: wallClock,
                kCGImagePropertyExifOffsetTimeOriginal as String: offset,
            ],
        ]
        if let camera {
            properties[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: abs(camera.latitude),
                kCGImagePropertyGPSLatitudeRef as String: camera.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude as String: abs(camera.longitude),
                kCGImagePropertyGPSLongitudeRef as String: camera.longitude < 0 ? "W" : "E",
            ]
        }
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func store() -> HikePhotoStore {
        HikePhotoStore(
            storageRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("staged-place-photos-\(UUID().uuidString)")
        )
    }

    /// A hike with one place on it, the way *Add* or the card's **Add** leaves it.
    private static func hikeWithPlace(in context: ModelContext) -> (Hike, TrailPlace) {
        let hike = Fixture.hike(in: context, route: route)
        let place = HikePlaceDraft().place(at: HikePlaceSpot(spot))
        #expect(hike.addPlace(place, in: context))
        return (hike, place)
    }

    private static func file(_ staged: HikePlaceStagedPhoto, under place: TrailPlace, of hike: Hike) async
        -> PhotoCaptureState.Failure? {
        await staged.file(
            under: place,
            of: hike,
            savesCapturesToPhotoLibrary: false,
            store: store(),
            save: { _ in /* in memory */ }
        )
    }

    @Test("a picked picture is filed under the new place, at the place, keeping its library identity")
    func pickedPictureFilesUnderThePlace() async throws {
        let context = try Fixture.modelContext()
        let (hike, place) = Self.hikeWithPlace(in: context)
        let staged = HikePlaceStagedPhoto(
            source: .picked(Self.jpeg(), assetLocalIdentifier: "asset-7"),
            thumbnail: nil
        )

        let failure = await Self.file(staged, under: place, of: hike)

        #expect(failure == nil)
        let photo = try #require(hike.photos(ofPlace: place.id).first)
        #expect(photo.assetLocalIdentifier == "asset-7")
        #expect(photo.latitude == place.latitude)
        #expect(photo.longitude == place.longitude)
    }

    /// Held in *Add Place*'s strip and filed at *Add*: dated by the shutter,
    /// in the zone the file names, rather than by the tap on *Add*.
    @Test("a picture held by Add Place keeps the capture time its file carries")
    func heldPickKeepsItsCaptureTime() async throws {
        let session = HikePlaceAdderSession()
        let data = try Self.exifJPEG()
        await session.stage(picks: [.init(assetLocalIdentifier: "asset-7") { data }]).value
        let staged = try #require(session.photos.first)
        let context = try Fixture.modelContext()
        let (hike, place) = Self.hikeWithPlace(in: context)

        let failure = await Self.file(staged, under: place, of: hike)

        #expect(failure == nil)
        let photo = try #require(hike.photos(ofPlace: place.id).first)
        #expect(photo.capturedAt == Self.takenAt)
        #expect(photo.assetLocalIdentifier == "asset-7")
        #expect(photo.matchEvidence == nil, "a place's screen is the app's own answer, with nothing to explain")
    }

    /// What the *Places Around Trail* card hands over: no thumbnail, filed at
    /// once. The camera's own position is on the trail, and the pill's picker
    /// would have snapped it there; under a place, the place is where it is.
    @Test("a picture picked on the place card keeps its capture time and is pinned at the place")
    func cardPickKeepsItsCaptureTimeAtThePlace() async throws {
        let context = try Fixture.modelContext()
        let (hike, place) = Self.hikeWithPlace(in: context)
        let data = try Self.exifJPEG(cameraAt: Self.elsewhereOnTheTrail)
        let staged = HikePlaceStagedPhoto(source: .picked(data, assetLocalIdentifier: "asset-9"), thumbnail: nil)

        let failure = await Self.file(staged, under: place, of: hike)

        #expect(failure == nil)
        let photo = try #require(hike.photos(ofPlace: place.id).first)
        #expect(photo.capturedAt == Self.takenAt)
        #expect(photo.latitude == place.latitude)
        #expect(photo.longitude == place.longitude)
        #expect(photo.matchEvidence == nil)
    }

    /// A screenshot, or a file the picker stripped: nothing to read, so it is
    /// dated the way the pill's picker dates one, by its import.
    @Test("a picked picture with no capture time is dated by its import")
    func bareTimelessPickIsDatedByItsImport() async throws {
        let context = try Fixture.modelContext()
        let (hike, place) = Self.hikeWithPlace(in: context)
        let staged = HikePlaceStagedPhoto(
            source: .picked(Self.jpeg(), assetLocalIdentifier: "asset-7"),
            thumbnail: nil
        )
        let before = Date.now

        let failure = await Self.file(staged, under: place, of: hike)

        let after = Date.now
        #expect(failure == nil)
        let photo = try #require(hike.photos(ofPlace: place.id).first)
        #expect(photo.capturedAt >= before)
        #expect(photo.capturedAt <= after)
    }

    /// Already on the walk — from the pill's picker or a library scan, both
    /// of which date it by its shutter — then picked again for a place: the
    /// same photograph moves under the place, with the date it came in with,
    /// and no second copy.
    @Test("a picture the hike already holds is refiled under the place with its own date")
    func pickedAgainIsRefiledWithItsDate() async throws {
        let context = try Fixture.modelContext()
        let (hike, place) = Self.hikeWithPlace(in: context)
        let data = try Self.exifJPEG()
        let first = try #require(
            await HikePhotoImport.add(
                data,
                to: hike,
                coordinate: Self.elsewhereOnTheTrail,
                savesToPhotoLibrary: false,
                capturedAt: Self.takenAt,
                assetLocalIdentifier: "asset-7",
                store: Self.store(),
                save: { _ in /* in memory */ }
            )
        )
        #expect(first.placeID == nil)
        let staged = HikePlaceStagedPhoto(source: .picked(data, assetLocalIdentifier: "asset-7"), thumbnail: nil)

        let failure = await Self.file(staged, under: place, of: hike)

        #expect(failure == nil)
        #expect(hike.photos.map(\.id) == [first.id], "the same photograph, not a second copy")
        let refiled = try #require(hike.photos(ofPlace: place.id).first)
        #expect(refiled.id == first.id)
        #expect(refiled.capturedAt == Self.takenAt)
    }

    @Test("bytes that are not a picture are reported as an import that failed")
    func unreadableBytesAreAFailedImport() async throws {
        let context = try Fixture.modelContext()
        let (hike, place) = Self.hikeWithPlace(in: context)
        let staged = HikePlaceStagedPhoto(
            source: .picked(Data("not a picture".utf8), assetLocalIdentifier: nil),
            thumbnail: nil
        )

        let failure = await Self.file(staged, under: place, of: hike)

        #expect(failure == .importFailed)
        #expect(hike.photos.isEmpty)
    }
}
