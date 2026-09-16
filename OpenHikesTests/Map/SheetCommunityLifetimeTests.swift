//
//  SheetCommunityLifetimeTests.swift
//  OpenHikesTests
//
//  "Sheet community lifetime", split out of
//  SheetCommunityNavigationTests.swift so that a file declares one @Suite.
//  That file's header still holds the context the two share.
//

import Foundation
@testable import OpenHikes
import Testing

/// The other half of the same question: not *who may navigate* but *who may
/// dispose*.
///
/// A pushed-over screen and a popped one are indistinguishable from inside a
/// SwiftUI view, and a community preview disposed on both: it retired its
/// route from the map and deleted the stranger's photographs it had
/// downloaded. A map pin can push a second preview over an open one, so that
/// was a gesture away from a screen whose cached detail pointed at files that
/// were no longer there — and `CommunityImport.attachPhotos` skips unreadable
/// paths silently, so the hike imported without them.
@Suite("Sheet community lifetime")
struct SheetCommunityLifetimeTests {
    private static let listing = CommunityListing.stub(id: "pilis")
    private static let other = CommunityListing.stub(id: "ridge", submissionID: "submission-2")

    @Test("a preview pushed over is still on the stack")
    func aPreviewPushedOverIsRetained() {
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing)]
        presentation.path.append(.communityHike(Self.other))

        #expect(
            presentation.isPresentingCommunityHike(Self.listing),
            "the hiker is one Back from this screen, with its answer intact"
        )
        #expect(presentation.isPresentingCommunityHike(Self.other))
    }

    /// Back is the case that must still dispose: the screen is gone, its
    /// downloads are nobody's, and the map's line goes with it.
    @Test("a preview popped is not")
    func aPoppedPreviewIsReleased() {
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing), .communityHike(Self.other)]
        presentation.path.removeLast()
        #expect(presentation.isPresentingCommunityHike(Self.listing))

        presentation.path.removeLast()

        #expect(!presentation.isPresentingCommunityHike(Self.listing))
        #expect(!presentation.isPresentingCommunityHike(Self.other))
    }

    /// And a path replaced wholesale — what importing does, and what blocking
    /// does — releases everything on it.
    @Test("a path replaced releases the preview it replaced")
    func aReplacedPathReleasesThePreview() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation()
        presentation.path = [.communityHike(Self.listing)]

        presentation.path = [.hike(hike)]

        #expect(!presentation.isPresentingCommunityHike(Self.listing))
    }
}
