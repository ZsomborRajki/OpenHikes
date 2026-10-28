//
//  HikePlacesSearchLifetimeTests.swift
//  OpenHikesTests
//
//  A place search belongs to its pushed route. Replacing the portrait host
//  with the landscape host must neither repeat its request nor cancel its
//  answer; leaving the route must do both kinds of cleanup.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Place search lifetime", .timeLimit(.minutes(1)))
struct HikePlacesSearchLifetimeTests {
    private static let line = [
        RouteCoordinate(latitude: 47.60, longitude: 12.98),
        RouteCoordinate(latitude: 47.61, longitude: 12.98),
    ]
    private static let spring = TrailPlace(latitude: 47.605, longitude: 12.98, name: "Spring", symbol: .water)

    @Test("reattaching while the requested kinds and reach are in flight asks nothing")
    func inFlightSearchAlreadyCoversTheRequest() async {
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let search = HikePlacesAroundSearch()
        let request = search.search(along: Self.line, from: source, showing: [.water])
        await source.waitUntilAsked()

        #expect(!search.needsSearch(showing: [.water]), "a replacement host must keep the request already out")
        #expect(search.needsSearch(showing: [.water, .shelter]), "a new kind still needs a wider request")

        await source.release()
        await request.value
        #expect(search.found.map(\.place.name) == ["Spring"])
        #expect(!search.needsSearch(showing: [.water]))
    }
    @Test("a canceled request stays eligible and its late answer is discarded")
    func cancellationCanBeRetried() async {
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let search = HikePlacesAroundSearch()
        let request = search.search(along: Self.line, from: source, showing: [.water])
        await source.waitUntilAsked()

        search.cancel()
        #expect(search.needsSearch(showing: [.water]))
        await source.release()
        await request.value
        #expect(await source.cancelledCalls == 1)
        #expect(search.found.isEmpty)

        await search.search(along: Self.line, from: source, showing: [.water]).value
        #expect(search.found.map(\.id) == [Self.spring.id])
        #expect(await source.calls == 2)
        #expect(!search.needsSearch(showing: [.water]))
    }

    @Test("a late canceled answer cannot finish the replacement request")
    func canceledAnswerLeavesTheNewRequestPending() async {
        let first = HeldPlaceSearchSource(answer: [Self.spring])
        let second = HeldPlaceSearchSource(answer: [])
        let search = HikePlacesAroundSearch()
        let old = search.search(along: Self.line, from: first, showing: [.water])
        await first.waitUntilAsked()
        let current = search.search(along: Self.line, from: second, showing: [.water, .shelter])
        await second.waitUntilAsked()

        await first.release()
        await old.value
        #expect(search.phase == .searching)
        #expect(search.found.isEmpty)
        #expect(!search.needsSearch(showing: [.water, .shelter]))

        await second.release()
        await current.value
        #expect(search.phase == .found)
        #expect(!search.needsSearch(showing: [.water, .shelter]))
    }

    @Test("ending a search discards area ordering that is still queued")
    func canceledAreaAnswerIsDiscarded() async {
        let search = HikePlacesAroundSearch()
        let receiving = search.receiveArea([Self.spring], along: Self.line)
        search.cancel()

        await receiving.value

        #expect(search.found.isEmpty)
        #expect(search.askedAbout.isEmpty)
    }

    @Test("canceling the returned task stops counting its pending coverage")
    func returnedTaskCancellationAllowsAnotherSearch() async {
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let search = HikePlacesAroundSearch()
        let request = search.search(along: Self.line, from: source, showing: [.water])
        await source.waitUntilAsked()

        request.cancel()
        #expect(search.needsSearch(showing: [.water]))
        await source.release()
        await request.value

        #expect(await source.cancelledCalls == 1)
        #expect(search.found.isEmpty)
        #expect(search.needsSearch(showing: [.water]))
    }

}
