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
//  line has to be answered by hand. ``RouteHitTest`` is the geometry,
//  `MapCoordinator+RouteTap.swift` owns the gesture and decides between these
//  lines and the hiker's own, and what is left here is the part that knows
//  which shared hike a projected line belongs to.
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
        reobserving(self, mapView, browser) {
            _ = browser.routeLines
        } onChange: { coordinator, map, model in
            coordinator.trackCommunityRoutes(model, on: map)
        }
    }

    /// Rebuilds the lines wholesale rather than diffing them, for the reason
    /// ``applyCommunityPins(_:on:)`` does: at most a page of them, and this
    /// runs when a request lands, a block hides somebody or a preview opens —
    /// never at drag or fix frequency. The guard is what keeps a republish of
    /// the same lines from removing and re-adding every overlay.
    func applyCommunityRoutes(_ lines: [CommunityRouteLine], on mapView: MKMapView) {
        guard communityRoutes.map(\.line) != lines else { return }
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
        // This listing's own colour, exactly as its marker and its row are.
        // Every shared line used to be the app's tint, which made a page of
        // results one tangle of identical green — see
        // ``CommunityListing/tint``.
        //
        // It is still not the route tint the hiker chose: that colour belongs
        // to their own selected hike, which may well be drawn on the same
        // screen. What keeps the two apart is what always did the work — these
        // are thinner, faded, and underneath — and that is unchanged below.
        #if os(macOS)
        let tint = NSColor(drawing.line.listing.tint)
        #else
        let tint = UIColor(drawing.line.listing.tint)
        #endif
        renderer.strokeColor = previewed ? tint : tint.withAlphaComponent(Self.communityRouteAlpha)
        renderer.lineWidth = previewed ? Self.previewedRouteWidth : Self.communityRouteWidth
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    /// Moves the map to the open preview's route.
    ///
    /// **Every time a preview opens**, which is the change from what this used
    /// to do. It used to skip the move when the whole route was already inside
    /// the visible rect, on the argument that a hiker who opened a short hike
    /// by tapping its line was already looking at all of it and a camera that
    /// jumped anyway would take away the context they chose it with.
    ///
    /// That argument was answered by what the condition actually did. "Already
    /// on screen" meant on screen *including the part behind the sheet*, so the
    /// case it fired in most was a short route sitting under the panel the
    /// hiker had just opened — and the hiker's report was not "it moved when it
    /// need not have" but "it never zooms into the new hike's route". A rule
    /// that holds sometimes reads as a bug rather than as restraint; opening a
    /// preview now always frames its route, and the framing is the focus area,
    /// so the route lands in the map that is visible rather than in the window.
    ///
    /// Still once per preview, tracked by listing, so a later rebuild — a
    /// block, a new page of results — does not re-fit a route the hiker has
    /// since panned away from. Reopening the same listing is a new preview and
    /// frames again, because the memo is cleared when the preview closes.
    private func bringPreviewedRouteIntoView(on mapView: MKMapView) {
        guard let previewed = communityRoutes.first(where: \.line.isPreviewed) else {
            fittedPreviewListingID = nil
            return
        }
        guard fittedPreviewListingID != previewed.line.id else { return }
        fittedPreviewListingID = previewed.line.id
        fit(previewed.polyline.boundingMapRect, on: mapView, animated: true)
    }
}

// MARK: - Tapping one

#if canImport(UIKit)
extension MapView.Coordinator {
    /// The shared hike a tap at `point` landed on, if any.
    ///
    /// Asked by ``routeTapTarget(at:in:)``, which owns the recognizer, the
    /// claim check and the order the two kinds of line are asked in — see
    /// `MapCoordinator+RouteTap.swift`. This half is the one that knows what a
    /// shared hike is, and it is the half worth asserting on: a
    /// `UITapGestureRecognizer`'s state and location are read-only and set by
    /// the touch system, so a suite driving the gesture would have to fake
    /// UIKit rather than the map.
    func communityListing(
        forTapAt point: CGPoint,
        in mapView: MKMapView
    ) -> CommunityListing? {
        guard !communityRoutes.isEmpty else { return nil }
        // At most a page of lines, each at most an outline's point budget —
        // see ``RouteHitTest``, which is sized against exactly that.
        // The previewed line is the one that can be longer, and it is one.
        let projected = communityRoutes.map { drawing in
            drawing.coordinates.map { mapView.convert($0, toPointTo: mapView) }
        }
        guard let index = RouteHitTest.nearest(
            to: point,
            among: projected,
            tolerance: Self.lineTapTolerancePoints
        ) else { return nil }
        return communityRoutes[index].line.listing
    }
}
#endif
