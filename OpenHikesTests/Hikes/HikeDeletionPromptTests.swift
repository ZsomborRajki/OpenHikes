//
//  HikeDeletionPromptTests.swift
//  OpenHikesTests
//
//  What the hiker is told before a hike goes, asserted without a screen.
//
//  `HikeDeletionPrompt` is a value type for the reason `CommunityReport` is:
//  the wording *is* the fix here. A dialog that appears but describes the
//  wrong thing is the same bug as no dialog at all — a hiker who reads "are
//  you sure?" and taps through has not been told that the photographs are
//  going and that they are going from every device.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike deletion prompt")
struct HikeDeletionPromptTests {
    private static func prompt(
        title: String = "Ben Nevis",
        photos: Int = 0,
        walks: Int = 0,
        publication: CommunityPublicationState = .notShared
    ) -> HikeDeletionPrompt {
        HikeDeletionPrompt(
            title: title,
            photoCount: photos,
            walkCount: walks,
            publication: publication
        )
    }

    /// A swipe on the wrong row is the mistake this exists to catch, and a
    /// generic title cannot catch it.
    @Test("the title names the hike")
    func namesTheHike() {
        #expect(Self.prompt(title: "Ben Nevis").title.contains("Ben Nevis"))
    }

    /// The route is always what goes, so it is always named.
    @Test("the route and the statistics are always named")
    func alwaysNamesTheRoute() {
        let message = Self.prompt().message
        #expect(message.contains("route"))
        #expect(message.contains("statistics"))
    }

    /// The half no care on this phone can undo. `Hike` is mirrored, so the
    /// deletion travels — and that is the sentence a hiker deleting a hike to
    /// tidy one device most needs before they tap.
    @Test("every prompt says the other devices lose it too", arguments: [
        (0, 0), (3, 0), (0, 2), (3, 2),
    ])
    func namesTheOtherDevices(photos: Int, walks: Int) {
        #expect(Self.prompt(photos: photos, walks: walks).message.contains("other devices"))
    }

    /// Named only when there are some: a hike with no photographs must not be
    /// described as though the hiker were about to lose photographs.
    @Test("photographs are named when there are any, and not when there are none")
    func photographs() {
        #expect(Self.prompt(photos: 0).message.contains("photograph") == false)
        #expect(Self.prompt(photos: 1).message.contains("1 photograph"))
        #expect(Self.prompt(photos: 3).message.contains("3 photographs"))
    }

    /// The walk history cascades with the hike, and nothing on screen says so
    /// anywhere else.
    @Test("walks are named when there are any, and not when there are none")
    func walks() {
        #expect(Self.prompt(walks: 0).message.contains("walk") == false)
        #expect(Self.prompt(walks: 1).message.contains("1 walk"))
        #expect(Self.prompt(walks: 4).message.contains("4 walks"))
    }

    /// Both, in the order of what cannot come back.
    @Test("a hike with both names both, photographs first")
    func bothNamedPhotographsFirst() throws {
        let message = Self.prompt(photos: 2, walks: 3).message
        let photographs = try #require(message.range(of: "2 photographs"))
        let walks = try #require(message.range(of: "3 walks"))
        #expect(photographs.lowerBound < walks.lowerBound)
    }

    /// The promise `docs/privacy` and `docs/terms` both make is that removing
    /// a hike from your own device does not withdraw a submission. This is the
    /// one moment the app can say so — and it must not imply otherwise by
    /// staying quiet.
    @Test("a published hike is told its public copy stays up")
    func publishedCopyStaysUp() {
        let message = Self.prompt(publication: .published).message
        #expect(message.contains("published copy"))
        #expect(message.contains("does not take it down"))
    }

    /// A submission in flight is the same news in different words: sent is not
    /// published, and neither is withdrawn by a deletion.
    @Test("a hike awaiting review is told its submission stands")
    func submissionStands() {
        let message = Self.prompt(publication: .awaitingReview).message
        #expect(message.contains("does not withdraw it"))
    }

    /// And a hike that was never shared is told nothing about the community,
    /// because there is nothing to tell.
    @Test("an unshared hike says nothing about the community")
    func unsharedSaysNothing() {
        let message = Self.prompt(publication: .notShared).message
        #expect(!message.lowercased().contains("community"))
        #expect(!message.lowercased().contains("published"))
    }

    /// The button is named for the act rather than left as "Delete", so the
    /// dialog's two buttons cannot be told apart only by their role.
    @Test("the confirming button names what it deletes")
    func confirmTitle() {
        #expect(Self.prompt().confirmTitle == "Delete Hike")
    }
}
