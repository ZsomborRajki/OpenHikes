//
//  TrailPlacesAround.swift
//  OpenHikes
//
//  *Places Around Trail*, as the map sees it: the places found near a saved
//  hike that are not on it yet, *Search This Area*, and the press that puts a
//  place of the hiker's own anywhere on the map.
//
//  The screen that asks — ``HikePlacesAroundView`` — is pushed onto the sheet
//  and the map is a `UIView` beside it, so the two meet in a reference type the
//  map observes directly, the arrangement ``TrailPlacePinController`` already
//  has for a hike's own places. It hangs off that controller rather than off
//  the map's parameter list: the two are the same map layer and the same
//  screens, and the root view that builds the map is at the length the linter
//  allows.
//
//  ## Pale pins beside the hike's own
//
//  A place found but not added is drawn as the kind's own balloon at half
//  strength, as Apple Maps draws a search's results beside the places a hiker
//  has saved: the same glyph, so a spring reads as a spring, and paler, so
//  what is on the trail and what could be are told apart at a glance. A tap on
//  one opens its card on the screen — see ``select(_:)`` — never a callout, for
//  the reason no place pin shows one.
//
//  ## The claim
//
//  The token dance is ``TrailPlacePinController``'s and is not restated: the
//  incoming screen appears before the outgoing one disappears, so a release is
//  checked against the token it was given.
//

import CoreLocation
import MapKit
import Observation
import OpenHikesData
import OpenHikesShared

@MainActor
@Observable
final class TrailPlacesAround {
    /// What the screen does with a tap, a search and a press on the map.
    struct Handlers {
        /// A pale pin was tapped: open that place's card.
        var select: (UUID) -> Void
        /// *Search This Area* was tapped.
        var searchArea: () -> Void
        /// The map was pressed and held at a spot with nothing on it.
        var dropPin: (CLLocationCoordinate2D) -> Void
    }

    /// *Search This Area* for this screen. A finder of its own rather than the
    /// maker's, because the maker's is told what to do with an answer once and
    /// for good, but built on the maker's source and switches — one gate on
    /// Overpass, and one set of kinds, app-wide.
    let finder: TrailPointFinder

    /// Whether the screen is up. Observed by the map: it raises the pill and
    /// lets a press drop a pin.
    private(set) var isActive = false

    /// The found places not on the hike, drawn as pale pins. Observed by the
    /// map, so a search landing redraws MapKit's annotations and no SwiftUI
    /// view.
    private(set) var candidates: [TrailPlaceRow] = []

    @ObservationIgnored private var activeToken: Int?
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var handlers: Handlers?

    init(finder: TrailPointFinder = TrailPointFinder()) {
        self.finder = finder
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Whether this launch can search at all — `false` under tests, which
    /// reach no network, and with every kind switched off.
    var canSearch: Bool { finder.isAvailable && !finder.filter.shown.isEmpty }

    /// Claims the map for a screen, returning the token that withdraws it.
    @discardableResult func attach(_ handlers: Handlers) -> Int {
        nextToken += 1
        activeToken = nextToken
        self.handlers = handlers
        if !isActive { isActive = true }
        return nextToken
    }

    /// Redraws the pale pins of the screen holding the claim.
    func show(_ rows: [TrailPlaceRow], token: Int) {
        guard activeToken == token, rows != candidates else { return }
        candidates = rows
    }

    /// Withdraws the pins, the pill and the press, unless another screen has
    /// already claimed them.
    func detach(token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
        handlers = nil
        finder.clear()
        if !candidates.isEmpty { candidates = [] }
        if isActive { isActive = false }
    }

    /// Opens a pale pin's card. Answers whether it was one of the screen's.
    @discardableResult func select(_ placeID: UUID) -> Bool {
        guard isActive, let handlers, candidates.contains(where: { $0.id == placeID }) else { return false }
        handlers.select(placeID)
        return true
    }

    /// *Search This Area*, from the pill.
    func searchVisibleArea() {
        guard isActive, finder.canSearch else { return }
        handlers?.searchArea()
    }

    /// A press and hold on open map. Answers whether the screen took it.
    @discardableResult func dropPin(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard isActive, let handlers else { return false }
        handlers.dropPin(coordinate)
        return true
    }
}

// MARK: - The map's half

/// What the map holds for *Places Around Trail*, as one stored property of
/// the coordinator — see ``MapView/Coordinator/placesAroundMap``.
struct PlacesAroundMapState {
    /// The pale pins, as the map has drawn them.
    var annotations: [TrailPlaceAnnotation] = []
    /// Guards the observation, as every flag of its kind does: a second
    /// registration can never be cancelled.
    var isObserving = false
    /// Whether the screen has the strip at the top of the map, which the
    /// Community tab's pill gives way to — see
    /// ``MapView/Coordinator/withdrawAreaSearchForPlacesAround(_:)``.
    var isBrowsing = false
    weak var around: TrailPlacesAround?

