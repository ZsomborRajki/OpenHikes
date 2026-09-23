//
//  FollowToggles.swift
//  OpenHikes
//
//  Follow This Trail, and the switch under it that decides whether being on
//  the trail asks to start a hike.
//
//  One view for the pair because the second only means anything while the
//  first is on: following is what lets a match ask at all — see
//  ``WalkOffer`` — so with it off the second is disabled rather than left
//  pretending to govern something. Its own file rather than two members of
//  ``HikeDetailView``, which sits at the linter's length limit.
//

import SwiftUI

struct FollowToggles: View {
    let hike: Hike
    let session: TrailWalkSession

    var body: some View {
        // Shows the live position and lets a matched fix offer a walk. The
        // walk's own controls pause or end one already under way; the
        // detail's `onChange(of: hike.autoFollowEnabled)` does the rest.
        Toggle(isOn: Binding(
            get: { hike.autoFollowEnabled },
            set: { hike.autoFollowEnabled = $0 }
        )) {
            Label("Follow This Trail", systemImage: "location.fill.viewfinder")
        }
        .disabled(hike.pointCount < 2)

        // The way back from Don't Ask Again.
        Toggle(isOn: Binding(
            get: { hike.walkOffersEnabled },
            set: { session.setOffersWalks($0, for: hike) }
        )) {
            Label("Ask to Start Hike", systemImage: "bell.badge")
        }
        .disabled(!hike.autoFollowEnabled || hike.pointCount < 2)
        .accessibilityIdentifier("walk-offer-toggle")
    }
}
