//
//  MapTrailDraftOverlay.swift
//  OpenHikes
//
//  The line being drawn, on the map it is being drawn on.
//
//  Its own overlay rather than the selected hike's, because the two say
//  different things and are on screen at the same time: a hiker can be drawing
//  a new route across a valley they already have a trail through. The drawn
//  line is the app's accent and the hiker's own routes are whatever colour
//  they chose, so neither is ever mistaken for the other.
//
//  Numbered pins rather than plain dots, and that is the affordance rather
//  than decoration: the order points were put down in is the direction the
//  trail runs, and it is the only thing about a drawn line that a picture of
//  the line cannot show. It is also what the list in the sheet is a list *of*,
//  so the two are readable against each other.
//
//  ## One polyline per leg, since Phase 2
//
//  The line used to be one `MKPolyline` through the waypoints. It is now one
//  per leg, because a leg is the thing that has a state: while a route is
//  being asked for it is dashed, once it has settled it is solid, and a leg
//  that was asked and could not be routed is drawn differently again. A single
//  overlay has a single renderer and could say only one of those about a whole
//  trail — and the commonest shape this feature produces is a line where all
//  but the last leg have settled.
//
//  What the three weights mean, and the distinction that matters most:
//
//  - **Solid** — settled and as asked. A snapped leg *and* a freehand one,
//    because a straight line the hiker asked for by turning the toggle off is
//    not a degraded anything.
//  - **Short dash** — still being routed. Provisional, and about to change.
//  - **Long dash** — asked, and straight anyway: nothing is mapped between
//    these two points, or Overpass refused. The line is real and saveable; it
//    just is not following anything.
//
//  ## A drag is the one thing that is not rebuilt wholesale
//
//  Everything else here throws every pin and every polyline away and puts them
//  back, because everything else happens when a hiker taps or when an answer
//  lands — a few dozen objects, a few times a minute. A point under a finger
//  moves at display rate, and removing and re-adding a pin sixty times a
//  second is a pin that flickers.
//
//  So while ``TrailDraft/drag`` is set, one pin's `coordinate` is assigned —
//  MapKit moves its view for free — and the one or two legs that point is an
//  end of are replaced with straight rubber bands. Every other line, every
//  other pin and the whole of the sheet below are untouched, and the wholesale
//  rebuild happens once, when the finger lifts and the drawing changes. That
//  is what ``MapView/Coordinator/trailDraftOverlays`` being **one polyline per
//  leg, in leg order** is for: the drag reaches its two lines by index.
//
//  Applied imperatively off ``TrailDraft``, like every other overlay here, so
//  a tap that adds a point moves MapKit and no SwiftUI view.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One waypoint, in the shape MapKit wants it, carrying the number it draws.
final class TrailDraftWaypointAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftWaypoint"

    /// `var` since Phase 3, and only for the drag: MapKit moves an
    /// annotation's view when this changes, so a point under a finger follows
    /// it without the pin being removed and added again sixty times a second.
    /// Every other change to where a point is goes through a rebuild.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// One-based, because it is read by a person rather than indexed by code.
    let number: Int
    /// How far along the line this point sits, which is the callout's second
    /// line and the same figure the list row carries.
    let distanceAlongLineMeters: Double

    init(coordinate: CLLocationCoordinate2D, number: Int, distanceAlongLineMeters: Double) {
        self.coordinate = coordinate
        self.number = number
        self.distanceAlongLineMeters = distanceAlongLineMeters
    }

    /// The callout's heading, and what VoiceOver reaches a waypoint by — a
    /// polyline is not an accessibility element and cannot be made one.
    var title: String? {
        String(localized: "Point \(number)")
    }

    /// How far along the trail it is, in the hiker's own units.
    var subtitle: String? {
        Measurement(value: distanceAlongLineMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

extension MapView.Coordinator {
    private static let trailDraftLineWidth: CGFloat = 4
    private static let trailDraftPinDiameter: CGFloat = 24
    private static let trailDraftPinBorderWidth: CGFloat = 2.5
    private static let trailDraftPinShadowOpacity: Float = 0.35
    /// Short ticks with wide gaps: unmistakably provisional at a glance, and
    /// visibly not the long dashes below.
    private static let trailDraftRoutingDashes = [2, 8]
    /// Long dashes, close together: a real line that did not find a path.
    private static let trailDraftDegradedDashes = [10, 6]

    /// Observes the draft and redraws it, then re-registers.
    ///
    /// The line, the legs' states and whether there is a canvas at all are
    /// tracked in one registration, because they are one question: the draft
    /// is drawn while the maker is up and not otherwise, so a change to any of
    /// them has the same answer to compute. Idempotent, like every
    /// registration here.
    func observeTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        guard !isObservingTrailDraft else { return }
        isObservingTrailDraft = true
        trackTrailDraft(controller, on: mapView)
    }

    private func trackTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        applyTrailDraft(controller, on: mapView)
        reobserving(self, mapView, controller) {
            _ = controller.isEditing
            _ = controller.draft.waypoints
            _ = controller.draft.legs
            // The drag's observed half, and the only one: the coordinate under
            // the finger is deliberately untracked, so a point being moved
            // publishes one `Int` per frame and nothing that reads it is a
            // SwiftUI body. See ``TrailDraft``.
            _ = controller.draft.dragRevision
            // The marked places, in the same registration and for the same
            // reason the line is: they are drawn while the maker is up and not
            // otherwise. Their own drag does not come through here — a place
            // under a finger moves its annotation directly, which is what
            // ``placeRows`` staying still through the gesture is for.
            _ = controller.draft.placeRows
            // And what OpenStreetMap last offered near the line, in the same
            // registration for the same reason: the candidates are drawn while
            // the maker is up and not otherwise. See
            // `MapTrailPointCandidates.swift`.
            _ = controller.finder.rows
        } onChange: { coordinator, map, model in
            coordinator.trackTrailDraft(model, on: map)
        }
    }

    /// Rebuilds the legs and the pins wholesale rather than diffing them.
    ///
    /// At most a few dozen of each, and this runs when a hiker taps or when a
    /// leg's route lands — never at drag or fix frequency. The guard in front
    /// of it is what keeps a republish of the same draft from removing and
    /// re-adding everything, and it compares the *legs* rather than the
    /// waypoints because a leg changes shape and state without a point
    /// moving: that is what an answer arriving is.
    private func applyTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        let isDrawing = controller.isEditing
        let legs = isDrawing ? controller.draft.legs : []
        let points = isDrawing ? controller.draft.coordinates : []
        let held = isDrawing ? controller.draft.drag : nil
        let snapping = controller.draft.snapsToPaths
        // Before the guard below, deliberately: that one lets a pass through
        // only when the *line* changed, and a place can be marked, renamed or
        // removed without a leg moving. It has a guard of its own.
        applyTrailDraftPlaces(isDrawing ? controller.draft.placeRows : [], on: mapView)
        // The offered places, on the same terms and before the same guard: a
        // search landing changes no leg at all.
        applyTrailPointCandidates(isDrawing ? controller.finder.rows : [], on: mapView)
        // And the strip at the top of the map, which the maker takes from the
        // *Community* tab for as long as it is up — the one exclusion in this
        // feature that does not fall out of an existing definition. See
        // ``withdrawAreaSearchForDrawing(_:)``.
        withdrawAreaSearchForDrawing(isDrawing)
        guard legs != trailDraftLegs
            || !Self.isSameDraft(points, as: trailDraftCoordinates) else {
            // Nothing has been committed, so this pass is a finger moving. The
            // whole of what that costs is one pin's coordinate and at most two
            // polylines — see ``applyTrailDraftDrag(_:snapping:on:)``.
            applyTrailDraftDrag(held, snapping: snapping, on: mapView)
            return
        }
        trailDraftLegs = legs
        trailDraftCoordinates = points
        // Whatever was bent is about to be drawn again from the committed
        // geometry, so nothing is held as far as the map is concerned. Cleared
        // before the rebuild rather than after it, or the call at the foot of
        // this method would think it had nothing to do.
        trailDraftDrag = nil

        if !trailDraftOverlays.isEmpty {
            mapView.removeOverlays(trailDraftOverlays)
            trailDraftOverlays = []
            trailDraftLegStyles = [:]
        }
        if !trailDraftAnnotations.isEmpty {
            mapView.removeAnnotations(trailDraftAnnotations)
            trailDraftAnnotations = []
            // One of them may have been the open callout — the same tidy-up
            // ``applyPhotoPins(_:on:)`` does, for the same reason: removing a
            // selected annotation takes its callout without MapKit reliably
            // reporting a deselection.
            refreshOpenCallout(on: mapView)
        }
        // The provisional pin belonged to the drawing as it was. A tap that
        // changed the line has answered the question it was asking, and one
        // left standing would offer *Add Stop* into a leg that has gone.
        if !isDrawing { removeTrailDraftDroppedPin(from: mapView) }
        guard !points.isEmpty else { return }

        addTrailDraftLegs(legs, to: mapView)
        let distances = controller.draft.distancesAlongLine
        let pins = points.enumerated().map { index, coordinate in
            TrailDraftWaypointAnnotation(
                coordinate: coordinate,
                number: index + 1,
                distanceAlongLineMeters: distances.indices.contains(index) ? distances[index] : 0
            )
        }
        trailDraftAnnotations = pins
        mapView.addAnnotations(pins)
        // A drag that is still held across a commit: an answer for another leg
        // can land while a finger is down, and the rebuild above has just
        // drawn that point where the draft still says it is.
        applyTrailDraftDrag(held, snapping: snapping, on: mapView)
    }

    /// Moves one pin and reshapes the one or two legs it is an end of.
    ///
    /// The whole of what a drag costs per frame, and the reason ``TrailDraft``
    /// keeps the moving coordinate off its published properties. A point in
    /// the middle of a trail bends two legs, the first and last points bend
    /// one, and every other leg, every other pin and the entire sheet below
    /// are untouched.
    ///
    /// The bent legs are drawn straight and provisional: straight because the
    /// shape they will take is a question for OpenStreetMap that is not worth
    /// asking sixty times a second, and provisional — the same short dash a
    /// leg waiting for an answer wears — because that is what they are about
    /// to become. With path-following switched off there is no answer coming,
    /// so they are drawn as the settled freehand lines they already are.
    private func applyTrailDraftDrag(
        _ held: TrailWaypointDrag?,
        snapping: Bool,
        on mapView: MKMapView
    ) {
        guard held != trailDraftDrag else { return }
        let released = trailDraftDrag
        trailDraftDrag = held

        if let released, released.index != held?.index,
           trailDraftCoordinates.indices.contains(released.index) {
            movePin(released.index, to: trailDraftCoordinates[released.index])
        }
        if let held {
            movePin(held.index, to: held.clCoordinate)
        }

        var bent: Set<Int> = []
        if let released { bent.formUnion(released.adjacentLegIndices) }
        if let held { bent.formUnion(held.adjacentLegIndices) }
        for legIndex in bent.sorted() {
            reshapeTrailDraftLeg(legIndex, held: held, snapping: snapping, on: mapView)
        }
    }

    /// Puts one pin where it should be, which MapKit answers by moving its
    /// view. Ignores an index the map no longer has — a commit can take the
    /// point away between the drag being released and this running.
    private func movePin(_ index: Int, to coordinate: CLLocationCoordinate2D) {
        guard trailDraftAnnotations.indices.contains(index) else { return }
        trailDraftAnnotations[index].coordinate = coordinate
    }

    /// Redraws one leg, bent to the held point or back to its settled shape.
    ///
    /// A polyline's points cannot be changed once it exists, so this is a
    /// remove and an add — which is what MapKit's own moving overlays cost and
    /// what the recording's tail already pays once per fix.
    private func reshapeTrailDraftLeg(
        _ index: Int,
        held: TrailWaypointDrag?,
        snapping: Bool,
        on mapView: MKMapView
    ) {
        guard trailDraftOverlays.indices.contains(index),
              trailDraftLegs.indices.contains(index) else { return }
        let leg = trailDraftLegs[index]
        let bent = held.map { moving in
            Self.rubberBand(forLegAt: index, held: moving, between: trailDraftCoordinates)
        } ?? []
        let coordinates = bent.isEmpty
            ? leg.coordinates.map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            : bent
        let snap: TrailLegSnap = if bent.isEmpty {
            leg.snap
        } else {
            snapping ? .routing : .freehand
        }

        let previous = trailDraftOverlays[index]
        mapView.removeOverlay(previous)
        trailDraftLegStyles[ObjectIdentifier(previous)] = nil
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        trailDraftOverlays[index] = line
        trailDraftLegStyles[ObjectIdentifier(line)] = snap
        mapView.addOverlay(line, level: .aboveLabels)
    }

    /// The straight line leg `index` takes while `held` is being moved, and
    /// **empty** when that leg is not one of its two.
    ///
    /// Leg *n* runs from point *n* to point *n + 1*, so the held point is
    /// substituted into whichever end it is and the other end stays where the
    /// draft has it.
    private static func rubberBand(
        forLegAt index: Int,
        held: TrailWaypointDrag,
        between points: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard held.adjacentLegIndices.contains(index),
              points.indices.contains(index),
              points.indices.contains(index + 1) else { return [] }
        return [
            held.index == index ? held.clCoordinate : points[index],
            held.index == index + 1 ? held.clCoordinate : points[index + 1],
        ]
    }

    /// One polyline per leg, each remembering the state it should be drawn in.
    ///
    /// Above the shared hikes' lines and the hiker's own, because this is the
    /// one the hiker is working on. All of it is still `.aboveLabels`: the
    /// raster tile overlay is opaque, so anything below that level is buried
    /// rather than faint — see ``MapCommunityRoutes``.
    private func addTrailDraftLegs(_ legs: [TrailLeg], to mapView: MKMapView) {
        for leg in legs {
            // **One polyline per leg, always, and in the same order.** A drag
            // reshapes the two lines either side of a point by index, so a leg
            // that quietly contributed nothing here would shift every line
            // after it onto the wrong leg. A shape that has collapsed to a
            // single coordinate — two waypoints dropped on one spot, or a
            // routed answer deduplicated down to a point — falls back to the
            // straight line between the leg's ends, which is the degenerate
            // line it is rather than no line at all.
            var coordinates = leg.coordinates.map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            if coordinates.count < 2 {
                coordinates = [leg.ends.startCoordinate, leg.ends.endCoordinate]
            }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            trailDraftOverlays.append(line)
            // Kept beside the overlay rather than on a subclass of it, so the
            // draft's lines stay plain `MKPolyline`s and everything that asks
            // MapKit about an overlay keeps one answer. `rendererFor` looks
            // the state up by identity.
            trailDraftLegStyles[ObjectIdentifier(line)] = leg.snap
            mapView.addOverlay(line, level: .aboveLabels)
        }
    }

    /// Whether two sets of pins would draw identically.
    ///
    /// Compared by value rather than by count, because a later phase moves a
    /// point without adding one — and a count comparison would silently stop
    /// redrawing the moment it did.
    private static func isSameDraft(
        _ lhs: [CLLocationCoordinate2D],
        as rhs: [CLLocationCoordinate2D]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.latitude == right.latitude && left.longitude == right.longitude
        }
    }

    /// One leg's renderer, or `nil` when this polyline is not one of the
    /// draft's.
    ///
    /// Asked by `rendererFor` before every style that describes the hiker's
    /// own route, for the reason the community one is: a draft is not a hike
    /// and must not be drawn in the colour and width somebody chose for one.
    func trailDraftRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        guard let snap = trailDraftLegStyles[ObjectIdentifier(polyline)] else { return nil }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor(Color.accentColor)
        #else
        renderer.strokeColor = UIColor(Color.accentColor)
        #endif
        renderer.lineWidth = Self.trailDraftLineWidth
        renderer.lineJoin = .round
        renderer.lineCap = .round
        // `lineDashPattern` is an `[NSNumber]?` and an empty array is not the
        // same as none — it draws nothing — so a solid line is `nil`. The
        // same conversion the recording overlays make; see
        // `MapCoordinator+RouteStyles.swift`.
        let dashes = Self.trailDraftDashes(for: snap)
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = dashes.isEmpty ? nil : dashes.map { NSNumber(value: $0) }
        return renderer
    }

    /// The dash pattern one leg's state is drawn in, and empty for a solid
    /// line. See the file header for what the three weights mean.
    private static func trailDraftDashes(for snap: TrailLegSnap) -> [Int] {
        if snap.isRouting { return trailDraftRoutingDashes }
        if snap.isDegraded { return trailDraftDegradedDashes }
        return []
    }

    /// A numbered dot for one waypoint, or `nil` when this annotation is not
    /// one.
    ///
    /// A plain ``MKAnnotationView`` rather than a marker balloon: a balloon's
    /// point is its tip, and what a hiker is reading here is where the *centre*
    /// of each point sits on the line they drew.
    func trailDraftAnnotationView(
        for annotation: TrailDraftWaypointAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = TrailDraftWaypointAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        // A callout since Phase 4, where it used to be none: every tap on this
        // canvas opens something now, so a pin that swallowed one would be the
        // only thing on the map that does nothing. What it says is which point
        // this is and how far along it sits; what it offers is the one verb a
        // list row cannot reach from here. See `MapTrailDraftCallout.swift`.
        view.canShowCallout = true
        let diameter = Self.trailDraftPinDiameter
        view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)

        #if canImport(UIKit)
        let label = trailDraftNumberLabel(in: view, diameter: diameter)
        label.text = "\(annotation.number)"

        let layer = view.layer
        layer.backgroundColor = UIColor(Color.accentColor).cgColor
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = diameter / 2
        layer.borderWidth = Self.trailDraftPinBorderWidth
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.trailDraftPinShadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        attachTrailDraftWaypointCallout(for: annotation, to: view, on: mapView)
        #endif
        return view
    }

    #if canImport(UIKit)
    /// The label inside a recycled pin, made once and found again afterwards.
    ///
    /// Tagged rather than subclassed: `dequeueReusableAnnotationView` hands
    /// back a view this method already furnished, and adding a second label to
    /// it on every reuse is how a recycled pin ends up drawing two numbers on
    /// top of each other.
    private func trailDraftNumberLabel(in view: MKAnnotationView, diameter: CGFloat) -> UILabel {
        let tag = 1
        if let existing = view.viewWithTag(tag) as? UILabel { return existing }
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        label.tag = tag
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        // Decoration: the number is already in the annotation's title, which
        // is what VoiceOver reads, and a label inside a pin would otherwise
        // announce the digit a second time.
        label.isAccessibilityElement = false
        view.addSubview(label)
        return label
    }
    #endif
}
