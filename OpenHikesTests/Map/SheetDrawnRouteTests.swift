//
//  SheetDrawnRouteTests.swift
//  OpenHikesTests
//
//  What a tap on the hiker's own line on the map opens.
//
//  The map draws one route of the hiker's own — the selected hike's — so the
//  tap has already named the hike by pointing at it, and there is no selection
//  to make and nothing to resolve. What is left is the two decisions the sheet
//  makes about every screen the map opens, and they are the two
//  ``SheetPresentation/showCommunityHike(_:)`` makes: where the sheet rests
//  when the screen arrives, and whether arriving is a push or a jump.
//
//  Both have a wrong answer that looks reasonable. Leaving the detent alone
//  puts a hike's screen into the compact detent, which is eighty points of
//  search field and nothing else — the screen is open and invisible. And
//  appending rather than assigning makes a tap on a line a step deeper into
//  whatever was already up, so Back from a trail lands on a stranger's preview
//  the hiker had left, or on a photograph of somewhere else.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

/// Where a tapped line goes.
@MainActor
@Suite("Sheet drawn route")
struct SheetDrawnRouteTests {
    @Test("tapping the drawn route opens its hike")
    func aTapOpensTheHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Line")
        let presentation = SheetPresentation(detent: .medium)

        presentation.showDrawnRoute(hike)

        #expect(presentation.path == [.hike(hike)])
    }

    /// The compact detent is the one the search state rests at, and it is the
    /// state this gesture was asked for: a hiker looking at a route they have
    /// already been reading, with the sheet dragged down out of the way.
    @Test("a tap from the search state raises the sheet to the middle detent")
    func aTapRaisesACompactSheet() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Line")
        let presentation = SheetPresentation(detent: SheetPresentation.compactDetent)

        presentation.showDrawnRoute(hike)

        #expect(presentation.detent == .medium)
        #expect(presentation.path == [.hike(hike)])
    }

    /// And down from the other end, which is the half that is easy to argue
    /// out of. A sheet at `.large` covers the map the thumb just landed on, so
    /// the height a reader chose is worth less than the thing they tapped.
    @Test("a tap from a full-height sheet drops it to the middle detent")
    func aTapDropsAFullHeightSheet() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Line")
        let presentation = SheetPresentation(detent: .large)

        presentation.showDrawnRoute(hike)

        #expect(presentation.detent == .medium)
    }

    /// A jump rather than a step deeper. Reached by tapping the line of the
    /// selected hike while somebody else's preview is up — the two are drawn
    /// on the same map at the same time, so this is one thumb away.
    @Test("a tap replaces whatever screen was up")
    func aTapReplacesTheStack() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Line")
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.communityHike(.stub(id: "pilis"))]

        presentation.showDrawnRoute(hike)

        #expect(presentation.path == [.hike(hike)])
    }

    /// And a tap on the line of the hike already in front asks for nothing:
    /// the detent is dealt with either way, and reassigning an identical path
    /// would take a `NavigationStack` through a push it has nowhere to go.
    @Test("tapping the line of the open hike changes nothing")
    func aRepeatedTapDoesNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Line")
        let presentation = SheetPresentation(detent: .medium)

        presentation.showDrawnRoute(hike)
        presentation.showDrawnRoute(hike)

        #expect(presentation.path == [.hike(hike)])
    }

    /// The map's own half of the same gesture: the coordinator calls this and
    /// nothing else, so a handler that was never set has to be a tap that does
    /// nothing rather than a crash — the window between the map being built
    /// and the view that owns the stack appearing.
    @Test("a tap before the sheet has claimed the line does nothing")
    func aTapWithoutAHandlerDoesNothing() {
        DrawnRouteTap().open()
    }

    @Test("the claimed handler is what a tap runs")
    func theClaimedHandlerRuns() {
        let tap = DrawnRouteTap()
        var opened = 0
        tap.onOpen { opened += 1 }

        tap.open()

        #expect(opened == 1)
    }
}
