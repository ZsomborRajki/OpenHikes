//
//  PickedPhotoMetadataTests.swift
//  OpenHikesTests
//
//  What a photograph from the system picker says about itself, read out of
//  its own bytes.
//
//  The inputs are written by ``PhotoMetadataStamp`` — the app's own EXIF
//  writer — so the two halves are checked against each other: a reader that
//  dropped a hemisphere or read the wall clock in the wrong zone would put a
//  picture on the wrong side of the world or hours along the walk, and the
//  round trip is what catches it.
//

import CoreLocation
import Foundation
import ImageIO
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Picked photo metadata")
struct PickedPhotoMetadataTests {
    nonisolated private static let capturedAt = Date(timeIntervalSince1970: 1_750_000_000)
    /// Southern and western, so the hemisphere references have something to
    /// be wrong about.
    nonisolated private static let southWest = CLLocationCoordinate2D(latitude: -33.87, longitude: -70.65)
    /// EXIF stores degrees, minutes and seconds as rationals; eleven metres of
    /// slack, against an error of whole degrees for a dropped sign.
    nonisolated private static let coordinateTolerance = 0.0001
    nonisolated private static let side = 8

    @Test("a stamped time and place are read back as written")
    func readsTimeAndPlace() async throws {
        let metadata = try await offMain {
            let stamped = try #require(
                PhotoMetadataStamp.stamped(Self.sampleJPEG(), capturedAt: Self.capturedAt, coordinate: Self.southWest)
            )
            return PickedPhotoMetadata.read(stamped)
        }

        #expect(metadata.capturedAt == Self.capturedAt)
        let coordinate = try #require(metadata.coordinate)
        #expect(abs(coordinate.latitude - Self.southWest.latitude) < Self.coordinateTolerance)
        #expect(abs(coordinate.longitude - Self.southWest.longitude) < Self.coordinateTolerance)
    }

    /// Location off for the camera, or stripped by the picker's own option:
    /// the time is still there and the place is honestly absent.
    @Test("a photo with no GPS block has a time and no place")
    func timeWithoutPlace() async throws {
        let metadata = try await offMain {
            let stamped = try #require(
                PhotoMetadataStamp.stamped(Self.sampleJPEG(), capturedAt: Self.capturedAt, coordinate: nil)
            )
            return PickedPhotoMetadata.read(stamped)
        }

        #expect(metadata.capturedAt == Self.capturedAt)
        #expect(metadata.coordinate == nil)
    }

    @Test("an image with no metadata says nothing")
    func bareImageSaysNothing() async {
        let metadata = await offMain { PickedPhotoMetadata.read(Self.sampleJPEG()) }

        #expect(metadata == .empty)
    }

    @Test("bytes that are not an image say nothing")
    func nonImageSaysNothing() async {
        let metadata = await offMain { PickedPhotoMetadata.read(Data("not an image".utf8)) }

        #expect(metadata == .empty)
    }

    /// The wall clock is only a moment once it has a zone. A photograph taken
    /// in Chile and picked in Budapest is read in Chile's, because the file
    /// says so — not in the device's, which would move it five hours along a
    /// walk.
    @Test("the file's own offset wins over the device's zone")
    func offsetTimeOriginalWins() throws {
        let budapest = try #require(TimeZone(identifier: "Europe/Budapest"))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2025:06:15 10:00:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "-04:00",
            ],
        ]

        let metadata = PickedPhotoMetadata(properties: properties, timeZone: budapest)

        let expected = try #require(
            ISO8601DateFormatter().date(from: "2025-06-15T14:00:00Z")
        )
        #expect(metadata.capturedAt == expected)
    }

    @Test("without an offset the wall clock is read in the zone given")
    func wallClockReadInGivenZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2025:06:15 10:00:00",
            ],
        ]

        let metadata = PickedPhotoMetadata(properties: properties, timeZone: utc)

        let expected = try #require(
            ISO8601DateFormatter().date(from: "2025-06-15T10:00:00Z")
        )
        #expect(metadata.capturedAt == expected)
    }

    /// A JPEG rather than the PNG the other photo suites use: JPEG is what a
    /// camera writes, and EXIF is native to it.
    nonisolated private static func sampleJPEG() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
        #else
        return Data()
        #endif
    }
}
