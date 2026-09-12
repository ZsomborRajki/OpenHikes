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
    private static let symbolFrameSize: CGFloat = 38
    private static let badgeOpacity: Double = 0.12

    let listing: CommunityListing
    /// True when this hike has already been imported. Drawn rather than
    /// hidden: a hiker who imported a trail last week and meets it again in
    /// a search is better served by "Saved" than by an import that silently
    /// does nothing.
    var isImported: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.hiking")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.symbolFrameSize, height: Self.symbolFrameSize)
                .background(.tint, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(listing.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if isImported {
                        Text("Saved")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(Self.badgeOpacity), in: Capsule())
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("community-hike-row")
    }

    /// "5.2 km · by Anna · 3 photos", with the parts that have nothing to say
    /// left out rather than rendered empty.
    ///
    /// The author is prefixed in the string rather than given its own line
    /// because the row is one spoken element either way, and "by Anna" is how
    /// a person reads a credit — "Anna" alone next to a distance is a second
    /// place name.
    private var subtitle: String {
        var parts = [
            Measurement(value: listing.distanceMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road)),
        ]
        if !listing.authorName.isEmpty {
            parts.append("by \(listing.authorName)")
        }
        if listing.photoCount > 0 {
            parts.append(
                listing.photoCount == 1 ? "1 photo" : "\(listing.photoCount) photos"
            )
        }
        return parts.joined(separator: " · ")
    }
}
