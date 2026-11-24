//
//  RootNavigationRequestTests.swift
//  OpenHikesTests
//
//  The root view's navigation requests, read from their four feeds in one
//  loop: every message of each feed arrives, in the order it was sent, and
//  the loop's task cancelled lets go of every feed.
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

    /// What the loop handed on, in order.
    @MainActor
    private final class Handled {
        private(set) var requests: [RootNavigationRequest] = []

        func append(_ request: RootNavigationRequest) { requests.append(request) }
    }

    private var readerCounts: [Int] {
        [links.readerCount, maker.readerCount, places.readerCount, endings.readerCount]
    }

    /// The loop, in a task of its own, once it is reading all four feeds.
    private func reading(into handled: Handled) async -> Task<Void, Never> {
        let task = Task {
            await RootNavigationRequest.read(
                hikeLinks: links.events(),
                makerRequests: maker.events(),
                placeRequests: places.events(),
                endings: endings.events()
            ) { handled.append($0) }
        }
        await settleDelegateHop(until: "every feed has its reader") { readerCounts == [1, 1, 1, 1] }
        return task
    }

    @Test("every request of every feed is handed on, each feed's in the order it was sent")
    func consecutiveRequests() async throws {
        let handled = Handled()
        let task = await reading(into: handled)
        let first = try #require(URL(string: "openhikes://hike/1"))
        let second = try #require(URL(string: "openhikes://hike/2"))
        let saved = ActivityEnding.recordingSaved(hikeID: UUID())
        let kept = ActivityEnding.walkKept(hikeID: UUID(), walkID: UUID())

        links.send(first)
        links.send(second)
        maker.send(())
        maker.send(())
        places.send(())
        places.send(())
        endings.send(saved)
        endings.send(kept)
        await settleDelegateHop(until: "all eight are handed on") { handled.requests.count == 8 }

        let requests = handled.requests
        #expect(requests.filter { if case .hike = $0 { true } else { false } } == [.hike(first), .hike(second)])
        #expect(requests.filter { if case .ending = $0 { true } else { false } } == [.ending(saved), .ending(kept)])
        #expect(requests.count { $0 == .maker } == 2)
        #expect(requests.count { $0 == .place } == 2)
        task.cancel()
        await task.value
    }

    @Test("cancelled, the loop ends and lets go of every feed, and hands on nothing after")
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
