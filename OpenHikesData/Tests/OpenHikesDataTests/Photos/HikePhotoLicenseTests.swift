//
//  HikePhotoLicenseTests.swift
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
struct HikePhotoLicenseTests {
    private static let license = HikePhotoLicense(
        name: "CC BY-SA 4.0",
        url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
        sourceURL: URL(fileURLWithPath: "/File:Summit.jpg")
    )

    @Test("a licensed copy comes back from the blob with its name and both links")
    func roundTrip() throws {
        let photo = HikePhoto(importedAuthorName: "Anna", license: Self.license)

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: JSONEncoder().encode([photo]))

        #expect(decoded.first?.license == Self.license)
        #expect(decoded.first?.importedAuthorName == "Anna")
    }

    @Test("a blob written before the licence existed decodes, with no licence")
    func olderBlobsDecode() throws {
        let older = Data(
            #"[{"id":"7C0A3C5E-0D0B-4C5E-9A52-1F1B2C3D4E5F","capturedAt":0,"pathExtension":"jpeg"}]"#.utf8
        )

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: older)

        #expect(decoded.count == 1)
        #expect(decoded.first?.license == nil)
        #expect(decoded.first?.isOwn == true)
    }

    /// The property is spelled `license` and the blob still says `licence`,
    /// the key every copy saved before #847 was written with. A key that
    /// followed the rename would read those copies as having no licence, and
    /// so as the hiker's own to publish.
    @Test("the licence is kept under the key it was first saved with")
    func storedKeyIsUnchanged() throws {
        let saved = Data(
            #"""
            [{"id":"7C0A3C5E-0D0B-4C5E-9A52-1F1B2C3D4E5F","capturedAt":0,"pathExtension":"jpeg",
            "licence":{"name":"CC BY-SA 4.0","sourceURL":"file:///File:Summit.jpg"}}]
            """#.utf8
        )

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: saved)
        let written = try JSONEncoder().encode(decoded)
        let keys = try #require(JSONSerialization.jsonObject(with: written) as? [[String: Any]]).first?.keys

        #expect(decoded.first?.license?.name == "CC BY-SA 4.0")
        #expect(decoded.first?.isOwn == false)
        #expect(keys?.contains("licence") == true)
        #expect(keys?.contains("license") == false)
    }

    /// The keys are written out by hand so the licence can keep its old one,
    /// and a list written by hand is one a new property can be left out of.
    /// That still compiles, and for an optional it means a field that is
    /// never saved. So every stored property, each one set, has to come back
    /// out of the blob under its own name — the licence under its old one.
    @Test("every stored property is written to the blob")
    func everyPropertyIsWritten() throws {
        var photo = HikePhoto(
            assetLocalIdentifier: "asset",
            matchEvidence: .place,
            importedFromListingID: "osm:r/1",
            importedAuthorName: "Anna",
            isPlaceOnly: false,
            license: Self.license
        )
        photo.latitude = 47.5
        photo.longitude = 12.4
        photo.sentToCommunityAt = .now
        photo.placeID = UUID()

        let written = try JSONEncoder().encode(photo)
        let keys = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any]).keys
        let stored = Mirror(reflecting: photo).children.compactMap(\.label)

        // A property missing here is either unset above or missing from
        // `HikePhoto.CodingKeys`.
        #expect(Set(keys) == Set(stored.map { $0 == "license" ? "licence" : $0 }))
    }

    @Test("a photograph under somebody else's licence is never the hiker's own to publish")
    func licenseMakesItNotOwn() {
        #expect(!HikePhoto(license: Self.license).isOwn)
        #expect(HikePhoto().isOwn)
        #expect(!HikePhoto(importedFromListingID: "osm:r/1").isOwn)
    }

    @Test("a licensed copy is somebody else's by the rule a build without the licence field applies")
    func previousBuildsRuleKeepsItOut() throws {
        let photo = HikePhoto(importedAuthorName: "Anna", license: Self.license)

        let decoded = try JSONDecoder().decode([HikePhoto].self, from: JSONEncoder().encode([photo]))

        // `isOwn` before 183ea3e7, which is what a 1.3 build 4 device applies.
        #expect(decoded.first?.importedFromListingID != nil)
        #expect(HikePhoto(importedFromListingID: "osm:r/1", license: Self.license).importedFromListingID == "osm:r/1")
        #expect(HikePhoto().importedFromListingID == nil)
    }
}
