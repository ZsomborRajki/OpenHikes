//
//  RouteAppearanceIsolationTests.swift
//  OpenHikesTests
//
//  `RenderIsolationTests` covers the state the app deliberately keeps *out* of
//  SwiftUI — `RouteHighlight`, `SheetMetrics`, `MapController`,
//  `LocationManager`, `TrackerState`. This covers the piece that joined them
//  last: a hike's `tint` and `routeWidth`.
//
//  Both live on the SwiftData `@Model` and both are written continuously (a
//  `ColorPicker` drag and a `Slider` drag). While `OpenHikesView.body` read them
//  — to hand them to the map inside `DisplayedRoute` — every drag sample
//  invalidated the root view, and with it the `.sheet` closure that builds
//  `MapSheet`: `HikeSearch.rankedHikes(matching:in:)` re-ran, the
//  `NavigationStack` rebuilt, and the pushed `HikeDetailView` that owns the
//  slider being dragged was re-evaluated. `MapView` is `.equatable()`, so the
//  diff stopped before MapKit; nothing stopped it before the sheet.
//
//  They now travel through `RouteStyle`, which the map coordinator observes
//  directly. So there are two halves to hold onto, and a test for each: the
//  root view's read set must not wake on a drag, and the map must still be told.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

@Suite("Route appearance isolation")
struct RouteAppearanceIsolationTests {
    /// Observes exactly what `OpenHikesView.body` reads of the selected hike —
    /// the real call, not a restatement of it, so a read added back to
    /// `DisplayedRoute.forSelection` fails here rather than passing against a
    /// copy that no longer matches.
    private func contentViewCounter(
        for hike: Hike,
        cache: DisplayedRouteCoordinateCache
    ) -> ObservationCounter {
        ObservationCounter { _ = DisplayedRoute.forSelection(hike, cache: cache) }
    }

    /// Dragging the line-width slider from 3 pt to 12 pt is nine writes. None
    /// of them is the root view's business: the map restyles its existing
    /// renderer from `RouteStyle`, and rebuilding the sheet would deliver
    /// nothing the map didn't already have.
    @Test("dragging the width slider doesn't invalidate the root view")
    func widthDragIsIsolatedFromTheRootView() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let cache = DisplayedRouteCoordinateCache()
        let style = RouteStyle()
        style.follow(hike)

        let rootView = contentViewCounter(for: hike, cache: cache)
        let map = ObservationCounter { _ = style.width }
        await rootView.settle()

        for width in stride(from: 4.0, through: 12.0, by: 1.0) {
            hike.routeWidth = width
            await rootView.settle()
        }

        #expect(rootView.count == 0, "the map restyles itself; the sheet has no part in it")
        #expect(map.count == 9, "…but every step must still reach the map")
        #expect(style.width == 12)
    }

    /// A `ColorPicker` drag writes `tintHex` continuously, and it used to reach
    /// the root view the same way. Worse than the slider, in fact: the picker's
    /// live preview updates on every touch sample rather than on integer steps.
    @Test("dragging the colour picker doesn't invalidate the root view")
    func tintDragIsIsolatedFromTheRootView() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let cache = DisplayedRouteCoordinateCache()
        let style = RouteStyle()
        style.follow(hike)

        let rootView = contentViewCounter(for: hike, cache: cache)
        let map = ObservationCounter { _ = style.tint }
        await rootView.settle()

        for step in 0..<10 {
            hike.tintHex = String(format: "#%02X8040FF", step * 20)
            await rootView.settle()
        }

        #expect(rootView.count == 0)
        #expect(map.count == 10)
        #expect(style.tint == hike.tint)
    }

    /// The half that has to keep working whatever else changes: the drawn
    /// route's identity is what tells the map to rebuild its polyline, and a
    /// new selection must still reach it.
    @Test("a new selection still reaches the map")
    func selectionStillInvalidates() throws {
        let context = try Fixture.modelContext()
        let first = Fixture.hike(in: context, title: "First")
        let second = Fixture.hike(in: context, title: "Second")
        let cache = DisplayedRouteCoordinateCache()

        let a = DisplayedRoute.forSelection(first, cache: cache)
        let b = DisplayedRoute.forSelection(second, cache: cache)
        #expect(a != b)
        #expect(a == DisplayedRoute.forSelection(first, cache: cache))
        #expect(DisplayedRoute.forSelection(nil, cache: cache) == nil)
    }

    /// The line pattern travels the same road as the colour and the width, and
    /// for the same reason: the map restyles its existing renderer from
    /// `RouteStyle`, so picking a pattern must not rebuild the sheet that the
    /// picker is sitting in.
    @Test("picking a line pattern doesn't invalidate the root view")
    func patternChangeIsIsolatedFromTheRootView() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let cache = DisplayedRouteCoordinateCache()
        let style = RouteStyle()
        style.follow(hike)

        let rootView = contentViewCounter(for: hike, cache: cache)
        let map = ObservationCounter { _ = style.pattern }
        await rootView.settle()

        for pattern in [RouteLinePattern.solid, .dashed, .dotted, .arrowheads] {
            hike.routeLinePattern = pattern
            await rootView.settle()
        }

        #expect(rootView.count == 0, "the map restyles itself; the sheet has no part in it")
        #expect(map.count == 4, "…but every choice must still reach the map")
        #expect(style.pattern == .arrowheads)
    }
}
