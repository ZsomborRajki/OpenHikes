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
//  link the widget's own router understands, and that the same hike asked for
//  twice is two requests rather than one.
//
//  The navigation itself is `OpenHikesView`'s and is covered where that lives.
//  The point of routing through the deep link is precisely that there is
//  nothing new to test on the far side of it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
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
    func requestIsAWidgetDeepLink() throws {
        let requests = HikeOpenRequests()
        let id = UUID()

        requests.open(hikeID: id)

        let url = try #require(requests.link)
        #expect(TrailWidgetDeepLink.hikeID(from: url) == id)
        #expect(TrailWidgetDeepLink.destination(from: url) == .hike(id))
    }

    /// The token is the message. A `URL?` alone would make the second ask
    /// invisible, and "open the Rennsteig" said twice is a hiker asking twice
    /// — most likely because the first one did not appear to do anything.
    @Test("the same hike asked for twice is two requests")
    func repeatedRequestsAreDistinct() {
        let requests = HikeOpenRequests()
        let id = UUID()

        requests.open(hikeID: id)
        let first = requests.request
        requests.open(hikeID: id)

        #expect(requests.request != first)
    }

    @Test("a different hike replaces the link as well as moving the token")
    func adifferentHikeReplacesTheLink() throws {
        let requests = HikeOpenRequests()
        let first = UUID()
        let second = UUID()

        requests.open(hikeID: first)
        requests.open(hikeID: second)

        let url = try #require(requests.link)
        #expect(TrailWidgetDeepLink.hikeID(from: url) == second)
    }

    /// A launch that was not started by an intent has nothing pending, so the
    /// view tree's `onChange` cannot fire on a stale link at startup.
    @Test("a fresh channel has nothing pending")
    func nothingIsPendingUntilSomethingAsks() {
        let requests = HikeOpenRequests()

        #expect(requests.link == nil)
        #expect(requests.request == 0)
    }
}
