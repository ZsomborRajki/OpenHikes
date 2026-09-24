//
//  HikeRow.swift
//  OpenHikes
//
//  A single hike row, used both in the Hikes list and in search suggestions.
//

import OpenHikesData
import SwiftUI

struct HikeRow: View {
    struct Status {
        let title: String
        let tint: Color
    }

    let hike: Hike
    var isSelected: Bool = false
    var status: Status?

    var body: some View {
        TrailListRow(
            title: hike.displayTitle,
            badge: status.map { TrailListRow.Badge(title: $0.title, tint: $0.tint) },
            subtitle: hike.subtitle,
            selectionTint: isSelected ? hike.tintOpaque : nil,
            identifier: "hike-row"
        ) {
            TrailListRowGlyph(systemName: hike.symbol, tint: hike.tintOpaque)
        }
    }
}
