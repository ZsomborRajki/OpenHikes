//
//  WalkOfferPrompt.swift
//  OpenHikes
//
//  The offer, on the trail's detail: Start, Ignore, or Don't Ask Again.
//
//  Where the walk controls go once there is a walk, and in their shape — two
//  glass buttons in the route's tint — so the card and the controls that
//  replace it read as one place on the screen. The notification's tap lands
//  here too, which is why Don't Ask Again is on this card and not on the
//  banner: it is the one answer worth a second look before it is given.
//
//  Reads ``TrailWalkSession/offer`` and nothing else, in a view of its own so
//  that the read is not charged to ``WalkControls``' body. The offer moves
//  when the hiker reaches the trail, answers, or leaves — never per fix.
//

import SwiftUI

struct WalkOfferPrompt: View {
    /// How close the two glass buttons have to come before they merge — the
    /// walk controls' own spacing.
    private static let buttonGlassSpacing: CGFloat = 8

    let hike: Hike
    let session: TrailWalkSession
    let routeLengthMeters: Double

    var body: some View {
        switch session.offer {
        case let .asking(hikeID) where hikeID == hike.id:
            asking
        case let .available(hikeID) where hikeID == hike.id:
            // Declined, but still on the trail: the hiker can change their
            // mind without walking off the route and back onto it.
            startButton
                .tint(hike.tintOpaque)
                .frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }

    private var asking: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You're on this trail")
                    .font(.headline)
                Text("Start the hike to keep track of how much of it you walk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("walk-offer")

            GlassStack(spacing: Self.buttonGlassSpacing) {
                HStack {
                    startButton
                    Button("Ignore", systemImage: "xmark") {
                        session.ignoreOffer(hikeID: hike.id)
                    }
                    .glassButtonStyle()
                    .accessibilityIdentifier("walk-offer-ignore")
                }
            }

            Button("Don't Ask Again for This Trail") {
                session.setOffersWalks(false, for: hike)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("walk-offer-never")
        }
        .tint(hike.tintOpaque)
        .frame(maxWidth: .infinity)
    }

    /// The walk's own start, which the phase haptic in ``WalkControls``
    /// answers once the controls replace this card.
    private var startButton: some View {
        Button("Start Hike", systemImage: "play.fill") {
            session.start(hike: hike, routeLengthMeters: routeLengthMeters)
        }
        .glassButtonStyle()
        .accessibilityIdentifier("walk-offer-start")
    }
}
