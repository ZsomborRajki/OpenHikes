//
//  MapPlacePlacement.swift
//  OpenHikes
//
//  Putting a new place exactly where it is: its pin stands still in the
//  middle of the map, and the hiker moves the map under it.
//
//  *Add Place* opens at a spot read off the walk — the live match, the
//  elevation graph's tracker, a recording's last fix, a press on the map —
//  and a spot read off a walk is where the hiker was, which is not always
//  where the place is: they noticed the viewpoint after they had walked past
//  it. So while ``HikePlaceAdder`` is up, its pin is not an annotation among
//  the others. It is a view of its own, fixed at the middle of the map the
//  sheet leaves — ``MapView/Coordinator/focusPoint(in:)`` — and wherever the
//  map comes to rest under it is where the place goes, the way Apple Maps'
//  *Add a Place* works. Exactly where it points: it is not snapped to the
//  line, because a spring a few metres off the path is off the path (the
//  user's choice, 2026-10-06).
//
//  ## One camera move, then every settle is read
//
//  The map is moved once, when a placeholder first appears, to put its spot
//  under the pin — in to a photograph's span if the map is wider than that,
//  at the hiker's own zoom if it is already closer. The move is made here
//  rather than by whoever opened the form, so it happens in the same pass the
//  pin appears in, and no settle of the map can come in between and be read
//  as the hiker having moved it.
//
//  From then on every settle is read, and the coordinate under the pin goes
//  to ``TrailPlacePinController/movePlaceholder(to:)``, which the form reads
//  at *Add*. A move no finger made — the tracking button's — is read too,
//  because the pin is showing it, and a place that went anywhere other than
//  where its pin stood would be the one thing this must not do. Following the
//  hiker is switched off for the same reason: on a recording, a map that
//  followed every fix would carry the place along the trail with them.
//
//  ## When the middle moves
//
//  The middle of the visible map moves with rotation, and once more when the
//  sheet's middle detent is first measured — which is the next time the sheet
//  is dragged, not the moment it comes to rest. Whenever it is found to have
//  moved, the pin goes to the new middle and the map moves with it, so the
//  place stays under the pin. That is checked on every settle, every redraw
//  of the placeholder and every report from the sheet, because a pin moved
//  on its own would point at ground the place is not being added at, and a
//  middle found moved only at the next settle would undo that settle's pan.
//

import MapKit
import OpenHikesData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the map holds of a placement, as one stored property of the
/// coordinator — see ``MapView/Coordinator/placePlacement``.
struct PlacePlacementState {
    /// The placeholder the camera was moved for, so a redraw of the same one
    /// — its kind changing — does not move it again.
    var placeholderID: UUID?
    /// Where the pin stood at the last read — see *When the middle moves*.
    var focus: CGPoint?

    #if canImport(UIKit)
    weak var pin: PlacePlacementPinView?
    #endif
}

extension MapView.Coordinator {
    /// How far the middle of the map may move between two reads before it
    /// counts as having moved. Under a point is the sheet's measured rest
    /// wobbling, and a fraction of a metre at any zoom a place is put at.
    private static let placementFocusTolerance: CGFloat = 1

    /// Stands the pin for the controller's placeholder, moving the map to put
    /// its spot under it the first time, or takes it down. Called whenever a
    /// saved hike's places are redrawn — which a kind picked in the form is.
    func applyPlacePlacement(_ controller: TrailPlacePinController, on mapView: MKMapView) {
        #if canImport(UIKit)
        guard let spot = Self.heldSpot(of: controller) else {
            placePlacement.pin?.removeFromSuperview()
            placePlacement = PlacePlacementState()
            return
        }
        let pin = placePlacement.pin ?? addPlacementPin(to: mapView)
        if let row = controller.rows.first(where: { $0.id == spot.id }) {
            pin.show(row.place)
        }
        guard placePlacement.placeholderID != spot.id else {
            keepPlacementUnderPin(spot, on: mapView)
            return
        }
        let focus = focusPoint(in: mapView)
        pin.stand(at: focus)
        placePlacement.placeholderID = spot.id
        placePlacement.focus = focus
        if mapView.userTrackingMode != .none {
            mapView.setUserTrackingMode(.none, animated: false)
        }
        bringUnderPin(spot.coordinate, on: mapView, animated: true)
        #endif
    }

