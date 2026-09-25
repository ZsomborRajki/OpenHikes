//
//  PlaceCardList.swift
//  OpenHikes
//
//  The grouped card an Apple Maps place card files its rows in: an optional
//  heading over one rounded list with a hairline between rows.
//
//  ``StatList`` was the first of these and is now a thin wrapper round this
//  one, so the hike detail's other groups — *About*, *On the Map* and the
//  actions at the foot of the card — sit in exactly the box the statistics
//  sit in, and a change to that box lands on every screen that draws one.
//

import SwiftUI

struct PlaceCardList<Content: View>: View {
    /// Drawn over the card as a heading. `nil` for a group whose rows say what
    /// they are — Maps' own closing list of actions has no heading.
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                // Each row after the first gets a divider ahead of it. Asked of
                // the resolved subviews, so a row a caller leaves out behind an
                // `if` leaves no hairline behind either.
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider()
                        }
                        row
                    }
                }
            }
            .placeCardGroup()
        }
    }
}

extension View {
    /// The card itself, for content that is not a list of rows — the walk's
    /// progress, which is one block rather than several.
    ///
    /// The ordinary quaternary fill rather than glass: this is content inside
    /// a glass sheet, and glass drawn on glass reads as neither — see
    /// `LiquidGlass.swift`.
    func placeCardGroup() -> some View {
        padding(.horizontal, StatCardMetrics.listPadding)
            .background {
                RoundedRectangle(cornerRadius: StatCardMetrics.listCornerRadius)
                    .fill(.quaternary)
            }
    }
}

/// One action row at the foot of a place card — *Rename*, *Edit Route* —
/// drawn in the accent colour like the rows Maps closes a card with.
///
/// The label of a `Button`, `ShareLink` or `Menu` given `.buttonStyle(.plain)`,
/// which is why it colours itself: a plain style draws no tint of its own.
struct PlaceCardActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: StatCardMetrics.rowMinimumHeight, alignment: .leading)
            // The whole row is the target, not the line of text in it — see
            // ``StatRow``.
            .contentShape(.rect)
    }
}
