//
//  MapCommunityRoutes.swift
//  OpenHikes
//
//  Where the shared hikes in the list actually go.
//
//  ``MapCommunityAnnotations`` put the results on the map as pins, which
//  answered *where near here* and left the question a hiker is really asking
//  untouched: a trail is a line before it is a point, and a marker on a
//  trailhead says nothing about whether the walk behind it climbs the ridge or
//  follows the valley. Until a hike was imported it had no line anywhere —
//  which meant deciding whether to keep somebody else's trail happened without
//  ever seeing it on a map.
//
//  So every shared hike in the answer is drawn, faded, under the hiker's own
//  route; and the one whose preview is open is drawn properly, from the full
//  route that preview downloaded. See ``CommunityRouteLine`` for why those are
//  one kind of thing here rather than two.
//
//  ## Faded, and underneath
//
//  Both halves of that are the same decision. These are other people's trails
//  on the hiker's map, and the map already belongs to something — a selected
//  route, drawn in a colour they chose, possibly with a walk highlighted along
//  it. A shared hike must be legible without ever competing with that, so it
//  is drawn at half strength and underneath the hiker's own route. Where the
//  two cross, theirs wins.
//
//  *Underneath* is a position within one level rather than a level of its
//  own: everything this app draws is at ``MKOverlayLevel/aboveLabels``, and a
//  shared line put below that is buried rather than faint. The order there is
//  the ground, then these, then the hiker's route — see
//  ``applyCommunityRoutes(_:on:)``, which explains what the opaque tile
//  overlay does to anything drawn beneath it.
//
//  The previewed line is the one exception and only to the fade: it is at full
//  strength because the screen showing it no longer draws a route of its own,
//  so this is where the hiker looks to see what they are deciding about. It
//  stays underneath.
//
//  ## Why a tap recognizer, and why the pins stay
//
//  MapKit gives annotations taps for free and overlays nothing at all — a
//  polyline is drawn pixels with no view and no hit-testing — so a tap on a
//  line has to be answered by hand. ``CommunityRouteHitTest`` is the geometry;
//  this file is the part that needs a map.
//
//  The pins are kept alongside, and not out of caution. A line is not an
//  accessibility element and cannot be one: VoiceOver reaches a shared hike
//  through its marker, which carries the name and the way in. Markers also
//  declutter, which lines cannot, and a hike whose route is a few hundred
//  metres at a valley-wide zoom is a smudge with a pin on it. The two say the
//  same thing at different sizes.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One shared hike's line, and what a tap on it opens.
///
/// The polyline and the coordinates are both kept because they are asked two
/// different questions: MapKit owns the first and draws it, and the hit-test
/// projects the second through the map to find out what a thumb landed on.
/// Reading the points back out of an `MKPolyline` means a `getCoordinates`
/// call into a buffer on every tap, for points this already had.
struct CommunityRouteDrawing {
    let line: CommunityRouteLine
    let polyline: MKPolyline
    let coordinates: [CLLocationCoordinate2D]

    init(line: CommunityRouteLine) {
        self.line = line
        coordinates = line.coordinates.map(\.clCoordinate)
        polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
    }
}

// MARK: - Shared hikes as lines on the map

extension MapView.Coordinator {
    /// Half strength, which is what makes a shared hike read as somebody
    /// else's without making it hard to see.
    private static let communityRouteAlpha: CGFloat = 0.5
    private static let communityRouteWidth: CGFloat = 3.5
    /// The open preview's own line: full strength and a little wider, because
    /// its screen no longer draws the route anywhere else.
    private static let previewedRouteWidth: CGFloat = 5
    /// How far from a line a tap may land and still count, in screen points.
    ///
    /// About a fingertip, and deliberately more than the line is wide: a
    /// three-point line nobody could hit is a line that is not tappable, and
    /// the hit-test resolves the overlap this creates by taking the nearest.
    static let communityTapTolerancePoints: CGFloat = 22

