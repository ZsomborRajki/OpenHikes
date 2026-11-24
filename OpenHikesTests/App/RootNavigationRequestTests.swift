//
//  RootNavigationRequestTests.swift
//  OpenHikesTests
//
//  The root view's navigation requests, read from their four feeds in one
//  loop: every message arrives, in the order it was sent across the feeds,
//  and the task cancelled lets go of every feed.
//
//  The feeds are the case's own, as the app's are ``EventFeed``s, so the
//  ending is read off their reader counts rather than waited out.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Root navigation requests")
struct RootNavigationRequestTests {
    private let links = EventFeed<URL>()
    private let maker = EventFeed<Void>()
    private let places = EventFeed<Void>()
    private let endings = EventFeed<ActivityEnding>()

    /// What the reader handed on, in order.
    @MainActor
    private final class Handled {
        private(set) var requests: [RootNavigationRequest] = []

        func append(_ request: RootNavigationRequest) { requests.append(request) }
    }

    private var readerCounts: [Int] {
        [links.readerCount, maker.readerCount, places.readerCount, endings.readerCount]
    }

    /// The reader, in a task of its own, once all four feeds have joined it,
    /// as the root view's own reads them.
    private func reading(into handled: Handled) async -> Task<Void, Never> {
        let task = Task { [links, maker, places, endings] in
            await RootNavigationRequest.read { requests in
                [
                    links.events(into: requests) { .hike($0) },
                    maker.events(into: requests) { _ in .maker },
                    places.events(into: requests) { _ in .place },
                    endings.events(into: requests) { .ending($0) },
                ]
            } handle: { handled.append($0) }
        }
        await settleDelegateHop(until: "every feed has its reader") { readerCounts == [1, 1, 1, 1] }
        return task
    }

    /// Sends `request` down the feed it comes from.
    private func send(_ request: RootNavigationRequest) {
        switch request {
        case .hike(let url): links.send(url)
        case .maker: maker.send(())
        case .place: places.send(())
        case .ending(let ending): endings.send(ending)
        }
    }

    @Test("every request of every feed is handed on, in the order it was sent")
    func consecutiveRequests() async throws {
        let handled = Handled()
        let task = await reading(into: handled)
        let first = try #require(URL(string: "openhikes://hike/1"))
        let second = try #require(URL(string: "openhikes://hike/2"))
        let sent: [RootNavigationRequest] = [
            .hike(first), .hike(second),
            .maker, .maker,
            .place, .place,
            .ending(.recordingSaved(hikeID: UUID())), .ending(.walkKept(hikeID: UUID(), walkID: UUID())),
        ]

        for request in sent {
            send(request)
        }
        await settleDelegateHop(until: "all eight are handed on") { handled.requests.count == sent.count }

        #expect(handled.requests == sent)
        task.cancel()
        await task.value
    }

    @Test("requests from different feeds are handed on in the order they were sent")
    func ordersAcrossFeeds() async throws {
        let handled = Handled()
        let task = await reading(into: handled)
        let link = try #require(URL(string: "openhikes://hike/1"))
        // *Make a Trail* and then a saved route's tap, and the other way
        // round: whichever came second replaces the first one's sheet, so it
        // has to be handled second. Repeated, because a reader that races
        // its feeds gets some rounds right.
        let round: [RootNavigationRequest] = [
            .maker, .hike(link), .hike(link), .maker,
            .place, .ending(.recordingDiscarded(hikeID: nil)), .hike(link), .place,
        ]
        let sent = Array(repeating: round, count: 25).flatMap(\.self)

        for request in sent {
            send(request)
        }
        await settleDelegateHop(until: "every request is handed on") { handled.requests.count == sent.count }

        #expect(handled.requests == sent)
        task.cancel()
        await task.value
    }

    @Test("cancelled, the reader ends and lets go of every feed, and hands on nothing after")
    func cancellationLetsGo() async {
        let handled = Handled()
        let task = await reading(into: handled)

        task.cancel()
        await task.value
        await settleDelegateHop(until: "every feed has lost its reader") { readerCounts == [0, 0, 0, 0] }
        maker.send(())
        endings.send(.recordingDiscarded(hikeID: nil))

        #expect(handled.requests.isEmpty)
    }
}
