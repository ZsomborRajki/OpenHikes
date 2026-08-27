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
            hike.routeLinePattern = .dotted
        }
        let style = RouteStyle()

        style.follow(hike)
        #expect(style.tint == hike.tint)
        #expect(style.width == 9)
        #expect(style.pattern == .dotted)
    }

    /// Deselecting leaves no trace of the last trail: the next route to be
    /// drawn before its hike is followed must not inherit a stranger's colour.
    @Test("clearing the selection returns to the defaults")
    func clearingResetsToDefaults() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.tintHex = "#FF0000FF"
            hike.routeLinePattern = .arrowheads
        }
        let style = RouteStyle()
        style.follow(hike)

        style.follow(nil)
        #expect(style.tint == RouteStyle.defaultTint)
        #expect(style.width == RouteStyle.defaultWidth)
        #expect(style.pattern == RouteStyle.defaultPattern)

        // And the hike it used to follow can no longer reach it.
        let map = ObservationCounter { _ = style.tint }
        await map.settle()
        hike.tintHex = "#0000FFFF"
        await map.settle()
        #expect(map.count == 0, "a cleared style has no hike left to hear from")
        #expect(style.tint == RouteStyle.defaultTint)
    }

    /// The map's observer is a `Task` hop and a renderer invalidation away, so
    /// a drag that returns a colour to where it already was must stop here.
    ///
    /// It does stop here, but not where the code reads as though it does. The
    /// three `if self.x != x` guards in ``RouteStyle/apply(tint:width:pattern:)``
    /// can all be deleted and this stays green: what filters the write is
    /// Observation's own expansion, which skips an assignment that compares
    /// equal, and `Color`, `Double` and `RouteLinePattern` all are `Equatable`.
    /// `an equal write to the map's appearance types notifies nobody` in
    /// `ObservationCostTests` pins that runtime behaviour; the guards are
    /// explicit belt-and-braces over it, the same shape and for the same
    /// reason as the one in `HikeRecorder`'s accepted-fix path.
    ///
    /// Which makes the precondition below the load-bearing half of this test.
    /// SwiftData does *not* coalesce a same-value write, so `RouteStyle.track`
    /// really is woken, really does re-derive the tint from `tintHex` and
    /// really does reach `apply`. Were that ever to change — the belief that it
    /// already had is what this precondition was added to refute — the zero
    /// below would still hold while measuring nothing at all, so assert that
    /// the write arrived before asserting what it cost.
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
        let tracker = ObservationCounter { _ = hike.tintHex }
        await map.settle()

        hike.tintHex = "#FF0000FF"
        hike.routeWidth = hike.routeWidth
        await map.settle()
        #expect(tracker.count == 1, "precondition: the same-value write reaches the tracker")
        #expect(map.count == 0)

        hike.tintHex = "#00FF00FF"
        await map.settle()
        #expect(map.count == 1, "a real change must still get through")
    }

    /// The same claim without the model in the way. Re-following the hike
    /// already followed drives ``RouteStyle/apply(tint:width:pattern:)``
    /// synchronously with the appearance it is already showing, so the zero
    /// here is a fact about what `RouteStyle` publishes rather than about
    /// whether anything called it — which is the one thing the test above
    /// cannot separate, since it can only observe the far end of a
    /// notification it did not see arrive.
    @Test("restating the same appearance publishes nothing")
    func refollowingTheSameHikeIsSilent() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.tintHex = "#FF0000FF"
            hike.routeWidth = 9
            hike.routeLinePattern = .dashed
        }
        let style = RouteStyle()
        style.follow(hike)
        let map = ObservationCounter {
            _ = style.tint
            _ = style.width
            _ = style.pattern
        }
        await map.settle()

        style.follow(hike)
        await map.settle()
        #expect(map.count == 0, "apply ran with values it is already publishing")
        #expect(style.tint == hike.tint)
        #expect(style.width == 9)
        #expect(style.pattern == .dashed)

        hike.routeWidth = 4
        style.follow(hike)
        await map.settle()
        #expect(map.count == 1, "and a restatement that differs does publish")
        #expect(style.width == 4)
    }

    /// Switching trails while the previous one's notification is still in
    /// flight: the callback re-registered for the old hike has no way to be
    /// cancelled, so it has to recognise that it is stale.
    ///
    /// Two independent mechanisms make it: the `generation` comparison, and
    /// the callback re-reading `self.trackedHike` instead of capturing the
    /// hike it registered against. Mutation-tested, either one alone is
    /// sufficient — this only goes red when *both* are removed, so neither is
    /// individually protected by any test here, and a reader deleting one on
    /// the evidence of a green suite would be right by luck. The value
    /// assertions are what catch it; the count assertion below has never
    /// failed under any mutation and is documentation, not evidence.
    @Test("a hike that is no longer selected can't restyle the route")
    func staleFollowIsIgnored() async throws {
        let context = try Fixture.modelContext()
        let previous = Fixture.hike(in: context, title: "Previous") { $0.tintHex = "#FF0000FF" }
        let current = Fixture.hike(in: context, title: "Current") { hike in
            hike.tintHex = "#0000FFFF"
            hike.routeWidth = 7
        }
        let style = RouteStyle()
        style.follow(previous)
        let map = ObservationCounter {
            _ = style.tint
            _ = style.width
        }
        await map.settle()

        // The write lands while `previous` is still the followed hike, so its
        // callback is already scheduled when the selection moves on.
        previous.tintHex = "#00FF00FF"
        style.follow(current)
        await map.settle()

        #expect(map.count == 1)
        #expect(style.tint == current.tint, "the stale callback must not repaint in the old colour")
        #expect(style.width == 7)

        // …and the old hike stays disconnected from then on.
        previous.routeWidth = 12
        await map.settle()
        #expect(map.count == 1, "the previous hike must not reach the style at all")
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
        await settleDelegateHop(until: "the coalesced writes to reach the style") {
            style.width == 11
        }
        #expect(style.width == 11)
    }
}
