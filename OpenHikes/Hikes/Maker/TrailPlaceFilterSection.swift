//
//  TrailPlaceFilterSection.swift
//  OpenHikes
//
//  What the maker's *Search this area* pill does, and a chip for each kind of
//  place it looks for — the same chips as *Places Around Trail*.
//
//  The pill is on the map and says two words. This is where it is explained,
//  under *Follow Paths*, and where a hiker who never wants parking pins says
//  so once — see ``TrailPlaceFilter`` for why the choice is app-wide.
//
//  The switch beside the heading is the one above the kinds: off hides the
//  trail's places, withdraws the pill and keeps them out of the save — see
//  ``TrailPlaceFilter/placesShown``. The chips go with it, because there is
//  nothing left for them to choose between.
//
//  Its own `View` for the reason ``TrailDraftSnapToggle`` is one: a `Toggle`
//  declared in ``TrailDraftView``'s body would make every flip of a switch a
//  pass over the whole route.
//

import OpenHikesData
import SwiftUI

struct TrailPlaceFilterSection: View {
    let maker: TrailDraftController

    var body: some View {
        let filter = maker.finder.filter
        let placesShown = filter.placesShown
        Section {
            // The same chips as *Places Around Trail*, because it is the same
            // app-wide choice — see ``TrailPlaceKindChips``. Here a kind
            // switched off also leaves the drawing.
            if placesShown {
                TrailPlaceKindChips(filter: filter) { symbol, shows in
                    maker.setShowsPlaces(shows, of: symbol)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
        } header: {
            // A title in the header's own style, and the explanation under it
            // at footnote size: a paragraph in iOS's bold header type reads as
            // a heading of its own.
            VStack(alignment: .leading, spacing: Self.subtitleSpacing) {
                HStack {
                    Text("Search This Area")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(
                        "Search This Area",
                        // A closure rather than the method itself, for the
                        // reason ``TrailPlacePinSwitch`` gives: the
                        // reabstraction thunk crashes Swift 6.3's IRGen.
                        isOn: Binding(get: { placesShown }, set: { maker.setPlacesShown($0) })
                    )
                    .labelsHidden()
                    .accessibilityIdentifier("trail-places-toggle")
                }
                Group {
                    if placesShown {
                        Text(
                            """
                            The Search this area button on the map adds what \
                            OpenStreetMap has mapped near your trail as pins you can tap. \
                            Choose what it looks for. Turning a kind off also removes its \
                            pins from the map.
                            """
                        )
                    } else {
                        Text(
                            """
                            Places are hidden from the map and won't be saved with \
                            this trail. Turn this on to show them and search for more.
                            """
                        )
                    }
                }
                .font(.footnote)
                .fontWeight(.regular)
                .accessibilityIdentifier("trail-place-filter-explanation")
            }
            .textCase(nil)
        }
    }

    /// Between the header's title and the explanation under it.
    private static let subtitleSpacing: CGFloat = 2
}
