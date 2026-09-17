//
//  CuratedTrailNoticeTests.swift
//  OpenHikesTests
//
//  What the caption under *Search this area* says about a search that asked
//  OpenStreetMap, and — the part worth a suite — which searches it says
//  nothing about.
//
//  The mapping is three lines long and every one of them was a bug at some
//  point. An area with no waymarked routes in it used to caption nothing at
//  all, which a hiker reads as a search that did not run; before that, the
//  only sentence this button could draw was *OpenStreetMap trails
//  unavailable*, which said a service was broken when the honest answer was
//  that there is nothing to walk near there. And a question that never asked
//  OpenStreetMap must stay silent, or a refill after a block would wipe a
//  rate limit that is still running off the screen.
//
//  Nothing here asserts the wording — see `CuratedTrailOutageTests` on why a
//  localised string is not a thing to pin — only that the sentences differ and
//  that they are differently *kinds* of sentence.
//

import Foundation
@testable import OpenHikes
import Testing

/// What each curated outcome puts under the button.
@Suite("Curated trail notice")
struct CuratedTrailNoticeTests {
    /// The case the scope exists for. A published-only question has nothing to
    /// report about a source it did not reach.
    @Test("a question that did not ask says nothing")
    func notAskedSaysNothing() {
        #expect(CuratedTrailOutcome.notAsked.notice == nil)
    }

    /// The gap this closed. The search worked, the answer is real, and it is
    /// an answer the hiker can act on by moving the map — which is precisely
    /// what they could not tell from a caption that stayed empty.
    @Test("an area with no trails in it says so")
    func anEmptyAreaSaysSo() {
        #expect(CuratedTrailOutcome.trails(0).notice == .noTrailsHere)
    }

    /// Trails are drawn in the list, which is where a hiker reads them. A
    /// caption saying the screen worked is a label on a working screen.
    @Test("trails that arrived say nothing")
    func trailsSayNothing() {
        #expect(CuratedTrailOutcome.trails(1).notice == nil)
        #expect(CuratedTrailOutcome.trails(25).notice == nil)
    }

    /// A refusal keeps its wait all the way to the caption, because the wait
    /// is what makes *try again* advice rather than a guess.
    @Test("a refusal is carried through as itself")
    func anOutageIsCarriedThrough() {
        let outage = CuratedTrailOutage.rateLimited(retryAfter: 60)

        #expect(CuratedTrailOutcome.outage(outage).notice == .outage(outage))
        #expect(CuratedTrailOutcome.outage(.unavailable).notice == .outage(.unavailable))
    }

    /// The two say different things, which is the whole point of there being
    /// two — and they say them differently: one is a failure and wears the
    /// warning glyph, and an empty area is not a failure at all.
    @Test("an empty area and a refusal are not the same sentence")
    func theTwoNoticesDiffer() {
        let empty = CuratedTrailNotice.noTrailsHere
        let refused = CuratedTrailNotice.outage(.unavailable)

        #expect(!empty.text.isEmpty)
        #expect(empty.text != refused.text)
        #expect(empty.symbolName != refused.symbolName)
        #expect(!empty.isWarning)
        #expect(refused.isWarning)
    }
}
