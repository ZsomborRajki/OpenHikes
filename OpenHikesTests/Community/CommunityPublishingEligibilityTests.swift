//
//  CommunityPublishingEligibilityTests.swift
//  OpenHikesTests
//
//  The gate in front of publishing, and the three things it is allowed to be
//  certain about.
//
//  The bug these exist for: `CommunityImport` stamps `importedFromListingID`
//  on a hike saved from somebody else's listing, and the share button never
//  asked. `CommunityPublicationState` knew three states — not shared, awaiting
//  review, published — and a hike saved from a stranger's listing is *not
//  shared*, because this hiker has not shared it. So it got the plain **Share
//  with the community** button, and publishing from there uploaded a
//  stranger's route, their description and re-encoded copies of up to twelve
//  of their photographs, credited to whatever name the saver typed.
//
//  The terms already said a hiker may not do that, and the share form repeated
//  it as advice. This is the one case where the app knows the answer, so advice
//  was the wrong instrument.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Community publishing eligibility")
struct CommunityPublishingEligibilityTests {
    private static func of(
        listingID: String? = nil,
        author: String? = nil,
        meters: Double = 5000
    ) -> CommunityPublishingEligibility {
        .of(
            importedFromListingID: listingID,
            importedAuthorName: author,
            distanceMeters: meters
        )
    }

    @Test("an ordinary recorded walk may be published")
    func ordinaryWalk() {
        #expect(Self.of() == .eligible)
        #expect(Self.of().isEligible)
        #expect(Self.of().reason == nil)
    }

    /// The case the issue is about, and the only one where the app is certain
    /// rather than asking the hiker to judge.
    @Test("a hike saved from the community cannot be published again")
    func savedFromTheCommunity() {
        let eligibility = Self.of(listingID: "listing-1", author: "Anna")
        #expect(eligibility == .refused(.savedFromTheCommunity(author: "Anna")))
    }

    /// A listing shared without a name still cannot be republished; the
    /// refusal just has to say it differently.
    @Test("an import with no credit is still an import")
    func savedWithoutACredit() {
        #expect(Self.of(listingID: "listing-1") == .refused(.savedFromTheCommunity(author: nil)))
        let explanation = CommunityPublishingEligibility.Reason
            .savedFromTheCommunity(author: nil).explanation
        #expect(explanation.contains("Another hiker"))
    }

    /// **A GPX imported from anywhere else is not an import in this sense.**
    ///
    /// A route downloaded from another provider, walked, and given the hiker's
    /// own photographs is exactly what this feature is for, and it carries no
    /// `importedFromListingID` — only a hike saved out of this app's own
    /// community does. A rule that refused every imported file would empty the
    /// list of the hikes most worth having in it.
    @Test("a hike imported from a file is not refused")
    func importedFromAFile() {
        #expect(Self.of(listingID: nil, author: nil) == .eligible)
    }

    /// The floor, from both sides of it. Pinned against the constant rather
    /// than against 1,000 written out again, so moving the floor moves the
    /// test with it rather than leaving it asserting a number nothing uses.
    @Test("a walk under the floor is refused and one on it is not")
    func theFloor() {
        let floor = CommunityPublishingEligibility.minimumDistanceMeters
        #expect(Self.of(meters: floor) == .eligible)
        #expect(Self.of(meters: floor - 1) == .refused(.tooShort(meters: floor - 1)))
        #expect(Self.of(meters: 0) == .refused(.tooShort(meters: 0)))
    }

    /// Provenance first. A hike that is both somebody else's *and* short is
    /// refused for the reason that is about who it belongs to, because that is
    /// the one the hiker cannot fix by walking further.
    @Test("an import that is also too short is refused as an import")
    func provenanceOutranksLength() {
        let eligibility = Self.of(listingID: "listing-1", author: "Anna", meters: 10)
        #expect(eligibility == .refused(.savedFromTheCommunity(author: "Anna")))
    }

    /// Every refusal has to name the thing the hiker can still do. A dead end
    /// reads as the feature being broken rather than as a rule.
    @Test("every refusal says what to do instead", arguments: [
        CommunityPublishingEligibility.Reason.savedFromTheCommunity(author: "Anna"),
        .tooShort(meters: 300),
        .retreads(title: "Thumsee Ridge Traverse"),
    ])
    func refusalsAreActionable(reason: CommunityPublishingEligibility.Reason) {
        #expect(!reason.title.isEmpty)
        #expect(!reason.shortLabel.isEmpty)
        #expect(reason.explanation.count > reason.title.count)
    }

    /// The specifics are what make a refusal checkable: a hiker who is told
    /// "too short" and not how short, or "already shared" and not which one,
    /// has been given a verdict rather than a reason.
    @Test("a refusal names the hike, the author or the distance")
    func refusalsCarryTheirSpecifics() {
        #expect(
            CommunityPublishingEligibility.Reason
                .savedFromTheCommunity(author: "Anna").explanation.contains("Anna")
        )
        #expect(
            CommunityPublishingEligibility.Reason
                .retreads(title: "Thumsee Ridge Traverse")
                .explanation.contains("Thumsee Ridge Traverse")
        )
        // The floor and the walk, in the same unit the stat grid above it uses.
        let tooShort = CommunityPublishingEligibility.Reason.tooShort(meters: 300).explanation
        #expect(tooShort.contains("1 km") || tooShort.contains("0.6 mi"))
    }
}
