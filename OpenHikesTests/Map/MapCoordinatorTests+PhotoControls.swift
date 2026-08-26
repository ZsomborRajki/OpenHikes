//
//  MapCoordinatorTests+PhotoControls.swift
//  OpenHikesTests
//
//  The camera pill sits opposite the "my location" button and is positioned by
//  the same call, so what is worth asserting is not where it is but that it is
//  never anywhere else: same constant, same opacity, through every sheet
//  position. A second control drawn independently would only be *approximately*
//  level with the first, and the drift would show up at the detents nobody
//  tests by hand.
//
//  The other half is the pill's own reason to be hidden. There is nothing to
//  photograph on the search screen, so the pill is not merely transparent
//  there — it is out of the hierarchy's way, because a control over a map the
//  user is panning must not answer hit tests it has no answer for.
//
//  Nothing here re-registers the observation by hand. `makeMapView` does it
//  once, after the pill exists, and it refuses to do it twice; a test that
//  called it again would be testing an arrangement the app never runs.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    @Test("the camera pill rides at exactly the tracking button's height")
    func photoControlsTrackTheTrackingButton() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let tracking = try #require(coordinator.trackingBottomConstraint)
        let pill = try #require(coordinator.photoControlsBottomConstraint)

        // Every detent a sheet can rest at, plus the clamped range above the
        // middle one where the tracking button stops climbing.
        for topY in stride(from: 120.0, through: map.bounds.height, by: 20) {
            sheetMetrics.topY = topY
            coordinator.applySheetTop(on: map)
            #expect(
                pill.constant == tracking.constant,
                "the pill and the tracking button disagree at a top of \(topY)"
            )
        }
        #endif
    }

    @Test("the camera pill fades with the sheet exactly as the button does")
    func photoControlsShareTheFade() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let button = try #require(coordinator.trackingButton)
        let controls = try #require(coordinator.photoControls)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        // The pill is only drawn at all while a screen is offering it, so the
        // fade can only be compared once something has.
        photoCapture.attach(to: hike) { nil }
        await settleDelegateHop(until: "the camera pill to appear") {
            !controls.isHidden
        }

        let middleRest = map.bounds.height * 0.45
        settleSheet(at: middleRest)
        coordinator.applySheetTop(on: map)
        #expect(controls.alpha == button.alpha)
        #expect(controls.alpha == 1)

        // Dragged up past the detent: both dim together.
        for topY in stride(from: middleRest - 20, through: 40, by: -20) {
            sheetMetrics.report(topY: topY, atMiddleDetent: true)
            coordinator.applySheetTop(on: map)
            #expect(
                controls.alpha == button.alpha,
                "the pill and the button faded differently at a top of \(topY)"
            )
        }
        #expect(controls.alpha == 0)
        #endif
    }

    @Test("there is no camera pill until a screen offers one")
    func photoControlsHiddenWithoutASubject() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let controls = try #require(coordinator.photoControls)

        // Hidden as well as transparent: it sits over a map the user pans.
        #expect(controls.isHidden)
        #expect(controls.alpha == 0)
        #endif
    }

    /// A screen can be offering the pill *before* the map exists — a restored
    /// selection or a widget deep link both push the hike screen during the
    /// same launch that builds the map. The first visibility pass therefore
    /// has to happen after the pill has been added, not before: registering
    /// the observation first left it hidden until the next time availability
    /// happened to change, which on that path is when the user navigates away.
    @Test("a pill already on offer when the map is built is visible at once")
    func photoControlsVisibleOnFirstBuild() throws {
        #if os(iOS)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        photoCapture.attach(to: hike) { nil }

        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let controls = try #require(coordinator.photoControls)

        // Synchronous: no availability change follows the build, so nothing
        // arrives later to correct it.
        #expect(!controls.isHidden)
        #expect(controls.alpha == 1)
        #endif
    }

    @Test("the pill arrives when a screen attaches and goes when it leaves")
    func photoControlsFollowTheSubject() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let controls = try #require(coordinator.photoControls)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let token = photoCapture.attach(to: hike) { nil }
        await settleDelegateHop(until: "the camera pill to appear") {
            !controls.isHidden
        }
        #expect(controls.alpha == 1)

        // The alpha is the assertion rather than `isHidden`: the fade sets the
        // model value at once and only takes the view out of the hierarchy's
        // way when the animation finishes.
        photoCapture.detach(token: token)
        await settleDelegateHop(until: "the camera pill to fade out") {
            controls.alpha == 0
        }
        #expect(controls.alpha == 0)
        #endif
    }

    /// `withObservationTracking` has no way to cancel a registration, so a
    /// second one is permanent: two observers, two overlapping fade animations
    /// against one view, for the life of the map. The guard is the same one
    /// `observeLocation` carries, and this is the same evidence — the second
    /// call is refused outright, so it cannot have registered anything.
    @Test("observing the pill twice registers nothing the second time")
    func photoControlsObservationIsIdempotent() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        #expect(coordinator.isObservingPhotoControls)

        let second = PhotoCaptureController()
        coordinator.observePhotoControls(second)

        #expect(coordinator.photoCaptureController === photoCapture)
        #expect(coordinator.photoCaptureController !== second)
        #endif
    }

    @Test("a pill brought back mid-drag returns to the sheet's opacity")
    func photoControlsRestoreTheSheetsFade() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let button = try #require(coordinator.trackingButton)
        let controls = try #require(coordinator.photoControls)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        // The sheet is already partway over the controls when the screen that
        // offers the pill appears. Coming back at full opacity there would put
        // a solid pill behind the sheet's top curve.
        let middleRest = map.bounds.height * 0.45
        settleSheet(at: middleRest)
        sheetMetrics.report(topY: middleRest * 0.5, atMiddleDetent: true)
        coordinator.applySheetTop(on: map)
        #expect(button.alpha > 0)
        #expect(button.alpha < 1)

        photoCapture.attach(to: hike) { nil }
        await settleDelegateHop(until: "the camera pill to come back") {
            !controls.isHidden
        }

        #expect(controls.alpha == button.alpha)
        #expect(controls.alpha < 1)
        #endif
    }

    /// The half of the withdrawal the fade cannot do.
    ///
    /// `isHidden` is only set once the animation lands, because taking the view
    /// out of the hierarchy mid-fade would make the pill vanish rather than
    /// leave — which left it a tap target over the map for the whole
    /// quarter-second it was on its way out. A tap there opened a picker with
    /// nothing behind it: by the time the user had chosen a photo the screen it
    /// would have been filed under was gone, and the button read as doing
    /// nothing at all. So interaction is switched outside the animation block,
    /// where the fade's own timing cannot reach it.
    @Test("a pill on its way out stops answering taps")
    func photoControlsStopAnsweringTapsImmediately() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let controls = try #require(coordinator.photoControls)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let token = photoCapture.attach(to: hike) { nil }
        await settleDelegateHop(until: "the camera pill to take taps") {
            controls.isUserInteractionEnabled
        }

        photoCapture.detach(token: token)
        await settleDelegateHop(until: "the camera pill to stop taking taps") {
            !controls.isUserInteractionEnabled
        }

        #expect(!controls.isUserInteractionEnabled)
        #endif
    }

    /// Puts the sheet at rest at the middle detent — a run of reports, a gap,
    /// then one more. Mirrors the private helper in the sheet-inset suite;
    /// duplicated rather than shared because making that one internal would
    /// widen a test harness for one caller.
    private func settleSheet(at topY: CGFloat) {
        sheetMetrics.report(topY: topY + 40, atMiddleDetent: true)
        sheetMetrics.report(topY: topY, atMiddleDetent: true)
        clock.advance(by: 1)
        sheetMetrics.report(topY: topY, atMiddleDetent: true)
    }
}
