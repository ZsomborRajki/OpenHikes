//
//  CommunityHikeView+Curated.swift
//  OpenHikes
//
//  The two sections a curated route has and a published hike does not.
//
//  Split from `CommunityHikeView.swift` for length alone — that file was over
//  SwiftLint's ceiling the moment these arrived — which is why these are
//  `internal` rather than `private`: `private` is file-scoped in Swift, and
//  these two files are one type. The same arrangement
//  `CloudKitCommunityTransport+Reviewing.swift` is in, for the same reason.
//
//  What is here is everything that follows from a route nobody published: the
//  facts that stand where an author and a strip of photographs would be, and
//  the credit that has to be *linked* rather than merely present.
//

import OpenHikesData
import SwiftUI

extension CommunityHikeView {
    /// What the signpost at the trailhead says, for a route nobody published.
    ///
    /// Above *Surface* and *Difficulty* rather than below, because those two
    /// are measured *from* OpenStreetMap and these are quoted *from* it: the
    /// waymark and the two ends are how a hiker recognises this path on the
    /// ground, and they are the first thing they would look for. Absent when
    /// there is nothing in it, which is the rule every section on this screen
    /// follows — a region tagged by one mapper on one evening draws no rows
    /// rather than a heading over blanks.
    @ViewBuilder var trailFactsSection: some View {
        if let facts = listing.curatedFacts, !facts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("On the Trail")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let waymark = facts.waymark {
                    DetailRow(label: "Waymark", value: waymark.displayName)
                }
                if let shape = facts.shape {
                    DetailRow(label: "Route", value: shape.displayName)
                }
                if let journey = facts.journey {
                    DetailRow(label: "Between", value: journey)
                }
                if let via = facts.via {
                    DetailRow(label: "Via", value: via)
                }
                if let maintainer = facts.maintainer {
                    DetailRow(label: "Maintained by", value: maintainer)
                }
                if let website = facts.website {
                    Link("More about this route", destination: website)
                        .font(.subheadline)
                        .accessibilityIdentifier("community-trail-website")
                }
            }
            .accessibilityIdentifier("community-trail-facts")
        }
    }

    /// The credit ODbL requires, with the licence reachable from it.
    ///
    /// A *link* rather than a line of text, which is the obligation rather
    /// than a nicety: ``TileAttribution`` already carries the argument for the
    /// whole app — "every provider here requires the credit to be *linked*,
    /// not merely present" — and a screen whose entire content is OSM data is
    /// not the place to make an exception. It doubles as the answer to the
    /// *Report* item this screen does not draw for a curated route: a wrong
    /// trail is fixed where it is wrong.
    @ViewBuilder var curatedAttribution: some View {
        if let relationID = listing.relationID {
            VStack(alignment: .leading, spacing: 4) {
                Text("This route is mapped by OpenStreetMap contributors.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(
                    string: "https://www.openstreetmap.org/relation/\(relationID)"
                ) {
                    Link("View or correct it on OpenStreetMap", destination: url)
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("community-osm-attribution")
        }
    }
}
