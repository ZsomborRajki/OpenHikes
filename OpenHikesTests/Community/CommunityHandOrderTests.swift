//
//  CommunityHandOrderTests.swift
//  OpenHikesTests
//
//  The order a hiker dragged community rows into, and where the rows nobody
//  moved end up.
//
//  The sort compares hand positions alone and leaves every tie to
//  `sorted(by:)` being stable, so the cases here are mostly ties: the rows
//  nobody moved all sort as one, and only stability keeps them in the order
//  the search gave them.
//

@testable import OpenHikes
import Testing

@MainActor
@Suite("Community hand order")
struct CommunityHandOrderTests {
    private static func browser(handOrder: [String: Int]) -> CommunityBrowser {
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        browser.handOrder = handOrder
        return browser
    }

    private static let found: [CommunityListing] = ["a", "b", "c", "d", "e"].map { .stub(id: $0) }

    @Test("with nothing moved, the search's order stands")
    func nothingMovedKeepsTheSearchOrder() {
        #expect(Self.browser(handOrder: [:]).arranged(Self.found).map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test("moved rows lead in their hand order, and the rest keep the search's order after them")
    func movedRowsLeadAndTheRestKeepTheirOrder() {
        let browser = Self.browser(handOrder: ["d": 0, "b": 1])

        #expect(browser.arranged(Self.found).map(\.id) == ["d", "b", "a", "c", "e"])
    }

    @Test("two rows given the same position keep the search's order")
    func equalPositionsKeepTheSearchOrder() {
        let browser = Self.browser(handOrder: ["e": 0, "c": 0, "a": 1])

        #expect(browser.arranged(Self.found).map(\.id) == ["c", "e", "a", "b", "d"])
    }
}
