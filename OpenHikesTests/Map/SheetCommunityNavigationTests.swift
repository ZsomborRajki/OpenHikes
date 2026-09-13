//
//  SheetCommunityNavigationTests.swift
//  OpenHikesTests
//
//  Who owns the sheet's navigation when a community import finishes.
//
//  Adding somebody else's hike is the longest-running thing a preview starts:
//  the route commits quickly and then a stranger's photographs are copied out
//  of a download directory, which is why the task is unstructured and finishes
//  even after the screen that started it has gone. That part is deliberate —
//  the save is already authorized and abandoning it halfway would cost the
//  pictures.
//
//  What must not outlive the screen is the *navigation*. `MapSheet.open`
//  assigns the whole path rather than appending to it, so an import landing
//  after the hiker went Back and opened something else would replace their
//  newer choice with the older screen's answer. The guard is this predicate,
//  and these are its four answers.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Sheet community navigation")
struct SheetCommunityNavigationTests {
    private static let listing = CommunityListing.stub(id: "pilis")

    @Test("an open preview still owns the navigation")
    func anOpenPreviewOwnsTheNavigation() {
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing)]

        #expect(presentation.isShowingCommunityHike(Self.listing))
    }

    /// Back: the stack is empty, and an import landing now has nowhere it
    /// belongs.
    @Test("a preview backed out of does not")
    func aBackedOutPreviewDoesNot() {
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing)]
        presentation.path.removeAll()

        #expect(!presentation.isShowingCommunityHike(Self.listing))
    }

    /// The case in the report: Back, then another hike opened while the first
    /// import was still copying photographs.
    @Test("a newer destination is not replaced by an older import")
    func aNewerDestinationIsNotReplaced() throws {
        let context = try Fixture.modelContext()
        let other = Fixture.hike(in: context, title: "Somewhere else")
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing)]
        presentation.path = [.hike(other)]

        #expect(!presentation.isShowingCommunityHike(Self.listing))
        #expect(presentation.path == [.hike(other)], "the newer navigation stands")
    }

    /// And another preview is another screen, not this one — two shared hikes
    /// opened in turn is the same mistake with the same shape.
    @Test("another hike's preview is not this one")
    func anotherPreviewIsNotThisOne() {
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(.stub(id: "another", submissionID: "submission-2"))]

        #expect(!presentation.isShowingCommunityHike(Self.listing))
    }

    /// A screen pushed over the preview counts as somebody else's too: the
    /// navigation being guarded assigns the whole path, so acting here would
    /// take the pushed screen away as well.
    @Test("a screen pushed over the preview takes ownership with it")
    func aPushedScreenTakesOwnership() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing), .hike(hike)]

        #expect(!presentation.isShowingCommunityHike(Self.listing))
    }
}
