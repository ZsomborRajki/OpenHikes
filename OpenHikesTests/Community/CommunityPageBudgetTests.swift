//
//  CommunityPageBudgetTests.swift
//  OpenHikesTests
//

@testable import OpenHikes
import Testing

/// How many pages a browse request spends, and the one case that made it spend
/// more than one.
@Suite("Community page budget")
struct CommunityPageBudgetTests {
    private static let limit = 25

    private static func page(
        of count: Int,
        by authorID: String,
        startingAt offset: Int = 0
    ) -> [CommunityListing] {
        (0..<count).map { index in
            .stub(id: "listing-\(offset + index)", authorID: authorID)
        }
    }

    /// The bargain that has to hold for everybody who has never blocked
    /// anyone: paging costs them nothing, because the first page already
    /// answers the question.
    @Test("a full page with nothing blocked ends the request")
    func oneFullPageIsEnough() {
        var budget = CommunityPageBudget(limit: Self.limit, excluding: [])
        let wantsMore = budget.accept(Self.page(of: Self.limit, by: "author-1"), hasMore: true)

        #expect(!wantsMore)
        #expect(budget.requestsMade == 1)
        #expect(budget.results.count == Self.limit)
    }

    /// The failure this type exists for. Twenty-five hikes by somebody the
    /// walker blocked used to draw *No shared hikes here* over an ordinary
    /// hike sitting at position twenty-six, and asking again returned the same
    /// hidden page forever.
    @Test("a page eaten by blocked rows buys another")
    func aBlockedPageIsFollowed() {
        var budget = CommunityPageBudget(limit: Self.limit, excluding: ["author-1"])

        let wantsSecond = budget.accept(
            Self.page(of: Self.limit, by: "author-1"),
            hasMore: true
        )
        #expect(wantsSecond)
        #expect(budget.results.isEmpty)

        let wantsThird = budget.accept(
            [.stub(id: "listing-26", authorID: "author-2")],
            hasMore: false
        )
        #expect(!wantsThird)
        #expect(budget.requestsMade == 2)
        #expect(budget.results.map(\.id) == ["listing-26"])
    }

    /// The public database's quota is shared by everybody using the app, so a
    /// walker who has blocked most of the authors near them must not be able
    /// to walk the whole table by panning.
    @Test("the request stops at the cap however much is blocked")
    func pagingIsBounded() {
        var budget = CommunityPageBudget(limit: Self.limit, excluding: ["author-1"])
        var pages = 0
        while budget.accept(Self.page(of: Self.limit, by: "author-1"), hasMore: true) {
            pages += 1
            #expect(pages < CommunityPageBudget.maxRequests, "paging did not stop")
        }

        #expect(budget.requestsMade == CommunityPageBudget.maxRequests)
        // Nothing, which is the honest reading of "everything near here is
        // from people you have blocked" rather than a failure.
        #expect(budget.results.isEmpty)
    }

    /// A last page ends the request however short it leaves the list. Asking
    /// again would return nothing, twice.
    @Test("a page with no cursor behind it ends the request")
    func noCursorEndsIt() {
        var budget = CommunityPageBudget(limit: Self.limit, excluding: ["author-1"])
        let wantsMore = budget.accept(
            Self.page(of: 3, by: "author-1") + [.stub(id: "keeper", authorID: "author-2")],
            hasMore: false
        )

        #expect(!wantsMore)
        #expect(budget.results.map(\.id) == ["keeper"])
    }

    /// Two short pages can add up to more than was asked for, and the caller
    /// asked for a screenful.
    @Test("more collected than asked for is trimmed to the limit")
    func resultsNeverExceedTheLimit() {
        var budget = CommunityPageBudget(limit: 3, excluding: ["author-1"])
        _ = budget.accept(Self.page(of: 2, by: "author-2"), hasMore: true)
        _ = budget.accept(Self.page(of: 5, by: "author-2", startingAt: 100), hasMore: true)

        #expect(budget.results.count == 3)
        #expect(budget.results.map(\.id) == ["listing-0", "listing-1", "listing-100"])
    }
}
