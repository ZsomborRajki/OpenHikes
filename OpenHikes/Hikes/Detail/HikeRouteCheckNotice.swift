//
//  HikeRouteCheckNotice.swift
//  OpenHikes
//
//  What a hike's screen says about a line that still asks for a look, and the
//  way to *Edit Route*, where the look is taken.
//
//  A recording used to stop in a review before it was saved, whenever trail
//  matching had moved its line or found it ambiguous. It is saved at once
//  now, and this is where the question went: a row on the saved hike, there
//  until the hiker has answered, said the line is right, or saved an edit —
//  on whichever of their devices they do it, because what it reads is
//  mirrored with the hike (``RouteEdit``).
//
//  It says two things, either or both:
//
//  - **Sections to check**: where the line was moved onto a mapped trail,
//    could have been more than one route, or crosses ground nothing was
//    recorded over — see ``RouteAssembly``.
//  - **Not on foot**: an end of the recording that was a drive or a ride,
//    which is what a recording left running on the way home looks like — see
//    ``RouteCarriedEnds``.
//
//  A view of its own so the hike's screen reads none of this: the column is
//  decoded here, on the passes this view makes, and those are the ones a
//  write to the column causes.
//

import OpenHikesData
import SwiftUI

struct HikeRouteCheckNotice: View {
    let hike: Hike

    var body: some View {
        // The columns first: most hikes have neither, and a body pass should
        // not decode JSON to learn that. A drawn trail is edited in the maker
        // and has nothing here.
        if hike.drawnRouteData == nil, hike.routeEditData != nil, let edit = hike.routeEdit, edit.isOwedALook {
            NavigationLink(value: SheetRoute.routeEdit(hike)) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check Route")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        ForEach(RouteCheckWording.noticeLines(for: edit), id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, StatCardMetrics.listPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .placeCardGroup()
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hike-route-check")
        }
    }
}
