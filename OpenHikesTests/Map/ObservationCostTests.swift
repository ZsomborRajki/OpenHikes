//
//  ObservationCostTests.swift
//  OpenHikesTests
//
//  "Observation cost", split out of RenderIsolationTests.swift so that a file
//  declares one @Suite. That file's header still holds the context the two
//  share.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

@Suite("Observation cost")
struct ObservationCostTests {
    /// The sheet's top edge is written at frame rate while dragging, and the
    /// map repositions its location button from it — but nothing in SwiftUI
    /// should hear about it.
    @Test("dragging the sheet notifies only its own observer")
    func sheetMetricsAreIsolated() async {
        let metrics = SheetMetrics()
        let highlight = RouteHighlight()
        let sheetCounter = ObservationCounter { _ = metrics.topY }
        let highlightCounter = ObservationCounter { _ = highlight.coordinate }
        await sheetCounter.settle()

        for y in stride(from: 800.0, to: 400.0, by: -20) {
            metrics.topY = y
            await sheetCounter.settle()
        }
        #expect(sheetCounter.count == 20)
        #expect(highlightCounter.count == 0, "a sheet drag must not wake the route highlight's observer")
    }

    /// The map registers the two one-shot commands separately so that bumping
    /// one doesn't re-arm the other.
    @Test("the map's two commands notify independently")
    func mapCommandsAreIndependent() async {
        let controller = MapController()
        let fitCounter = ObservationCounter { _ = controller.fitRouteRequest }
        let regionCounter = ObservationCounter { _ = controller.showRegionRequest }
        await fitCounter.settle()

        controller.fitToRoute()
        await fitCounter.settle()
        #expect(fitCounter.count == 1)
        #expect(regionCounter.count == 0)

        controller.show(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        ))
        await regionCounter.settle()
        #expect(regionCounter.count == 1)
        #expect(fitCounter.count == 1, "showing a region must not also re-fit the route")
    }

    /// Every live match carries a point for the photo pill, and nothing draws
    /// it. A coordinate is not `Equatable`, so were the point observed, every
    /// fix would notify whoever read it, even standing still; it is read only
    /// at the tap, so it notifies nobody, and a new point at the old distance
    /// leaves the graph alone too.
    @Test("a live match's point wakes nobody")
    func liveMatchPointIsUnobserved() async {
        let tracker = TrackerState()
        tracker.showLiveMatch(at: 100, on: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86))
        let pointCounter = ObservationCounter { _ = tracker.liveMatch }
        let graphCounter = ObservationCounter { _ = tracker.liveTrackerDistance }
        await pointCounter.settle()

        tracker.showLiveMatch(at: 100, on: CLLocationCoordinate2D(latitude: 48, longitude: 12))
        await pointCounter.settle()
        #expect(pointCounter.count == 0, "the point is read at the tap, never observed")
        #expect(graphCounter.count == 0, "a new point at the same distance moves nothing on the graph")
        #expect(tracker.liveMatch?.coordinate.latitude == 48)

        tracker.clearLiveMatch()
        await pointCounter.settle()
        #expect(pointCounter.count == 0)
        #expect(graphCounter.count == 1, "clearing the match must still reach the graph")
    }
}