    /// Reads where the map came to rest under the pin. Called from
    /// `regionDidChangeAnimated`.
    func placePlacementRegionDidSettle(on mapView: MKMapView) {
        #if canImport(UIKit)
        guard let pin = placePlacement.pin, let controller = hikePlaceController,
              let spot = Self.heldSpot(of: controller), spot.id == placePlacement.placeholderID
        else { return }
        pin.lower()
        guard !keepPlacementUnderPin(spot, on: mapView) else { return }
        controller.movePlaceholder(to: mapView.convert(focusPoint(in: mapView), toCoordinateFrom: mapView))
        #endif
    }

    /// Keeps the place under the pin when the sheet's measured rest moves the
    /// middle of the map. Called on every report from the sheet.
    func placePlacementSheetDidMove(on mapView: MKMapView) {
        #if canImport(UIKit)
        guard placePlacement.placeholderID != nil, let controller = hikePlaceController,
              let spot = Self.heldSpot(of: controller), spot.id == placePlacement.placeholderID
        else { return }
        keepPlacementUnderPin(spot, on: mapView)
        #endif
    }

    /// Stands the pin on the middle of the map and moves the map to keep
    /// `spot` under it, if the middle has moved since the pin was stood —
    /// see *When the middle moves*. Returns whether it had.
    @discardableResult private func keepPlacementUnderPin(_ spot: HikePlaceSpot, on mapView: MKMapView) -> Bool {
        let focus = focusPoint(in: mapView)
        guard let held = placePlacement.focus,
              hypot(held.x - focus.x, held.y - focus.y) > Self.placementFocusTolerance
        else { return false }
        placePlacement.focus = focus
        #if canImport(UIKit)
        placePlacement.pin?.stand(at: focus)
        #endif
        bringUnderPin(spot.coordinate, on: mapView, animated: false)
        return true
    }

    /// Lifts the pin off the map while the map moves under it. The only use
    /// of this callback, so it lives here rather than beside its settle in
    /// `MapCoordinator.swift`.
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        #if canImport(UIKit)
        placePlacement.pin?.lift()
        #endif
    }

    /// The placeholder's spot as it stands now: where the map last left it,
    /// or where the form opened it.
    private static func heldSpot(of controller: TrailPlacePinController) -> HikePlaceSpot? {
        guard let id = controller.placeholderID,
              let row = controller.rows.first(where: { $0.id == id })
        else { return nil }
        return controller.placement(of: HikePlaceSpot(row.place.clCoordinate, id: id))
    }

    /// Moves the map so `coordinate` is under the pin: through the focus area
    /// at a photograph's span when the map shows more than that, otherwise by
    /// sliding it there at the zoom the hiker chose.
    private func bringUnderPin(_ coordinate: CLLocationCoordinate2D, on mapView: MKMapView, animated: Bool) {
        let span = MapController.photoSpotSpanMeters
        let shownMeters = mapView.visibleMapRect.width / MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        guard shownMeters <= span else {
            show(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span),
                on: mapView,
                animated: animated
            )
            return
        }
        // Measured on the map as it is drawn, rather than in map points, so a
        // map the hiker has turned slides the right way.
        let point = mapView.convert(coordinate, toPointTo: mapView)
        let focus = focusPoint(in: mapView)
        let centre = CGPoint(
            x: mapView.bounds.midX + point.x - focus.x,
            y: mapView.bounds.midY + point.y - focus.y
        )
        mapView.setCenter(mapView.convert(centre, toCoordinateFrom: mapView), animated: animated)
    }

    #if canImport(UIKit)
    private func addPlacementPin(to mapView: MKMapView) -> PlacePlacementPinView {
        let pin = PlacePlacementPinView()
        mapView.addSubview(pin)
        placePlacement.pin = pin
        return pin
    }
    #endif
}

