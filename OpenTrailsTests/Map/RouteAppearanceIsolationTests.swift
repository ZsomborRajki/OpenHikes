//
//  RouteAppearanceIsolationTests.swift
//  OpenTrailsTests
//
//  `RenderIsolationTests` covers the state the app deliberately keeps *out* of
//  SwiftUI — `RouteHighlight`, `SheetMetrics`, `MapController`,
//  `LocationManager`, `TrackerState`. This covers the piece that joined them
//  last: a hike's `tint` and `routeWidth`.
//
//  Both live on the SwiftData `@Model` and both are written continuously (a
//  `ColorPicker` drag and a `Slider` drag). While `OpenTrailsView.body` read them
//  — to hand them to the map inside `DisplayedRoute` — every drag sample
//  invalidated the root view, and with it the `.sheet` closure that builds
//  `MapSheet`: `rankedMatchingHikes()` re-ran, the `NavigationStack` rebuilt,
//  and the pushed `HikeDetailView` that owns the slider being dragged was
//  re-evaluated. `MapView` is `.equatable()`, so the diff stopped before
//  MapKit; nothing stopped it before the sheet.
//
//  They now travel through `RouteStyle`, which the map coordinator observes
//  directly. So there are two halves to hold onto, and a test for each: the
//  root view's read set must not wake on a drag, and the map must still be told.
//

import CoreLocation
import Foundation
@testable import OpenTrails
import SwiftData
import SwiftUI
import Testing

@Suite("Route appearance isolation")
struct RouteAppearanceIsolationTests {
    /// Observes exactly what `OpenTrailsView.body` reads of the selected hike —
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
        let first = Fixture.hike(title: "First", in: context)
        let second = Fixture.hike(title: "Second", in: context)
        let cache = DisplayedRouteCoordinateCache()

        let a = DisplayedRoute.forSelection(first, cache: cache)
        let b = DisplayedRoute.forSelection(second, cache: cache)
        #expect(a != b)
        #expect(a == DisplayedRoute.forSelection(first, cache: cache))
        #expect(DisplayedRoute.forSelection(nil, cache: cache) == nil)
    }
}

@Suite("Route style")
struct RouteStyleTests {
    /// Selecting a hike must put its colour and width on the map before
    /// anything is dragged — the line is drawn in them, not merely updated to
    /// them later.
    @Test("following a hike adopts its appearance immediately")
    func followAdoptsAppearance() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.tintHex = "#FF0000FF"
            hike.routeWidth = 9
        }
        let style = RouteStyle()

        style.follow(hike)
        #expect(style.tint == hike.tint)
        #expect(style.width == 9)
    }

    /// Deselecting leaves no trace of the last trail: the next route to be
    /// drawn before its hike is followed must not inherit a stranger's colour.
    @Test("clearing the selection returns to the defaults")
    func clearingResetsToDefaults() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.tintHex = "#FF0000FF" }
        let style = RouteStyle()
        style.follow(hike)

        style.follow(nil)
        #expect(style.tint == RouteStyle.defaultTint)
        #expect(style.width == RouteStyle.defaultWidth)

        // And the hike it used to follow can no longer reach it.
        hike.tintHex = "#0000FFFF"
        for _ in 0..<8 { await Task.yield() }
        #expect(style.tint == RouteStyle.defaultTint)
    }

    /// The map's observer is a `Task` hop and a renderer invalidation away, so
    /// a drag that returns a colour to where it already was must stop here.
    @Test("an unchanged appearance doesn't wake the map")
    func unchangedWriteIsFiltered() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.tintHex = "#FF0000FF" }
        let style = RouteStyle()
        style.follow(hike)
        let map = ObservationCounter {
            _ = style.tint
            _ = style.width
        }
        await map.settle()

        hike.tintHex = "#FF0000FF"
        hike.routeWidth = hike.routeWidth
        await map.settle()
        #expect(map.count == 0)

        hike.tintHex = "#00FF00FF"
        await map.settle()
        #expect(map.count == 1, "a real change must still get through")
    }

    /// Switching trails while the previous one's notification is still in
    /// flight: the callback re-registered for the old hike has no way to be
    /// cancelled, so it has to recognise that it is stale. Without the
    /// generation check it would repaint the newly selected route in the
    /// previous one's colour.
    @Test("a hike that is no longer selected can't restyle the route")
    func staleFollowIsIgnored() async throws {
        let context = try Fixture.modelContext()
        let previous = Fixture.hike(title: "Previous", in: context) { $0.tintHex = "#FF0000FF" }
        let current = Fixture.hike(title: "Current", in: context) { hike in
            hike.tintHex = "#0000FFFF"
            hike.routeWidth = 7
        }
        let style = RouteStyle()
        style.follow(previous)

        // The write lands while `previous` is still the followed hike, so its
        // callback is already scheduled when the selection moves on.
        previous.tintHex = "#00FF00FF"
        style.follow(current)
        for _ in 0..<8 { await Task.yield() }

        #expect(style.tint == current.tint)
        #expect(style.width == 7)

        // …and the old hike stays disconnected from then on.
        previous.routeWidth = 12
        for _ in 0..<8 { await Task.yield() }
        #expect(style.width == 7)
    }

    /// Two writes in one turn: the second lands while no registration is armed
    /// (the first consumed it and the re-registration hasn't run yet). The
    /// callback re-reads the hike rather than carrying a value, so the style
    /// still converges on the later write instead of stopping at the first.
    @Test("two writes in one turn converge on the last")
    func coalescedWritesConverge() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let style = RouteStyle()
        style.follow(hike)

        hike.routeWidth = 6
        hike.routeWidth = 11
        for _ in 0..<8 { await Task.yield() }
        #expect(style.width == 11)
    }
}
