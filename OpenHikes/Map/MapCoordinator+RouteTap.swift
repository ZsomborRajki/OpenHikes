//
//  MapCoordinator+RouteTap.swift
//  OpenHikes
//
//  A thumb on a line, and which line it was.
//
//  MapKit hit-tests annotations and never overlays: a polyline is drawn pixels
//  with no view behind it, so without a recognizer of our own every line on
//  this map is scenery. There are two kinds drawn — the hiker's own selected
//  route, and the shared hikes faded beneath it — and this file is here
//  because *one* recognizer has to answer for both.
//
//  Two would not. They would both recognize the same tap (they have to; see
//  `shouldRecognizeSimultaneouslyWith` below), so a thumb where the lines
//  cross would open a hike *and* somebody else's preview, and which of them
//  ended up on top would be gesture-resolution order rather than a decision
//  anybody made. So the gesture, the check that nothing above the map has a
//  better claim to the touch, and the order the two hit-tests are asked in all
//  live here, and each kind of line keeps only the part that knows what it is:
//  ``communityListing(forTapAt:in:)`` in `MapCommunityRoutes.swift`, and
//  ``isTapOnDrawnRoute(at:in:)`` below.
//
//  ## The drawn trail's own legs, since Phase 3
//
//  A third kind of line is on this map while the trail maker is up, and it is
//  the one kind whose tap is not *open something*: a tap on a leg of the line
//  being drawn puts a point into it. That is answered before the two above and
//  by ``addTrailDraftWaypoint(at:in:)`` rather than here, because while the
//  maker is up a tap on the map has exactly one meaning — see the note on that
//  method, and `MapTrailDraftDrag.swift` for the press that moves a point
//  rather than adding one.
//
//  ## The hiker's own line wins
//
//  It is drawn on top, it is drawn at full strength and the hiker chose its
//  colour, so it is the one they can see under their thumb where the two
//  overlap. Asking it first is the whole of that rule.
//
//  ## What a tap costs
//
//  Both hit-tests project their points through the map, because the tolerance
//  is a fingertip and a fingertip is a distance on the glass — see
//  ``RouteHitTest``. A page of shared lines is bounded by an outline's point
//  budget, but the hiker's own route is not bounded by anything: a six-hour
//  recording is twenty thousand points, measured at 2.2 ms to project and
//  0.05 ms to then measure against.
//
//  Which is why the drawn route is asked for its bounding rectangle first.
//  MapKit converts that rectangle in one call, whatever the camera is doing to
//  it, and a tap outside it cannot be within a fingertip of the line inside —
//  so the ordinary miss, which is most taps on a map, costs one conversion
//  rather than twenty thousand.
//

import MapKit
import OpenHikesShared
#if canImport(UIKit)
import UIKit
#endif

/// Which line a tap landed on.
///
/// An enumeration rather than two optionals, because the point of asking once
/// is that the answer is one thing.
enum RouteTapTarget: Equatable {
    /// A published hike, drawn faded beneath the hiker's own route.
    case communityListing(CommunityListing)
    /// The hiker's own drawn route — the selected hike's, and the only one of
    /// theirs the map ever draws.
    case drawnRoute

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.communityListing(left), .communityListing(right)): left.id == right.id
        case (.drawnRoute, .drawnRoute): true
        default: false
        }
    }
}

#if canImport(UIKit)
extension MapView.Coordinator: UIGestureRecognizerDelegate {
    /// How far from a line a tap may land and still count, in screen points.
    ///
    /// About a fingertip, and deliberately more than either line is wide: a
    /// three-point line nobody could hit is a line that is not tappable, and
    /// the hit-tests resolve the overlap this creates by taking the nearest.
    ///
    /// One number for both kinds, because it is a number about thumbs rather
    /// than about what the line underneath one happens to be.
    static let lineTapTolerancePoints: CGFloat = 22

