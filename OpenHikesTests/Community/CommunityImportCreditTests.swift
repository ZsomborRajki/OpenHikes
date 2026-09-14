//
//  CommunityImportCreditTests.swift
//  OpenHikesTests
//
//  The credit a community import collects, and where it has to survive to.
//
//  ``Hike/importedAuthorName`` was written by ``CommunityImport`` and read by
//  nothing: a `grep` over the app target found one write and no reads. Right
//  up to the moment a hiker tapped Save, the credit was everywhere — the list
//  row says "by Anna", the preview screen is headed "Shared by Anna · 3 March"
//  — and the saved hike then appeared in the library as one of the hiker's
//  own, with nothing anywhere saying whose walk it was.
//
//  These are the two places it now has to reach. The detail screen is a
//  SwiftUI view and cannot be asserted from here, so what is pinned is the
//  half that leaves the app: a GPX exported from somebody else's published
//  route carries who published it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community import credit")
struct CommunityImportCreditTests {
    private static func exported(_ hike: Hike) throws -> GPXImport.Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("credit-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try GPXExport.data(for: GPXExport.Track(hike: hike)).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GPXImport.load(from: url)
    }

    private static func imported(into context: ModelContext) async throws -> Hike {
        let detail = CommunityHikeDetail(
            listing: .stub(),
            route: Fixture.ridgeRoute,
            trackDescription: "A ridge walk",
            photoPins: [],
            photoFileURLs: [],
            photosOnRecord: 0
        )
        let outcome = await CommunityImport.importHike(detail, into: context)
        return try #require(outcome.hike)
    }

    /// The whole path, end to end: a hike saved from somebody else's listing,
    /// exported, and read back by a real GPX reader. `<metadata><author>` was
    /// omitted entirely before, because the import writes no ``Hike/author``.
    @Test("a hike saved from the community exports with its credit")
    func exportCarriesTheCommunityCredit() async throws {
        let context = try Fixture.modelContext()
        let hike = try await Self.imported(into: context)
        #expect(hike.author == nil)
        #expect(hike.importedAuthorName == "Anna")

        #expect(try Self.exported(hike).author == "Anna")
    }

    /// A file's own author is the more specific claim about the document being
    /// written, so it wins. Nothing in the app sets both today; this says what
    /// happens if anything ever does.
    @Test("a GPX author outranks a community credit")
    func fileAuthorWins() throws {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, date: .now, route: Fixture.ridgeRoute)
        hike.author = "Ada Lovelace"
        hike.importedAuthorName = "Anna"

        #expect(try Self.exported(hike).author == "Ada Lovelace")
    }

    /// A recorded hike has neither, and the element stays absent rather than
    /// becoming an empty one.
    @Test("a hike with no credit at all exports no author element")
    func noCreditExportsNoAuthor() {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, date: .now, route: Fixture.ridgeRoute)

        #expect(hike.author == nil)
        #expect(hike.importedAuthorName == nil)
        #expect(!GPXExport.xml(for: GPXExport.Track(hike: hike)).contains("<author>"))
    }
}
