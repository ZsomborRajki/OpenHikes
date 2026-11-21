//
//  MapRouteTrim.swift
//  OpenHikes
//
//  *Edit Route*'s half of the map: a handle on each end of the kept line,
//  the stretches a save would cut off drawn over in gray, and the stretch to
//  check the hiker is looking at picked out. See ``RouteTrimSession``, whose
//  cuts and answers this reads directly.
//
//  ## Drawn over the line, not instead of it
//
//  The hike's own line stays as the map draws it. A stretch being cut is
//  covered: one gray polyline of the whole line for each end, of which MapKit
//  strokes only the part past the cut (`strokeStart` and `strokeEnd`). A
//  handle moving is then two numbers written to two renderers, and the line
//  of twenty thousand points is handed to MapKit once a visit rather than
//  once a touch.
//
//  Those two numbers are fractions of the polyline's length as MapKit
//  measures it, which is in map points and across a paused leg, so they come
//  from ``RouteTrimLine/drawnFractions`` and not from the cut's metres.
//
//  ## Where the hike's own line is not the kept one
//
//  The session works on the whole line, and the map has the hike's: after an
//  earlier trim that is less than a handle can now be dragged back out over,
//  and after an answer changed in this visit one of its stretches is the old
//  one. So then (``RouteTrimSession/drawsKeptLine``) the whole line goes on
//  the map a third time, stroked between the cuts, with the replaced
//  stretches of the hike's own line covered under it: run by run in the
//  route's colour, and dotted across each pause as the route itself is —
//  see `MapRouteTrim+KeptLine.swift`.
//
//  ## A handle slides along its line
//
//  Dragged with a recognizer of this file's own, for the reasons the maker's
//  pins are (`MapTrailDraftDrag.swift`): MapKit's dragging reports a start
//  and an end and nothing between, and the map has to stop scrolling under a
//  finger that is moving a handle. The handle goes to the spot on the line
//  nearest the finger, looking only near where it is — see
//  ``RouteTrimLine/distance(nearest:around:)``.
//
//  Where the two handles stand on one spot, a loop's start and finish, a
//  press takes the end: that is the one a recording left running moves.
//

import MapKit
import OpenHikesData
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One of the two handles, in the shape MapKit wants it.
final class RouteTrimHandleAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "routeTrimHandle"

    let handle: RouteTrimHandle
    /// `dynamic` so MapKit moves the view when a cut moves, rather than the
    /// handle being removed and added again at drag frequency.
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(handle: RouteTrimHandle, coordinate: CLLocationCoordinate2D) {
        self.handle = handle
        self.coordinate = coordinate
    }
}

struct RouteTrimMapState {
    var isObserving = false
    /// The session on the map, and the line of it the covers were built
    /// from.
    weak var session: RouteTrimSession?
    var lineRevision: Int?
    /// The whole line twice: what is stroked of each is the part before the
    /// start cut and the part after the end cut.
    var leadingCover: MKPolyline?
    var trailingCover: MKPolyline?
    weak var leadingRenderer: MKPolylineRenderer?
    weak var trailingRenderer: MKPolylineRenderer?
    /// The whole line a third time, stroked between the cuts, in pieces —
    /// see the file header. Empty while the hike's own line is the kept one.
    var keptPieces: [RouteTrimKeptPiece] = []
    /// The stretches of the hike's own line an answer has replaced.
    var staleCovers: [MKPolyline] = []
    /// The stretch to check the hiker is looking at, and which it is.
    var focus: MKPolyline?
    var focusedCheckID: Int?
    var startHandle: RouteTrimHandleAnnotation?
    var endHandle: RouteTrimHandleAnnotation?

    #if canImport(UIKit)
    var dragRecognizer: UILongPressGestureRecognizer?
    #endif

    /// The handle under a finger, and how far its center was from the touch
    /// when it was taken, so it does not jump.
    var held: RouteTrimHandle?
    var dragOffset: CGSize = .zero
    /// Whether this drag is why the map is not scrolling.
    var pausedScrolling = false
}

extension MapView.Coordinator {
    /// Wide enough to hide the line and its border underneath.
    private static let trimCoverWidthFactor: CGFloat = 2.6
    /// The stretch being looked at, as the review before a save drew it.
    private static let trimFocusWidth: CGFloat = 7
    private static let trimHandleDiameter: CGFloat = 30
    private static let trimHandleRingWidth: CGFloat = 4
    /// How long a finger rests on a handle before it takes hold: long enough
    /// that a pan begun over one is still a pan, and no longer.
    private static let trimHandlePressDuration: TimeInterval = 0.12
    /// What one step of VoiceOver's adjust moves a handle by, as a share of
    /// the line.
    private static let trimHandleStepFraction = 0.02

