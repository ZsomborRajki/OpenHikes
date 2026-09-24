//
//  CommunityHikeRow.swift
//  OpenHikes
//
//  One published hike, in the search results.
//
//  Drawn to ``HikeRow``'s contract rather than merely to look like it: one
//  accessibility element with one label, the identifier on the leaf, and
//  everything decorative hidden. `AccessibilityUITests` and
//  `AccessibilityLabelUITests` enforce that for every composite row in the
//  app, and a new one is not an exception.
//
//  What it says that a local row does not is who walked it and whether it is
//  already in the library — the two things that decide whether the hiker
//  taps it.
//

import SwiftUI

struct CommunityHikeRow: View {
    let listing: CommunityListing
    /// True when this hike has already been imported. Drawn rather than
    /// hidden: a hiker who imported a trail last week and meets it again in
    /// a search is better served by "Saved" than by an import that silently
    /// does nothing.
    var isImported: Bool

    var body: some View {
        TrailListRow(
            title: listing.title,
            // The listing's colour, which is what ``HikeRow`` does with its own
            // status capsule: the badge belongs to the row it is in, and a row
            // whose circle and capsule disagree reads as two things.
            badge: isImported ? TrailListRow.Badge(title: "Saved", tint: listing.tint) : nil,
            subtitle: subtitle,
            identifier: "community-hike-row"
        ) {
            // A different glyph for a curated route, because the two rows are
            // different things and the badge alone is easy to miss at a
            // glance: a signpost for a waymarked trail nobody walked yet, and
            // a walker for somebody's hike. Spoken as a word rather than a
            // picture in ``subtitle``, which is why the glyph itself is
            // hidden.
            TrailListRowGlyph(
                systemName: listing.isCurated ? "signpost.right" : "figure.hiking",
                tint: listing.tint
            )
        }
    }

    /// "5.2 km · by Anna · 3 photos", or "5.2 km · Loop · Red waymark 411",
    /// with the parts that have nothing to say left out rather than rendered
    /// empty.
    ///
    /// The author is prefixed in the string rather than given its own line
    /// because the row is one spoken element either way, and "by Anna" is how
    /// a person reads a credit — "Anna" alone next to a distance is a second
    /// place name.
    ///
    /// A curated route's two extra parts are chosen for what a hiker decides
    /// on rather than for what OpenStreetMap happens to carry most of: whether
    /// they end up back at the car, and what to follow on the ground. Both are
    /// short enough to sit inside the one line the row spends, which is why
    /// the rest of what a route knows — its maintainer, its two ends, its
    /// website — waits for the screen that has room for it.
    private var subtitle: String {
        // The distance leads when there is one, and is simply absent when
        // there is not: a curated row whose line Overpass refused still has a
        // name, a shape and a waymark to decide on, and *0 m* beside them
        // would be the one part of the row that is false. See
        // ``CommunityListing/drawnDistanceMeters``.
        var parts: [String] = []
        if let metres = listing.drawnDistanceMeters {
            parts.append(
                Measurement(value: metres, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
            )
        }
        if !listing.authorName.isEmpty {
            parts.append("by \(listing.authorName)")
        }
        if let facts = listing.curatedFacts {
            if let shape = facts.shape { parts.append(shape.displayName) }
            if let waymark = facts.waymark { parts.append(waymark.displayName) }
        }
        if listing.photoCount > 0 {
            parts.append(
                listing.photoCount == 1 ? "1 photo" : "\(listing.photoCount) photos"
            )
        }
        return parts.joined(separator: " · ")
    }
}
