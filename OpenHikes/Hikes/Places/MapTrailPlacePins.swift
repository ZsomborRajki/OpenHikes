//
//  MapTrailPlacePins.swift
//  OpenHikes
//
//  Putting the places on the map, from whichever of the two sources is live.
//
//  While a trail is being drawn they come off ``TrailDraft/placeRows`` through
//  the maker's own observation — see `MapTrailDraftOverlay.swift` — and they
//  can be edited, dragged and removed. While a saved hike's screen is pushed
//  they come off its ``TrailPoint`` rows through ``TrailPlacePinController``
//  and can only be read.
//
//  **The two are never on screen together**, and nothing here enforces it —
//  the same arrangement the camera pill and the maker's pill fall out of. The
//  maker and a hike's detail are two different pushed screens, and the
//  controller below withdraws its pins whenever its own screen is not up,
//  exactly as ``PhotoMapPinController`` does. They are still two arrays,
//  because one array written by two observers is how a pin belonging to a
//  screen that has gone survives on the map.
//
//  The claim/withdraw dance, the token, and why it is a token at all are all
//  ``PhotoMapPinController``'s and are not restated: SwiftUI presents the
//  incoming screen before it tears the outgoing one down, so a release checked
//  against anything else cancels the screen that has already replaced it.
//

import MapKit
import Observation
import SwiftUI

/// The places of the hike whose screen is up, and the claim a screen holds
/// them by.
///
/// A reference type for the reason ``PhotoMapPinController`` is one: the pins
/// are drawn by MapKit, the hike is on a screen inside the sheet, and the map
/// observes this object directly rather than being handed a list through a
/// SwiftUI body.
///
/// Read-only, deliberately: there is no `open` here and no selection request,
/// because a place's callout says everything a place has to say. That is what
/// makes this the small half of the type it is modelled on.
@MainActor
@Observable
final class TrailPlacePinController {
    /// Observed directly by ``MapView/Coordinator``, so a hike's places
    /// arriving from CloudKit redraws MapKit's annotations and no SwiftUI
    /// view.
    private(set) var rows: [TrailPlaceRow] = []

    @ObservationIgnored private var activeToken: Int?
    @ObservationIgnored private var nextToken = 0
    /// What the claiming screen last published, kept apart from ``rows`` so a
    /// screen being navigated away from can have its pins taken off the map
    /// and put back without re-deriving them.
    @ObservationIgnored private var claimed: [TrailPlaceRow] = []
    /// See ``setHostScreenPresent(_:)``.
    @ObservationIgnored private var hasHostScreen = true

    /// Claims the map's place pins for a screen, returning the token that has
    /// to be handed back to withdraw them.
    @discardableResult func attach(_ rows: [TrailPlaceRow]) -> Int {
        nextToken += 1
        activeToken = nextToken
        apply(rows)
        return nextToken
    }

    /// Redraws the pins of a screen that already holds the claim — a place
    /// arriving from another device while the hike is open.
    func update(_ rows: [TrailPlaceRow], token: Int) {
        guard activeToken == token else { return }
        apply(rows)
    }

    /// Withdraws the pins, unless another screen has already claimed them.
    func detach(token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
        apply([])
    }

    /// Takes the pins off the map for as long as the sheet has no screen
    /// pushed they could belong to, for the reason
    /// ``PhotoMapPinController/setHostScreenPresent(_:)`` exists: a pop
    /// animation runs before the leaving screen's `onDisappear`.
    func setHostScreenPresent(_ present: Bool) {
        guard hasHostScreen != present else { return }
        hasHostScreen = present
        publish()
    }

    private func apply(_ updated: [TrailPlaceRow]) {
        claimed = updated
        publish()
    }

    private func publish() {
        let visible = hasHostScreen ? claimed : []
        guard visible != rows else { return }
        rows = visible
    }
}