    func observeRouteTrim(_ preview: RouteTrimPreview, on mapView: MKMapView) {
        guard !routeTrimMap.isObserving else { return }
        routeTrimMap.isObserving = true
        #if canImport(UIKit)
        installRouteTrimDrag(on: mapView)
        #endif
        trackRouteTrim(preview, on: mapView)
    }

    private func trackRouteTrim(_ preview: RouteTrimPreview, on mapView: MKMapView) {
        applyRouteTrim(preview.session, on: mapView)
        reobserving(self, mapView, preview) {
            let session = preview.session
            _ = session?.lineRevision
            _ = session?.startMeters
            _ = session?.endMeters
            _ = session?.pausesTakenOff
            _ = session?.focusedCheckID
        } onChange: { coordinator, map, model in
            coordinator.trackRouteTrim(model, on: map)
        }
    }

    /// Draws `session`'s cuts, building the covers and the handles when the
    /// session or its line is new and only moving them otherwise.
    func applyRouteTrim(_ session: RouteTrimSession?, on mapView: MKMapView) {
        guard let session, let line = session.line else {
            removeRouteTrim(from: mapView)
            return
        }
        if routeTrimMap.session !== session || routeTrimMap.lineRevision != session.lineRevision {
            removeRouteTrim(from: mapView)
            routeTrimMap.session = session
            routeTrimMap.lineRevision = session.lineRevision
            addRouteTrim(of: line, in: session, to: mapView)
        }
        guard let start = session.spot(of: .start), let end = session.spot(of: .end) else { return }
        if let renderer = routeTrimMap.leadingRenderer { cover(renderer, from: 0, to: start.drawnFraction) }
        if let renderer = routeTrimMap.trailingRenderer { cover(renderer, from: end.drawnFraction, to: 1) }
        for piece in routeTrimMap.keptPieces {
            guard let renderer = piece.renderer else { continue }
            coverKept(piece, with: renderer, from: start, to: end)
        }
        move(routeTrimMap.startHandle, to: start.coordinate)
        move(routeTrimMap.endHandle, to: end.coordinate)
        focusRouteTrim(on: session.focusedCheckID, of: line, on: mapView)
    }

    /// Picks out the stretch the hiker is looking at, or none. A handful of
    /// points, replaced only when which stretch it is changes.
    private func focusRouteTrim(on id: Int?, of line: RouteTrimLine, on mapView: MKMapView) {
        guard routeTrimMap.focusedCheckID != id || (id != nil && routeTrimMap.focus == nil) else { return }
        if let focus = routeTrimMap.focus { mapView.removeOverlay(focus) }
        routeTrimMap.focus = nil
        routeTrimMap.focusedCheckID = id
        guard let id else { return }
        let stretch = line.coordinates(ofCheck: id)
        guard stretch.count > 1 else { return }
        let focus = MKPolyline(coordinates: stretch, count: stretch.count)
        routeTrimMap.focus = focus
        mapView.addOverlay(focus, level: .aboveLabels)
    }

    private func addRouteTrim(of line: RouteTrimLine, in session: RouteTrimSession, to mapView: MKMapView) {
        let coordinates = line.profile.coordinates
        // In the order they lie in, lowest first: what an answer replaced,
        // the kept line over it, and what a save would cut off over that.
        let stale = session.staleStretches.filter { $0.count > 1 }.map { stretch in
            MKPolyline(coordinates: stretch, count: stretch.count)
        }
        routeTrimMap.staleCovers = stale
        let kept = session.drawsKeptLine ? Self.keptPieces(of: line) : []
        routeTrimMap.keptPieces = kept
        let leading = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let trailing = MKPolyline(coordinates: coordinates, count: coordinates.count)
        routeTrimMap.leadingCover = leading
        routeTrimMap.trailingCover = trailing
        // Above the route, which is at the top of the same level.
        mapView.addOverlays(stale + kept.map(\.polyline) + [leading, trailing], level: .aboveLabels)
        guard let first = coordinates.first, let last = coordinates.last else { return }
        let start = RouteTrimHandleAnnotation(handle: .start, coordinate: first)
        let end = RouteTrimHandleAnnotation(handle: .end, coordinate: last)
        routeTrimMap.startHandle = start
        routeTrimMap.endHandle = end
        mapView.addAnnotations([start, end])
    }