    /// Adds the recognizer that answers a tap on any of the lines drawn here.
    ///
    /// Idempotent for the reason the observations are: `makeMapView` runs once
    /// per map, but nothing here should depend on that, and a second
    /// recognizer would open the same screen twice.
    func installRouteTap(on mapView: MKMapView) {
        guard routeTapRecognizer == nil else { return }
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleRouteTap(_:))
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
        routeTapRecognizer = recognizer
        mapView.addGestureRecognizer(recognizer)
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Whether a recognizer on this map may start.
    ///
    /// Only one of the two this delegate answers for is ever refused, and it
    /// is refused for nearly every press: the waypoint drag begins only when a
    /// pin is under the finger. Everything else — a press on open map, on a
    /// line, on a control — is left to mean exactly what it meant before,
    /// which is what keeps a gesture nobody is using from costing a quarter of
    /// a second of every long press on the map. See `MapTrailDraftDrag.swift`.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === trailDraftDragRecognizer,
              let mapView = recognizer.view as? MKMapView else { return true }
        return trailDraftWaypointIndex(
            at: recognizer.location(in: mapView),
            in: mapView
        ) != nil
    }

    @objc func handleRouteTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let mapView = recognizer.view as? MKMapView
        else { return }
        let point = recognizer.location(in: mapView)
        // **While the maker is up, a tap on the map means one thing.** Every
        // other meaning this recognizer carries — the hiker's own line, a
        // shared hike's — is suspended, because a tap that put a point down
        // *and* opened somebody's trail would be a tap that did two things,
        // and the one thing it is for is the one the hiker came here to do.
        // The controls above the map keep their claim: `addTrailDraftWaypoint`
        // asks the same question `routeTapTarget(at:in:)` asks first.
        if addTrailDraftWaypoint(at: point, in: mapView) { return }
        let target = routeTapTarget(at: point, in: mapView)
        // Only a hit. A tap that landed on open map is not a failed gesture —
        // it is panning, or nothing at all — and answering it would make the
        // whole map buzz under a finger.
        if target != nil { HapticMoment.targetHit.play() }
        switch target {
        case .drawnRoute: drawnRouteTap?.open()
        case let .communityListing(listing): community?.open(listing)
        case nil: break
        }
    }

    /// Puts a waypoint down where a tap landed, while the maker is up.
    ///
    /// - Returns: whether the tap was spent here, which is what tells the
    ///   handler above to stop asking what else it could have meant.
    ///
    /// Split from the handler for the reason ``routeTapTarget(at:in:)`` is:
    /// a `UITapGestureRecognizer`'s state and location are set by the touch
    /// system and cannot be driven by a suite, so what is worth asserting on
    /// has to be reachable without one.
    ///
    /// A tap that landed on something over the map is not a waypoint. The
    /// tracking button, the credit line and the pill that opened this mode all
    /// sit on the canvas, and a thumb on one of them must not leave a point
    /// behind it.
    ///
    /// **Markers are among those things, deliberately.** What this suspends is
    /// the *canvas* — the lines, which are drawn pixels with no view behind
    /// them and are reached only through this recognizer. An `MKAnnotationView`
    /// is a view with its own touches, and ``isTapClaimed(at:in:)`` has always
    /// given it the tap; a shared hike's pin therefore still opens its callout
    /// while a trail is being drawn, and the callout's accessory still opens
    /// the hike. That is a second deliberate tap rather than a stray one, the
    /// maker keeps its draft underneath and Back returns to it — and somebody
    /// planning a walk has a real use for reading the waymarked route beside
    /// the line they are drawing. The hiker's own photo pins cannot be there
    /// at all: like the camera pill, they are offered only by a screen that
    /// attaches a subject, and the maker attaches none.
    ///
    /// The maker's *own* numbered pins are not among them, and
    /// ``isTapClaimed(at:in:)`` says why: they answer no tap, so a claim by
    /// one is a tap that disappears rather than a tap that did something else.
    ///
    /// ## Two meanings, and the line decides which
    ///
    /// A tap on open map appends a point at the end of the line, which is what
    /// drawing is. A tap **on a leg that is already drawn** puts a point into
    /// that leg where the thumb landed, which is how a route that cuts a
    /// corner is made to bend round it. The second is not a second gesture:
    /// it is the same tap, and which it means is decided by whether it landed
    /// within a fingertip of a line the hiker can see. Appending to the end of
    /// a trail by tapping a point on its own middle is not a thing anybody
    /// means.
    func addTrailDraftWaypoint(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let trailDraftController, trailDraftController.isEditing else { return false }
        guard !isTapClaimed(at: point, in: mapView) else { return false }
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        if let leg = trailDraftLegIndex(at: point, in: mapView) {
            trailDraftController.insertWaypoint(at: coordinate, intoLegAt: leg)
        } else {
            trailDraftController.appendWaypoint(at: coordinate)
        }
        return true
    }

    /// Which leg of the drawn line a tap landed on, if any.
    ///
    /// Measured against the polylines the map is drawing rather than against
    /// the draft, for the reason ``trailDraftWaypointIndex(at:in:)`` is: they
    /// are the same list one observation pass apart, and the lines are what
    /// the hiker aimed at.
    ///
    /// Each leg's bounding rectangle is asked first, exactly as
    /// ``isTapOnDrawnRoute(at:in:)`` asks the whole route's — a snapped leg
    /// through a valley is hundreds of points, and there is one of these per
    /// leg rather than one per trail, so the guard matters more here than
    /// there. Nearest wins, not first: a tap where a trail doubles back on
    /// itself is aimed at the pixels under the thumb.
    func trailDraftLegIndex(at point: CGPoint, in mapView: MKMapView) -> Int? {
        guard trailDraftController?.isEditing == true,
              !trailDraftOverlays.isEmpty else { return nil }
        let tolerance = Self.lineTapTolerancePoints
        var projected: [[CGPoint]] = []
        projected.reserveCapacity(trailDraftOverlays.count)
        for line in trailDraftOverlays {
            let bounds = mapView
                .convert(MKCoordinateRegion(line.boundingMapRect), toRectTo: mapView)
                .insetBy(dx: -tolerance, dy: -tolerance)
            guard bounds.contains(point) else {
                // Kept in the list rather than skipped, so an index here is an
                // index into the legs. An empty line is never the nearest.
                projected.append([])
                continue
            }
            projected.append(Self.points(of: line, in: mapView))
        }
        return RouteHitTest.nearest(to: point, among: projected, tolerance: tolerance)
    }

    /// One polyline's points, projected into the map's own screen space — the
    /// space the tolerance is a number in. See ``RouteHitTest``.
    private static func points(of line: MKPolyline, in mapView: MKMapView) -> [CGPoint] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: line.pointCount
        )
        line.getCoordinates(&coordinates, range: NSRange(location: 0, length: line.pointCount))
        return coordinates.map { mapView.convert($0, toPointTo: mapView) }
    }

    /// The line a tap at `point` landed on, if any.
    ///
    /// Split from the handler above because this is the half worth asserting
    /// on and a `UITapGestureRecognizer` is the half that cannot be: its state
    /// and its location are read-only and set by the touch system, so a suite
    /// driving the handler would have to fake UIKit rather than the map. What
    /// is left in the handler is the four lines that turn a gesture into this
    /// call and hand the answer on.
    func routeTapTarget(at point: CGPoint, in mapView: MKMapView) -> RouteTapTarget? {
        guard !isTapClaimed(at: point, in: mapView) else { return nil }
        if isTapOnDrawnRoute(at: point, in: mapView) { return .drawnRoute }
        return communityListing(forTapAt: point, in: mapView).map(RouteTapTarget.communityListing)
    }

    /// Whether a tap at `point` landed on the hiker's own drawn route.
    ///
    /// The line only, and deliberately not the inferred or paused stretches
    /// drawn over it: those are the same geometry drawn differently, so every
    /// point of them is already a point of this.
    ///
    /// The bounding rectangle first, for the reason this file's header gives —
    /// a route is unbounded in length and a tap that missed it by the width of
    /// the screen must not pay for twenty thousand projections to find that
    /// out. Grown by the tolerance, because a tap just outside the rectangle
    /// can still be within a fingertip of the line that touches its edge.
    ///
    /// MapKit converts the rectangle, rather than this deciding what a map
    /// rectangle is worth in screen points, and that is what makes the guard
    /// safe to put in front of an exact answer: a camera can be rotated and
    /// pitched, and both change where a map rectangle lands. Checked against
    /// every point of a drawn line at heading 37°, at 34° of pitch, and at
    /// both together — the returned rectangle contained all of them each time,
    /// so a line that would be hit is never rejected here.
    func isTapOnDrawnRoute(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard routeCoordinates.count > 1, let polyline = routeOverlay else { return false }
        let tolerance = Self.lineTapTolerancePoints
        let bounds = mapView
            .convert(MKCoordinateRegion(polyline.boundingMapRect), toRectTo: mapView)
            .insetBy(dx: -tolerance, dy: -tolerance)
        guard bounds.contains(point) else { return false }
        let projected = routeCoordinates.map { mapView.convert($0, toPointTo: mapView) }
        guard let distance = RouteHitTest.distance(from: point, to: projected) else { return false }
        return distance <= tolerance
    }

    /// Whether something on top of the map has a better claim to this tap.
    ///
    /// A marker, a callout, the tracking button, the camera pill, the maker's
    /// pill, *Search this area*, the credit line — all of them are views, all
    /// of them sit over the lines, and a tap that opens a hike *as well as*
    /// pressing a button is a tap that did two things. A recognizer on the map
    /// view sees those touches whatever the view under them does with them, so
    /// this is the whole of what stops it.
    ///
    /// The walk up the hierarchy rather than a test of the hit view alone is
    /// because every one of these is a tree: what a tap actually lands on is a
    /// label inside a button inside an annotation view.
    ///
    /// The named views are named because none of them is a `UIControl` —
    /// `MKUserTrackingButton` is a plain `UIView`, and the rest are this
    /// app's own containers with the buttons *inside* them. Testing for
    /// `UIControl` alone would let a tap on the padding around a button through
    /// while catching the button itself, which is the sort of difference
    /// nobody can see and everybody hits.
    /// The maker's own pins are the one exception, and they are an exception
    /// because they are not a claim. A ``TrailDraftWaypointAnnotation``'s view
    /// shows no callout and answers no tap, so letting it take one means a
    /// thumb inside its 24 points does nothing at all — no point put down, no
    /// callout opened, no feedback — and a hiker drawing a switchback or
    /// doubling back past a point they already placed cannot tell a swallowed
    /// tap from a missed one. The paragraph above argues from markers that
    /// *do* something with a touch; these do not, so the tap goes on to mean
    /// what every other tap on this canvas means.
    ///
    /// **A waypoint pin answers a *press*, and that is a different gesture.**
    /// Since Phase 3 a long press on one takes hold of it and moves it, which
    /// is a `UILongPressGestureRecognizer` of the map's own rather than
    /// anything the annotation view does with a touch — see
    /// `MapTrailDraftDrag.swift`. So the pin still claims nothing here, and
    /// the two gestures do not have to be told apart.
    private func isTapClaimed(at point: CGPoint, in mapView: MKMapView) -> Bool {
        var view = mapView.hitTest(point, with: nil)
        while let current = view, current !== mapView {
            if let annotationView = current as? MKAnnotationView {
                return !(annotationView.annotation is TrailDraftWaypointAnnotation)
            }
            if current is UIControl { return true }
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
        if view === trailDraftControls { return true }
        #endif
        return false
    }
}
#endif
