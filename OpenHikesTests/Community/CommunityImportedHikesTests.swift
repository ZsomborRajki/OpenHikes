//
//  CommunityImportedHikesTests.swift
//  OpenHikesTests
//
//  Which published hikes this hiker already has, off the list they are drawn
//  from.
//
//  Two things on a community row come from this answer and must not disagree:
//  the *Saved* badge, and whether tapping the row opens the hiker's own hike
//  or a stranger's preview. They used to be one question — a set of listing
//  ids, asked only by the badge — while the destination was the preview
//  either way. Now the row's tap reads the hike itself, so the answer carries
//  one.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The hiker's own copies of published hikes, keyed by listing.
@MainActor
@Suite("Community imported hikes")
struct CommunityImportedHikesTests {
    private static func imported(
        _ listingID: String,
        titled title: String,
        in context: ModelContext
    ) -> Hike {
        Fixture.hike(in: context, title: title) { hike in
            hike.importedFromListingID = listingID
        }
    }

    @Test("an imported hike is found by the listing it came from")
    func importedHikeIsKeyedByItsListing() throws {
        let context = try Fixture.modelContext()
        let hike = Self.imported("pilis", titled: "Pilis Ridge", in: context)

        let imported = CommunityImport.importedByListing(in: [hike])

        #expect(imported["pilis"] === hike)
    }

    /// The hiker's own walks are the rest of the list, and every one of them
    /// carries `nil` here. A row badged from an answer that included them
    /// would say *Saved* about somebody else's hike.
    @Test("a hike the hiker walked themselves is not in it")
    func ownHikesAreAbsent() throws {
        let context = try Fixture.modelContext()
        let own = Fixture.hike(in: context, title: "Ridge Loop")
        let hike = Self.imported("pilis", titled: "Pilis Ridge", in: context)

        let imported = CommunityImport.importedByListing(in: [own, hike])

        #expect(imported.count == 1)
        #expect(imported["pilis"] === hike)
    }

    @Test("a listing nobody imported opens nothing")
    func anUnimportedListingIsAbsent() throws {
        let context = try Fixture.modelContext()
        let hike = Self.imported("pilis", titled: "Pilis Ridge", in: context)

        #expect(CommunityImport.importedByListing(in: [hike])["ridge"] == nil)
    }

    /// The import refuses to make a second copy — see
    /// ``CommunityImport/importHike(_:into:store:libraryWriter:save:)`` — but
    /// a mirrored store can deliver one from another device. The lists this
    /// reads are sorted newest first, so first wins means the newer copy.
    @Test("one listing imported twice answers with the newer copy")
    func aDuplicateKeepsTheFirst() throws {
        let context = try Fixture.modelContext()
        let newer = Self.imported("pilis", titled: "Pilis Ridge", in: context)
        let older = Self.imported("pilis", titled: "Pilis Ridge", in: context)

        let imported = CommunityImport.importedByListing(in: [newer, older])

        #expect(imported.count == 1)
        #expect(imported["pilis"] === newer)
    }

    @Test("an empty library has imported nothing")
    func anEmptyLibraryIsEmpty() {
        #expect(CommunityImport.importedByListing(in: []).isEmpty)
    }
}
