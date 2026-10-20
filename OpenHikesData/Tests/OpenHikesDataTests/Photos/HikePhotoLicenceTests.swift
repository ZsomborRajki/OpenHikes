//
//  HikePhotoLicenceTests.swift
//  OpenHikesDataTests
//
//  The licence a saved Wikimedia Commons photograph keeps, inside the
//  `CD_photos` blob every hike's photographs are stored in.
//
//  Two directions matter and both are asserted. A blob written before the key
//  existed has to decode unchanged — the photographs decode as one array, so a
//  row that failed would lose every picture on the hike rather than one field.
//  And a blob carrying it has to come back carrying all three things the
//  licence asks the app to keep showing: its name, its link, and the
//  photograph's page.
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Hike photo licence")
struct HikePhotoLicenceTests {
    private static let licence = HikePhotoLicence(
        name: "CC BY-SA 4.0",
        url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
        sourceURL: URL(fileURLWithPath: "/File:Summit.jpg")
    )

    @Test("a licensed copy comes back from the blob with its name and both links")
    func roundTrip() throws {
        let photo = HikePhoto(importedAuthorName: "Anna", licence: Self.licence)

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: JSONEncoder().encode([photo]))

        #expect(decoded.first?.licence == Self.licence)
        #expect(decoded.first?.importedAuthorName == "Anna")
    }

    @Test("a blob written before the licence existed decodes, with no licence")
    func olderBlobsDecode() throws {
        let older = Data(
            #"[{"id":"7C0A3C5E-0D0B-4C5E-9A52-1F1B2C3D4E5F","capturedAt":0,"pathExtension":"jpeg"}]"#.utf8
        )

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: older)

        #expect(decoded.count == 1)
        #expect(decoded.first?.licence == nil)
        #expect(decoded.first?.isOwn == true)
    }

    @Test("a photograph under somebody else's licence is never the hiker's own to publish")
    func licenceMakesItNotOwn() {
        #expect(!HikePhoto(licence: Self.licence).isOwn)
        #expect(HikePhoto().isOwn)
        #expect(!HikePhoto(importedFromListingID: "osm:r/1").isOwn)
    }

    @Test("a licensed copy is somebody else's by the rule a build without the licence field applies")
    func previousBuildsRuleKeepsItOut() throws {
        let photo = HikePhoto(importedAuthorName: "Anna", licence: Self.licence)

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: JSONEncoder().encode([photo]))

        // `isOwn` before 183ea3e7, which is what a 1.3 build 4 device applies.
        #expect(decoded.first?.importedFromListingID != nil)
        #expect(HikePhoto(importedFromListingID: "osm:r/1", licence: Self.licence).importedFromListingID == "osm:r/1")
        #expect(HikePhoto().importedFromListingID == nil)
    }
}
