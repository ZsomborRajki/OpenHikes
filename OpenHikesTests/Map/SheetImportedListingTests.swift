//
//  SheetImportedListingTests.swift
//  OpenHikesTests
//
//  What a tap on a published hike opens.
//
//  A shared hike is reachable from two doors — the sheet's community rows and
//  the map's pins and route lines — and both used to push the same screen for
//  every listing: the preview, the page that asks whether to keep somebody
//  else's trail. For a hike already in the library that question has been
//  answered, and what the page offered instead was one button reading *Open
//  in My Hikes*: a second tap for the thing the first tap asked for, in front
//  of a page about a stranger's copy of a hike the hiker owns.
//
//  So the destination is decided in one place, from one fact the caller
//  brings — the hiker's own copy, if they have one. These are its answers.
//  The two doors resolving that fact differently is fine; disagreeing about
//  what to do with it is not, which is why neither of them decides.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

/// Where a tapped listing goes.
@MainActor
@Suite("Sheet imported listings")
struct SheetImportedListingTests {
    private static let listing = CommunityListing.stub(id: "pilis")

    @Test("a hike the hiker does not have opens its preview")
    func anUnimportedListingOpensThePreview() {
        let presentation = SheetPresentation(detent: .medium)
        var selected: Hike?

        presentation.open(Self.listing, importedAs: nil, selectedHike: &selected)

        #expect(presentation.path == [.communityHike(Self.listing)])
        #expect(selected == nil, "nothing on the map belongs to a hike that is not there")
    }

    @Test("a hike already imported opens the hiker's own copy")
    func anImportedListingOpensTheHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Pilis Ridge")
        let presentation = SheetPresentation(detent: .medium)
        var selected: Hike?

        presentation.open(Self.listing, importedAs: hike, selectedHike: &selected)

        #expect(presentation.path == [.hike(hike)])
        #expect(selected === hike, "and it is the route the map draws")
    }

    /// The preview is replaced rather than left underneath. Backing out of a
    /// hike that is in the library, into a page offering to add it, describes
    /// a decision already made — which is the same reason
    /// ``MapSheet``'s import navigation assigns the path.
    @Test("the preview it replaces is not left on the stack")
    func thePreviewIsReplaced() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Pilis Ridge")
        let presentation = SheetPresentation(detent: .medium)
        var selected: Hike?

        presentation.showCommunityHike(Self.listing)
        presentation.open(Self.listing, importedAs: hike, selectedHike: &selected)

        #expect(presentation.path == [.hike(hike)])
    }

    /// A pin can be tapped with the sheet dragged shut over it, and the
    /// compact detent is only tall enough for the search field — so this
    /// moves the sheet for the same reason ``SheetPresentation/showCommunityHike(_:)``
    /// does.
    @Test("a sheet dragged shut opens far enough to read the hike")
    func opensTheSheetForTheHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Pilis Ridge")
        let presentation = SheetPresentation(detent: SheetPresentation.compactDetent)
        var selected: Hike?

        presentation.open(Self.listing, importedAs: hike, selectedHike: &selected)

        #expect(presentation.path == [.hike(hike)])
        #expect(!presentation.isCompact, "there is a hike to read down there")
    }

    /// The pin of a hike whose screen is already up. Nothing moves, which is
    /// what the hiker asked for by tapping the thing they are looking at.
    @Test("tapping the open hike's pin again changes nothing")
    func aRepeatedTapChangesNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Pilis Ridge")
        let presentation = SheetPresentation(detent: .medium)
        var selected: Hike?

        presentation.open(Self.listing, importedAs: hike, selectedHike: &selected)
        presentation.open(Self.listing, importedAs: hike, selectedHike: &selected)

        #expect(presentation.path == [.hike(hike)])
    }

    /// A photo pushed over the hike is a screen the hiker is inside, not one
    /// they asked to leave — but the tap says otherwise, and the pin is a
    /// jump to one trail rather than a step in a journey.
    @Test("a screen pushed over the hike is popped by opening it again")
    func aPushedScreenIsReplaced() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Pilis Ridge")
        let presentation = SheetPresentation(detent: .medium)
        var selected: Hike?

        presentation.path = [.hike(hike), .photo(hike, UUID())]
        presentation.open(Self.listing, importedAs: hike, selectedHike: &selected)

        #expect(presentation.path == [.hike(hike)])
    }
}
