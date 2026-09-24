//
//  TrailPlaceCardParts.swift
//  OpenHikes
//
//  The pieces a place's card is built from, shared by the two cards there
//  are: the maker's sheet over the map (``TrailPlaceSheet``), and a saved
//  hike's pushed place screen (``HikePlaceView``). Split out of the first when
//  the second arrived, rather than drawn twice, because they say the same
//  things about the same kind of place — what OpenStreetMap knows, where it
//  is — and a fact row that reads one way in the maker and another on the
//  saved trail would be the app contradicting itself about one spring.
//

import CoreLocation
import SwiftUI

/// What OpenStreetMap says about a place, then where it is.
///
/// One view for both cards, which is the reason this file exists. `address` is
/// the maker's, which asks MapKit; a saved hike's screen passes `nil` rather
/// than a second geocoding path.
struct TrailPlaceFactsAndLocation: View {
    let facts: [TrailPlaceFact]
    var address: String?
    let coordinate: CLLocationCoordinate2D
    var openStreetMapURL: URL?

    var body: some View {
        if !facts.isEmpty {
            StatList(title: String(localized: "Details")) {
                ForEach(facts, id: \.self, content: TrailPlaceFactRow.init)
            }
        }
        StatList(title: String(localized: "Location")) {
            if let address {
                StatRow(label: String(localized: "Address"), value: address)
                    .accessibilityIdentifier("trail-place-address")
            }
            StatRow(
                label: String(localized: "Coordinates"),
                value: TrailPlaceCoordinates.text(coordinate)
            )
            .textSelection(.enabled)
            .accessibilityIdentifier("trail-place-coordinates")
            if let openStreetMapURL {
                Link(destination: openStreetMapURL) {
                    Label("View on OpenStreetMap", systemImage: "arrow.up.right.square")
                }
                .trailPlaceRow()
                .accessibilityIdentifier("trail-place-osm-link")
            }
        }
    }
}

/// What kind of place a hiker's own place is, with *None* first — an unstated
/// kind is a state, not a missing value; see ``TrailPlace``.
struct TrailPlaceKindPicker: View {
    @Binding var selection: TrailPlaceSymbol?

    var body: some View {
        Picker("Kind", selection: $selection) {
            Text("None").tag(TrailPlaceSymbol?.none)
            ForEach(TrailPlaceSymbol.allCases, id: \.self) { kind in
                Label(kind.label, systemImage: kind.systemImageName).tag(Optional(kind))
            }
        }
        .accessibilityIdentifier("trail-place-kind-picker")
    }
}

/// A place's glyph on its own colour, as Apple Maps heads a place card.
struct TrailPlaceBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(tint, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Apple Maps' action buttons: the glyph over one short word.
///
/// Three of them share the card's width, which at the default type size is a
/// little over a hundred points each — too narrow for a glyph *beside* "Remove
/// Pin", which is how they wrapped onto two lines when they were drawn that
/// way. Stacked, each word has its button's whole width to itself.
struct TrailPlaceActionLabelStyle: LabelStyle {
    static let cornerRadius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon
                .font(.body.weight(.semibold))
                .imageScale(.medium)
            configuration.title
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 6)
    }
}

/// One thing OpenStreetMap says about a place, in words.
struct TrailPlaceFactRow: View {
    let fact: TrailPlaceFact

    var body: some View {
        switch fact.kind {
        case .website:
            if let url = URL(string: fact.value), url.scheme?.hasPrefix("http") == true {
                TrailPlaceLinkRow(label: fact.kind.label, title: fact.value, destination: url)
            } else {
                StatRow(label: fact.kind.label, value: fact.value)
            }
        case .phone:
            let digits = fact.value.filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:\(digits)"), !digits.isEmpty {
                TrailPlaceLinkRow(label: fact.kind.label, title: fact.value, destination: url)
            } else {
                StatRow(label: fact.kind.label, value: fact.value)
            }
        default:
            StatRow(label: fact.kind.label, value: fact.displayValue)
        }
    }
}

/// A ``StatRow`` whose value is a link: the website or the phone number.
struct TrailPlaceLinkRow: View {
    let label: String
    let title: String
    let destination: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Link(title, destination: destination)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .trailPlaceRow()
    }
}

extension View {
    /// A ``StatRow``'s height and padding, for the card's rows that are not one.
    func trailPlaceRow() -> some View {
        font(.body)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: StatCardMetrics.rowMinimumHeight, alignment: .leading)
    }
}
