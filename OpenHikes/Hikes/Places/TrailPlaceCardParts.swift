//
//  TrailPlaceCardParts.swift
//  OpenHikes
//
//  The pieces a place's card is built from, shared by the cards there are:
//  the maker's sheet over the map (``TrailPlaceSheet``), a saved hike's
//  pushed place screen (``HikePlaceView``), and the card and *Add Place* form
//  the Places screens raise (``HikePlaceAroundCard``, ``HikePlaceAdder``).
//  Split out of the first when the second arrived, rather than drawn twice,
//  because they say the same things about the same kind of place — what
//  OpenStreetMap knows, where it is — and a fact row that reads one way in
//  the maker and another on the saved trail would be the app contradicting
//  itself about one spring.
//

import CoreLocation
import OpenHikesData
import SwiftUI

/// What Wikipedia says about a place, what OpenStreetMap says about it, then
/// where it is.
///
/// One view for every card, which is the reason this file exists. `address` is
/// the maker's, which asks MapKit; a saved hike's screen passes `nil` rather
/// than a second geocoding path.
struct TrailPlaceFactsAndLocation: View {
    let facts: [TrailPlaceFact]
    var address: String?
    let coordinate: CLLocationCoordinate2D
    var openStreetMapURL: URL?
    /// The Wikidata item OpenStreetMap links the place to, which the card
    /// opens with what Wikipedia says about — see ``WikidataPlaceSection``.
    var wikidataItem: String?

    @Environment(\.wikidataLookup) private var wikidata
    /// What ``wikidataItem`` was answered with, carrying the item it is about
    /// so a card handed another place never draws the last one's.
    ///
    /// Held here rather than by the section, because a section with nothing
    /// to draw yet would have to be drawn as something for its task to run,
    /// and that something would leave a gap in the card the size of the
    /// space between sections. The *Location* list is always drawn, so the
    /// question rides on it.
    @State private var described: WikidataPlace?

    var body: some View {
        // The answer this card was handed, or one an earlier card was — so a
        // card reopened has its section in its first pass.
        if let shown = wikidata?.shown(for: wikidataItem, described: described) {
            WikidataPlaceSection(place: shown)
        }
        if !facts.isEmpty {
            StatList(title: String(localized: "Details")) {
                ForEach(facts, id: \.self, content: TrailPlaceFactRow.init)
            }
        }
        StatList(title: String(localized: "Location")) {
            if let address {
                StatRow(label: "Address", value: address)
                    .accessibilityIdentifier("trail-place-address")
            }
            StatRow(
                label: "Coordinates",
                value: TrailPlaceCoordinates.text(coordinate)
            )
            .textSelection(.enabled)
            .accessibilityIdentifier("trail-place-coordinates")
            if let openStreetMapURL {
                // The row's height and hit shape inside the label, where the
                // link's accessibility frame is measured: outside it, the
                // frame stayed one text line tall, a 19 pt target the audit
                // reports on the card that shows this row at the middle
                // detent.
                Link(destination: openStreetMapURL) {
                    Label("View on OpenStreetMap", systemImage: "arrow.up.right.square")
                        .trailPlaceRow()
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("trail-place-osm-link")
            }
        }
        .task(id: wikidataItem) { await describe() }
    }

    private func describe() async {
        guard let wikidataItem, let wikidata else { return }
        let answer = await wikidata.place(wikidataItem)
        // A card handed another place while this was asked has a task of its
        // own for that one, which this answer must not overwrite.
        guard !Task.isCancelled else { return }
        withAnimation { described = answer }
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
/// The actions share the card's width, so a narrow side panel has too little
/// room for a glyph beside its caption. Stacked, the words have their
/// button's whole width, and the row grows to fit the longest caption.
struct TrailPlaceActionLabelStyle: LabelStyle {
    static let cornerRadius: CGFloat = 14
    /// The caption's text style, which ``TrailPlaceActions`` also scales its
    /// line allowance by.
    static let captionStyle: Font.TextStyle = .caption

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon
                .font(.body.weight(.semibold))
                .imageScale(.medium)
            configuration.title
                .font(.system(Self.captionStyle, weight: .semibold))
                // TrailPlaceActions measures this wrapped height before it
                // chooses how many buttons share a row.
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 6)
    }
}

/// The two ways a photograph reaches a place — the camera, prominent, and the
/// library beside it — as each place screen that takes one offers them: a
/// saved hike's place, a place around the trail, and *Add Place*.
///
/// Two buttons rather than a row of its own, so they sit in the screen's row
/// beside whatever else it offers and share its width with the rest. What
/// each one does, and the name automation finds it by, is the screen's.
struct TrailPlacePhotoButtons: View {
    let cameraIdentifier: String
    let libraryIdentifier: String
    let onCamera: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        Button(action: onCamera) {
            Label("Take Photo", systemImage: "camera")
                .labelStyle(TrailPlaceActionLabelStyle())
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(cameraIdentifier)
        Button(action: onLibrary) {
            Label("Add Photos", systemImage: "photo.on.rectangle")
                .labelStyle(TrailPlaceActionLabelStyle())
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(libraryIdentifier)
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
                StatRow(verbatim: fact.kind.label, value: fact.value)
            }
        case .phone:
            let digits = fact.value.filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:\(digits)"), !digits.isEmpty {
                TrailPlaceLinkRow(label: fact.kind.label, title: fact.value, destination: url)
            } else {
                StatRow(verbatim: fact.kind.label, value: fact.value)
            }
        default:
            StatRow(verbatim: fact.kind.label, value: fact.displayValue)
        }
    }
}

/// A ``StatRow`` whose value is a link: the website, the phone number, the
/// licence of Wikipedia's words.
///
/// The whole row is the link, with its height and hit shape inside the label
/// for the reason the card's *View on OpenStreetMap* has them there: with the
/// row's height outside it, the link was one line of text tall, 20 pt
/// measured. And one element, as a composite row is, so an identifier set on
/// the row lands on the link and not on its label's words as well.
struct TrailPlaceLinkRow: View {
    let label: String
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .foregroundStyle(.primary)
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .trailPlaceRow()
            .contentShape(.rect)
        }
        .accessibilityLabel(label)
        .accessibilityValue(title)
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