extension View {
    /// Draws this hike's marked places on the map for as long as this screen
    /// is up.
    ///
    /// - Parameters:
    ///   - controller: `nil` draws nothing, which is what a preview or a test
    ///     with no map passes.
    ///   - rows: The hike's places in along-route order — see
    ///     ``Hike/orderedPlaces``.
    func trailPlacePins(_ controller: TrailPlacePinController?, rows: [TrailPlaceRow]) -> some View {
        modifier(TrailPlacePinsModifier(controller: controller, rows: rows))
    }
}

/// The claim, as a modifier, so a screen says *these are mine* in one line.
///
/// Its own type rather than three `onAppear`/`onChange`/`onDisappear` closures
/// at the call site, which is the shape ``PhotoMapPinController``'s own
/// modifier already takes and for the same reason: the token has to outlive
/// the body that created it.
private struct TrailPlacePinsModifier: ViewModifier {
    let controller: TrailPlacePinController?
    let rows: [TrailPlaceRow]

    @State private var token: Int?

    func body(content: Content) -> some View {
        content
            .onAppear { token = controller?.attach(rows) }
            .onChange(of: rows) { _, updated in
                guard let token else { return }
                controller?.update(updated, token: token)
            }
            .onDisappear {
                guard let token else { return }
                controller?.detach(token: token)
                self.token = nil
            }
    }
}

// MARK: - The map's half

extension MapView.Coordinator {
    /// Observes a saved hike's places and draws them, then re-registers.
    ///
    /// Idempotent, like every registration here: `withObservationTracking`
    /// offers no way to cancel one, so a second would leave two observers
    /// rebuilding the same annotations for ever.
    func observeHikePlaces(_ controller: TrailPlacePinController, on mapView: MKMapView) {
        guard !isObservingHikePlaces else { return }
        isObservingHikePlaces = true
        trackHikePlaces(controller, on: mapView)
    }

    private func trackHikePlaces(_ controller: TrailPlacePinController, on mapView: MKMapView) {
        hikePlaceController = controller
        applyPlaceAnnotations(
            controller.rows,
            isEditable: false,
            to: \.hikePlaceAnnotations,
            on: mapView
        )
        reobserving(self, mapView, controller) {
            _ = controller.rows
        } onChange: { coordinator, map, model in
            coordinator.trackHikePlaces(model, on: map)
        }
    }

    /// The maker's own places. Called from ``applyTrailDraft(_:on:)`` rather
    /// than from an observation of its own, because they are drawn while the
    /// maker is up and not otherwise — which is a question that registration
    /// already computes.
    func applyTrailDraftPlaces(_ rows: [TrailPlaceRow], on mapView: MKMapView) {
        applyPlaceAnnotations(
            rows,
            isEditable: true,
            to: \.trailDraftPlaceAnnotations,
            on: mapView
        )
    }

    /// Rebuilds one source's pins wholesale rather than diffing them.
    ///
    /// A hiker marks a handful of places, and this runs when one is marked,
    /// edited, moved or removed — never at drag frequency, because a place
    /// under a finger moves its annotation's `coordinate` directly and this
    /// does not run at all. See `MapTrailPlaceDrag.swift`.
    ///
    /// The guard compares every drawn pin against every wanted row, because a
    /// place changes its glyph, its heading and its callout without moving:
    /// renaming one is exactly that.
    private func applyPlaceAnnotations(
        _ rows: [TrailPlaceRow],
        isEditable: Bool,
        to storage: ReferenceWritableKeyPath<MapView.Coordinator, [TrailPlaceAnnotation]>,
        on mapView: MKMapView
    ) {
        let drawn = self[keyPath: storage]
        guard drawn.count != rows.count
            || !zip(drawn, rows).allSatisfy({ $0.matches($1, isEditable: isEditable) })
        else { return }

        if !drawn.isEmpty {
            mapView.removeAnnotations(drawn)
            self[keyPath: storage] = []
            // One of them may have been the open callout — the tidy-up
            // ``applyPhotoPins(_:on:)`` documents, for the same reason.
            refreshOpenCallout(on: mapView)
        }
        guard !rows.isEmpty else { return }
        let annotations = rows.map { row in
            TrailPlaceAnnotation(row: row, isEditable: isEditable)
        }
        self[keyPath: storage] = annotations
        mapView.addAnnotations(annotations)
    }
}
