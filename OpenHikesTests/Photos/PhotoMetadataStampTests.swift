//
//  PhotoMetadataStampTests.swift
//  OpenHikesTests
//
//  What the app knows about a photograph, checked as it is written into the
//  photograph.
//
//  Read back through ImageIO rather than by inspecting the dictionary that was
//  handed in — the question is whether a JPEG on somebody's disk carries the
//  date and the place, and the only thing that can answer it is decoding one.
//
//  The third test is the one that would otherwise rot. Stamping metadata is
//  trivially implementable by decoding the image and encoding it again, which
//  passes every assertion about EXIF while quietly costing a JPEG generation
//  and the quality that goes with it. Comparing the decoded pixels byte for
//  byte is what makes that implementation fail: a re-encode at any quality
//  moves them.
//

import CoreLocation
import Foundation
import ImageIO
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Photo metadata stamp")
struct PhotoMetadataStampTests {
    nonisolated private static let latitude: Double = 47.6300
    nonisolated private static let longitude: Double = 12.8600
    /// Southern and western, so the hemisphere references have something to be
    /// wrong about: a stamp that dropped the sign or the reference would still
    /// pass on a northeastern coordinate.
    nonisolated private static let southernLatitude: Double = -33.8700
    nonisolated private static let westernLongitude: Double = -70.6500
    /// Fixed, so nothing here depends on when it is run.
    nonisolated private static let capturedAt = Date(timeIntervalSince1970: 1_750_000_000)
    nonisolated private static let side = 24
    nonisolated private static let quality = 0.9
    /// EXIF stores a coordinate as degrees, minutes and seconds in rationals,
    /// so what comes back out is the same place rather than the same `Double`.
    /// Eleven metres of slack; a stamp wrong by a hemisphere or by a dropped
    /// component is wrong by whole degrees.
    nonisolated private static let coordinateTolerance = 0.0001

    @Test("the capture time is written where a camera would write it")
    func stampWritesTheCaptureTime() async throws {
        let stamped = try #require(
            await offMain {
                PhotoMetadataStamp.stamped(
                    Self.sampleJPEG(),
                    capturedAt: Self.capturedAt,
                    coordinate: nil
                )
            }
        )

