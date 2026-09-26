//
//  TrailPlaceKindChips.swift
//  OpenHikes
//
//  The kinds of place a search looks for, as Apple Maps' category chips: on is
//  filled in the kind's own colour, off is plain glass.
//
//  One view for the two screens that choose them — the trail maker, under
//  *Search This Area*, and *Places Around Trail* — because they are one
//  choice: the switches are ``TrailPlaceFilter``'s, which are app-wide, so a
//  chip turned off in one is off in the other, and it should look the same in
//  both. What turning one off *does* differs, and the screen says so through
//  `onChange`: the maker also takes that kind's pins off the drawing — see
//  ``TrailDraftController/setShowsPlaces(_:of:)``.
//
//  Its own `View` so a tap redraws the chips and not the screen around them —
//  the reason ``TrailDraftSnapToggle`` is one.
//

import OpenHikesData
import SwiftUI

struct TrailPlaceKindChips: View {
    let filter: TrailPlaceFilter
    /// What a tap does, or `nil` to switch the kind on the filter and nothing
    /// else.
    var onChange: ((TrailPlaceSymbol, Bool) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(TrailPointQuery.searchableSymbols, id: \.self) { kind in
                    chip(kind, isOn: filter.shows(kind))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func chip(_ kind: TrailPlaceSymbol, isOn: Bool) -> some View {
        let label = Label(Self.title(of: kind), systemImage: kind.systemImageName)
            .font(.subheadline.weight(.medium))
        Group {
            if isOn {
                Button { set(kind, shown: false) } label: { label }
                    .prominentGlassButtonStyle()
                    .tint(kind.tint)
            } else {
                Button { set(kind, shown: true) } label: { label }
                    .glassButtonStyle()
            }
        }
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("trail-place-kind-\(kind.rawValue)")
    }

    private func set(_ kind: TrailPlaceSymbol, shown: Bool) {
        if let onChange {
            onChange(kind, shown)
        } else {
            filter.setShows(shown, kind)
        }
    }

    /// A chip's word: short, and plural, because a chip is about all of them
    /// — not ``TrailPlaceSymbol/label``, which names one pin.
    private static func title(of kind: TrailPlaceSymbol) -> String {
        switch kind {
        case .camp: String(localized: "Campsites")
        case .parking: String(localized: "Parking")
        case .shelter: String(localized: "Huts")
        case .summit: String(localized: "Summits")
        case .viewpoint: String(localized: "Viewpoints")
        case .water: String(localized: "Water")
        // Nothing is searched for as either, so neither is ever a chip — see
        // ``TrailPointQuery/searchableSymbols``.
        case .caution, .junction: kind.label
        }
    }
}
