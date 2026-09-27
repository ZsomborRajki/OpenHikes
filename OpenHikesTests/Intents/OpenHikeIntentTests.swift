//
//  OpenHikeIntentTests.swift
//  OpenHikesTests
//
//  What "open this hike" amounts to when the thing asking is outside the view
//  tree.
//
//  `AppIntent.perform()` can only be exercised by the system, which is the
//  split every other intent in this folder is built around — the intent is a
//  title, a phrase and one call, and what is tested is the call. Here the call
//  is into ``HikeOpenRequests``, and what is worth asserting is the shape of
//  the request rather than the navigation it triggers: that it arrives as a
//  link the widget's own router understands, that the same hike asked for
//  twice is two requests rather than one, and that nothing is replayed to a
//  listener that arrives late. What any reader of the underlying feed is
//  promised is `EventFeedTests`'.
//
//  The navigation itself is `OpenHikesView`'s and is covered where that lives.
//  The point of routing through the deep link is precisely that there is
//  nothing new to test on the far side of it.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Opening a hike from outside the view tree")
@MainActor
struct OpenHikeIntentTests {
    /// The request arrives as something ``TrailWidgetDeepLink`` can read back,
    /// which is the whole of why it is a URL and not an id: it means the
    /// intent reaches the router *as a widget tap* and inherits every rule
    /// that path already keeps.
    @Test("a request arrives as a link the widget's own router understands")
    func requestIsAWidgetDeepLink() async throws {
        let requests = HikeOpenRequests()
        let reader = FeedReader(requests.links())
        let id = UUID()

        requests.open(hikeID: id)
        await settleDelegateHop(until: "the link to be read") { !reader.received.isEmpty }

        let url = try #require(reader.received.last)
        #expect(TrailWidgetDeepLink.hikeID(from: url) == id)
        #expect(TrailWidgetDeepLink.destination(from: url) == .hike(id))
    }

    /// Each ask is its own request. "Open the Rennsteig" said twice is a
    /// hiker asking twice — most likely because the first one did not appear
    /// to do anything — and a channel that folded the repeat into the first
    /// would answer the second ask with nothing.
    @Test("the same hike asked for twice is two requests, and a different one its own")
    func eachAskIsARequest() async {
        let requests = HikeOpenRequests()
        let reader = FeedReader(requests.links())
        let first = UUID()
        let second = UUID()

        requests.open(hikeID: first)
        requests.open(hikeID: first)
        requests.open(hikeID: second)
        await settleDelegateHop(until: "all three links to be read") { reader.received.count == 3 }

        #expect(reader.received.map(TrailWidgetDeepLink.hikeID(from:)) == [first, first, second])
    }

    /// Nothing asked before the view tree started reading reaches it, so a
    /// launch cannot act on a stale link at startup. The feed's own suite
    /// covers the rest of what a reader is promised — see `EventFeedTests`.
    @Test("a request made before anyone listened is not replayed")
    func nothingIsReplayedToALateListener() async {
        let requests = HikeOpenRequests()
        let early = UUID()
        let late = UUID()

        requests.open(hikeID: early)
        let reader = FeedReader(requests.links())
        requests.open(hikeID: late)
        await settleDelegateHop(until: "the later link to be read") { !reader.received.isEmpty }

        #expect(reader.received.map(TrailWidgetDeepLink.hikeID(from:)) == [late])
    }
}
