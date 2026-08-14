//
//  MapCoordinatorTests+SheetInsets.swift
//  OpenHikesTests
//
//  Where the "my location" button ends up, given where the sheet is.
//
//  The button is pinned by its *bottom* to the map's top edge, so the
//  constraint's constant is a plain Y in the map's own coordinates — the same
//  space `SheetMetrics.topY` reports in, since the map ignores the safe area.
//  Every assertion here is therefore one comparison between two numbers on the
//  same axis, and the interesting ones are the boundaries: a sheet resting just
//  above the map's midpoint, a sheet at full height, and a reading that can't
//  be the sheet at all.
//
//  Test maps are 390x844 with no window, so `safeAreaInsets.top` is 0 here and
//  the top clamp is the button's height plus its spacing. That is the point of
//  measuring it rather than hard-coding a device's inset.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// The "my location" button rides just above the sheet's top edge as it is
    /// dragged, at touch frequency, without a SwiftUI pass in between.
    @Test("the tracking button follows the sheet's top edge")
    func trackingButtonFollowsTheSheet() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)
        let spacing: CGFloat = 16

        sheetMetrics.topY = 700
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant == 700 - spacing)

        // A detent that stops just above the map's midpoint, which is what the
        // medium detent does on a tall phone. The button belongs above it.
        let aboveMidpoint = map.bounds.height * 0.5 - 20
        sheetMetrics.topY = aboveMidpoint
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant == aboveMidpoint - spacing)

        // A sheet dragged nearly to the top: the button stops clear of the top
        // safe area rather than climbing into the status bar. The sheet covers
        // it entirely by then, so there is nothing to see either way.
        let button = try #require(coordinator.trackingButton)
        let buttonHeight = max(
            button.bounds.height,
            button.intrinsicContentSize.height
        )
        sheetMetrics.topY = 8
        coordinator.applySheetTop(on: map)
        #expect(
            constraint.constant == map.safeAreaInsets.top + buttonHeight + spacing
        )
        #endif
    }

    /// The regression this guards: the clamp keeping the button out of the
    /// status bar used to read `max(sheetTop, height * 0.5)`, which assumed the
    /// medium detent always stops below the map's midpoint. On a tall phone it
    /// stops a little above, and the "cap" then pushed the button *down* to the
    /// midpoint — behind the sheet's top curve.
    @Test("the tracking button is never pushed down into the sheet")
    func trackingButtonStaysClearOfTheSheet() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)

        // Every detent a sheet can rest at, from full height down to compact.
        for topY in stride(from: 120.0, through: map.bounds.height, by: 20) {
            sheetMetrics.topY = topY
            coordinator.applySheetTop(on: map)
            #expect(
                constraint.constant < topY,
                "the button's bottom is inside the sheet at a top of \(topY)"
            )
        }
        #endif
    }

    /// A reading that can't be the sheet's edge — the sheet is presented over
    /// this map — is refused rather than followed off screen.
    @Test("an out-of-bounds sheet report falls back rather than being followed")
    func trackingButtonIgnoresImpossibleSheetTops() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)

        sheetMetrics.topY = 700
        coordinator.applySheetTop(on: map)
        let followed = constraint.constant

        sheetMetrics.topY = map.bounds.height + 500
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant != map.bounds.height + 500 - 16)
        #expect(constraint.constant < map.bounds.height)

        // And the same for the state before the sheet has reported anything.
        sheetMetrics.topY = 0
        coordinator.applySheetTop(on: map)
        let fallback = constraint.constant
        #expect(fallback < map.bounds.height)
        #expect(fallback != followed)
        #endif
    }

    /// Observed rather than passed in, so a drag never reaches SwiftUI.
    @Test("a sheet drag moves the button without an update pass")
    func sheetDragIsObserved() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)
        let spacing: CGFloat = 16

        sheetMetrics.topY = 640
        await settle()

        #expect(constraint.constant == 640 - spacing, "no `update` call in between")
        #endif
    }

    /// The fade is a pure function of how far past the button the sheet has
    /// come, and of how much climb the button gave up by stopping — so it can
    /// be checked without a window or a render.
    @Test("the button fades out across exactly the travel it gives up")
    func trackingButtonFadesAcrossTheTravelItGivesUp() {
        let travel: CGFloat = 300

        // Still below the button, with its spacing intact: fully opaque.
        #expect(MapView.Coordinator.trackingButtonAlpha(encroachment: -50, over: travel) == 1)
        #expect(MapView.Coordinator.trackingButtonAlpha(encroachment: 0, over: travel) == 1)

        // Halfway through that travel: halfway faded.
        #expect(MapView.Coordinator.trackingButtonAlpha(encroachment: 150, over: travel) == 0.5)

        // At the end of it, and beyond: gone, and it stays gone.
        #expect(MapView.Coordinator.trackingButtonAlpha(encroachment: 300, over: travel) == 0)
        #expect(MapView.Coordinator.trackingButtonAlpha(encroachment: 900, over: travel) == 0)
    }

    /// The behaviour this whole file exists for. Expanding the sheet past its
    /// middle detent used to drag the button up the screen ahead of it, all
    /// the way to the status bar. It now stays where it was and fades out,
    /// which is what Maps does.
    @Test("expanding past the middle detent hides the button instead of moving it")
    func trackingButtonStopsAtTheMiddleDetent() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)
        let button = try #require(coordinator.trackingButton)
        let middleRest = map.bounds.height * 0.45

        settle(sheetMetrics, at: middleRest)
        coordinator.applySheetTop(on: map)
        let resting = constraint.constant
        #expect(resting == middleRest - 16)
        #expect(button.alpha == 1)

        // Dragged up past it: the button holds its place and dims.
        for topY in stride(from: middleRest - 20, through: 40, by: -20) {
            sheetMetrics.report(topY: topY, atMiddleDetent: true)
            coordinator.applySheetTop(on: map)
            #expect(
                constraint.constant == resting,
                "the button moved with the sheet at a top of \(topY)"
            )
        }
        #expect(button.alpha == 0)

        // And it comes back, in place, on the way down.
        sheetMetrics.report(topY: middleRest, atMiddleDetent: true)
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant == resting)
        #expect(button.alpha == 1)
        #endif
    }

    /// Before the sheet has been seen resting, there is nothing to stop at, so
    /// the button keeps its old behaviour rather than guessing at a detent.
    @Test("an unmeasured sheet leaves the button following it")
    func trackingButtonFollowsAnUnmeasuredSheet() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)

        #expect(sheetMetrics.middleRestY == nil)
        sheetMetrics.topY = map.bounds.height * 0.45
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant == map.bounds.height * 0.45 - 16)
        #endif
    }

    /// The learning itself. A drag reports at display rate; a rest is the only
    /// thing that produces a gap between two reports.
    @Test("the sheet's middle detent is learned from where it stops, not guessed")
    func middleDetentIsLearnedFromRest() {
        let metrics = SheetMetrics(clock: clock.read)

        // The snap into the detent: several reports in quick succession.
        for topY in stride(from: 800.0, through: 400, by: -100) {
            metrics.report(topY: topY, atMiddleDetent: true)
        }
        #expect(metrics.middleRestY == nil, "still moving")

        // It sits there, and then the next drag begins.
        clock.advance(by: 1)
        metrics.report(topY: 390, atMiddleDetent: true)
        #expect(metrics.middleRestY == 400)

        // A hand pausing mid-drag is not a second resting place.
        clock.advance(by: 1)
        metrics.report(topY: 200, atMiddleDetent: true)
        #expect(metrics.middleRestY == 400)
    }

    /// A pause at any other detent says nothing about where the middle one is.
    @Test("only the middle detent's resting place is learned")
    func otherDetentsAreNotLearned() {
        let metrics = SheetMetrics(clock: clock.read)

        metrics.report(topY: 800, atMiddleDetent: false)
        clock.advance(by: 1)
        metrics.report(topY: 700, atMiddleDetent: false)
        #expect(metrics.middleRestY == nil)
    }

    /// Re-measured on every visit, so it follows a rotation rather than
    /// pinning the button to a resting place the sheet no longer has.
    @Test("committing to the middle detent re-arms the measurement")
    func settlingAgainRemeasures() {
        let metrics = SheetMetrics(clock: clock.read)

        settle(metrics, at: 400)
        #expect(metrics.middleRestY == 400)

        metrics.detentCommitted(toMiddle: true)
        settle(metrics, at: 300)
        #expect(metrics.middleRestY == 300)
    }

    /// Puts the sheet at rest at the middle detent: a run of reports, then a
    /// gap, then one more. The gap is what identifies the rest — a drag reports
    /// at display rate, so nothing else produces one.
    private func settle(_ metrics: SheetMetrics, at topY: CGFloat) {
        metrics.report(topY: topY + 40, atMiddleDetent: true)
        metrics.report(topY: topY, atMiddleDetent: true)
        clock.advance(by: 1)
        metrics.report(topY: topY, atMiddleDetent: true)
    }
}
