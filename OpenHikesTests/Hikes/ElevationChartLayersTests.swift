//
//  ElevationChartLayersTests.swift
//  OpenHikesTests
//
//  `ElevationChartView` draws its graph in layers: what stays put in
//  ``ElevationChartPlot``, and what moves, with the finger that moves it, in
//  charts laid over the plot. The split is worth exactly as much as the plot
//  staying put while the marks move, and two things about the plot decide that.
//
//  Its equality leaves out the tracker, which a scrub or a fix moves, and the
//  two scrub callbacks it passes on, and still catches everything it draws
//  from.
//
//  And it holds no `Binding`. A binding held as a stored property is a dynamic
//  property, and a write through it re-evaluates the view holding it,
//  equatable, equal and unread as that view is — one pass per write, measured
//  both on a stand-in and on a simulator. So the selection never reaches the
//  plot: the marks own it (``ElevationScrubSelection``), and the tracker and
//  the two closures pass through untouched. The mirror below keeps the plot
//  free of a binding.
//
//  The suite also pins the view around the plot: a scrub step writes the
//  selection and the tracker, and ``ElevationChartView``'s own body reads
//  neither. The selection belongs to the marks and is handed on by a relay
//  beneath them, rather than by an `onChange` on the outer view, and the
//  spoken value reads the tracker in a modifier of its own. Before, the outer
//  body ran twice per selection change, once for each.
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
    // periphery:ignore - read by the mirror, which is the point of it.
    let selection: Binding<Double?>

    var body: some View { Color.clear }
}

/// A view keeping a selection in its own state, for the mirror to find.
private struct HeldSelectionProbe: View {
    // periphery:ignore - read by the mirror, which is the point of it.
    @State private var selection: Double?

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
            onScrub: { _ in /* no-op */ },
            onScrubbingChanged: { _ in /* no-op */ }
        )
        #expect(!holdsABinding(plot), "a held binding re-runs the plot on every drag event")
    }

    /// What lets the plot be skipped on a scrub step and on a fix, and still
    /// redrawn when the graph it shows changes.
    @Test("the plot's equality leaves out what moves, and catches what it draws from")
    func plotEqualityLeavesOutWhatMoves() {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let domain = 0.0...1000.0
        func plot(
            _ profile: RouteProfile,
            domain: ClosedRange<Double>,
            tint: Color = .green,
            tracker: TrackerState = TrackerState()
        ) -> ElevationChartPlot {
            ElevationChartPlot(
                profile: profile,
                tint: tint,
                domain: domain,
                tracker: tracker,
                onScrub: { _ in /* no-op */ },
                onScrubbingChanged: { _ in /* no-op */ }
            )
        }
        let base = plot(profile, domain: domain)

        // A tracker of its own, standing somewhere else: an equality that read
        // it would tell these two plots apart, which reading a single shared
        // tracker on both sides never could.
        let tracker = TrackerState()
        tracker.trackerDistance = 500
        tracker.liveTrackerDistance = 250
        #expect(
            base == plot(profile, domain: domain, tracker: tracker),
            "what moves is not what the plot draws"
        )

        #expect(base != plot(profile, domain: domain, tint: .red))
        #expect(base != plot(profile, domain: 0...1200))
        #expect(base != plot(RouteProfile(route: Array(Fixture.ridgeRoute.dropLast())), domain: domain))
    }

    // MARK: The view around the plot

    /// The first of the two reads that ran the outer body on every drag
    /// event: the selection in its `@State`, made an input of its body by an
    /// `onChange(of:)` there.
    @Test("the view around the plot keeps no selection of its own")
    func outerViewHoldsNoSelection() {
        // By the type's name, because what backs `@State` is SwiftUI's own
        // business: on iOS 27 it is a `LazyState`, which `is State<Double?>`
        // does not match. The precondition is what notices it moving again.
        func holdsASelection(_ view: some View) -> Bool {
            Mirror(reflecting: view).children.contains { child in
                String(describing: type(of: child.value)).hasSuffix("State<Optional<Double>>")
            }
        }
        #expect(
            holdsASelection(HeldSelectionProbe()),
            "precondition: the mirror sees a selection where one is held"
        )

        let chart = ElevationChartView(
            profile: RouteProfile(route: Fixture.ridgeRoute),
            tint: .green,
            tracker: TrackerState()
        ) { _ in /* no-op */ }
        #expect(!holdsASelection(chart), "a selection held here re-runs the outer view on every drag event")
    }

    /// The second: what the graph speaks, read off the tracker in the outer
    /// body. A scrub step moves the tracker, and so does every fix while
    /// following.
    @Test("the view around the plot does not read the tracker")
    func outerBodyDoesNotReadTheTracker() async {
        let tracker = TrackerState()
        let chart = ElevationChartView(
            profile: RouteProfile(route: Fixture.ridgeRoute),
            tint: .green,
            tracker: tracker
        ) { _ in /* no-op */ }
        let bodyCounter = ObservationCounter { _ = chart.body }
        let readCounter = ObservationCounter { _ = tracker.trackerDistance }

        tracker.trackerDistance = 500
        await settleDelegateHop(until: "the direct read hears the move") { readCounter.count == 1 }

        #expect(readCounter.count == 1, "precondition: a read of the tracker hears it move")
        #expect(bodyCounter.count == 0, "the outer body re-runs on every scrub step and every fix")
    }

    /// The selection's two halves. What the touch chart's binding reads back
    /// is read while Swift Charts updates its own display, so a tracked read
    /// there would make the display depend on every write; what the relay
    /// hands on is the one a view is meant to hear.
    @Test("the selection the chart reads back is unobserved, and the one handed on is observed")
    func selectionIsObservedOnlyWhereItIsHandedOn() async {
        let scrub = ElevationScrubSelection()
        let readBack = ObservationCounter { _ = scrub.distance }
        let handedOn = ObservationCounter { _ = scrub.handedOn }

        scrub.select(120)
        await settleDelegateHop(until: "the relay hears the selection") { handedOn.count == 1 }
        #expect(scrub.distance == 120)
        #expect(scrub.handedOn == 120)

        scrub.select(nil)
        await settleDelegateHop(until: "the relay hears the release") { handedOn.count == 2 }
        #expect(scrub.distance == nil)
        #expect(scrub.handedOn == nil)

        #expect(handedOn.count == 2, "the relay hears a selection and a release")
        #expect(readBack.count == 0, "a read through the binding would tie Swift Charts' display to the selection")
    }
}
