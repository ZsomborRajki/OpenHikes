//
//  TopEdgeReaderTests.swift
//  OpenHikesTests
//
//  `onTopEdgeChange` feeds `MapSheet`'s `SheetMetrics` while the sheet is
//  dragged, so it runs at touch frequency on the render path. Four of its
//  properties are load-bearing there and all four are quietly easy to break:
//  the value is a *global* Y (a `.local` frame reads 0 forever and the sheet
//  would never move), it is reported *again* every time the view moves rather
//  than only on appearance, it is reported *only* when it moves — an
//  implementation calling back on every layout pass would write to an
//  observable at layout frequency, which is the cost the render-isolation
//  arrangement exists to avoid — and reading the geometry does not resize the
//  view being read.
//
//  What is deliberately *not* asserted is that a caller's body survives the
//  edge changing. That was tried and it cannot fail: SwiftUI does not
//  invalidate an ancestor's body from a `GeometryReader` in a `background`,
//  and it does not do so from a `PreferenceKey` or from a `@State` inside a
//  `ViewModifier` either — substituting a `@State`-storing implementation for
//  the real one left every body count unchanged. Whether the *caller* stores
//  the edge somewhere that invalidates it is the caller's business, and
//  `SheetPresentationIsolationTests` is where that is held to account.
//

import Foundation
import Observation
@testable import OpenHikes
import SwiftUI
import Testing

/// Collects the edges the modifier reports. A class so the readings survive
/// the value-type copies SwiftUI makes of the view.
@MainActor
final class TopEdgeRecorder {
    private(set) var edges: [CGFloat] = []

    var count: Int { edges.count }

    var latest: CGFloat? { edges.last }

    func record(_ edge: CGFloat) { edges.append(edge) }
}

/// A stable box for the offset, so the probe can be moved without rebuilding
/// the hierarchy around it.
@MainActor
@Observable
final class TopEdgeOffset {
    var points: CGFloat

    init(points: CGFloat) { self.points = points }
}

/// The probe: a fixed-height strip pushed down the screen by `offset`.
private struct TopEdgeProbe: View {
    let recorder: TopEdgeRecorder
    let offset: TopEdgeOffset

    var body: some View {
        VStack(spacing: 0) {
            OffsetSpacer(offset: offset)
            Color.clear
                .frame(height: 40)
                .onTopEdgeChange { edge in recorder.record(edge) }
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }
}

/// The only view that reads the offset, so moving the probe rebuilds as little
/// as possible.
private struct OffsetSpacer: View {
    let offset: TopEdgeOffset

    var body: some View {
        Color.clear.frame(height: offset.points)
    }
}

/// Two intrinsically-sized views stacked, each reporting its own top edge. The
/// gap between the two readings is whatever the first one's height turned out
/// to be, which is how the layout test below sees the modifier change it.
private struct StackedProbes: View {
    let first: TopEdgeRecorder
    let second: TopEdgeRecorder

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "first")
                .onTopEdgeChange { edge in first.record(edge) }
            Text(verbatim: "second")
                .onTopEdgeChange { edge in second.record(edge) }
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }
}

@MainActor
@Suite("Top edge reader")
struct TopEdgeReaderTests {
    private static let width: CGFloat = 390
    private static let height: CGFloat = 844

    /// Hosts a view in a real window, for the same reason `SheetQueryIsolationTests`
    /// does: a `GeometryReader` reports nothing until something lays it out,
    /// and a scene-less `UIWindow` never lays out.
    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// One layout pass, plus the tick that lets SwiftUI's own work drain.
    private func layout(_ window: UIWindow) async -> Bool {
        window.rootViewController?.view.setNeedsLayout()
        window.layoutIfNeeded()
        return await settlePollTick()
    }

