//
//  MapTrailPlacePins.swift
//  OpenHikes
//
//  Putting the places on the map, from whichever of the two sources is live.
//
//  While a trail is being drawn they come off ``TrailDraft/placeRows`` through
//  the maker's own observation — see `MapTrailDraftOverlay.swift` — and a tap
//  opens the maker's place sheet. While a saved hike's screen is pushed
//  they come off its ``TrailPoint`` rows through ``TrailPlacePinController``,
//  and a tap opens that place's own screen — see ``HikePlaceView``.
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
/// A tap on a pin opens that place's screen through ``open(_:)``, which asks
/// whichever screen holds the claim — the claim carries the opener, for the
/// reason it carries the rows: a pin belongs to the screen that put it there.
/// There is no callout. A place's screen says more than a callout can, and a
/// callout MapKit opened is one MapKit closes again a moment later — the race
/// the maker's own pins were taken off callouts for.
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
    /// What a tap on one of the claimed pins does. See ``open(_:)``.
    @ObservationIgnored private var opener: ((UUID) -> Void)?
    /// See ``setHostScreenPresent(_:)``.
    @ObservationIgnored private var hasHostScreen = true
    /// Whether the hiker wants saved hikes' places on the map at all.
    /// Observed, so the switch drawing it follows a change made from another
    /// screen. See ``setShowsPins(_:)``.
    private(set) var showsPins: Bool
    /// Where ``showsPins`` is kept, or `nil` for a choice that lives only as
    /// long as this object — a preview, and every suite that does not ask for
    /// one.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        // What is stored is the switch turned *off*, so an empty store is the
        // default: places are drawn.
        showsPins = !(defaults?.bool(forKey: SettingsKey.trailPlacePinsHidden) ?? false)
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Claims the map's place pins for a screen, returning the token that has
    /// to be handed back to withdraw them.
    @discardableResult func attach(_ rows: [TrailPlaceRow], onOpen: ((UUID) -> Void)? = nil) -> Int {
        nextToken += 1
        activeToken = nextToken
        opener = onOpen
        apply(rows)
        return nextToken
    }

    /// Opens the place a pin stands for, on the screen that drew it. Answers
    /// whether anything could — a pin whose screen has gone opens nothing.
    @discardableResult func open(_ placeID: UUID) -> Bool {
        guard activeToken != nil, hasHostScreen, showsPins, let opener,
              rows.contains(where: { $0.id == placeID }) else { return false }
        opener(placeID)
        return true
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
        opener = nil
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

    /// Puts every saved hike's places on the map, or takes them off. Hiding
    /// removes pins, not places.
    func setShowsPins(_ shows: Bool) {
        guard showsPins != shows else { return }
        showsPins = shows
        defaults?.set(!shows, forKey: SettingsKey.trailPlacePinsHidden)
        publish()
    }

    private func apply(_ updated: [TrailPlaceRow]) {
        claimed = updated
        publish()
    }

    private func publish() {
        let visible = hasHostScreen && showsPins ? claimed : []
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
    ///   - onOpen: What a tap on one of the pins does.
    func trailPlacePins(
        _ controller: TrailPlacePinController?,
        rows: [TrailPlaceRow],
        onOpen: ((UUID) -> Void)? = nil
    ) -> some View {
        modifier(TrailPlacePinsModifier(controller: controller, rows: rows, onOpen: onOpen))
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
    let onOpen: ((UUID) -> Void)?

    @State private var token: Int?

    func body(content: Content) -> some View {
        content
            .onAppear { token = controller?.attach(rows, onOpen: onOpen) }
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

/// A hike's places on the map, claimed by a whole screen rather than by the
/// section that lists them.
///
/// The detail screen's *Places* section is only drawn on its *Details* face,
/// and a claim made from there was withdrawn by flipping to *History* — the
/// pins went with the list. Hung off the screen's container instead, where the
/// segment switch never reaches, so the pins stay for as long as the hike's
/// screen does.
///
/// A view of its own, and reading ``Hike/orderedPlaces`` in its own body, so
/// a place arriving from CloudKit redraws this and not the screen that hosts
/// it.
struct HikePlacePinClaim: View {
    let hike: Hike
    let controller: TrailPlacePinController?
    var onOpen: ((UUID) -> Void)?

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .trailPlacePins(controller, rows: hike.orderedPlaces, onOpen: onOpen)
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
            belongsToDraft: false,
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
            belongsToDraft: true,
            to: \.trailDraftPlaceAnnotations,
            on: mapView
        )
    }

    /// Rebuilds one source's pins wholesale rather than diffing them.
    ///
    /// This runs when a search adds places or one is removed — a few dozen
    /// pins, a few times a session.
    ///
    /// The guard compares every drawn pin against every wanted row, because a
    /// place can change its glyph, its heading and its callout without moving.
    private func applyPlaceAnnotations(
        _ rows: [TrailPlaceRow],
        belongsToDraft: Bool,
        to storage: ReferenceWritableKeyPath<MapView.Coordinator, [TrailPlaceAnnotation]>,
        on mapView: MKMapView
    ) {
        let drawn = self[keyPath: storage]
        guard drawn.count != rows.count
            || !zip(drawn, rows).allSatisfy({ $0.matches($1, belongsToDraft: belongsToDraft) })
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
            TrailPlaceAnnotation(row: row, belongsToDraft: belongsToDraft)
        }
        self[keyPath: storage] = annotations
        mapView.addAnnotations(annotations)
    }
}