        let exif = try #require(
            Self.properties(of: stamped)[kCGImagePropertyExifDictionary]
                as? [CFString: Any]
        )
        #expect(
            exif[kCGImagePropertyExifDateTimeOriginal] as? String
                == Self.expectedLocalTimestamp
        )
        #expect(
            exif[kCGImagePropertyExifDateTimeDigitized] as? String
                == Self.expectedLocalTimestamp
        )
    }

    @Test("a coordinate is written as an EXIF GPS block")
    func stampWritesTheCoordinate() async throws {
        let stamped = try #require(
            await offMain {
                PhotoMetadataStamp.stamped(
                    Self.sampleJPEG(),
                    capturedAt: Self.capturedAt,
                    coordinate: CLLocationCoordinate2D(
                        latitude: Self.latitude,
                        longitude: Self.longitude
                    )
                )
            }
        )

        let gps = try #require(
            Self.properties(of: stamped)[kCGImagePropertyGPSDictionary]
                as? [CFString: Any]
        )
        #expect(Self.isClose(gps[kCGImagePropertyGPSLatitude], to: Self.latitude))
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "N")
        #expect(Self.isClose(gps[kCGImagePropertyGPSLongitude], to: Self.longitude))
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "E")
    }

    /// EXIF stores magnitudes and a hemisphere beside them, so a southern or
    /// western coordinate written as a negative number would place the picture
    /// on the wrong side of the equator or the meridian.
    @Test("a southern, western coordinate keeps its hemispheres")
    func stampWritesHemispheres() async throws {
        let stamped = try #require(
            await offMain {
                PhotoMetadataStamp.stamped(
                    Self.sampleJPEG(),
                    capturedAt: Self.capturedAt,
                    coordinate: CLLocationCoordinate2D(
                        latitude: Self.southernLatitude,
                        longitude: Self.westernLongitude
                    )
                )
            }
        )

        let gps = try #require(
            Self.properties(of: stamped)[kCGImagePropertyGPSDictionary]
                as? [CFString: Any]
        )
        #expect(
            Self.isClose(gps[kCGImagePropertyGPSLatitude], to: abs(Self.southernLatitude))
        )
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "S")
        #expect(
            Self.isClose(gps[kCGImagePropertyGPSLongitude], to: abs(Self.westernLongitude))
        )
        #expect(gps[kCGImagePropertyGPSLongitudeRef] as? String == "W")
    }

    /// A photo the app has no position for — location refused, or a hike with
    /// no route point to stand on. A guessed coordinate would be worse than an
    /// absent one: a pin on a map reads as a fact.
    @Test("a photo with no coordinate is dated but not placed")
    func stampOmitsAnAbsentCoordinate() async throws {
        let stamped = try #require(
            await offMain {
                PhotoMetadataStamp.stamped(
                    Self.sampleJPEG(),
                    capturedAt: Self.capturedAt,
                    coordinate: nil
                )
            }
        )

        let properties = Self.properties(of: stamped)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyExifDictionary] != nil)
    }

    /// The whole argument for handing `CGImageDestination` the *source*
    /// instead of a decoded image: the compressed data is copied across and
    /// only the container's metadata is rewritten. A decode-and-re-encode
    /// would satisfy every other test in this file and move every pixel.
    @Test("stamping rewrites the metadata without re-encoding the pixels")
    func stampDoesNotReEncode() async throws {
        let original = Self.sampleJPEG()
        let stamped = try #require(
            await offMain {
                PhotoMetadataStamp.stamped(
                    original,
                    capturedAt: Self.capturedAt,
                    coordinate: CLLocationCoordinate2D(
                        latitude: Self.latitude,
                        longitude: Self.longitude
                    )
                )
            }
        )

        let before = try #require(await offMain { Self.pixels(of: original) })
        let after = try #require(await offMain { Self.pixels(of: stamped) })
        #expect(!before.isEmpty, "an empty comparison would pass for the wrong reason")
        #expect(before == after)
    }

    @Test("bytes that are not an image are refused rather than rewritten")
    func stampRefusesNonImageBytes() async {
        let stamped = await offMain {
            PhotoMetadataStamp.stamped(
                Data("not a picture".utf8),
                capturedAt: Self.capturedAt,
                coordinate: nil
            )
        }

        #expect(stamped == nil)
    }

    // MARK: - Fixtures

    /// The same wall-clock string a camera writes: EXIF has no time zone, so
    /// the moment is expressed in whatever zone the device is in, and the
    /// expectation has to be derived the same way rather than hard-coded — a
    /// literal would pass only in the zone it was written in.
    private static var expectedLocalTimestamp: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: capturedAt
        )
        return String(
            format: "%04d:%02d:%02d %02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// A real JPEG, because this is a test about JPEG containers. Gradient
    /// rather than flat colour: a uniform image compresses to almost nothing
    /// and would make the pixel comparison above nearly free to satisfy.
    nonisolated private static func sampleJPEG() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for row in 0..<side {
                UIColor(
                    hue: Double(row) / Double(side),
                    saturation: 0.8,
                    brightness: 0.9,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: 0, y: row, width: side, height: 1))
            }
        }
        return image.jpegData(compressionQuality: quality) ?? Data()
        #else
        return Data()
        #endif
    }

    /// `false` for an absent value as well as a wrong one, so a GPS block
    /// that never arrived cannot pass.
    nonisolated private static func isClose(_ value: Any?, to expected: Double) -> Bool {
        guard let degrees = value as? Double else { return false }
        return abs(degrees - expected) < coordinateTolerance
    }

    nonisolated private static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any]
        else { return [:] }
        return copied
    }

    /// The decoded bitmap, so two encodings can be compared by what they draw.
    ///
    /// Drawn into a context of this test's own rather than read off the
    /// `CGImage`'s data provider: for a JPEG the provider hands back the
    /// *compressed* bytes, which differ here by design — one of the two
    /// carries metadata the other does not — and comparing those would fail on
    /// a correct implementation.
    nonisolated private static func pixels(of data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let bytesPerRow = image.width * 4
        var buffer = Data(count: bytesPerRow * image.height)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        return drew ? buffer : nil
    }
}
