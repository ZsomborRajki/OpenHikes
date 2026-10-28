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

import Algorithms
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
    /// For a photograph's full-screen viewer, whose *Show on Map* moves it.
    let mapController: MapController

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { maker.selection != nil },
            set: { if !$0 { maker.select(nil) } }
        )) {
            TrailPlaceSheet(maker: maker, mapController: mapController)
        }
    }
}

struct TrailPlaceSheet: View {
    let maker: TrailDraftController
    let mapController: MapController

    // periphery:ignore - read only as `$detent`, the binding
    // `.presentationDetents(_:selection:)` takes.
    /// Where the card rests. It opens at the middle height, where the buttons
    /// and the address are in view, and a new selection leaves it wherever the
    /// hiker put it. State of this view rather than of the presenter, so every
    /// presentation starts from the middle again.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        Group {
            if let selection = maker.selection,
               let card = TrailPlaceCard(
                   selection,
                   in: maker.draft,
                   droppedPin: maker.droppedPin,
                   photos: maker.photos.photos
               ) {
                TrailPlaceCardView(
                    maker: maker, card: card, mapController: mapController, allowsScrolling: detent == .large
                )
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
    let mapController: MapController
    let allowsScrolling: Bool

    /// The address MapKit found, `nil` until it answers and for a spot it
    /// cannot place. Asked once per coordinate.
    @State private var address: String?

    /// Room between the grabber and the title, as the map sheet leaves above
    /// its search field.
    private static let topPadding: CGFloat = 20

    /// Short detents still resize on a drag. At the tallest one, wrapped
    /// actions and accessibility text can scroll to their location rows.
    var body: some View {
        PlaceCardScroll(selection: card, allowsScrolling: allowsScrolling) {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                if let photo = card.photo {
                    TrailDraftPhotoHeader(photo: photo, gallery: { maker.photos.photos }, mapController: mapController)
                }
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
        }
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
        TrailPlaceActions {
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
            // A photograph is not the maker's to remove: the *Photos* chip
            // is what takes them off the map.
            if case .addStop = card.primary, card.photo == nil { removeButton }
        }
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
        .accessibilityIdentifier("trail-place-share")
    }

    private var shareMessage: String {
        [card.title, address, TrailPlaceCoordinates.text(card.coordinate)]
            .compacted()
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
        .accessibilityIdentifier(identifier)
    }
}
