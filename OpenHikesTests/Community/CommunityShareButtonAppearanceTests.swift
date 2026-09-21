//
//  CommunityShareButtonAppearanceTests.swift
//  OpenHikesTests
//
//  The eight things the community button on a hike's toolbar can be, and the
//  precedence that picks between them.
//
//  ``CommunityShareButtonAppearance`` exists because a glyph, a spoken label
//  and a spoken hint used to be three functions walking the same precedence in
//  parallel, and its header argues that the walk is not obvious enough to be
//  safely written three times. A walk worth folding into one place is a walk
//  worth pinning: what is asserted here is the *shape* of each answer — which
//  glyph, whether there is a hint, and which of the two journeys wins when a
//  hike is on both at once — rather than the sentences, which are copy and
//  will be rewritten without the button changing.
//
//  The one string compared literally is the refusal's label, and it is
//  compared to ``CommunityPublishingEligibility/Reason/shortLabel`` rather
//  than to a quoted sentence: the claim is that the button says what the
//  reason says, which stays true in any wording and in any locale.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Community share button appearance")
struct CommunityShareButtonAppearanceTests {
    /// Somewhere for photographs to go: a trail the list already has.
    private static let target = CommunityPhotoTarget(
        listingID: "listing-1",
        title: "Königssee",
        authorName: nil
    )

    private static let everyContribution: [CommunityContributionState] = [
        .notShared, .awaitingReview, .published,
    ]

    private static func appearance(
        _ publication: CommunityPublicationState,
        _ eligibility: CommunityPublishingEligibility,
        _ contribution: CommunityContributionState = .notShared
    ) -> CommunityShareButtonAppearance {
        CommunityShareButtonAppearance(
            publication: publication,
            eligibility: eligibility,
            contribution: contribution
        )
    }

    @Test("an eligible hike offers to go, and says nothing the glyph has not")
    func eligible() {
        let button = Self.appearance(.notShared, .eligible)
        #expect(button.symbol == "person.2")
        #expect(button.hint.isEmpty, "the label already says it; a hint here is a second thing to listen to")
    }

    @Test("a refused hike is slashed, and borrows the reason's own words")
    func refused() {
        let reason = CommunityPublishingEligibility.Reason.tooShort(meters: 420)
        let button = Self.appearance(.notShared, .refused(reason))
        #expect(button.symbol == "person.2.slash")
        #expect(button.label == reason.shortLabel)
        #expect(!button.hint.isEmpty, "a refusal has to offer the explanation")
    }

    @Test("a trail the list already has offers the photographs instead")
    func photographsOnly() {
        let eligibility = CommunityPublishingEligibility.photographsOnly(
            Self.target, because: .savedFromOpenStreetMap
        )
        #expect(Self.appearance(.notShared, eligibility).symbol == "photo.badge.plus")
    }

    @Test("photographs sent and unchecked are waiting, and can be withdrawn")
    func photographsAwaitingReview() {
        let eligibility = CommunityPublishingEligibility.photographsOnly(
            Self.target, because: .savedFromOpenStreetMap
        )
        let button = Self.appearance(.notShared, eligibility, .awaitingReview)
        #expect(button.symbol == "hourglass")
        #expect(!button.hint.isEmpty)
    }

    @Test("photographs already on the trail say so")
    func photographsPublished() {
        let eligibility = CommunityPublishingEligibility.photographsOnly(
            Self.target, because: .savedFromOpenStreetMap
        )
        #expect(Self.appearance(.notShared, eligibility, .published).symbol == "photo.badge.checkmark")
    }

    @Test("a hike waiting for review says waiting, whatever its photographs are doing")
    func hikeAwaitingReview() {
        for contribution in Self.everyContribution {
            let button = Self.appearance(.awaitingReview, .eligible, contribution)
            #expect(button.symbol == "hourglass", "contribution \(contribution) changed the route's own answer")
        }
    }

    @Test("a published hike outranks its photographs, in all three of their states")
    func publishedOutranksPhotographs() {
        for contribution in Self.everyContribution {
            let button = Self.appearance(.published, .eligible, contribution)
            #expect(button.symbol == "person.2.fill", "contribution \(contribution) took the route's glyph")
        }
    }

    @Test("a published hike's hint is the half that names whichever is waiting")
    func publishedHintFollowsThePhotographs() {
        let hints = Self.everyContribution.map { contribution in
            Self.appearance(.published, .eligible, contribution).hint
        }
        #expect(
            Set(hints).count == hints.count,
            "two contribution states shared a hint, so the button cannot tell them apart"
        )
        #expect(hints.allSatisfy { !$0.isEmpty })
    }

    @Test("nothing waiting for review is ever called rejected")
    func neverRejected() {
        // The absence of a listing covers a reviewer who has not looked and
        // one who declined, and the app cannot tell those apart. A button that
        // claimed to would be an observation nothing supports.
        let everything = Self.everyMatrixEntry()
        #expect(everything.allSatisfy { !$0.label.lowercased().contains("reject") })
        #expect(everything.allSatisfy { !$0.hint.lowercased().contains("reject") })
    }

    @Test("every state gives the glyph something to say")
    func everyStateSpeaks() {
        for button in Self.everyMatrixEntry() {
            #expect(!button.symbol.isEmpty)
            #expect(!button.label.isEmpty, "a glyph says nothing on its own")
        }
    }

    /// Every combination the button can be asked for, which is what makes the
    /// two claims above claims about the type rather than about one branch.
    private static func everyMatrixEntry() -> [CommunityShareButtonAppearance] {
        let eligibilities: [CommunityPublishingEligibility] = [
            .eligible,
            .photographsOnly(target, because: .savedFromOpenStreetMap),
            .refused(.tooShort(meters: 420)),
            .refused(.retreads(title: "Königssee")),
            .refused(.savedFromTheCommunity(author: nil)),
        ]
        let publications: [CommunityPublicationState] = [.notShared, .awaitingReview, .published]
        return publications.flatMap { publication in
            eligibilities.flatMap { eligibility in
                everyContribution.map { appearance(publication, eligibility, $0) }
            }
        }
    }
}
