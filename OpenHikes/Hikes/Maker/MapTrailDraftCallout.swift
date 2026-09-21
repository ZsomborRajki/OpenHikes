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
    /// **MapKit finishes with a tap about half a second after this app does**,
    /// and one of the things it does then is close whatever callout is open —
    /// including the one this pin has just opened. Measured on a simulator:
    /// the pin is selected at +1 ms and deselected at +500 ms, every time, so
    /// a hiker saw a pin appear and nothing to press. Our recognizer sits
    /// *alongside* MapKit's own by design (see ``installRouteTap(on:)``), and
    /// there is no recognizer of MapKit's to sequence behind — its dismissal
    /// is not one.
    ///
    /// So the first close is treated as the map saying *now I have finished
    /// with that tap*, and the callout is opened again. Once, and only once: a
    /// budget rather than a timer, because a duration long enough to be safe
    /// on a cold simulator is a pin that appears late on a phone. The second
    /// close is the hiker's, and it takes the pin with it.
    var mayReopen = true

    @objc let title: String? = String(localized: "Dropped Pin")

    init(
        coordinate: CLLocationCoordinate2D,
        legIndex: Int?,
        actions: [TrailDraftPinAction]
    ) {
        self.coordinate = coordinate
        self.legIndex = legIndex
        self.actions = actions
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
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        // Asked on the glass, while the tap is still a tap: which leg a thumb
        // aimed at is a question about pixels, and the answer is carried on
        // the pin rather than re-derived when a button is pressed a second
        // later at a camera that may have moved.
        let leg = trailDraftLegIndex(at: point, in: mapView)
        let pin = TrailDraftDroppedPin(
            coordinate: coordinate,
            legIndex: leg,
            actions: TrailDraftPinAction.offered(
                forWaypointCount: controller.draft.waypoints.count
            )
        )
        removeTrailDraftDroppedPin(from: mapView)
        trailDraftDroppedPin = pin
        mapView.addAnnotation(pin)
        // **A turn later, and it has to be.** This runs from a recognizer that
        // deliberately sits *alongside* MapKit's own — see
        // ``installRouteTap(on:)`` — and one of the things MapKit's own tap
        // does is dismiss whatever callout is open. Selecting synchronously
        // puts the callout up and has it taken straight back down inside the
        // same gesture, which reads as a tap that did nothing at all: the
        // pin was there, the buttons were never reachable, and every
        // `TrailMakerUITests` that draws a line failed on the first run of
        // this phase saying so.
        //
        // The guard is what makes the hop safe: a second tap between the two
        // turns has already replaced this pin, and selecting it then would
        // open a callout for a spot the hiker has moved on from.
        DispatchQueue.main.async { [weak self, weak mapView] in
            guard let self, let mapView, trailDraftDroppedPin === pin else { return }
            mapView.selectAnnotation(pin, animated: true)
        }
        return true
        #else
        return false
        #endif
    }

    /// The maker's own annotation views: a waypoint's numbered dot, a marked
    /// place's balloon, and the provisional pin a tap dropped.
    ///
    /// One question rather than three at the delegate's `viewFor`, so the
    /// three kinds this feature puts on the map are recognised in the file
    /// that puts them there — and so `MapCoordinator.swift`, which is at the
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
        #if os(iOS)
        if let dropped = annotation as? TrailDraftDroppedPin {
            return trailDraftDroppedPinView(for: dropped, on: mapView)
        }
        #endif
        return nil
    }

    /// Answers a closed callout: the first close reopens it, and the second
    /// takes the pin away.
    ///
    /// Only its own pin: `didDeselect` fires for every annotation on the map,
    /// and a photo pin closing must not take this one.
    ///
    /// A turn later either way, because it arrives *during* MapKit's own
    /// deselection — reopening or removing inside that callback is a mutation
    /// of the thing being enumerated. The guard is re-asked on the way
    /// through, so a tap that dropped the next pin before this ran finds a
    /// different pin here and leaves it alone.
    ///
    /// See ``TrailDraftDroppedPin/mayReopen`` for why the first close is not
    /// the hiker's.
    func dismissTrailDraftPin(for annotation: (any MKAnnotation)?, on mapView: MKMapView) {
        guard let pin = annotation as? TrailDraftDroppedPin else { return }
        DispatchQueue.main.async { [weak self, weak mapView] in
            guard let self, let mapView, trailDraftDroppedPin === pin else { return }
            guard pin.mayReopen else {
                removeTrailDraftDroppedPin(from: mapView)
                return
            }
            pin.mayReopen = false
            mapView.selectAnnotation(pin, animated: true)
        }
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
    func applyTrailDraftPin(
        _ action: TrailDraftPinAction,
        at coordinate: CLLocationCoordinate2D,
        legIndex: Int?,
        in mapView: MKMapView
    ) {
        guard let controller = trailDraftController else { return }
        removeTrailDraftDroppedPin(from: mapView)
        switch action {
        // Three verbs, one call: *start*, *destination* and *new destination*
        // are the same edit at three lengths of line — a point on the end —
        // and the words differ because what they mean to a hiker does.
        case .startHere, .setAsDestination, .makeDestination:
            controller.appendWaypoint(at: coordinate)
        case .addStop:
            // The leg the thumb was on, or the one the ground says is nearest.
            // An append is the fallback rather than a refusal: a trail with no
            // legs cannot have a stop put into it, and the callout only offers
            // this verb once there are two points — so the `nil` here is the
            // race where a leg went away under an open callout.
            if let leg = legIndex ?? controller.draft.nearestLegIndex(to: coordinate) {
                controller.insertWaypoint(at: coordinate, intoLegAt: leg)
            } else {
                controller.appendWaypoint(at: coordinate)
            }
        case .markAPlace:
            // Marked and then opened for naming, which is one gesture from the
            // hiker's side — see ``TrailDraftController/markPlace(at:named:symbol:)``.
            if let place = controller.markPlace(at: coordinate) {
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
            // By place in the list rather than by identity, because that is
            // what the pin knows: the annotations are rebuilt from the
            // waypoints in order, and the number on the dot is that place plus
            // one. A list that changed under an open callout is the race the
            // controller's own bounds check answers.
            trailDraftController?.removeWaypoints(
                atOffsets: IndexSet(integer: annotation.number - 1)
            )
        }
    }
    #endif
}