    /// Observes the lines the browser is showing and applies them
    /// imperatively, then re-registers — the same arrangement
    /// ``observeCommunityPins(_:on:)`` uses, and for the same reason: an
    /// answer landing has to redraw MapKit and no SwiftUI view.
    ///
    /// Idempotent, like every other registration here: `withObservationTracking`
    /// offers no way to cancel one, so a second would leave two observers
    /// rebuilding the same overlays forever.
    func observeCommunityRoutes(_ browser: CommunityBrowser, on mapView: MKMapView) {
        guard !isObservingCommunityRoutes else { return }
        isObservingCommunityRoutes = true
        trackCommunityRoutes(browser, on: mapView)
    }

    private func trackCommunityRoutes(_ browser: CommunityBrowser, on mapView: MKMapView) {
        applyCommunityRoutes(browser.routeLines, on: mapView)
        withObservationTracking {
            _ = browser.routeLines
        } onChange: { [weak self, weak mapView, weak browser] in
            let coordinator = self
            let map = mapView
            let model = browser
            Task { @MainActor in
                guard let coordinator, let map, let model else { return }
                coordinator.trackCommunityRoutes(model, on: map)
            }
        }
    }

    /// Rebuilds the lines wholesale rather than diffing them, for the reason
    /// ``applyCommunityPins(_:on:)`` does: at most a page of them, and this
    /// runs when a request lands, a block hides somebody or a preview opens —
    /// never at drag or fix frequency. The guard is what keeps a republish of
    /// the same lines from removing and re-adding every overlay.
    func applyCommunityRoutes(_ lines: [CommunityRouteLine], on mapView: MKMapView) {
        guard communityRoutes.map(\.line) != lines else { return }
        RenderSignpost.mark("MapCommunityRoutesRebuilt", "\(lines.count) lines")
        if !communityRoutes.isEmpty {
            mapView.removeOverlays(communityRoutes.map(\.polyline))
            communityRoutes = []
        }
        if !lines.isEmpty {
            let drawings = lines.map(CommunityRouteDrawing.init)
            communityRoutes = drawings
            addCommunityOverlays(drawings.map(\.polyline), on: mapView)
        }
        // Also on the way to nothing drawn, which is what disarms the fit: an
        // early return here would leave the last preview's id standing, and
        // opening the same hike a second time would then find the camera
        // already "fitted" to it and stay wherever the hiker had panned to.
        bringPreviewedRouteIntoView(on: mapView)
    }

    /// Puts the lines on the map, underneath the hiker's own route and on top
    /// of the ground.
    ///
    /// **Not `level: .aboveRoads`**, which is what this did first and is why
    /// the lines were invisible rather than faint: this app replaces the base
    /// map with raster tiles, and that overlay is opaque
    /// (`canReplaceMapContent`) and lives at ``MKOverlayLevel/aboveLabels`` —
    /// so *every* level below it is painted over. A shared hike was being
    /// built, added and rendered, and then buried under the ground it was
    /// drawn on. Every other overlay this app adds is at `.aboveLabels` for
    /// the same reason, and these belong there too.
    ///
    /// Being underneath is therefore a position within that level rather than
    /// a level of its own: each line goes just above the tile overlay, which
    /// is the bottom of everything the app draws. `MapView`'s own route
    /// anchors on the topmost of these in turn, so theirs stays on top
    /// however the two arrive.
    ///
    /// The position is computed rather than timed, which is the second half of
    /// the same bug: `makeMapView` starts these observations *before* it
    /// installs the tile source, so a map built while an answer is already
    /// held draws its lines before there is a tile overlay to sit above. An
    /// `if let tileOverlay` would put those back under the ground. Asking the
    /// level where the tiles are — or that there are none yet — is true
    /// whenever it is asked, and the tiles are re-inserted `at: 0` whenever
    /// the provider changes, so they stay underneath by their own doing.
    ///
    /// Indices rather than `insertOverlay(_:above:)` so the lines keep their
    /// order, which `addInferredOverlays` documents the trap for: `above:`
    /// inserts *just* above what it is given, so naming one base repeatedly
    /// stacks them in reverse — and the previewed line is last precisely so it
    /// draws on top.
    private func addCommunityOverlays(_ polylines: [MKPolyline], on mapView: MKMapView) {
        let drawn = mapView.overlays(in: .aboveLabels)
        let floor = tileOverlay
            .flatMap { tiles in drawn.firstIndex { $0 === tiles } }
            .map { $0 + 1 } ?? 0
        for (offset, polyline) in polylines.enumerated() {
            mapView.insertOverlay(polyline, at: floor + offset, level: .aboveLabels)
        }
    }

