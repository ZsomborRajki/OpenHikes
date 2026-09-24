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
//  so the two are readable against each other. The alternatives a leg could
//  take and the time bubbles are drawn beside it — see
//  `MapTrailDraftRouteChoices.swift`.
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
//  ## Nothing is rebuilt wholesale
//
//  A commit is diffed against what is drawn. A leg keeps its polyline for as
//  long as it is the same leg with the same shape and state — matched by the
//  id of the waypoint it arrives at — and a pin is the same annotation for as
//  long as its waypoint exists, with its role, name and distance written onto
//  it in place. So an answer landing replaces one line and touches no pin but
//  the subtitles further along, where it used to take every pin and every line
//  off the map and put them back: nineteen times over for a twenty-stop route.
//  The route choices — the grey alternatives and the time bubbles — are the one
//  layer still redrawn whole, and only when a leg or the travel mode changed,
//  since every bubble is a leg's time.
//
//  A drag is cheaper still. While ``TrailDraft/drag`` is set, one pin's
//  `coordinate` is assigned — MapKit moves its view for free — and the one or
//  two legs that point is an end of are replaced with straight rubber bands.
//  Every other line, every other pin and the whole of the sheet below are
//  untouched. That is what ``MapView/Coordinator/trailDraftOverlays`` being
//  **one polyline per leg, in leg order** is for: the drag reaches its two
//  lines by index, and the diff keeps that order.
//
//  Applied imperatively off ``TrailDraft``, like every other overlay here, so
//  a tap that adds a point moves MapKit and no SwiftUI view.
//

import MapKit
import OpenHikesData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One waypoint, in the shape MapKit wants it, carrying the number it draws.
final class TrailDraftWaypointAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftWaypoint"

    /// The stop this pin draws — what a tap on it opens the place sheet on,
    /// and what a commit matches pins by, so a pin outlives a reorder, a leg
    /// landing and a stop being named, and only a stop that has gone takes its
    /// pin with it.
    let waypointID: UUID

    /// `var` since Phase 3, for the drag: MapKit moves an annotation's view
    /// when this changes, so a point under a finger follows it without the pin
    /// being removed and added again sixty times a second. A committed move is
    /// written here too, by ``update(from:)``.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// What this stop is to the route, so the pin and the row in the sheet say
    /// the same thing about it.
    private(set) var role: TrailStopRole
    /// What it is called, or empty for a stop nothing has named yet — see
    /// ``TrailWaypoint/name``.
    private(set) var name: String
    /// How far along the line this point sits — the figure the list row carries.
    private(set) var distanceAlongLineMeters: Double

    init(
        coordinate: CLLocationCoordinate2D,
        waypointID: UUID,
        role: TrailStopRole,
        name: String,
        distanceAlongLineMeters: Double
    ) {
        self.waypointID = waypointID
        self.coordinate = coordinate
        self.role = role
        self.name = name
        self.distanceAlongLineMeters = distanceAlongLineMeters
        title = Self.title(name: name, role: role)
        subtitle = Self.subtitle(name: name, role: role, along: distanceAlongLineMeters)
    }

    /// The pin's title, and what VoiceOver reaches a waypoint by — a
    /// polyline is not an accessibility element and cannot be made one.
    ///
    /// Stored and `dynamic` rather than computed, because MapKit observes both
    /// keys: a pin whose stop is named rewrites what it says when they change,
    /// which is what lets ``update(from:)`` reach a pin without taking it off
    /// the map.
    @objc private(set) dynamic var title: String?

    /// What it is to the route and how far along it sits — see
    /// ``subtitle(name:role:along:)``.
    @objc private(set) dynamic var subtitle: String?

    /// Brings the pin up to what its waypoint now is, writing only what
    /// changed — each write is a KVO notification MapKit acts on.
    ///
    /// - Returns: whether the role changed, which is the one thing drawn on
    ///   the pin itself — see
    ///   ``MapView/Coordinator/trailDraftPinDigit(for:)``.
    @discardableResult func update(from pin: TrailDraftPinFacts) -> Bool {
        let roleChanged = role != pin.role
        if coordinate.latitude != pin.coordinate.latitude
            || coordinate.longitude != pin.coordinate.longitude {
            coordinate = pin.coordinate
        }
        role = pin.role
        name = pin.name
        distanceAlongLineMeters = pin.distanceAlongLineMeters
        let newTitle = Self.title(name: name, role: role)
        if title != newTitle { title = newTitle }
        let newSubtitle = Self.subtitle(name: name, role: role, along: distanceAlongLineMeters)
        if subtitle != newSubtitle { subtitle = newSubtitle }
        return roleChanged
    }

    /// The same rule ``TrailStopRowView`` draws by, so a hiker reading the pin
    /// and a hiker reading the row are told the same thing: the name when there
    /// is one, and what the stop is to the route when there is not.
    private static func title(name: String, role: TrailStopRole) -> String {
        name.isEmpty ? role.title : name
    }

    /// In the hiker's own units. The role is repeated here only when the
    /// heading is a name, which is the one case where it would otherwise not
    /// be said at all.
    private static func subtitle(name: String, role: TrailStopRole, along meters: Double) -> String {
        let length = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        guard !name.isEmpty else { return length }
        return "\(role.title) · \(length)"
    }
}