    private func removeRouteTrim(from mapView: MKMapView) {
        #if canImport(UIKit)
        if routeTrimMap.held != nil { releaseRouteTrimDrag(on: mapView) }
        #endif
        let covers = [routeTrimMap.leadingCover, routeTrimMap.trailingCover, routeTrimMap.focus]
        let kept = routeTrimMap.keptPieces.map(\.polyline)
        mapView.removeOverlays(routeTrimMap.staleCovers + kept + covers.compactMap(\.self))
        mapView.removeAnnotations([routeTrimMap.startHandle, routeTrimMap.endHandle].compactMap(\.self))
        routeTrimMap.leadingCover = nil
        routeTrimMap.trailingCover = nil
        routeTrimMap.keptPieces = []
        routeTrimMap.staleCovers = []
        routeTrimMap.focus = nil
        routeTrimMap.focusedCheckID = nil
        routeTrimMap.startHandle = nil
        routeTrimMap.endHandle = nil
        routeTrimMap.session = nil
        routeTrimMap.lineRevision = nil
    }

    /// Strokes `renderer`'s polyline between two fractions of its length. A
    /// renderer asked to stroke nothing is hidden instead: a zero-length
    /// stroke with a round cap is still a dot.
    func cover(_ renderer: MKPolylineRenderer, from start: Double, to end: Double) {
        let alpha: CGFloat = end <= start ? 0 : 1
        guard renderer.strokeStart != start || renderer.strokeEnd != end || renderer.alpha != alpha else { return }
        renderer.strokeStart = start
        renderer.strokeEnd = end
        renderer.alpha = alpha
        renderer.setNeedsDisplay()
    }

    private func move(_ annotation: RouteTrimHandleAnnotation?, to coordinate: CLLocationCoordinate2D) {
        guard let annotation,
              annotation.coordinate.latitude != coordinate.latitude
                || annotation.coordinate.longitude != coordinate.longitude
        else { return }
        annotation.coordinate = coordinate
    }

    /// The renderer for one of this file's polylines, or `nil` for any other.
    func routeTrimRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        if routeTrimMap.focus === polyline { return routeTrimFocusRenderer(for: polyline) }
        if let kept = routeTrimKeptRenderer(for: polyline) { return kept }
        let isLeading = routeTrimMap.leadingCover === polyline
        let isTrailing = routeTrimMap.trailingCover === polyline
        guard isLeading || isTrailing || routeTrimMap.staleCovers.contains(where: { $0 === polyline }) else {
            return nil
        }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor.systemGray
        #else
        renderer.strokeColor = UIColor.systemGray
        #endif
        renderer.lineWidth = CGFloat(routeWidth) * Self.trimCoverWidthFactor
        renderer.lineJoin = .round
        renderer.lineCap = .butt
        if isLeading {
            routeTrimMap.leadingRenderer = renderer
        } else if isTrailing {
            routeTrimMap.trailingRenderer = renderer
        }
        // The cut it is drawn to, which the pass that added the overlay
        // could not set: MapKit asks for the renderer afterwards.
        if isLeading, let spot = routeTrimMap.session?.spot(of: .start) {
            cover(renderer, from: 0, to: spot.drawnFraction)
        } else if isTrailing, let spot = routeTrimMap.session?.spot(of: .end) {
            cover(renderer, from: spot.drawnFraction, to: 1)
        }
        return renderer
    }

    /// The stretch being looked at: dashed in orange, over everything else.
    private func routeTrimFocusRenderer(for polyline: MKPolyline) -> MKPolylineRenderer {
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor.systemOrange
        #else
        renderer.strokeColor = UIColor.systemOrange
        #endif
        renderer.lineWidth = Self.trimFocusWidth
        renderer.lineDashPattern = [3, 5]
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    /// The view for one of the two handles, or `nil` for any other
    /// annotation: a white knob ringed in the route's colour, which is what a
    /// thing to drag along a line looks like.
    func routeTrimHandleView(for annotation: any MKAnnotation, on mapView: MKMapView) -> MKAnnotationView? {
        guard let handle = annotation as? RouteTrimHandleAnnotation else { return nil }
        let view = mapView.reusableView(
            RouteTrimHandleView.self,
            for: handle,
            reuseIdentifier: RouteTrimHandleAnnotation.reuseIdentifier
        )
        view.canShowCallout = false
        let diameter = Self.trimHandleDiameter
        view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        // Never decluttered away, and the end over the start where a loop
        // stands them on one spot — the one a press there takes.
        view.displayPriority = .required
        view.zPriority = handle.handle == .end ? .max : .defaultSelected
        #if canImport(UIKit)
        let layer = view.layer
        layer.backgroundColor = UIColor.white.cgColor
        layer.borderColor = UIColor(routeTint).withAlphaComponent(1).cgColor
        layer.cornerRadius = diameter / 2
        layer.borderWidth = Self.trimHandleRingWidth
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.trimHandleShadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        view.isAccessibilityElement = true
        view.accessibilityTraits = .adjustable
        view.accessibilityIdentifier = handle.handle == .start ? "route-trim-start-handle" : "route-trim-end-handle"
        view.accessibilityLabel = handle.handle == .start
            ? String(localized: "Start of route")
            : String(localized: "End of route")
        #endif
        view.onAdjust = { [weak self] direction in
            self?.adjustRouteTrim(handle.handle, by: direction)
        }
        return view
    }

    private static let trimHandleShadowOpacity: Float = 0.3

    /// VoiceOver's swipe up or down on a handle: one step along the line.
    private func adjustRouteTrim(_ handle: RouteTrimHandle, by direction: Double) {
        guard let session = routeTrimMap.session else { return }
        let step = session.totalMeters * Self.trimHandleStepFraction
        session.move(handle, to: session.position(of: handle) + direction * step)
    }
}

