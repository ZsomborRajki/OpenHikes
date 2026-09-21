//
//  TrailDraftPlaceSection.swift
//  OpenHikes
//
//  The maker's list of places, and the three ways to mark one that are not a
//  tap on the map.
//
//  Its own `View` for the reason every other piece of this screen is one — see
//  `TrailDraftFields.swift`: only a `View` is a render boundary, and a place
//  marked, renamed or dragged would otherwise rebuild the list of waypoints
//  above it.
//
//  ## Along-route order, and no way to reorder it
//
//  The waypoints above can be dragged into a different order, because their
//  order *is* the trail. These cannot, and the absence is the design rather
//  than a gap: a place is a spot on the ground, so where it sits in this list
//  is a fact about the line rather than a rank anybody chose. Bending the
//  route past a spring moves it up the list on its own. See
//  ``TrailPlaceOrder``.
//
//  ## Four ways to mark one, and only one of them is here
//
//  A tap on the map is the main one and it is not in this file: it drops a pin
//  and *Mark a Place* is a button in its callout — see
//  ``TrailDraftPinAction``. What the menu below adds is the three spots a tap
//  cannot reach conveniently: the middle of the screen, the hiker's own
//  position, and a place that was searched for by name. Each of them lands in
//  the same ``TrailDraftController/markPlace(at:named:symbol:)`` and opens the
//  same editor.
//

import CoreLocation
import MapKit
import OpenHikesShared
import SwiftUI

struct TrailDraftPlaceSection: View {
    let maker: TrailDraftController
    /// Where the map is looking, so *Mark the Map's Centre* has a coordinate.
    /// The map feeds this the region it settled at — see ``SearchCompleter``.
    let completer: SearchCompleter
    /// The hiker's own position, or `nil` for a launch with no location.
    var locationManager: LocationManager?
    /// What the screen's own *Find a Place* field last found, so it can be
    /// marked by name — see ``TrailDraftSearchRun/lastResult``.
    let search: TrailDraftSearchRun
    /// Opens the editor on a place. The screen's, because the sheet belongs to
    /// the screen — see ``TrailDraftView``.
    var onEdit: (UUID) -> Void

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        Section {
            if draft.placeRows.isEmpty {
                Text("Tap the map and choose Mark a Place, or use the button below.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("trail-draft-places-empty")
            } else {
                ForEach(draft.placeRows) { row in
                    Button { onEdit(row.id) } label: {
                        TrailPlaceRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }
                // The one gesture a list already has a meaning for. Through the
                // controller, like every other mutation in this feature,
                // because the drawing has to be written down — and by row
                // offsets, which are not the order the places are stored in.
                .onDelete { offsets in
                    maker.removePlaces(atRowOffsets: offsets)
                }
            }
            addMenu
        } header: {
            Text("Places")
        } footer: {
            Text("Marked spots along the trail. Drag a pin on the map to move one.")
        }
    }

    /// The three spots a tap on the map cannot reach conveniently.
    ///
    /// A `Menu` rather than three rows, for the reason
    /// ``TrailDraftActionsMenu`` is one: this screen already carries a search
    /// field, a switch, a list of points and a list of places, and three more
    /// rows would be most of what is left. Nothing inside carries an
    /// identifier — a `Menu`'s contents are rebuilt by the system when it
    /// opens, and one on a button inside does not survive that. Reached by
    /// title; see that type for what the finding cost.
    @ViewBuilder private var addMenu: some View {
        Menu {
            Button("At the Map's Centre", systemImage: "scope", action: markMapCentre)
                .disabled(completer.region == nil)
            Button("At My Location", systemImage: "location", action: markMyLocation)
                .disabled(currentCoordinate == nil)
            // The only one of the four that arrives already named. Withheld
            // rather than disabled, because until a lookup has answered there
            // is no such place to describe — an entry reading "Mark" with
            // nothing after it says less than no entry at all.
            if let found = search.lastResult, !found.name.isEmpty {
                Button("Mark \(found.name)", systemImage: "magnifyingglass") {
                    markSearchResult(found)
                }
            }
        } label: {
            Label("Mark a Place", systemImage: "mappin.and.ellipse")
        }
        .accessibilityIdentifier("trail-draft-add-place")
    }

    /// The hiker's last known position, or `nil` for a launch with no location
    /// or one that has not had a fix yet.
    ///
    /// Read in an action rather than in the body wherever it can be — see
    /// ``LocationManager``, whose published fix is the highest-frequency
    /// source in the app. The one read that *is* in a body is the `disabled`
    /// above, and it is deliberate: a menu entry that silently did nothing
    /// would be worse than one that says it cannot. A fix arriving re-renders
    /// this section and nothing else, which is what this file being its own
    /// `View` is for.
    private var currentCoordinate: CLLocationCoordinate2D? {
        locationManager?.coordinate
    }

    private func markMapCentre() {
        guard let centre = completer.region?.center else { return }
        mark(at: centre)
    }

    private func markMyLocation() {
        guard let here = currentCoordinate else { return }
        mark(at: here)
    }

    private func markSearchResult(_ found: TrailPlaceSearchResult) {
        guard let place = maker.markPlace(at: found.clCoordinate, named: found.name) else { return }
        HapticMoment.targetHit.play()
        onEdit(place.id)
    }

    /// Marks and opens the editor, which is one gesture from the hiker's side
    /// — the same pair the callout's own *Mark a Place* makes.
    private func mark(at coordinate: CLLocationCoordinate2D) {
        guard let place = maker.markPlace(at: coordinate) else { return }
        HapticMoment.targetHit.play()
        onEdit(place.id)
    }
}
