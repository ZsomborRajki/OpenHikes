//
//  HikePhotoPlaceTests.swift
//  OpenHikesTests
//
//  A photograph filed under one of a hike's places.
//
//  The link is a key in the `CD_photos` blob, so the half worth pinning first
//  is that every photograph written before it existed still decodes — one
//  throw there loses a hike's whole gallery, not one field. The rest is the
//  path a picture takes from a place's screen: the camera pill carries the
//  place, the import files under it only if it is still there, and a picture
//  the hike already holds is re-filed rather than copied again.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite("Photos of a place")
struct HikePhotoPlaceTests {
    private enum Line {
        static let route = [
            RouteCoordinate(latitude: 47.60, longitude: 12.98),
            RouteCoordinate(latitude: 47.62, longitude: 12.98),
        ]
    }

    private static let spring = TrailPlace(latitude: 47.61, longitude: 12.98, symbol: .water)

    /// A small JPEG, drawn here rather than through ``HikePhotoStore/encode(_:)``,
    /// which asserts it is off the main actor these tests run on.
    nonisolated private static func jpeg() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
        #else
        return Data()
        #endif
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("place-photos-\(UUID().uuidString)")
    }

    private func hike() throws -> (Hike, ModelContext) {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Line.route)
        hike.replacePlaces(with: [Self.spring], in: context)
        return (hike, context)
    }

    @Test("a photograph written before places had photographs still decodes")
    func oldBlobDecodes() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","capturedAt":0,"pathExtension":"jpeg"}]"#
        let photos = try JSONDecoder().decode([HikePhoto].self, from: Data(old.utf8))
        #expect(photos.count == 1)
        #expect(photos.first?.placeID == nil)
    }

    @Test("the link survives an encode and decode")
    func linkRoundTrips() throws {
        var photo = HikePhoto()
        photo.placeID = Self.spring.id
        let data = try JSONEncoder().encode([photo])
        let back = try JSONDecoder().decode([HikePhoto].self, from: data)
        #expect(back.first?.placeID == Self.spring.id)
    }

    @Test("a place's photographs are the ones filed under it, in gallery order")
    func photosOfAPlace() throws {
        let (hike, _) = try hike()
        var later = HikePhoto(capturedAt: Date(timeIntervalSince1970: 200))
        later.placeID = Self.spring.id
        var earlier = HikePhoto(capturedAt: Date(timeIntervalSince1970: 100))
        earlier.placeID = Self.spring.id
        hike.addPhoto(later)
        hike.addPhoto(HikePhoto(capturedAt: Date(timeIntervalSince1970: 150)))
        hike.addPhoto(earlier)

        #expect(hike.photos(ofPlace: Self.spring.id).map(\.id) == [earlier.id, later.id])
    }

    @Test("a picture added from a place's screen is filed under the place")
    func addFilesUnderPlace() async throws {
        let (hike, _) = try hike()
        let store = HikePhotoStore(storageRoot: Self.temporaryRoot())

        let photo = await HikePhotoImport.add(
            Self.jpeg(),
            to: hike,
            coordinate: Self.spring.clCoordinate,
            savesToPhotoLibrary: false,
            placeID: Self.spring.id,
            store: store,
            save: { _ in /* in memory */ }
        )

        #expect(photo?.placeID == Self.spring.id)
        #expect(hike.photos(ofPlace: Self.spring.id).count == 1)
    }

    @Test("a picture meant for a place that has gone is filed under the walk")
    func addForGonePlace() async throws {
        let (hike, _) = try hike()
        let store = HikePhotoStore(storageRoot: Self.temporaryRoot())

        let photo = await HikePhotoImport.add(
            Self.jpeg(),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            placeID: UUID(),
            store: store,
            save: { _ in /* in memory */ }
        )

        #expect(photo != nil)
        #expect(photo?.placeID == nil)
    }

    @Test("picking again a picture the hike holds files it under the place")
    func pickingAgainRefiles() async throws {
        let (hike, _) = try hike()
        let store = HikePhotoStore(storageRoot: Self.temporaryRoot())
        let data = Self.jpeg()
        _ = await HikePhotoImport.add(
            data,
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            assetLocalIdentifier: "asset-1",
            store: store,
            save: { _ in /* in memory */ }
        )

        let again = await HikePhotoImport.add(
            data,
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            assetLocalIdentifier: "asset-1",
            placeID: Self.spring.id,
            store: store,
            save: { _ in /* in memory */ }
        )

        #expect(hike.photos.count == 1)
        #expect(again?.placeID == Self.spring.id)
        #expect(hike.photos.first?.placeID == Self.spring.id)
    }

    @Test("the camera pill carries the place of the screen that offers it")
    func captureSubjectCarriesPlace() throws {
        let (hike, _) = try hike()
        let controller = PhotoCaptureController()

        controller.attach(to: hike, place: Self.spring.id) { Self.spring.clCoordinate }

        let filing = try #require(controller.currentSubject())
        #expect(filing.placeID == Self.spring.id)
        #expect(filing.coordinate?.latitude == Self.spring.latitude)
    }
}
