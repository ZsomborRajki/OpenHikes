//
//  MapTrailDraftCallout.swift
//  OpenHikes
//
//  The pin a tap drops, and the buttons inside its callout.
//
//  A tap on the canvas no longer draws anything — see ``TrailDraftPinAction``
//  for why. It drops *this*, MapKit opens the callout MapKit already knows how
//  to draw, and the drawing changes when one of the buttons in it is pressed.
//
//  ## Built out of MapKit's own pieces
//
//  The same argument ``MapPhotoAnnotations`` makes: `MKMarkerAnnotationView`
//  already draws the balloon, the drop, the shadow and the selection, and its
//  callout already draws the rounded card, the arrow and the dismissal. What
//  is app-specific is a stack of buttons, and that is exactly what
//  ``MKAnnotationView/detailCalloutAccessoryView`` is for. The buttons carry
//  their own actions rather than going through
//  `calloutAccessoryControlTapped(_:)`, which MapKit documents only for the
//  left and right slots.
//
//  ## There is at most one, and it belongs to the map rather than the draft
//
//  A dropped pin is not part of the trail — nothing is, until a button is
//  pressed — so it is deliberately not in ``TrailDraft``. It is a thing on the
//  map that the map puts away: the next tap replaces it, taking an action
//  spends it, dismissing the callout removes it, and closing the maker takes
//  it with everything else. Keeping it in the draft would mean writing a
//  provisional pin to disk and restoring it a launch later, which is a promise
//  about a tap nobody made.
//
//  ## The waypoints answer a tap now too
//
//  Phase 3's pins showed no callout and claimed no tap, because a tap that
//  disappeared inside a 24-point dot was worse than one that drew. Now every
//  tap opens something, so a waypoint's own callout is the honest answer:
//  which point it is, how far along it sits, and the one verb a point has that
//  a list row cannot reach from the map. That is what took the carve-out out
//  of ``MapView/Coordinator/isTapClaimed(at:in:)``.
//

import MapKit
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The provisional pin a tap leaves behind, and what the tap knew about where
/// it landed.
final class TrailDraftDroppedPin: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftDroppedPin"

    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// Which leg the tap landed on, or `nil` for a tap on open map.
    ///
    /// Carried from the tap rather than re-derived when a button is pressed,
    /// and that is the difference between *the leg you aimed at* and *the leg
    /// that happens to be nearest now*: the two differ where a trail doubles
    /// back, and the hiker aimed at pixels. A tap on open map has nothing to
    /// carry, and ``TrailDraft/nearestLegIndex(to:)`` answers for it.
    let legIndex: Int?
    /// What the callout offers, decided when the pin was dropped.
    let actions: [TrailDraftPinAction]
    /// Whether this pin's callout may be opened again after the map closes it.
    ///
    /// **MapKit finishes with a tap after this app's own recognizer does**, and
    /// one of the things it does then is close whatever callout is open —
    /// including the one this pin has just opened. It is measured rather than
    /// assumed, twice: at **+500 ms** when the route tap fired on the first
    /// touch, and at **+150 ms** now that the tap is sequenced behind MapKit's
    /// own double tap (see
    /// ``MapView/Coordinator/gestureRecognizer(_:shouldRequireFailureOf:)``).
    /// It did not go away, because the recognizer that does it is not on the
    /// map view at all — `mapView.gestureRecognizers` holds only this app's
    /// own two, at install time and at tap time both — so there is nothing left
    /// to sequence behind.
    ///
    /// So the first close is still treated as the map saying *now I have
    /// finished with that tap*, and the callout is opened again. Once, and only
    /// once: a budget rather than a timer, because a duration long enough to be
    /// safe on a cold simulator is a callout that opens late on a phone. The
    /// second close is the hiker's, and it takes the pin with it.
    ///
    /// What changed is that the hiker no longer *sees* it — see
    /// ``MapView/Coordinator/dismissTrailDraftPin(for:on:)``.
    var mayReopen = true

    /// What the place is called, for a pin dropped on one of the map's own
    /// labels — a summit, a car park, a hut — or empty for a tap on open map.
    ///
    /// Carried to whichever verb is pressed, so the stop arrives named the way
    /// the label read rather than as an address worked out a second later.
    /// See `MapTrailDraftFeatures.swift`.
    let placeName: String

    /// The place's name, or *Dropped Pin* for a spot that has none — Apple
    /// Maps' own heading for both.
    @objc let title: String?

    /// Nothing under the heading — the buttons are what this callout carries
    /// — but **declared rather than left out**.
    ///
    /// `subtitle` is an optional requirement of `MKAnnotation` to Swift and a
    /// plain key to Objective-C, and MapKit reads it by key when it lays out a
    /// marker's label: a class that does not answer to it at all takes the
    /// process down with `valueForUndefinedKey:`. It is reached with a second
    /// pin on the map, which is what makes it a crash a tap on an empty canvas
    /// never finds. Every other annotation in this app declares both keys, and
    /// `MapAnnotationKeyCodingTests` holds all of them to it.
    @objc let subtitle: String? = nil

    init(
        coordinate: CLLocationCoordinate2D,
        legIndex: Int?,
        actions: [TrailDraftPinAction],
        placeName: String = ""
    ) {
        self.coordinate = coordinate
        self.legIndex = legIndex
        self.actions = actions
        self.placeName = placeName
        title = placeName.isEmpty ? String(localized: "Dropped Pin") : placeName
    }
}

