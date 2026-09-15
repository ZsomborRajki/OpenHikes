//
//  SheetCommunityPushTests.swift
//  OpenHikesTests
//
//  The rule that makes a community preview's teardown answerable: one listing
//  is never on the sheet's stack twice.
//
//  A disappearing preview asks ``SheetPresentation/isPresentingCommunityHike(_:)``
//  to tell a push over it from the hiker leaving, and that is a question about
//  the *listing* rather than about the screen asking. So a second copy of the
//  same listing answers for the copy being popped: it cancels no download,
//  cancels no analysis, tells the map nothing, and leaves a directory of a
//  stranger's photographs in `tmp` that nothing will ever come back for.
//
//  That was a gesture away, because only one of the two ways in checked
//  anything and it only checked the top of the stack. Pin A, pin B, pin A is
//  three ordinary taps; a second tap on a community row before the push
//  commits is one. `[A, A]` is also a Back that lands the hiker on the screen
//  they were already looking at.
//
//  So every push goes through one door, and the door pops back to an open
//  copy instead of making a second one. These are that door's answers.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Sheet community pushes")
struct SheetCommunityPushTests {
    private static let first = CommunityListing.stub(id: "pilis")
    private static let second = CommunityListing.stub(id: "ridge", submissionID: "submission-2")

    @Test("opening a shared hike pushes its preview")
    func opensAPreview() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(Self.first)

        #expect(presentation.path == [.communityHike(Self.first)])
    }

    /// The gesture the old guard did cover: a pin tapped again while its own
    /// preview is the screen in front.
    @Test("tapping the open preview's pin again changes nothing")
    func aRepeatedTapOnTheOpenPreviewDoesNothing() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(Self.first)
        presentation.showCommunityHike(Self.first)

        #expect(presentation.path == [.communityHike(Self.first)])
    }

    /// And the one it did not: pin A, pin B, pin A. The hiker asked to see A,
    /// so A is what they get — the copy already on the stack, with the answer
    /// it has already loaded, rather than a second one underneath it.
    ///
    /// Built by hand rather than by three taps: a second listing now replaces
    /// the first, so three taps never leave both on the stack to pop between.
    @Test("returning to a preview already on the stack pops back to it")
    func returningPopsBackRatherThanPushingAgain() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.path = [.communityHike(Self.first), .communityHike(Self.second)]
        presentation.showCommunityHike(Self.first)

        #expect(presentation.path == [.communityHike(Self.first)])
    }

    /// The cost of getting that wrong, stated as the thing the screen asks.
    ///
    /// With a second copy of A on the stack, popping the upper one left
    /// `isPresentingCommunityHike(A)` true — so that screen returned from
    /// `onDisappear` before doing anything, and its download, its analysis and
    /// its directory were nobody's.
    @Test("a preview popped after a return is released")
    func aPoppedPreviewIsReleasedAfterAReturn() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(Self.first)
        presentation.showCommunityHike(Self.second)
        presentation.showCommunityHike(Self.first)
        presentation.path.removeLast()

        #expect(!presentation.isPresentingCommunityHike(Self.first), "nothing answers for it")
        #expect(!presentation.isPresentingCommunityHike(Self.second))
    }

    /// Popping back takes the screens above with it, and only those: a
    /// preview reached again from under somebody's own hike is still the same
    /// screen, and what the hiker asked to leave is the hike on top of it.
    @Test("popping back to a preview takes only what was over it")
    func poppingBackKeepsWhatWasUnderneath() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(Self.first)
        presentation.path.append(.hike(hike))
        presentation.showCommunityHike(Self.first)

        #expect(presentation.path == [.communityHike(Self.first)])
    }

    /// The compact detent is only tall enough for the search field. A preview
    /// popped back to down there has as little room to draw as one pushed —
    /// the hiker can have dragged the sheet down over it — so both branches
    /// move the sheet.
    @Test("a sheet dragged shut opens far enough to read the preview")
    func popsTheSheetOpenOnTheWayBack() {
        let presentation = SheetPresentation(detent: SheetPresentation.compactDetent)

        presentation.showCommunityHike(Self.first)
        presentation.showCommunityHike(Self.second)
        presentation.detent = SheetPresentation.compactDetent
        presentation.showCommunityHike(Self.first)

        #expect(presentation.path == [.communityHike(Self.first)])
        #expect(!presentation.isCompact, "there is a page to read down there")
    }

    /// Two different hikes are one screen, not two: tapping B over A's preview
    /// replaces it, so Back lands on the list rather than on A — where it
    /// refit the map to A's route. A tap is a jump to one trail, exactly as
    /// ``MapSheet/open(_:)`` assigns for the hiker's own hikes.
    @Test("a different shared hike replaces the open one")
    func aDifferentHikeReplaces() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.showCommunityHike(Self.first)
        presentation.showCommunityHike(Self.second)

        #expect(presentation.path == [.communityHike(Self.second)])
        #expect(
            !presentation.isPresentingCommunityHike(Self.first),
            "Back goes to the list, not to the trail just left"
        )
    }

    /// The gallery goes with the preview it belongs to: its files live in the
    /// screen underneath's download directory.
    @Test("a different shared hike takes the gallery with the preview it replaces")
    func aDifferentHikeReplacesGalleryToo() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.path = [
            .communityHike(Self.first),
            .communityPhoto(Self.first, [], 0),
        ]
        presentation.showCommunityHike(Self.second)

        #expect(presentation.path == [.communityHike(Self.second)])
    }

    /// Anything that is not a stranger's preview stays: an owned hike under
    /// the preview is still there when the next one replaces it.
    @Test("replacing a preview keeps what was underneath it")
    func replacingKeepsWhatWasUnderneath() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)

        presentation.path = [.hike(hike), .communityHike(Self.first)]
        presentation.showCommunityHike(Self.second)

        #expect(presentation.path == [.hike(hike), .communityHike(Self.second)])
    }
}