#if canImport(UIKit)
/// The pin a new place is put down with: its kind's glyph on its kind's
/// colour, held up on a stem over a dot that is the exact spot.
///
/// Not a marker annotation view: those are drawn by MapKit, at a coordinate,
/// and this one stays at a point on the screen while the coordinates move
/// under it. The dot is what the place is put at; the balloon lifts while the
/// map moves and comes down on it when the map stops, so what is being
/// pointed at is never hidden under a thumb-sized badge.
final class PlacePlacementPinView: UIView {
    private static let badgeSize: CGFloat = 36
    private static let glyphSize: CGFloat = 16
    private static let borderWidth: CGFloat = 2
    private static let stemWidth: CGFloat = 3
    private static let stemLength: CGFloat = 14
    private static let dotSize: CGFloat = 8
    private static let liftHeight: CGFloat = 10
    private static let liftDuration: TimeInterval = 0.15
    private static let shadowOpacity: Float = 0.3
    private static let shadowRadius: CGFloat = 3
    private static let shadowOffset = CGSize(width: 0, height: 2)

    private let badge = UIView()
    private let glyph = UIImageView()
    private let stem = UIView()
    private let dot = UIView()
    /// What the badge was last drawn as, so a redraw of the same place sets
    /// nothing.
    private var shownSymbol: TrailPlaceSymbol??

    init() {
        let height = Self.badgeSize + Self.stemLength + Self.dotSize
        super.init(frame: CGRect(x: 0, y: 0, width: Self.badgeSize, height: height))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "hike-place-placeholder"
        accessibilityLabel = String(localized: "New place")
        accessibilityTraits = .image

        dot.frame = CGRect(
            x: (Self.badgeSize - Self.dotSize) / 2,
            y: height - Self.dotSize,
            width: Self.dotSize,
            height: Self.dotSize
        )
        dot.layer.cornerRadius = Self.dotSize / 2
        dot.backgroundColor = .black.withAlphaComponent(CGFloat(Self.shadowOpacity))
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 1

        // From the badge's middle down to the dot's, so the badge can rise
        // off it without leaving a gap.
        stem.frame = CGRect(
            x: (Self.badgeSize - Self.stemWidth) / 2,
            y: Self.badgeSize / 2,
            width: Self.stemWidth,
            height: height - Self.dotSize / 2 - Self.badgeSize / 2
        )
        stem.layer.cornerRadius = Self.stemWidth / 2

        badge.frame = CGRect(x: 0, y: 0, width: Self.badgeSize, height: Self.badgeSize)
        badge.layer.cornerRadius = Self.badgeSize / 2
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.borderWidth = Self.borderWidth
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = Self.shadowOpacity
        badge.layer.shadowRadius = Self.shadowRadius
        badge.layer.shadowOffset = Self.shadowOffset

        glyph.frame = badge.bounds.insetBy(
            dx: (Self.badgeSize - Self.glyphSize) / 2,
            dy: (Self.badgeSize - Self.glyphSize) / 2
        )
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = .white
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: Self.glyphSize, weight: .semibold)
        badge.addSubview(glyph)

        addSubview(dot)
        addSubview(stem)
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlacePlacementPinView is created in code only")
    }

    /// Draws the badge as `place`'s kind — the glyph and colour its pin will
    /// have once it is added.
    func show(_ place: TrailPlace) {
        guard shownSymbol != .some(place.symbol) else { return }
        shownSymbol = .some(place.symbol)
        let tint = UIColor(place.tint)
        badge.backgroundColor = tint
        stem.backgroundColor = tint
        glyph.image = UIImage(systemName: place.systemImageName)
    }

    /// Puts the dot on `point`, in the map's own points.
    func stand(at point: CGPoint) {
        center = CGPoint(x: point.x, y: point.y - bounds.height / 2 + Self.dotSize / 2)
    }

    /// Raises the balloon off its dot while the map moves.
    func lift() {
        setLifted(true)
    }

    /// Brings the balloon back down onto its dot.
    func lower() {
        setLifted(false)
    }

    private func setLifted(_ lifted: Bool) {
        let transform = lifted ? CGAffineTransform(translationX: 0, y: -Self.liftHeight) : .identity
        guard badge.transform != transform else { return }
        UIView.animate(withDuration: Self.liftDuration, delay: 0, options: [.beginFromCurrentState]) {
            self.badge.transform = transform
        }
    }
}
#endif
