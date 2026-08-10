//
//  TrailWidgetDeepLinkTests.swift
//  OpenTrailsSharedTests
//
//  The widget formats these links and the app parses them, in two different
//  processes that ship together — so the round trip is worth pinning, as is
//  the refusal of anything unrecognised.
//

import Foundation
import Testing
@testable import OpenTrailsShared

@Suite("Widget deep links")
struct TrailWidgetDeepLinkTests {
    @Test("a hike link round trips")
    func roundTrip() throws {
        let id = UUID()
        let url = try #require(TrailWidgetDeepLink.url(hikeID: id))
        #expect(TrailWidgetDeepLink.hikeID(from: url) == id)
    }

    @Test("round trips for any hike, not just a lucky one")
    func roundTripsForAnyID() throws {
        for _ in 0..<500 {
            let id = UUID()
            let url = try #require(TrailWidgetDeepLink.url(hikeID: id))
            #expect(TrailWidgetDeepLink.hikeID(from: url) == id)
        }
    }

    @Test("the link is the shape the app expects")
    func linkShape() throws {
        let id = UUID()
        let url = try #require(TrailWidgetDeepLink.url(hikeID: id))
        #expect(url.scheme == "opentrails")
        #expect(url.host == "hike")
        #expect(url.absoluteString == "opentrails://hike/\(id.uuidString)")
    }

    /// Anything unrecognised has to come back `nil` so the app falls through
    /// to "just launch" rather than acting on a link it misread.
    @Test("unrecognised links are refused", arguments: [
        "opentrails://hike/not-a-uuid",
        "opentrails://hike/",
        "opentrails://hike",
        "opentrails://settings/\(UUID().uuidString)",
        "https://example.com/hike/\(UUID().uuidString)",
        "othertrails://hike/\(UUID().uuidString)",
        "opentrails:/\(UUID().uuidString)"
    ])
    func refusesUnknownLinks(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(TrailWidgetDeepLink.hikeID(from: url) == nil)
    }
}
