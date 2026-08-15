//
//  HikeRow.swift
//  OpenHikes
//
//  A single hike row, used both in the Hikes list and in search suggestions.
//

import SwiftUI

struct HikeRow: View {
    private static let symbolFrameSize: CGFloat = 38
    private static let statusBadgeOpacity: Double = 0.12

    struct Status {
        let title: String
        let tint: Color
    }

    let hike: Hike
    var isSelected: Bool = false
    var status: Status?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hike.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.symbolFrameSize, height: Self.symbolFrameSize)
                .background(hike.tintOpaque, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(hike.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let status {
                        Text(status.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(status.tint.opacity(Self.statusBadgeOpacity), in: Capsule())
                    }
                    Text(hike.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(hike.tintOpaque) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
        }
        // One element rather than four: the row is a single tap target, so
        // stepping through a symbol, a badge and a chevron to reach the
        // subtitle is three stops that say nothing. The title leads, which is
        // also what UI automation matches a row by.
        .accessibilityElement(children: .combine)
        // Being the drawn route is otherwise carried only by the tinted
        // chevron and the tinted row background — colour alone.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("hike-row")
    }
}
