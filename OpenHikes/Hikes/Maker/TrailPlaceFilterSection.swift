//
//  TrailPlaceFilterSection.swift
//  OpenHikes
//
//  What the maker's *Search this area* pill does, and a switch for each kind
//  of place it looks for.
//
//  The pill is on the map and says two words. This is where it is explained,
//  under *Follow Paths*, and where a hiker who never wants parking pins says
//  so once — see ``TrailPlaceFilter`` for why the choice is app-wide.
//
//  Its own `View` for the reason ``TrailDraftSnapToggle`` is one: a `Toggle`
//  declared in ``TrailDraftView``'s body would make every flip of a switch a
//  pass over the whole route.
//

import SwiftUI

struct TrailPlaceFilterSection: View {
    let maker: TrailDraftController

    var body: some View {
        let filter = maker.finder.filter
        Section {
            ForEach(TrailPointQuery.searchableSymbols, id: \.self) { symbol in
                Toggle(isOn: Binding(
                    get: { filter.shows(symbol) },
                    set: { shows in maker.setShowsPlaces(shows, of: symbol) }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: Self.subtitleSpacing) {
                            Text(Self.title(of: symbol))
                            if let detail = Self.detail(of: symbol) {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        // The pin's own glyph on the pin's own colour, so the
                        // row names the thing on the map it switches.
                        Image(systemName: symbol.systemImageName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .background(symbol.tint, in: .circle)
                    }
                }
                .accessibilityIdentifier("trail-place-filter-\(symbol.rawValue)")
            }
        } header: {
            // A title in the header's own style, and the explanation under it
            // at footnote size: a paragraph in iOS's bold header type reads as
            // a heading of its own.
            VStack(alignment: .leading, spacing: Self.subtitleSpacing) {
                Text("Search This Area")
                Text(
                    """
                    The Search this area button on the map adds what \
                    OpenStreetMap has mapped near your trail as pins you can tap. \
                    Choose what it looks for. Turning a kind off also removes its \
                    pins from the map.
                    """
                )
                .font(.footnote)
                .fontWeight(.regular)
                .accessibilityIdentifier("trail-place-filter-explanation")
            }
            .textCase(nil)
        }
    }

    /// Between a row's title and the line under it.
    private static let subtitleSpacing: CGFloat = 2

    /// The coloured circle behind a row's glyph — Settings' row-icon size.
    private static let iconSize: CGFloat = 28

    /// What a row is called: the plural of what the pin says.
    ///
    /// Not ``TrailPlaceSymbol/label``, which names one pin — *Shelter* — where
    /// a switch is about all of them.
    private static func title(of symbol: TrailPlaceSymbol) -> String {
        switch symbol {
        case .camp: String(localized: "Campsites")
        case .parking: String(localized: "Parking")
        case .shelter: String(localized: "Shelters and Huts")
        case .summit: String(localized: "Summits")
        case .viewpoint: String(localized: "Viewpoints")
        case .water: String(localized: "Water")
        // Nothing is searched for as either, so neither is ever a row — see
        // ``TrailPointQuery/searchableSymbols``.
        case .caution, .junction: symbol.label
        }
    }

    /// What a row covers, where the title alone would leave a hiker guessing
    /// which of OpenStreetMap's kinds it switches — ``TrailPointQuery/kinds``.
    private static func detail(of symbol: TrailPlaceSymbol) -> String? {
        switch symbol {
        case .shelter: String(localized: "Alpine huts, wilderness huts and shelters")
        case .summit: String(localized: "Peaks and saddles")
        case .water: String(localized: "Springs, waterfalls and drinking water")
        case .camp, .caution, .junction, .parking, .viewpoint: nil
        }
    }
}