    /// The renderer for one of the shared hikes' lines, or `nil` for a
    /// polyline that is not one — which is what lets `rendererFor` ask this
    /// and carry on to the hiker's own route styles otherwise.
    func communityRouteRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        guard let drawing = communityRoutes.first(where: { $0.polyline === polyline })
        else { return nil }
        let renderer = MKPolylineRenderer(polyline: polyline)
        let previewed = drawing.line.isPreviewed
        // The app's tint rather than the route tint the hiker chose, exactly
        // as the markers are: that colour belongs to their own selected hike,
        // which may well be drawn on the same screen.
        #if os(macOS)
        let tint = NSColor.controlAccentColor
        #else
        let tint = UIColor.tintColor
        #endif
        renderer.strokeColor = previewed ? tint : tint.withAlphaComponent(Self.communityRouteAlpha)
        renderer.lineWidth = previewed ? Self.previewedRouteWidth : Self.communityRouteWidth
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    /// Moves the map to the open preview's route, unless the whole of it is
    /// already on screen.
    ///
    /// The condition is the whole of it. A hiker who opened a short hike by
    /// tapping its line was looking straight at all of it, and a camera that
    /// jumped anyway would take away the context they chose it with. A hiker
    /// who opened one from a typed search may be looking at another country,
    /// and a preview that draws its route on a map showing somewhere else is
    /// the caricature back again in a worse form. A route that runs off the
    /// edge is the case in between, and it is fitted: the screen showing it
    /// draws no route of its own, so this is the only place the hiker can see
    /// the whole of what they are deciding about.
    ///
    /// The padding is the route padding and not the sheet's height, which is
    /// the same thing ``fitToCurrentRoute(_:animated:)`` does for the hiker's
    /// own route. Being wrong the same way in both places is worth more here
    /// than being right in one.
    ///
    /// Once per preview, tracked by listing, so a later rebuild — a block, a
    /// new page of results — does not re-fit a route the hiker has since
    /// panned away from.
    private func bringPreviewedRouteIntoView(on mapView: MKMapView) {
        guard let previewed = communityRoutes.first(where: \.line.isPreviewed) else {
            fittedPreviewListingID = nil
            return
        }
        guard fittedPreviewListingID != previewed.line.id else { return }
        fittedPreviewListingID = previewed.line.id
        let rect = previewed.polyline.boundingMapRect
        guard !mapView.visibleMapRect.contains(rect) else { return }
        fit(rect, on: mapView, animated: true)
    }
}

// MARK: - Tapping one