    #if canImport(UIKit)
    /// *Search This Area*, the third pill in the strip.
    weak var searchControl: MapAreaSearchView?
    #endif
}

extension MapView.Coordinator {
    /// Observes the pale pins and the pill, then re-registers. Idempotent, like
    /// every registration here.
    func observePlacesAround(_ around: TrailPlacesAround, on mapView: MKMapView) {
        guard !placesAroundMap.isObserving else { return }
        placesAroundMap.isObserving = true
        placesAroundMap.around = around
        trackPlacesAround(around, on: mapView, animated: false)
    }

    private func trackPlacesAround(_ around: TrailPlacesAround, on mapView: MKMapView, animated: Bool) {
        applyPlaceCandidates(around.candidates, on: mapView)
        applyPlacesAroundSearchVisibility(animated: animated)
        reobserving(self, mapView, around) {
            _ = around.candidates
            _ = around.isActive
            _ = around.finder.isSearching
            _ = around.finder.searchableArea
            _ = around.finder.notice
            _ = around.finder.filter.hidden
        } onChange: { coordinator, map, model in
            coordinator.trackPlacesAround(model, on: map, animated: true)
        }
    }

    /// Rebuilds the pale pins wholesale, as ``applyPlaceAnnotations`` does the
    /// hike's own: a search lands a few dozen, a few times a visit.
    private func applyPlaceCandidates(_ rows: [TrailPlaceRow], on mapView: MKMapView) {
        let drawn = placesAroundMap.annotations
        guard drawn.count != rows.count
            || !zip(drawn, rows).allSatisfy({ annotation, row in annotation.matches(row, belongsToDraft: false) })
        else { return }
        if !drawn.isEmpty {
            mapView.removeAnnotations(drawn)
            placesAroundMap.annotations = []
        }
        guard !rows.isEmpty else { return }
        let annotations = rows.map { TrailPlaceAnnotation(row: $0, belongsToDraft: false, isCandidate: true) }
        placesAroundMap.annotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// Shows the pill while the screen is up and this launch can search.
    ///
    /// The Community tab's pill is withdrawn while it is, by the rule the
    /// maker's already follows — see ``withdrawAreaSearchForDrawing(_:)`` —
    /// because both would sit in one strip asking OpenStreetMap two different
    /// questions.
    func applyPlacesAroundSearchVisibility(animated: Bool) {
        #if os(iOS)
        guard let control = placesAroundMap.searchControl, let around = placesAroundMap.around else { return }
        let visible = around.isActive && around.canSearch && !hasOpenCallout
        withdrawAreaSearchForPlacesAround(around.isActive)
        control.isSearching = around.finder.isSearching
        control.isEnabled = around.finder.canSearch
        control.notice = visible ? around.finder.notice?.caption : nil
        control.fadeMapControl(visible: visible, restingAlpha: 1, animated: animated) { [weak self] in
            self?.placesAroundMap.around?.isActive != true
        }
        #endif
    }

    /// A tap on a pale pin, which opens that place's card — see
    /// ``selectHikePlaceAnnotation(_:on:)``, which hands it here.
    func selectPlaceCandidateAnnotation(_ place: TrailPlaceAnnotation, on mapView: MKMapView) -> Bool {
        // Deselected at once, as every place pin is: an annotation left
        // selected swallows the next tap on it.
        mapView.deselectAnnotation(place, animated: false)
        if placesAroundMap.around?.select(place.place.id) == true {
            HapticMoment.targetHit.play()
        }
        return true
    }
}

#if os(iOS)
extension MapView {
    /// *Places Around Trail*'s *Search This Area*, in the strip the other two
    /// share — see ``placeInAreaSearchStrip(_:on:alignedTo:)``. Only one of the
    /// three is ever visible.
    func addPlacesAroundSearchControl(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let around = placePins.around
        let control = MapAreaSearchView(
            identifiers: .placesAround,
            onTap: { around.searchVisibleArea() },
            onDismissNotice: { around.finder.dismissNotice() }
        )
        placeInAreaSearchStrip(control, on: mapView, alignedTo: guide)
        coordinator.placesAroundMap.searchControl = control
    }
}
#endif
