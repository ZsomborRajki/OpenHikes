//
//  TrailDraftPlaceSection.swift
//  OpenHikes
//
//  The maker's list of places, and the three ways to mark one that are not a
//  tap on the map.
//
//  Its own `View` for the reason every other piece of this screen is one — see
//  `TrailDraftFields.swift`: only a `View` is a render boundary, and a place
//  marked, renamed or dragged would otherwise rebuild the route above it.
//
//  ## Along-route order, and no way to reorder it
//
//  The stops above can be dragged into a different order, because their
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
//  ``TrailDraftPinAction``. What the rows below add is the three spots a tap
//  cannot reach conveniently: the middle of the screen, the hiker's own
//  position, and a place that was searched for by name. Each of them lands in
//  the same ``TrailDraftController/markPlace(at:named:symbol:)`` and opens the
//  same editor.
//
//  The third of those used to be fed by the maker's own *Find a Place* field.
//  That field is gone and the fact it kept is not: the search sheet a stop row
//  opens remembers what it last resolved, which is the same "the place you just
//  looked up" and is now reachable from two lists rather than one. See
//  ``TrailStopSearchRun/lastPick``.
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
    /// What the stop search sheet last resolved, so it can be marked by name
    /// — see ``TrailStopSearchRun/lastPick``.
    let search: TrailStopSearchRun
    /// Opens the editor on a place. The screen's, because the sheet belongs to
    /// the screen — see ``TrailDraftView``.
    var onEdit: (UUID) -> Void

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        Section {
            if draft.placeRows.isEmpty {
                Text("Tap the map and choose Mark a Place, or use the rows below.")
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
            addRows
        } header: {
            Text("Places")
        } footer: {
            Text("Marked spots along the trail. Drag a pin on the map to move one.")
        }
    }

    /// The three spots a tap on the map cannot reach conveniently.
    ///
    /// **Rows rather than a `Menu`, and that is a constraint rather than a
    /// preference.** It was a menu, for the reason ``TrailDraftActionsMenu`` is
    /// one — this screen carried a search field, a switch and two lists, and
    /// three more rows would have been most of what was left. Two things
    /// changed. The search field went into a sheet of its own, which is the
    /// room; and the list is now in ``EditMode/active`` permanently so the
    /// route's rows can carry their grabbers — and **a `Menu` inside a `List`
    /// in edit mode does not open at all**. A `Button` does, which is what the
    /// route's own rows rest on, so this is the shape that survives. Found by
    /// pressing it: nothing else on this screen would have said so, and
    /// `testMarkingAPlaceFromTheList` is here to keep saying it.
    @ViewBuilder private var addRows: some View {
        Button("At the Map's Centre", systemImage: "scope", action: markMapCentre)
            .disabled(completer.region == nil)
            .accessibilityIdentifier("trail-draft-add-place")
        Button("At My Location", systemImage: "location", action: markMyLocation)
            .disabled(currentCoordinate == nil)
            .accessibilityIdentifier("trail-draft-add-place-here")
        // The only one of the four that arrives already named. Withheld
        // rather than disabled, because until a lookup has answered there
        // is no such place to describe — a row reading "Mark" with
        // nothing after it says less than no row at all.
        if let found = search.lastPick, !found.name.isEmpty {
            Button("Mark \(found.name)", systemImage: "magnifyingglass") {
                markSearchResult(found)
            }
            .accessibilityIdentifier("trail-draft-add-place-found")
        }
    }

    /// The hiker's last known position, or `nil` for a launch with no location
    /// or one that has not had a fix yet.
    ///
    /// Read in an action rather than in the body wherever it can be — see
    /// ``LocationManager``, whose published fix is the highest-frequency
    /// source in the app. The one read that *is* in a body is the `disabled`
    /// above, and it is deliberate: a row that silently did nothing
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

    private func markSearchResult(_ found: TrailStopSearchPick) {
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