#if os(iOS)
/// The buttons inside a dropped pin's callout.
///
/// A `UIStackView` of rows rather than three buttons side by side: the route
/// verbs are a choice between each other and *Mark a Place* is not one of
/// them, so they are on separate lines — the split ``TrailDraftPinAction``
/// draws with ``TrailDraftPinAction/changesTheLine``, made visible.
final class TrailDraftCalloutActions: UIStackView {
    /// Wide enough for two route verbs side by side at the default text size,
    /// and narrow enough that MapKit's callout does not have to stretch beyond
    /// a phone's width. The same kind of number ``PhotoCalloutMetrics`` holds
    /// and for the same reason.
    private static let width: CGFloat = 244
    private static let rowSpacing: CGFloat = 6

    private var handler: ((TrailDraftPinAction) -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Self.rowSpacing
        alignment = .fill
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("A trail draft callout is created in code only")
    }

    /// Fills the stack with `actions`, replacing whatever a recycled view was
    /// showing.
    ///
    /// Rebuilt rather than reconfigured, because the *number* of buttons
    /// changes with the trail: a pin dropped on an empty map offers two and
    /// one dropped on a drawn line offers three, and a recycled view that kept
    /// the wrong count would offer a verb the draft cannot honour.
    func show(_ actions: [TrailDraftPinAction], perform: @escaping (TrailDraftPinAction) -> Void) {
        handler = perform
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in Self.rows(of: actions) {
            addArrangedSubview(Self.row(of: row.map(button(for:))))
        }
    }

    /// The route verbs on one line, and everything else on its own.
    private static func rows(of actions: [TrailDraftPinAction]) -> [[TrailDraftPinAction]] {
        let route = actions.filter(\.changesTheLine)
        let rest = actions.filter { !$0.changesTheLine }
        return ([route] + rest.map { [$0] }).filter { !$0.isEmpty }
    }

    private static func row(of buttons: [UIButton]) -> UIView {
        guard buttons.count > 1 else { return buttons[0] }
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.spacing = rowSpacing
        stack.distribution = .fillEqually
        return stack
    }

    private func button(for action: TrailDraftPinAction) -> UIButton {
        var configuration: UIButton.Configuration = action.changesTheLine
            ? .borderedProminent()
            : .bordered()
        configuration.title = action.title
        configuration.image = UIImage(systemName: action.systemImageName)
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        // The title is what a hiker reads and what a narrow callout has to fit,
        // so it wraps rather than being cut: "Set as Destination" is two lines
        // at an accessibility text size and no words at all when truncated.
        configuration.titleLineBreakMode = .byWordWrapping
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.addAction(
            UIAction { [weak self] _ in self?.handler?(action) },
            for: .touchUpInside
        )
        return button
    }
}

