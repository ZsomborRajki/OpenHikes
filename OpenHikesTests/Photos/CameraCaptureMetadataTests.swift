//
//  CameraCaptureMetadataTests.swift
//  OpenHikesTests
//
//  The shutter time, read out of the dictionary shape the camera actually
//  hands over.
//
//  Every case here is a dictionary rather than a photograph, because that is
//  what ``CameraCaptureMetadata`` is given: `UIImagePickerController` reports
//  `.mediaMetadata` as image properties, not as a file, and there is no camera
//  in a simulator to produce one anyway.
//
//  The zone is pinned in every test. EXIF writes a wall clock with no offset,
//  so the same six numbers are a different instant in a different zone — and a
//  suite that read them in the machine's own zone would assert one thing in
//  Cupertino and another in Berlin.
//

import Foundation
import ImageIO
@testable import OpenHikes
import Testing

@Suite("Camera capture metadata")
struct CameraCaptureMetadataTests {
    private static let utc = TimeZone(secondsFromGMT: 0) ?? .current
    /// 2025-06-15 14:30:05 UTC, as an instant and as EXIF writes it.
    private static let shutter = Date(timeIntervalSince1970: 1_749_997_805)
    private static let shutterText = "2025:06:15 14:30:05"
    /// A different, earlier reading, so a test that expects the *right* field
    /// cannot pass by reading either.
    private static let olderText = "2025:06:15 09:05:59"
    private static let older = Date(timeIntervalSince1970: 1_749_978_359)

    /// Both nested dictionaries every time, empty where a case has nothing to
    /// put in them — a metadata block that is present and says nothing is the
    /// ordinary shape of the ones this has to refuse.
    private static func properties(
        exif: [String: Any] = [:],
        tiff: [String: Any] = [:]
    ) -> [String: Any] {
        [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
        ]
    }

    @Test("the EXIF shutter time is what comes back")
    func readsDateTimeOriginal() {
        let properties = Self.properties(
            exif: [
                kCGImagePropertyExifDateTimeOriginal as String: Self.shutterText,
            ]
        )

        #expect(
            CameraCaptureMetadata.capturedAt(in: properties, timeZone: Self.utc)
                == Self.shutter
        )
    }

    /// The original is the shutter; the digitized time is when the file was
    /// written, which on a phone is close and on anything else need not be.
    @Test("the original wins over the digitized time and the TIFF one")
    func prefersTheOriginal() {
        let properties = Self.properties(
            exif: [
                kCGImagePropertyExifDateTimeDigitized as String: Self.olderText,
                kCGImagePropertyExifDateTimeOriginal as String: Self.shutterText,
            ],
            tiff: [kCGImagePropertyTIFFDateTime as String: Self.olderText]
        )

        #expect(
            CameraCaptureMetadata.capturedAt(in: properties, timeZone: Self.utc)
                == Self.shutter
        )
    }

    @Test("a frame carrying only a TIFF timestamp is still dated")
    func fallsBackToTIFF() {
        let properties = Self.properties(
            tiff: [kCGImagePropertyTIFFDateTime as String: Self.olderText]
        )

        #expect(
            CameraCaptureMetadata.capturedAt(in: properties, timeZone: Self.utc)
                == Self.older
        )
    }

    /// A timestamp key holding something that is not a string is reported as
    /// absent rather than coerced into one.
    @Test("a timestamp that is not text is reported as absent")
    func refusesANonStringTimestamp() {
        let properties = Self.properties(
            exif: [kCGImagePropertyExifDateTimeOriginal as String: Self.older]
        )

        #expect(
            CameraCaptureMetadata.capturedAt(in: properties, timeZone: Self.utc) == nil
        )
    }

    /// The claim the header makes about zones, checked rather than asserted:
    /// the reading is a local wall clock, so two hours east of UTC it names an
    /// instant two hours earlier.
    @Test("the timestamp is read as local time, not as UTC")
    func readsTheWallClockInTheGivenZone() throws {
        let east = try #require(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let properties = Self.properties(
            exif: [kCGImagePropertyExifDateTimeOriginal as String: Self.shutterText]
        )

        #expect(
            CameraCaptureMetadata.capturedAt(in: properties, timeZone: east)
                == Self.shutter.addingTimeInterval(-2 * 60 * 60)
        )
    }

    /// The all-zero placeholder is the case a range check exists for: a
    /// calendar resolves it happily, into a date two millennia before the
    /// walk, and a photograph pinned there is worse than one with no time at
    /// all.
    @Test(
        "a timestamp that isn't one is reported as absent",
        arguments: [
            "0000:00:00 00:00:00",
            "2025:13:15 14:30:05",
            "2025:06:32 14:30:05",
            "2025:06:15 24:30:05",
            "2025:06:15 14:60:05",
            "2025:06:15",
            "2025-06-15 14:30:05",
            "not a timestamp at all",
            "",
        ]
    )
    func refusesUnreadableTimestamps(text: String) {
        let properties = Self.properties(
            exif: [kCGImagePropertyExifDateTimeOriginal as String: text]
        )

        #expect(
            CameraCaptureMetadata.capturedAt(in: properties, timeZone: Self.utc) == nil
        )
    }

    @Test("metadata with no timestamp in it reports nothing")
    func reportsNothingWhenThereIsNoTimestamp() {
        #expect(CameraCaptureMetadata.capturedAt(in: [:], timeZone: Self.utc) == nil)
        #expect(
            CameraCaptureMetadata.capturedAt(
                in: Self.properties(),
                timeZone: Self.utc
            ) == nil
        )
    }
}
