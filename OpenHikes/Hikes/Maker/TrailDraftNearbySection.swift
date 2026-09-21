//
//  TrailDraftNearbySection.swift
//  OpenHikes
//
//  What OpenStreetMap offered, as a list, under the places the hiker has
//  actually marked.
//
//  The pins on the map are the main way to read this — they are *where* the
//  things are, which is the whole question — and the list is the other half of
//  the same answer, for the same reason the marked places have one: a pin
//  offscreen is a pin nobody knows about, and "Waterfall · 2.3 km" is a thing
//  you can read down a column and compare. Tapping a row marks it, exactly as
//  the button in its callout does.
//
//  Its own `View` for the reason every other piece of this screen is one — see
//  `TrailDraftFields.swift`: only a `View` is a render boundary, and a search
//  landing with forty answers would otherwise rebuild the list of waypoints
//  above it.
//
//  ## It says nothing until it has something to say
//
//  No empty state, and that is the difference between this section and the two
//  above it. Those describe a trail that exists whether or not anything is in
//  them, so an empty one has to explain itself. This one describes an offer
//  that has not been made: a hiker who has never tapped the pill has not asked
//  a question, and a section telling them so would be a permanent advertisement
//  for a button on the map. What the caption under that button says after a
//  search that found nothing is ``TrailPointNotice/nothingHere``.
//

import OpenHikesShared
import SwiftUI

struct TrailDraftNearbySection: View {
    let maker: TrailDraftController
    /// Opens the editor on a place. The screen's, because the sheet belongs to
    /// the screen — see ``TrailDraftView``.
    var onEdit: (UUID) -> Void

    var body: some View {
        // `finder.rows` rather than a stored flag: the section is exactly as
        // present as the offer is, and it goes when the next search replaces
        // it or the maker closes.
        if !maker.finder.rows.isEmpty {
            Section {
                ForEach(maker.finder.rows) { row in
                    Button { mark(row.place) } label: {
                        TrailPlaceRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trail-point-candidate-row")
                }
            } header: {
                Text("Nearby in OpenStreetMap")
            } footer: {
                Text("Tap one to add it to your trail. They are not saved until you do.")
            }
        }
    }

    /// Marks one, and opens the editor on it — which is what makes this row
    /// different from the same place's pin.
    ///
    /// The pin's own button deliberately does *not* open the editor: adopting
    /// several from the map is a run of single taps, and a sheet between each
    /// pair would be the thing that stopped it being one. From a list row the
    /// bargain is the other way round — the hiker is already in the sheet,
    /// reading, and the row they tapped scrolls away underneath the one that
    /// replaces it, so opening what was just marked is the only thing that
    /// says it happened.
    private func mark(_ candidate: TrailPlace) {
        guard let place = maker.adopt(candidate) else { return }
        HapticMoment.targetHit.play()
        onEdit(place.id)
    }
}
