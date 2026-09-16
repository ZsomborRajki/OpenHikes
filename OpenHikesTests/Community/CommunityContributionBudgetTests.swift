//
//  CommunityContributionBudgetTests.swift
//  OpenHikesTests
//
//  How much one tap on a community row is allowed to download.
//
//  Two ceilings sit on a hike's contributed photographs and they bound
//  different things, which is the whole reason this suite exists: the query's
//  limit bounds *how many sets come back* and does nothing at all about the
//  transfer, because a single set may carry
//  ``CommunityPublisher/maximumPhotos`` pictures. Twenty sets of thirty-six is
//  seven hundred assets for one row somebody tapped to see whether a trail is
//  worth their Saturday.
//
//  What makes it testable is that the count is on the **published** record —
//  ``CommunitySchema/Contribution/photoCount`` — so the budget is spent before
//  the fetch rather than described after it. A budget applied to what came
//  back is not a budget; it is a note about what was already paid for.
//
//  The shape of the answer matters as much as its size. It is a **prefix**
//  taken oldest-first, so a hike's gallery cannot depend on which sets
//  happened to fit — skipping an over-large set would let a later, smaller one
//  jump ahead of an earlier one, and two people opening the same hike would
//  see the pictures in different orders.
//
//  `CKRecord`-free, like `CommunityPhotoPairingTests` beside it: what is worth
//  pinning is the arithmetic, and the fetch around it needs the public
//  database.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Community contribution budget")
struct CommunityContributionBudgetTests {
    private static func record(
        _ id: String,
        photos: Int
    ) -> CloudKitCommunityTransport.ContributionRecord {
        CloudKitCommunityTransport.ContributionRecord(
            id: id,
            photoSubmissionID: "\(id)-submission",
            authorName: "Anna",
            authorID: "author-1",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            photoCount: photos
        )
    }

    private static func budget(
        _ counts: [Int]
    ) -> [CloudKitCommunityTransport.ContributionRecord] {
        CloudKitCommunityTransport.withinBudget(
            counts.enumerated().map { index, photos in
                record("c\(index)", photos: photos)
            }
        )
    }

    /// The ordinary case: a hike with a handful of contributions, all of them
    /// drawn. Nothing about the budget should be visible here.
    @Test("everything under the ceiling is kept")
    func aSmallHikeKeepsEverything() {
        #expect(Self.budget([3, 4, 2]).map(\.photoCount) == [3, 4, 2])
    }

    /// The ceiling itself, from both sides of it, pinned against the constant
    /// rather than against 60 written out again.
    @Test("a set that would overflow stops the list")
    func theCeilingStops() {
        let ceiling = CloudKitCommunityTransport.maximumContributedPhotos
        // Exactly full, then one more.
        #expect(Self.budget([ceiling, 1]).map(\.photoCount) == [ceiling])
        #expect(Self.budget([ceiling - 1, 1]).map(\.photoCount) == [ceiling - 1, 1])
        #expect(Self.budget([ceiling - 1, 2]).map(\.photoCount) == [ceiling - 1])
    }

    /// A prefix and not a filter. A smaller set after an over-large one is
    /// left out rather than promoted, because a gallery whose order depended
    /// on what fitted would show two people the same hike differently.
    @Test("a later small set does not jump an earlier large one")
    func theOrderIsNotRearranged() {
        let ceiling = CloudKitCommunityTransport.maximumContributedPhotos
        let kept = Self.budget([4, ceiling, 1])

        #expect(kept.map(\.photoCount) == [4])
        #expect(!kept.contains { $0.photoCount == 1 })
    }

    /// The first set is always taken, however large. A hike whose only
    /// contribution is over the budget would otherwise draw nothing at all and
    /// say nothing about why — and the cap on what one hiker may *send* is
    /// what bounds that case at source.
    @Test("a single oversized set is still drawn")
    func theFirstSetIsAlwaysTaken() {
        let overCap = CloudKitCommunityTransport.maximumContributedPhotos + 40
        #expect(Self.budget([overCap]).map(\.photoCount) == [overCap])
    }

    /// A record written before the count existed, or by hand in the Console,
    /// spends nothing — which errs towards showing the photographs rather than
    /// hiding them, the direction every other absence in this feature is
    /// resolved in.
    @Test("a set with no recorded count costs nothing")
    func anUncountedSetSpendsNothing() {
        let ceiling = CloudKitCommunityTransport.maximumContributedPhotos
        #expect(Self.budget([0, 0, ceiling]).count == 3)
    }

    @Test("no contributions is no work")
    func nothingIsNothing() {
        #expect(Self.budget([]).isEmpty)
    }

    /// The relationship between the two ceilings, stated so a change to either
    /// has to be argued for: the download budget has to be reachable within
    /// the number of sets the query returns, or one of the two is decoration.
    @Test("the two ceilings are about different things and both bite")
    func bothCeilingsAreLoadBearing() {
        let sets = CloudKitCommunityTransport.maximumContributions
        let photos = CloudKitCommunityTransport.maximumContributedPhotos
        #expect(sets > 1, "a set limit of one would make the photo budget unreachable")
        #expect(
            photos < sets * CommunityPublisher.maximumPhotos,
            """
            the photo budget has to be the binding one at full sets — \
            \(photos) against \(sets) × \(CommunityPublisher.maximumPhotos)
            """
        )
    }
}