    /// Pumps layout until `condition` holds, or gives up on a deadline naming
    /// what it was waiting for. A fixed count of turns would buy an amount of
    /// SwiftUI progress that depends on how loaded the machine is.
    private func settle(
        _ window: UIWindow,
        until condition: () -> Bool,
        _ description: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
            guard await layout(window) else { return }
        }
    }

    /// The edge is a *global* Y. A `.local` frame would read 0 here forever,
    /// and the sheet driven by this would never leave the top of the screen.
    @Test("the top edge is reported in global coordinates once the view is laid out")
    func reportsAnInitialGlobalEdge() async throws {
        let recorder = TopEdgeRecorder()
        let offset = TopEdgeOffset(points: 100)
        let window = try host(TopEdgeProbe(recorder: recorder, offset: offset))
        defer { dismiss(window) }

        await settle(window, until: { recorder.latest != nil }, "the first top edge")

        let edge = try #require(recorder.latest)
        #expect(edge >= offset.points, "the probe sits below a \(offset.points)pt spacer")
        #expect(edge < Self.height, "…and inside the window")
    }

    /// Moving the view by a known number of points has to move the reading by
    /// exactly that many. Asserted as a delta rather than against an absolute
    /// number, because an absolute one would be asserting the simulator's
    /// safe-area insets rather than anything this modifier does.
    @Test("moving the view moves the reported edge by the same amount")
    func tracksTheEdgeAsItMoves() async throws {
        let recorder = TopEdgeRecorder()
        let offset = TopEdgeOffset(points: 100)
        let window = try host(TopEdgeProbe(recorder: recorder, offset: offset))
        defer { dismiss(window) }
        await settle(window, until: { recorder.latest != nil }, "the first top edge")
        let before = try #require(recorder.latest)

        let displacement: CGFloat = 160
        offset.points += displacement
        await settle(window, until: { recorder.latest != before }, "the edge to follow the view")

        let after = try #require(recorder.latest)
        #expect(abs((after - before) - displacement) < 0.5)
    }

    /// The one that matters for the render path. Widening the window changes
    /// the probe's frame without moving its top edge, and that must not
    /// produce a reading: the callback writes into `SheetMetrics`, and an
    /// implementation watching the whole `CGRect` — the easy mistake, since
    /// the rect is what the proxy hands you — would write to an observable
    /// every time the geometry changed for any reason at all.
    ///
    /// The positive control comes first, so "no further readings" is a
    /// statement about a modifier demonstrably still reporting rather than
    /// about one that has stopped.
    @Test("geometry that changes without moving the top edge reports nothing")
    func standingStillIsSilent() async throws {
        let recorder = TopEdgeRecorder()
        let offset = TopEdgeOffset(points: 100)
        let window = try host(TopEdgeProbe(recorder: recorder, offset: offset))
        defer { dismiss(window) }
        await settle(window, until: { recorder.latest != nil }, "the first top edge")

        let before = try #require(recorder.latest)
        offset.points += 40
        await settle(window, until: { recorder.latest != before }, "the edge to follow the view")
        let readings = recorder.count
        let edge = try #require(recorder.latest)

        for narrower in stride(from: Self.width - 40, through: Self.width - 160, by: -40) {
            window.frame = CGRect(x: 0, y: 0, width: narrower, height: Self.height)
            for _ in 0..<3 {
                guard await layout(window) else { return }
            }
        }

        #expect(recorder.latest == edge, "precondition: the top edge really did not move")
        #expect(recorder.count == readings, "a view whose top edge held still has nothing to report")
    }

    /// A `GeometryReader` is a greedy container, so reading geometry through
    /// one has to happen in a `background` — used directly it would stretch
    /// the view it was measuring to fill everything available, and in
    /// `MapSheet` that view is a row inside a scrolling stack.
    @Test("reading the edge does not resize the view it is attached to")
    func doesNotChangeLayout() async throws {
        let first = TopEdgeRecorder()
        let second = TopEdgeRecorder()
        let window = try host(StackedProbes(first: first, second: second))
        defer { dismiss(window) }

        await settle(
            window,
            until: { first.latest != nil && second.latest != nil },
            "both probes to report"
        )

        let top = try #require(first.latest)
        let below = try #require(second.latest)
        let heightOfTheFirstProbe = below - top
        #expect(heightOfTheFirstProbe > 0, "the second probe is below the first")
        #expect(
            heightOfTheFirstProbe < 40,
            "a line of text, not a GeometryReader stretched to fill the window"
        )
    }
}
