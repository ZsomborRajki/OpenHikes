//
//  HikePlaceStagedPhotoTests.swift
//  OpenHikesTests
//
//  A photograph *Add Place* held until the place existed, filed at *Add*:
//  under the new place, at the place's own spot, through the same importer
//  every photograph takes.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing
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

    private static func store() -> HikePhotoStore {
        HikePhotoStore(
            storageRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("staged-place-photos-\(UUID().uuidString)")
        )
    }

    @Test("a picked picture is filed under the new place, at the place, keeping its library identity")
    func pickedPictureFilesUnderThePlace() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let place = HikePlaceDraft().place(at: HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98)))
        #expect(hike.addPlace(place, in: context))
        let staged = HikePlaceStagedPhoto(
            source: .picked(Self.jpeg(), assetLocalIdentifier: "asset-7"),
            thumbnail: nil
        )

        let failure = await staged.file(
            under: place,
            of: hike,
            savesCapturesToPhotoLibrary: false,
            store: Self.store(),
            save: { _ in /* in memory */ }
        )

        #expect(failure == nil)
        let photo = try #require(hike.photos(ofPlace: place.id).first)
        #expect(photo.assetLocalIdentifier == "asset-7")
        #expect(photo.latitude == place.latitude)
        #expect(photo.longitude == place.longitude)
    }

    @Test("bytes that are not a picture are reported as an import that failed")
    func unreadableBytesAreAFailedImport() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let place = HikePlaceDraft().place(at: HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98)))
        #expect(hike.addPlace(place, in: context))
        let staged = HikePlaceStagedPhoto(
            source: .picked(Data("not a picture".utf8), assetLocalIdentifier: nil),
            thumbnail: nil
        )

        let failure = await staged.file(
            under: place,
            of: hike,
            savesCapturesToPhotoLibrary: false,
            store: Self.store(),
            save: { _ in /* in memory */ }
        )

        #expect(failure == .importFailed)
        #expect(hike.photos.isEmpty)
    }
}
