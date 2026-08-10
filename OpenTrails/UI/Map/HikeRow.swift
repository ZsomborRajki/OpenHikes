//
//  HikeRow.swift
//  OpenTrails
//
//  A single hike row, used both in the Hikes list and in search suggestions.
//

import SwiftUI

struct HikeRow: View {
    let hike: Hike
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hike.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(hike.tintOpaque, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(hike.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(hike.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(hike.tintOpaque) : AnyShapeStyle(.tertiary))
        }
    }
}