/// What one waypoint's pin should say, read off the draft in one pass.
nonisolated struct TrailDraftPinFacts {
    let waypointID: UUID
    let coordinate: CLLocationCoordinate2D
    let role: TrailStopRole
    let name: String
    let distanceAlongLineMeters: Double
}

/// Everything a pin or a time bubble says that a leg does not: the stops with
/// their names, which field a lone stop is in, the pace a straight leg is
/// timed at and the climb a hiking route's time counts. Compared beside the
/// legs, so a stop being named, a mode change on a freehand line or a climb
/// landing redraws what they changed.
nonisolated struct TrailDraftDrawnState: Equatable {
    var waypoints: [TrailWaypoint] = []
    var startIsOpen = false
    var travelMode = TrailTravelMode.hiking
    /// See ``TrailDraft/travelTime(climb:)``.
    var climb: RouteElevationSummary?

    init() { /* nothing drawn */ }

    @MainActor
    init(_ draft: TrailDraft, climb: RouteElevationSummary?) {
        waypoints = draft.waypoints
        startIsOpen = draft.startIsOpen
        travelMode = draft.travelMode
        self.climb = climb
    }
}

extension MapView.Coordinator {
    /// Where the pins currently are, in leg order.
    var trailDraftCoordinates: [CLLocationCoordinate2D] {
        trailDraftDrawn.waypoints.map(\.clCoordinate)
    }

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
            _ = controller.droppedPin
            _ = controller.draft.waypoints
            _ = controller.draft.startIsOpen
            _ = controller.draft.travelMode
            _ = controller.draft.legs
            // The drag's observed half, and the only one: the coordinate under
            // the finger is deliberately untracked, so a point being moved
            // publishes one `Int` per frame and nothing that reads it is a
            // SwiftUI body. See ``TrailDraft``.
            _ = controller.draft.dragRevision
            // The trail's places, in the same registration and for the same
            // reason the line is: they are drawn while the maker is up and not
            // otherwise.
            _ = controller.draft.placeRows
            // And whether they are shown at all — the switch beside *Search
            // This Area*, which hides them without taking them off the trail.
            _ = controller.finder.filter.placesShown
            // The route's time bubble counts the climb once it is measured,
            // which lands on its own schedule, two seconds after the drawing
            // settles — see ``TrailDraftElevation``.
            _ = controller.elevation.summary
        } onChange: { coordinator, map, model in
            coordinator.trackTrailDraft(model, on: map)
        }
    }

    /// Brings the legs, the pins and the route choices on the map up to the
    /// draft, touching only what changed — see the file header.
    ///
    /// Runs when a hiker taps or when a leg's route lands — never at drag or
    /// fix frequency. The guard in front of the diff is what lets a finger
    /// moving cost one pin and two lines. It compares the legs, because a leg
    /// changes shape and state without a point moving, and the rest of what a
    /// pin or a bubble says — see ``TrailDraftDrawnState``.
    private func applyTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        let draft = controller.draft
        let isDrawing = controller.isEditing
        let legs = isDrawing ? draft.legs : []
        let drawn = isDrawing
            ? TrailDraftDrawnState(draft, climb: controller.elevation.summary)
            : TrailDraftDrawnState()
        let held = isDrawing ? draft.drag : nil
        // Before the guard below, deliberately: that one lets a pass through
        // only when the *line* changed, and places and the sheet's pin change
        // without a leg moving. Each has a guard of its own.
        let showsPlaces = isDrawing && controller.finder.filter.placesShown
        applyTrailDraftPlaces(showsPlaces ? draft.placeRows : [], on: mapView)
        applyTrailDraftDroppedPin(isDrawing ? controller.droppedPin : nil, on: mapView)
        // And the strip at the top of the map, which the maker takes from the
        // *Community* tab for as long as it is up — the one exclusion in this
        // feature that does not fall out of an existing definition. See
        // ``withdrawAreaSearchForDrawing(_:)``.
        withdrawAreaSearchForDrawing(isDrawing)
        // And the map's own labels, which a tap may pick only while drawing —
        // see `MapTrailDraftFeatures.swift`.
        refreshTrailDraftFeatureSelection(on: mapView)
        guard legs != trailDraftLegs || drawn != trailDraftDrawn else {
            // Nothing has been committed, so this pass is a finger moving. The
            // whole of what that costs is one pin's coordinate and at most two
            // polylines — see ``applyTrailDraftDrag(_:snapping:on:)``.
            applyTrailDraftDrag(held, snapping: draft.snapsToPaths, on: mapView)
            return
        }
        // Every bubble is a leg's time and every grey line a leg's
        // alternative, so a stop being named — the commonest commit that moves
        // neither — leaves them where they are.
        let routeChoicesChanged = legs != trailDraftLegs
            || drawn.travelMode != trailDraftDrawn.travelMode
            || drawn.climb != trailDraftDrawn.climb
        trailDraftDrawn = drawn
        // Whatever was bent is about to be drawn again from the committed
        // geometry, so nothing is held as far as the map is concerned. Cleared
        // before the diff rather than after it, or the call at the foot of
        // this method would think it had nothing to do.
        trailDraftDrag = nil

        if routeChoicesChanged { removeTrailDraftRouteChoices(from: mapView) }
        syncTrailDraftLegs(legs, on: mapView)
        let distances = draft.distancesAlongLine
        syncTrailDraftPins(
            drawn.waypoints.enumerated().map { index, waypoint in
                TrailDraftPinFacts(
                    waypointID: waypoint.id,
                    coordinate: waypoint.clCoordinate,
                    role: draft.role(ofWaypointAt: index),
                    name: waypoint.name,
                    // Answers for an index the two lists disagree about, which
                    // they can for one observation pass after an edit.
                    distanceAlongLineMeters: distances.indices.contains(index) ? distances[index] : 0
                )
            },
            on: mapView
        )
        // Under the drawn line, which the diff above has kept on the map — see
        // ``addTrailDraftRouteChoices(for:of:climb:to:)``.
        if routeChoicesChanged, !legs.isEmpty {
            addTrailDraftRouteChoices(for: legs, of: draft, climb: drawn.climb, to: mapView)
        }
        // A drag that is still held across a commit: an answer for another leg
        // can land while a finger is down, and the diff above has just put
        // that point back where the draft still says it is.
        applyTrailDraftDrag(held, snapping: draft.snapsToPaths, on: mapView)
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
        // See `MapTrailDraftRouteChoices.swift`: hidden while a point is held,
        // and back as they were when one is let go without a rebuild.
        if held != nil {
            removeTrailDraftRouteChoices(from: mapView)
        } else if let controller = trailDraftController {
            addTrailDraftRouteChoices(
                for: trailDraftLegs,
                of: controller.draft,
                climb: trailDraftDrawn.climb,
                to: mapView
            )
        }

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

    /// Makes the pins on the map the pins in `facts`, in that order, keeping
    /// every pin whose waypoint is still there.
    ///
    /// Matched by waypoint id, so a reorder, a leg landing or a stop being
    /// named updates pins in place and only a stop that has gone is taken off
    /// the map. The one thing drawn on the pin itself — the stop's number — is
    /// redrawn when a role changes, which it does for the old destination
    /// every time a point is appended.
    private func syncTrailDraftPins(_ facts: [TrailDraftPinFacts], on mapView: MKMapView) {
        var existing: [UUID: TrailDraftWaypointAnnotation] = [:]
        for pin in trailDraftAnnotations where existing[pin.waypointID] == nil {
            existing[pin.waypointID] = pin
        }
        var kept: [TrailDraftWaypointAnnotation] = []
        var added: [TrailDraftWaypointAnnotation] = []
        kept.reserveCapacity(facts.count)
        for fact in facts {
            if let pin = existing.removeValue(forKey: fact.waypointID) {
                if pin.update(from: fact) { redrawTrailDraftPinDigit(pin, on: mapView) }
                kept.append(pin)
            } else {
                let pin = TrailDraftWaypointAnnotation(
                    coordinate: fact.coordinate,
                    waypointID: fact.waypointID,
                    role: fact.role,
                    name: fact.name,
                    distanceAlongLineMeters: fact.distanceAlongLineMeters
                )
                kept.append(pin)
                added.append(pin)
            }
        }
        let gone = Array(existing.values)
        trailDraftAnnotations = kept
        if !gone.isEmpty {
            mapView.removeAnnotations(gone)
            // The same tidy-up ``applyPhotoPins(_:on:)`` does, for the same
            // reason: removing a selected annotation takes its callout without
            // MapKit reliably reporting a deselection.
            refreshOpenCallout(on: mapView)
        }
        if !added.isEmpty { mapView.addAnnotations(added) }
    }

    /// Makes the lines on the map one per leg, in leg order, keeping every
    /// line whose leg has not changed.
    ///
    /// A leg is matched by the id of the waypoint it arrives at and kept only
    /// when it is *equal* — same ends, same shape, same state — because a
    /// line's dash is fixed when its renderer is made, and a leg that changed
    /// state needs a new one.
    private func syncTrailDraftLegs(_ legs: [TrailLeg], on mapView: MKMapView) {
        var existing: [UUID: (leg: TrailLeg, line: MKPolyline)] = [:]
        for (leg, line) in zip(trailDraftLegs, trailDraftOverlays) where existing[leg.id] == nil {
            existing[leg.id] = (leg, line)
        }
        var lines: [MKPolyline] = []
        lines.reserveCapacity(legs.count)
        for leg in legs {
            if let drawn = existing[leg.id], drawn.leg == leg {
                existing[leg.id] = nil
                lines.append(drawn.line)
            } else {
                let line = Self.trailDraftLine(for: leg)
                // Kept beside the overlay rather than on a subclass of it, so
                // the draft's lines stay plain `MKPolyline`s and everything
                // that asks MapKit about an overlay keeps one answer.
                // `rendererFor` looks the state up by identity.
                trailDraftLegStyles[ObjectIdentifier(line)] = leg.snap
                mapView.addOverlay(line, level: .aboveLabels)
                lines.append(line)
            }
        }
        let kept = Set(lines.map { ObjectIdentifier($0) })
        let gone = trailDraftOverlays.filter { !kept.contains(ObjectIdentifier($0)) }
        if !gone.isEmpty {
            mapView.removeOverlays(gone)
            for line in gone { trailDraftLegStyles[ObjectIdentifier(line)] = nil }
        }
        trailDraftOverlays = lines
        trailDraftLegs = legs
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

    /// The polyline one leg is drawn as.
    ///
    /// Above the shared hikes' lines and the hiker's own, because this is the
    /// one the hiker is working on — see ``syncTrailDraftLegs(_:on:)``, which
    /// adds it `.aboveLabels`: the raster tile overlay is opaque, so anything
    /// below that level is buried rather than faint. See
    /// ``MapCommunityRoutes``.
    ///
    /// **Always a line.** A drag reshapes the two lines either side of a point
    /// by index, so a leg that quietly contributed nothing here would shift
    /// every line after it onto the wrong leg. A shape that has collapsed to a
    /// single coordinate — two waypoints dropped on one spot, or a routed
    /// answer deduplicated down to a point — falls back to the straight line
    /// between the leg's ends, which is the degenerate line it is rather than
    /// no line at all.
    private static func trailDraftLine(for leg: TrailLeg) -> MKPolyline {
        var coordinates = leg.coordinates.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        if coordinates.count < 2 {
            coordinates = [leg.ends.startCoordinate, leg.ends.endCoordinate]
        }
        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    /// One leg's renderer, or `nil` when this polyline is not one of the
    /// draft's.
    ///
    /// Asked by `rendererFor` before every style that describes the hiker's
    /// own route, for the reason the community one is: a draft is not a hike
    /// and must not be drawn in the colour and width somebody chose for one.
    ///
    /// In the accent colour *as the map shows it* — see
    /// `MapTrailDraftTint.swift`.
    func trailDraftRenderer(for polyline: MKPolyline, on mapView: MKMapView) -> MKPolylineRenderer? {
        guard let snap = trailDraftLegStyles[ObjectIdentifier(polyline)] else { return nil }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor(Color.accentColor)
        #else
        renderer.strokeColor = Self.trailDraftTint(on: mapView)
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
        // No callout: a tap opens the place sheet on this stop instead — see
        // `MapTrailDraftSelection.swift`.
        view.canShowCallout = false
        let diameter = Self.trailDraftPinDiameter
        view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)

        #if canImport(UIKit)
        // **What the row says, not where the point sits in the array.** The
        // list is a start, its numbered stops and a destination, and a pin
        // reading "2" beside a row reading "Stop 1" is the map and the sheet
        // counting two different things in front of one hiker. The two ends
        // carry no digit at all, which is also what Apple Maps draws: they are
        // told apart by being the ends.
        let label = trailDraftNumberLabel(in: view, diameter: diameter)
        label.text = Self.trailDraftPinDigit(for: annotation.role)

        let layer = view.layer
        layer.backgroundColor = Self.trailDraftTint(on: mapView).cgColor
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = diameter / 2
        layer.borderWidth = Self.trailDraftPinBorderWidth
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.trailDraftPinShadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        #endif
        return view
    }

    /// Redraws the number inside a pin that is already on the map, for a stop
    /// whose role changed under it — the destination becoming *Stop 2* when a
    /// point is appended after it. A pin that is not on screen has no view and
    /// is drawn right when MapKit next asks for one.
    private func redrawTrailDraftPinDigit(_ pin: TrailDraftWaypointAnnotation, on mapView: MKMapView) {
        #if canImport(UIKit)
        guard let view = mapView.view(for: pin) else { return }
        trailDraftNumberLabel(in: view, diameter: Self.trailDraftPinDiameter).text =
            Self.trailDraftPinDigit(for: pin.role)
        #endif
    }

    #if canImport(UIKit)
    /// What a pin draws inside itself: a stop's number, and nothing for either
    /// end of the route. See ``TrailStopRole``.
    private static func trailDraftPinDigit(for role: TrailStopRole) -> String {
        switch role {
        case .start, .end: ""
        case .stop(let number): "\(number)"
        }
    }

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
        // Decoration: what this pin is is already in the annotation's title,
        // which is what VoiceOver reads, and a label inside a pin would
        // otherwise announce the digit a second time.
        label.isAccessibilityElement = false
        view.addSubview(label)
        return label
    }
    #endif
}
