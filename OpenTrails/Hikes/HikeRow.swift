//
//  HikeRow.swift
//  OpenTrails
//
//  A single hike row, used both in the Hikes list and in search suggestions.
//

import SwiftUI

struct HikeRow: View {
    struct Status {
        let title: String
        let tint: Color
    }

    let hike: Hike
    var isSelected: Bool = false
    var status: Status? = nil

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
                HStack(spacing: 6) {
                    if let status {
                        Text(status.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(status.tint.opacity(0.12), in: Capsule())
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
        }
    }
}