#if canImport(UIKit)
extension MapView.Coordinator: UIGestureRecognizerDelegate {
    /// Adds the recognizer that answers a tap on a shared hike's line.
    ///
    /// Idempotent for the reason the observations are: `makeMapView` runs once
    /// per map, but nothing here should depend on that, and a second
    /// recognizer would open the same preview twice.
    func installCommunityRouteTap(on mapView: MKMapView) {
        guard communityRouteTap == nil else { return }
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleCommunityRouteTap(_:))
        )
        // Alongside MapKit's own recognizers rather than instead of them: this
        // one answers a question about overlays, and a tap that hits no line
        // must still do everything a tap on the map did before — dismissing a
        // callout most visibly.
        recognizer.delegate = self
        // **This recognizer observes and never consumes**, and both of these
        // are what make that true rather than merely intended.
        //
        // `cancelsTouchesInView` defaults to *true*, and it does not mean "when
        // this recognizer acts on the tap" — it means whenever it recognizes
        // one, which here is every tap anywhere on the map. The touch is then
        // cancelled in whatever view was under it, so a photo pin's callout
        // stops opening the gallery and a button stops being a button. That
        // shipped for exactly as long as it took
        // `PhotoUITests.testOpensTheGalleryFromAPhotoPinOnTheMap` to run.
        //
        // `delaysTouchesEnded` defaults to true too, which would hold every
        // `touchesEnded` on the map back until this recognizer resolved.
        // Nothing here needs to arrive first.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        communityRouteTap = recognizer
        mapView.addGestureRecognizer(recognizer)
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc func handleCommunityRouteTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let mapView = recognizer.view as? MKMapView
        else { return }
        guard let listing = communityListing(
            forTapAt: recognizer.location(in: mapView),
            in: mapView
        ) else { return }
        community?.open(listing)
    }

    /// The shared hike a tap at `point` landed on, if any.
    ///
    /// Split from the handler above because this is the half worth asserting
    /// on and a `UITapGestureRecognizer` is the half that cannot be: its state
    /// and its location are read-only and set by the touch system, so a suite
    /// driving the handler would have to fake UIKit rather than the map. What
    /// is left in the handler is the three lines that turn a gesture into this
    /// call.
    func communityListing(
        forTapAt point: CGPoint,
        in mapView: MKMapView
    ) -> CommunityListing? {
        guard !communityRoutes.isEmpty else { return nil }
        guard !isTapClaimed(at: point, in: mapView) else { return nil }
        // At most a page of lines, each at most an outline's point budget —
        // see ``CommunityRouteHitTest``, which is sized against exactly that.
        // The previewed line is the one that can be longer, and it is one.
        let projected = communityRoutes.map { drawing in
            drawing.coordinates.map { mapView.convert($0, toPointTo: mapView) }
        }
        guard let index = CommunityRouteHitTest.nearest(
            to: point,
            among: projected,
            tolerance: Self.communityTapTolerancePoints
        ) else { return nil }
        return communityRoutes[index].line.listing
    }

    /// Whether something on top of the map has a better claim to this tap.
    ///
    /// A marker, a callout, the tracking button, the camera pill, *Search this
    /// area*, the credit line — all of them are views, all of them sit over the
    /// lines, and a tap that opens a preview *as well as* pressing a button is
    /// a tap that did two things. A recognizer on the map view sees those
    /// touches whatever the view under them does with them, so this is the
    /// whole of what stops it.
    ///
    /// The walk up the hierarchy rather than a test of the hit view alone is
    /// because every one of these is a tree: what a tap actually lands on is a
    /// label inside a button inside an annotation view.
    ///
    /// The four named views are named because none of them is a `UIControl` —
    /// `MKUserTrackingButton` is a plain `UIView`, and the other three are this
    /// app's own containers with the buttons *inside* them. Testing for
    /// `UIControl` alone would let a tap on the padding around a button through
    /// while catching the button itself, which is the sort of difference
    /// nobody can see and everybody hits.
    private func isTapClaimed(at point: CGPoint, in mapView: MKMapView) -> Bool {
        var view = mapView.hitTest(point, with: nil)
        while let current = view, current !== mapView {
            if current is MKAnnotationView || current is UIControl { return true }
            if isOwnControl(current) { return true }
            view = current.superview
        }
        return false
    }

    /// Whether `view` is one of the controls this map puts over its own
    /// drawing. Identity rather than type, because the coordinator already
    /// holds each one.
    private func isOwnControl(_ view: UIView) -> Bool {
        if view === trackingButton || view === areaSearchControl { return true }
        #if os(iOS)
        if view === photoControls || view === attributionView { return true }
        #endif
        return false
    }
}
#endif
