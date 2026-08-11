//
//  RouteAppearanceIsolationTests.swift
//  OpenTrailsTests
//
//  `RenderIsolationTests` covers the state the app deliberately keeps *out* of
//  SwiftUI — `RouteHighlight`, `SheetMetrics`, `MapController`,
//  `LocationManager`, `TrackerState`. This covers the one piece of
//  drag-frequency state that is still very much inside it: a hike's `tint` and
//  `routeWidth`.
//
//  Both live on the SwiftData `@Model`, both are written continuously (a
//  `ColorPicker` drag and a `Slider` drag), and `ContentView.displayedRoute`
//  reads both in `ContentView.body` in order to hand them to the map. So each
//  drag sample invalidates the root view — and with it the `.sheet` closure
//  that builds `MapSheet`, which re-runs `rankedMatchingHikes()`, rebuilds the
//  `NavigationStack`, and re-evaluates the pushed `HikeDetailView` that owns
//  the slider being dragged.
//
//  `MapView` is `.equatable()`, so the diff stops before MapKit. Nothing stops
//  it before the sheet.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import OpenTrails

@MainActor
@Suite("Route appearance isolation")
struct RouteAppearanceIsolationTests {
    /// The exact read set `ContentView.displayedRoute` performs: id (through
    /// the coordinate cache), tint, and width.
    private func contentViewCounter(for hike: Hike) -> ObservationCounter {
        ObservationCounter {
            _ = hike.id
            _ = hike.tint
            _ = hike.routeWidth
        }
    }

    /// Dragging the line-width slider from 3 pt to 12 pt is nine writes. Each
    /// one wakes the root view's read of `routeWidth`.
    ///
    /// The map genuinely needs the new width, and gets it through
    /// `MapView.updateRouteStyle`. What it doesn't need is for the whole sheet
    /// to be rebuilt to deliver it — and that is what a `ContentView.body`
    /// invalidation costs, because the sheet's content closure is inside it.
    ///
    /// The same pattern the rest of the app already uses would fix it: hold
    /// the drawn route's appearance in a stable `@Observable` reference type
    /// the coordinator observes directly, as `RouteHighlight` does, rather
    /// than reading it out of the model in `body`.
    @Test("dragging the width slider doesn't invalidate the root view")
    func widthDragIsIsolatedFromTheRootView() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let counter = contentViewCounter(for: hike)
        await counter.settle()

        for width in stride(from: 4.0, through: 12.0, by: 1.0) {
            hike.routeWidth = width
            await counter.settle()
        }

        withKnownIssue("ContentView.displayedRoute reads tint and width in ContentView.body") {
            #expect(counter.count == 0, "the map restyles itself; the sheet has no part in it")
        }
        #expect(counter.count == 9, "today every slider step rebuilds the root view and its sheet")
    }

    /// A `ColorPicker` drag writes `tintHex` continuously, and it reaches the
    /// root view the same way. Worse than the slider, in fact: the picker's
    /// live preview updates on every touch sample rather than on integer steps.
    @Test("dragging the colour picker doesn't invalidate the root view")
    func tintDragIsIsolatedFromTheRootView() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let counter = contentViewCounter(for: hike)
        await counter.settle()

        for step in 0..<10 {
            hike.tintHex = String(format: "#%02X8040FF", step * 20)
            await counter.settle()
        }

        withKnownIssue("ContentView.displayedRoute reads tint in ContentView.body") {
            #expect(counter.count == 0)
        }
        #expect(counter.count == 10)
    }

    /// The half that has to keep working whatever else changes: the drawn
    /// route's identity is what tells the map to rebuild its polyline, and a
    /// new selection must still reach it.
    @Test("a new selection still reaches the map")
    func selectionStillInvalidates() throws {
        let context = try Fixture.modelContext()
        let first = Fixture.hike(title: "First", in: context)
        let second = Fixture.hike(title: "Second", in: context)

        let a = DisplayedRoute(id: first.id, coordinates: first.coordinates, tint: first.tint, width: first.routeWidth)
        let b = DisplayedRoute(id: second.id, coordinates: second.coordinates, tint: second.tint, width: second.routeWidth)
        #expect(a != b)
    }

}
