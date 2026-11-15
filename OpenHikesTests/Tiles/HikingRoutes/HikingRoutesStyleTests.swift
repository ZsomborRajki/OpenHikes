//
//  HikingRoutesStyleTests.swift
//  OpenHikesTests
//
//  The layer's look, zoom by zoom, as Waymarked Trails drew it: which
//  networks are stroked, which are stacked, and which routes get a sign.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Hiking routes style")
struct HikingRoutesStyleTests {
    /// Whether any stroke at `zoom` draws a line of `networks`.
    private static func isStroked(_ networks: RouteNetworkSet, at zoom: Int) -> Bool {
        HikingRoutesStyle.strokes(atZoom: zoom).contains { $0.draws(networks) }
    }

    @Test("a route outside OpenStreetMap's scheme is drawn as a local one")
    func untaggedIsLocal() {
        #expect(RouteNetworkSet(.other) == .local)
        #expect(RouteNetworkSet(.international) == .international)
    }

    @Test("a local route is not drawn from a country's view, and is from zoom 12")
    func localRoutesByZoom() {
        for zoom in [7, 9, 10, 11] {
            #expect(!Self.isStroked(.local, at: zoom), "zoom \(zoom)")
        }
        for zoom in [12, 13, 14, 18] {
            #expect(Self.isStroked(.local, at: zoom), "zoom \(zoom)")
        }
        #expect(!HikingRoutesStyle.isDrawn(.local, at: .region))
        #expect(HikingRoutesStyle.isDrawn(.local, at: .area))
        #expect(HikingRoutesStyle.isDrawn(.regional, at: .region))
    }

    @Test("a regional route is drawn from zoom 10, and the long routes at every zoom")
    func longRoutesByZoom() {
        #expect(!Self.isStroked(.regional, at: 9))
        #expect(Self.isStroked(.regional, at: 10))
        for zoom in 7...18 {
            #expect(Self.isStroked(.national, at: zoom), "zoom \(zoom)")
            #expect(Self.isStroked(.international, at: zoom), "zoom \(zoom)")
        }
    }

    @Test("routes that share a way are stacked: the more important network wider and underneath")
    func stacked() throws {
        let shared: RouteNetworkSet = [.international, .national]
        let strokes = HikingRoutesStyle.strokes(atZoom: 12).filter { $0.draws(shared) }
        #expect(strokes.count == 2)
        let under = try #require(strokes.first), over = try #require(strokes.last)
        #expect(under.width > over.width)
        #expect(HikingRoutesStyle.widestStroke(atZoom: 12) >= under.width)
    }

    @Test("a regional route along a national one is dots on it")
    func dots() {
        let strokes = HikingRoutesStyle.strokes(atZoom: 12)
        let dotted = strokes.filter { $0.draws([.regional, .national]) && !$0.dash.isEmpty }
        let alone = strokes.filter { $0.draws(.regional) }.map(\.dash)
        #expect(dotted.count == 1)
        #expect(alone == [[]], "on its own it is one solid line")
    }

    @Test("only the long routes get a sign until zoom 13, and from there every route does")
    func signsByZoom() {
        #expect(HikingRoutesStyle.waymarkRule(atZoom: 8).minimumNetwork == .international)
        #expect(HikingRoutesStyle.waymarkRule(atZoom: 9).minimumNetwork == .national)
        for zoom in 10...12 {
            #expect(HikingRoutesStyle.waymarkRule(atZoom: zoom).minimumNetwork == .regional, "zoom \(zoom)")
        }
        for zoom in [13, 14, 18] {
            #expect(HikingRoutesStyle.waymarkRule(atZoom: zoom).minimumNetwork == .local, "zoom \(zoom)")
        }
    }

    @Test("the same sign stands further apart than any two signs do, at every zoom")
    func repeatDistance() {
        for zoom in 7...18 {
            let rule = HikingRoutesStyle.waymarkRule(atZoom: zoom)
            #expect(rule.repeatDistance > rule.margin, "zoom \(zoom)")
            #expect(rule.spacing > rule.repeatDistance, "zoom \(zoom)")
        }
    }
}
