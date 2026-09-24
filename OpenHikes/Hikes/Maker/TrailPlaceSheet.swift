//
//  TrailPlaceSheet.swift
//  OpenHikes
//
//  Apple Maps' place card, for whatever the hiker tapped on the maker's map.
//
//  One sheet for the three things a tap can land on — open ground, one of the
//  trail's places, one of its stops — because to the hiker they are the same
//  question: *what is here, and do I want my route to go through it?* So the
//  card always says where it is (the address MapKit finds and the
//  coordinates), what OpenStreetMap knows about it when it came from there, and
//  offers the one verb the maker has for a spot: **Add Stop**, which fills an
//  open start or destination field or goes into the nearest leg. A stop's card
//  offers to take it out instead.
//
//  ## A sheet over the sheet, and the map still live behind it
//
//  Presented from inside the maker's screen, like the stop search — see
//  *Present modals from inside the sheet's contents* in the repository
//  instructions. Its smallest detent leaves the map uncovered and interactive,
//  so tapping somewhere else moves the card to there rather than closing it
//  first, the way Apple Maps behaves.
//

import CoreLocation
import MapKit
import OpenHikesShared
import SwiftUI

/// Presents the place sheet off ``TrailDraftController/selection``.
///
/// A modifier rather than a `.sheet` in ``TrailDraftView``'s body, so the
/// selection is read here and a tap on the map does not rebuild the list of
/// stops underneath — a `ViewModifier` is a render boundary for the reason a
/// `View` is.
struct TrailPlaceSheetPresenter: ViewModifier {
    let maker: TrailDraftController

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { maker.selection != nil },
            set: { if !$0 { maker.select(nil) } }
        )) {
            TrailPlaceSheet(maker: maker)
        }
    }
}

struct TrailPlaceSheet: View {
    let maker: TrailDraftController

    /// Where the card rests. It opens at the middle height, where the buttons
    /// and the address are in view, and a new selection leaves it wherever the
    /// hiker put it. State of this view rather than of the presenter, so every
    /// presentation starts from the middle again.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        Group {
            if let selection = maker.selection,
               let card = TrailPlaceCard(selection, in: maker.draft, droppedPin: maker.droppedPin) {
                TrailPlaceCardView(maker: maker, card: card)
            } else {
                // What the card was about has gone — a stop deleted from the
                // list under it — so there is nothing left to say about it.
                Color.clear.onAppear { maker.select(nil) }
            }
        }
        // The smallest detent is the map sheet's own: the title and the ✕, and
        // the rest of the screen left to the map the hiker is choosing from.
        .presentationDetents(
            [SheetPresentation.compactDetent, .medium, .large],
            selection: $detent
        )
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // A sheet stays a sheet in landscape. Left to adapt, a vertically
        // compact phone presents it as a full-screen cover — the whole map
        // hidden behind a card about one spot on it, on the one screen whose
        // job is the map.
        .presentationCompactAdaptation(.none)
    }
}

private struct TrailPlaceCardView: View {
    let maker: TrailDraftController
    let card: TrailPlaceCard

    /// The address MapKit found, `nil` until it answers and for a spot it
    /// cannot place. Asked once per coordinate.
    @State private var address: String?

    /// Room between the grabber and the title, as the map sheet leaves above
    /// its search field.
    private static let topPadding: CGFloat = 20

    /// Not in a scroll view: the card is short enough to fit at the tallest
    /// detent, and a scroll view is what let the smallest one slide its
    /// contents about under the grabber instead of resizing the sheet.
    var body: some View {
        VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            header
            actions
            TrailPlaceFactsAndLocation(
                facts: card.facts,
                address: address,
                coordinate: card.coordinate,
                openStreetMapURL: card.openStreetMapURL
            )
        }
        .padding(.horizontal)
        .padding(.top, Self.topPadding)
        // Laid out at its own height and hung from the top of whatever the
        // detent offers. Without the `minHeight`, a card taller than the
        // smallest detent sized its frame to itself and the sheet centred it —
        // the buttons in view and the title above the top edge.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trail-place-sheet")
        .task(id: [card.latitude, card.longitude]) {
            address = nil
            address = await maker.address(at: card.coordinate)
        }
    }

    private var header: some View {
        PlaceCardHeader {
            TrailPlaceBadge(systemImage: card.systemImage, tint: card.tint)
        } title: {
            Text(card.title)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("trail-place-title")
        } subtitle: {
            if let subtitle = card.subtitle {
                Text(subtitle)
            }
        } trailing: {
            // Drawn as Maps' own ✕ and as the recording card's controls: a
            // round glass button, not a bare glyph in a grey circle.
            Button("Close", systemImage: "xmark") { maker.select(nil) }
                .glassButtonStyle()
                .placeCardControl()
                .accessibilityIdentifier("trail-place-close")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            switch card.primary {
            case let .addStop(name, leg):
                action(
                    "Add Stop",
                    systemImage: "plus",
                    prominent: true,
                    role: nil,
                    identifier: "trail-place-add-stop"
                ) {
                    maker.select(nil)
                    // The pin has become the stop; two markers on one spot
                    // would be the map saying it twice.
                    if card.isDroppedPin { maker.removeDroppedPin() }
                    maker.addStop(at: card.coordinate, named: name, preferringLeg: leg)
                    HapticMoment.targetHit.play()
                }
            case .removeStop(let id):
                // Destructive, and drawn so: the card's one filled button is
                // otherwise the accent, which is what *Add Stop* looks like.
                action(
                    "Remove Stop",
                    systemImage: "trash",
                    prominent: true,
                    role: .destructive,
                    identifier: "trail-place-remove-stop"
                ) {
                    maker.select(nil)
                    maker.removeStop(id: id)
                }
            }
            shareButton
            if case .addStop = card.primary { removeButton }
        }
        // One height for the row, whichever button's word needs the most room
        // at the hiker's type size.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// *Remove Pin* for the dropped pin, which takes it off the map, and
    /// *Remove* for one of the trail's places, which takes it off the trail.
    private var removeButton: some View {
        action(
            card.removablePlace == nil ? "Remove Pin" : "Remove",
            systemImage: card.removablePlace == nil ? "mappin.slash" : "trash",
            prominent: false,
            role: card.removablePlace == nil ? nil : .destructive,
            identifier: "trail-place-remove"
        ) {
            if let place = card.removablePlace {
                maker.select(nil)
                maker.removePlace(id: place)
            } else {
                maker.removeDroppedPin()
            }
        }
    }

    private var shareButton: some View {
        ShareLink(
            item: TrailPlaceCoordinates.mapsURL(card.coordinate, named: card.title),
            subject: Text(card.title),
            message: Text(shareMessage)
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
                .labelStyle(TrailPlaceActionLabelStyle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        .accessibilityIdentifier("trail-place-share")
    }

    private var shareMessage: String {
        [card.title, address, TrailPlaceCoordinates.text(card.coordinate)]
            .compactMap(\.self)
            .joined(separator: "\n")
    }

    @ViewBuilder
    private func action(
        _ title: LocalizedStringKey,
        systemImage: String,
        prominent: Bool,
        role: ButtonRole?,
        identifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        let label = Label(title, systemImage: systemImage)
            .labelStyle(TrailPlaceActionLabelStyle())
        Group {
            if prominent {
                Button(role: role, action: perform) { label }
                    .buttonStyle(.borderedProminent)
                    .tint(role == .destructive ? .red : nil)
            } else {
                Button(role: role, action: perform) { label }.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        .accessibilityIdentifier(identifier)
    }
}
