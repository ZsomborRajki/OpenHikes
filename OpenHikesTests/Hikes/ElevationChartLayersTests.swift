//
//  ElevationChartLayersTests.swift
//  OpenHikesTests
//
//  `ElevationChartView` draws its graph in layers: what stays put in
//  ``ElevationChartPlot``, and what moves, with the finger that moves it, in
//  charts laid over the plot. The split is worth exactly as much as the plot
//  staying put while the marks move, and two things about the plot decide that.
//
//  Its equality leaves out everything a scrub or a fix changes — the tracker,
//  the selection's copy and the closure that writes the selection — and still
//  catches everything it draws from.
//
//  And it holds no `Binding`. A binding held as a stored property is a dynamic
//  property, and a write through it re-evaluates the view holding it,
//  equatable, equal and unread as that view is — one pass per write, measured
//  both on a stand-in and on a simulator. So the plot passes the selection on
//  as a plain reference and a closure (``ElevationScrubSelection``), and the
//  mirror below keeps it that way.
//
//  Whether the plot is then left alone during a scrub is a question for
//  `Scripts/render-trace.sh`, which is where it was answered. A window hosted
//  from this bundle counted the same probe's bodies differently from one run to
//  the next, so no count here pins it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

/// A view holding a binding as a stored property, for the mirror to find.
private struct HeldBindingProbe: View {
    let selection: Binding<Double?>

    var body: some View { Color.clear }
}

@MainActor
@Suite("Elevation chart layers")
struct ElevationChartLayersTests {
    @Test("the plot holds no binding to the selection")
    func plotHoldsNoBinding() {
        func holdsABinding(_ view: some View) -> Bool {
            Mirror(reflecting: view).children.contains { $0.value is Binding<Double?> }
        }
        #expect(
            holdsABinding(HeldBindingProbe(selection: .constant(nil))),
            "precondition: the mirror sees a binding where one is held"
        )

        let plot = ElevationChartPlot(
            profile: RouteProfile(route: Fixture.ridgeRoute),
            tint: .green,
            domain: 0...1000,
            tracker: TrackerState(),
            scrub: ElevationScrubSelection()
        ) { _ in /* no-op */ }
        #expect(!holdsABinding(plot), "a held binding re-runs the plot on every drag event")
    }

    /// What lets the plot be skipped on a scrub step and on a fix, and still
    /// redrawn when the graph it shows changes.
    @Test("the plot's equality leaves out what moves, and catches what it draws from")
    func plotEqualityLeavesOutWhatMoves() {
        let tracker = TrackerState()
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let domain = 0.0...1000.0
        func plot(
            _ profile: RouteProfile,
            domain: ClosedRange<Double>,
            tint: Color = .green,
            scrub: ElevationScrubSelection = ElevationScrubSelection()
        ) -> ElevationChartPlot {
            ElevationChartPlot(
                profile: profile,
                tint: tint,
                domain: domain,
                tracker: tracker,
                scrub: scrub
            ) { _ in /* no-op */ }
        }
        let base = plot(profile, domain: domain)

        tracker.trackerDistance = 500
        tracker.liveTrackerDistance = 250
        let scrub = ElevationScrubSelection()
        scrub.distance = 300
        #expect(base == plot(profile, domain: domain, scrub: scrub), "what moves is not what the plot draws")

        #expect(base != plot(profile, domain: domain, tint: .red))
        #expect(base != plot(profile, domain: 0...1200))
        #expect(base != plot(RouteProfile(route: Array(Fixture.ridgeRoute.dropLast())), domain: domain))
    }
}