/// A handle's view, which VoiceOver adjusts as it does a slider's thumb.
final class RouteTrimHandleView: MKAnnotationView {
    /// Called with 1 for a step towards the line's end and -1 for one
    /// towards its start.
    var onAdjust: ((Double) -> Void)?

    #if canImport(UIKit)
    override func accessibilityIncrement() { onAdjust?(1) }

    override func accessibilityDecrement() { onAdjust?(-1) }
    #endif
}

#if canImport(UIKit)
extension MapView.Coordinator {
    /// Adds the recognizer that drags a handle. Idempotent, like the
    /// maker's, and for the same reason.
    func installRouteTrimDrag(on mapView: MKMapView) {
        guard routeTrimMap.dragRecognizer == nil else { return }
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleRouteTrimDrag(_:)))
        recognizer.minimumPressDuration = Self.trimHandlePressDuration
        // The delegate `gestureRecognizerShouldBegin` discriminates on: this
        // one begins only over a handle.
        recognizer.delegate = self
        routeTrimMap.dragRecognizer = recognizer
        mapView.addGestureRecognizer(recognizer)
    }

    @objc func handleRouteTrimDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        switch recognizer.state {
        case .began: beginRouteTrimDrag(at: point, in: mapView)
        case .changed: moveRouteTrimDrag(to: point, in: mapView)
        case .ended, .cancelled, .failed: releaseRouteTrimDrag(on: mapView)
        case .possible: break
        @unknown default: releaseRouteTrimDrag(on: mapView)
        }
    }

    /// Which handle is under `point`, if either: the nearer within a
    /// fingertip, and the end where they are equally near.
    func routeTrimHandle(at point: CGPoint, in mapView: MKMapView) -> RouteTrimHandle? {
        guard routeTrimMap.session != nil else { return nil }
        let reach = Self.lineTapTolerancePoints
        let handles = [routeTrimMap.endHandle, routeTrimMap.startHandle].compactMap(\.self)
        let within = handles.compactMap { handle -> (handle: RouteTrimHandle, distance: CGFloat)? in
            let center = mapView.convert(handle.coordinate, toPointTo: mapView)
            let distance = hypot(point.x - center.x, point.y - center.y)
            return distance <= reach ? (handle.handle, distance) : nil
        }
        // `min` keeps the first of two equals, which is the end.
        return within.min { $0.distance < $1.distance }?.handle
    }

    /// Takes hold of whichever handle is under `point`. Split from the
    /// recognizer's own handler so a suite can reach it — see
    /// ``beginTrailDraftDrag(at:in:)``.
    @discardableResult func beginRouteTrimDrag(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let handle = routeTrimHandle(at: point, in: mapView),
              let annotation = handle == .start ? routeTrimMap.startHandle : routeTrimMap.endHandle
        else { return false }
        let center = mapView.convert(annotation.coordinate, toPointTo: mapView)
        routeTrimMap.held = handle
        routeTrimMap.dragOffset = CGSize(width: center.x - point.x, height: center.y - point.y)
        routeTrimMap.pausedScrolling = mapView.isScrollEnabled
        mapView.isScrollEnabled = false
        HapticMoment.targetHit.play()
        return true
    }

    /// Slides the held handle along the line towards the finger.
    func moveRouteTrimDrag(to point: CGPoint, in mapView: MKMapView) {
        guard let handle = routeTrimMap.held, let session = routeTrimMap.session else { return }
        let aimed = CGPoint(
            x: point.x + routeTrimMap.dragOffset.width,
            y: point.y + routeTrimMap.dragOffset.height
        )
        session.move(handle, toward: mapView.convert(aimed, toCoordinateFrom: mapView))
        // Applied here as well as by the observation, which is a hop behind:
        // a handle a frame behind the finger reads as lag.
        applyRouteTrim(session, on: mapView)
    }

    /// Lets go, and hands the map back its scrolling.
    func releaseRouteTrimDrag(on mapView: MKMapView) {
        routeTrimMap.held = nil
        guard routeTrimMap.pausedScrolling else { return }
        routeTrimMap.pausedScrolling = false
        mapView.isScrollEnabled = true
    }
}
#endif