/// The one verb a waypoint's callout carries.
///
/// Its own small view for the reason above: a callout accessory is a view this
/// code owns, and an identifier on one survives into the automation.
final class TrailDraftWaypointCalloutActions: UIStackView {
    static let removeIdentifier = "trail-draft-point-remove"

    private var handler: (() -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        translatesAutoresizingMaskIntoConstraints = false
        var configuration: UIButton.Configuration = .bordered()
        configuration.title = String(localized: "Remove Point")
        configuration.image = UIImage(systemName: "trash")
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        configuration.baseForegroundColor = .systemRed
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = Self.removeIdentifier
        button.addAction(
            UIAction { [weak self] _ in self?.handler?() },
            for: .touchUpInside
        )
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("A trail draft callout is created in code only")
    }

    func onRemove(_ perform: @escaping () -> Void) {
        handler = perform
    }
}
#endif

// MARK: - Dropping one

extension MapView.Coordinator {
    /// Puts a provisional pin where a tap landed and opens its callout.
    ///
    /// - Returns: whether the tap was spent here, which is what tells the
    ///   handler to stop asking what else it could have meant.
    ///
    /// Replaces whatever pin was already down, so there is never more than one
    /// and a hiker exploring the map leaves no trail of discarded markers.
    ///
    /// A tap that landed on something over the map is not a drop — the
    /// tracking button, the credit line and the maker's own pill all sit on
    /// the canvas — and neither is a tap on an annotation, which now includes
    /// the draft's own pins and this one. See
    /// ``MapView/Coordinator/isTapClaimed(at:in:)``.
    @discardableResult func dropTrailDraftPin(at point: CGPoint, in mapView: MKMapView) -> Bool {
        #if os(iOS)
        guard let controller = trailDraftController, controller.isEditing else { return false }
        guard !isTapClaimed(at: point, in: mapView) else { return false }
        showTrailDraftPin(
            at: mapView.convert(point, toCoordinateFrom: mapView),
            // Asked on the glass, while the tap is still a tap: which leg a
            // thumb aimed at is a question about pixels, and the answer is
            // carried on the pin rather than re-derived when a button is
            // pressed a second later at a camera that may have moved.
            legIndex: trailDraftLegIndex(at: point, in: mapView),
            named: "",
            offering: controller,
            in: mapView
        )
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// Puts the provisional pin down at a coordinate and opens its callout —
    /// the half a tap on open map and a tap on one of the map's own labels
    /// share. See `MapTrailDraftFeatures.swift` for the second.
    func showTrailDraftPin(
        at coordinate: CLLocationCoordinate2D,
        legIndex leg: Int?,
        named placeName: String,
        offering controller: TrailDraftController,
        in mapView: MKMapView
    ) {
        let pin = TrailDraftDroppedPin(
            coordinate: coordinate,
            legIndex: leg,
            actions: TrailDraftPinAction.offered(
                forWaypointCount: controller.draft.waypoints.count
            ),
            placeName: placeName
        )
        removeTrailDraftDroppedPin(from: mapView)
        trailDraftDroppedPin = pin
        mapView.addAnnotation(pin)
        // **A turn later, and it still has to be.** MapKit's own single tap
        // dismisses whatever callout is open, and this recognizer now fires in
        // the same cycle as it — sequenced behind the double tap they were
        // always both waiting on. Which of the two runs first inside that cycle
        // is not ours to decide, so the selection is put on the far side of it:
        // selecting synchronously would risk putting the callout up and having
        // it taken straight back down inside one gesture, which reads as a tap
        // that did nothing at all.
        //
        // The guard is what makes the hop safe: a second tap between the two
        // turns has already replaced this pin, and selecting it then would
        // open a callout for a spot the hiker has moved on from.
        DispatchQueue.main.async { [weak self, weak mapView] in
            guard let self, let mapView, trailDraftDroppedPin === pin else { return }
            mapView.selectAnnotation(pin, animated: true)
        }
    }
    #endif

    /// The maker's own annotation views: a waypoint's numbered dot, a marked
    /// place's balloon, the grey balloon of a place OpenStreetMap offered, and
    /// the provisional pin a tap dropped.
    ///
    /// One question rather than four at the delegate's `viewFor`, so the kinds
    /// this feature puts on the map are recognised in the file that puts them
    /// there — and so `MapCoordinator.swift`, which is at the
    /// length the linter allows, does not grow a branch per phase.
    func makerAnnotationView(
        for annotation: any MKAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView? {
        if let waypoint = annotation as? TrailDraftWaypointAnnotation {
            return trailDraftAnnotationView(for: waypoint, on: mapView)
        }
        if let place = annotation as? TrailPlaceAnnotation {
            return trailPlaceAnnotationView(for: place, on: mapView)
        }
        if let candidate = annotation as? TrailPointCandidateAnnotation {
            return trailPointCandidateView(for: candidate, on: mapView)
        }
        #if os(iOS)
        if let dropped = annotation as? TrailDraftDroppedPin {
            return trailDraftDroppedPinView(for: dropped, on: mapView)
        }
        #endif
        return nil
    }

    /// Answers a closed callout: the map's own close reopens it, and the
    /// hiker's takes the pin away.
    ///
    /// **The reopen is synchronous and unanimated, and that is the whole of
    /// what the hiker stopped seeing.** It used to hop a turn and animate, so
    /// MapKit's close and this reopen were two separate frames with an
    /// animation each — the callout opened, closed and opened again in front of
    /// somebody who had tapped once. Reopening inside the same callback means
    /// no frame is ever drawn with the callout down, so there is nothing to
    /// see; `animated: false` is what keeps it that way, since an animated
    /// reopen would fade in from nothing however early it started. The budget
    /// on ``TrailDraftDroppedPin/mayReopen`` is what makes the synchronous call
    /// safe from recursion: the second close finds it spent.
    ///
    /// The *removal* still hops a turn, because that one really is a mutation
    /// of what MapKit is enumerating — a selection change is a selection
    /// change, and taking the annotation out from under it is not. The guard is
    /// re-asked on the way through, so a tap that dropped the next pin before
    /// this ran finds a different pin here and leaves it alone.
    ///
    /// Only its own pin: `didDeselect` fires for every annotation on the map,
    /// and a photo pin closing must not take this one.
    func dismissTrailDraftPin(for annotation: (any MKAnnotation)?, on mapView: MKMapView) {
        guard let pin = annotation as? TrailDraftDroppedPin,
              trailDraftDroppedPin === pin else { return }
        guard pin.mayReopen else {
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView, trailDraftDroppedPin === pin else { return }
                removeTrailDraftDroppedPin(from: mapView)
            }
            return
        }
        pin.mayReopen = false
        mapView.selectAnnotation(pin, animated: false)
    }

    /// Takes the provisional pin off the map, if there is one.
    ///
    /// Called from four places and they are all the ways one ends: the next
    /// tap, a button in its own callout, the callout being dismissed, and the
    /// maker closing. Deselected before it is removed, so the callout goes
    /// with it rather than being left to MapKit to tidy up.
    func removeTrailDraftDroppedPin(from mapView: MKMapView) {
        guard let pin = trailDraftDroppedPin else { return }
        trailDraftDroppedPin = nil
        mapView.deselectAnnotation(pin, animated: false)
        mapView.removeAnnotation(pin)
    }

    /// Acts on a button in a dropped pin's callout.
    ///
    /// The pin goes first, and always: every one of these verbs either changes
    /// the drawing or opens a sheet over it, and a provisional marker left
    /// standing over the point it has just become is two pins on one spot.
    ///
    /// Split from the button's own closure for the reason
    /// ``addTrailDraftWaypoint(at:in:)`` was split from its recognizer: this
    /// is the half worth asserting on, and a `UIButton` inside a callout
    /// inside an `MKAnnotationView` is not something a suite can press.
    ///
    /// - Parameter name: what the place under the pin is called, for a pin
    ///   dropped on one of the map's own labels; empty for open map, which
    ///   ``TrailStopNamer`` describes afterwards.
    func applyTrailDraftPin(
        _ action: TrailDraftPinAction,
        at coordinate: CLLocationCoordinate2D,
        legIndex: Int?,
        named name: String,
        in mapView: MKMapView
    ) {
        guard let controller = trailDraftController else { return }
        removeTrailDraftDroppedPin(from: mapView)
        switch action {
        // Three verbs, one call: *start*, *destination* and *new destination*
        // are the same edit at three lengths of line — a point on the end —
        // and the words differ because what they mean to a hiker does.
        case .startHere, .setAsDestination, .makeDestination:
            controller.appendWaypoint(at: coordinate, named: name)
        case .addStop:
            // The leg the thumb was on, or the one the ground says is nearest.
            // An append is the fallback rather than a refusal: a trail with no
            // legs cannot have a stop put into it, and the callout only offers
            // this verb once there are two points — so the `nil` here is the
            // race where a leg went away under an open callout.
            if let leg = legIndex ?? controller.draft.nearestLegIndex(to: coordinate) {
                controller.insertWaypoint(at: coordinate, intoLegAt: leg, named: name)
            } else {
                controller.appendWaypoint(at: coordinate, named: name)
            }
        case .markAPlace:
            // Marked and then opened for naming, which is one gesture from the
            // hiker's side — see ``TrailDraftController/markPlace(at:named:symbol:)``.
            if let place = controller.markPlace(at: coordinate, named: name) {
                controller.requestPlaceEditor(for: place.id)
            }
        }
        HapticMoment.targetHit.play()
    }

    #if os(iOS)
    /// A marker with a callout of buttons, for the pin a tap left behind.
    ///
    /// `MKMarkerAnnotationView` rather than the plain dot the waypoints use,
    /// and the difference is the point: a waypoint is part of a line the hiker
    /// is reading, and this is a question standing over the map waiting to be
    /// answered.
    func trailDraftDroppedPinView(
        for annotation: TrailDraftDroppedPin,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = TrailDraftDroppedPin.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.canShowCallout = true
        view.markerTintColor = UIColor(Color.accentColor)
        view.glyphImage = UIImage(systemName: "mappin")
        // A pin the hiker put there on purpose, a moment ago. Letting MapKit
        // declutter it away would be the map answering a tap with nothing.
        view.displayPriority = .required
        view.accessibilityIdentifier = "trail-draft-dropped-pin"
        let actions = view.detailCalloutAccessoryView as? TrailDraftCalloutActions
            ?? TrailDraftCalloutActions()
        view.detailCalloutAccessoryView = actions
        actions.show(annotation.actions) { [weak self, weak mapView] action in
            guard let mapView else { return }
            self?.applyTrailDraftPin(
                action,
                at: annotation.coordinate,
                legIndex: annotation.legIndex,
                named: annotation.placeName,
                in: mapView
            )
        }
        return view
    }

    /// Attaches *Remove Point* to a waypoint's callout.
    ///
    /// Reached from ``trailDraftAnnotationView(for:on:)``, which builds the
    /// numbered dot itself — see `MapTrailDraftOverlay.swift`.
    func attachTrailDraftWaypointCallout(
        for annotation: TrailDraftWaypointAnnotation,
        to view: MKAnnotationView,
        on mapView: MKMapView
    ) {
        let actions = view.detailCalloutAccessoryView as? TrailDraftWaypointCalloutActions
            ?? TrailDraftWaypointCalloutActions()
        view.detailCalloutAccessoryView = actions
        actions.onRemove { [weak self, weak mapView] in
            guard let self, let mapView else { return }
            mapView.deselectAnnotation(annotation, animated: true)
            // By place in the list, read when the button is pressed: every
            // commit writes each pin's number back as its place plus one, so
            // a pin that has survived a reorder still names the right row. A list that changed under an open callout is the race the
            // controller's own bounds check answers.
            trailDraftController?.removeWaypoints(
                atOffsets: IndexSet(integer: annotation.number - 1)
            )
        }
    }
    #endif
}
