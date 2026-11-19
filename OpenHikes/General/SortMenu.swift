//
//  SortMenu.swift
//  OpenHikes
//
//  The capsule that says what order a list is in, and offers the others: the
//  hikes list's, and *Offline Maps*'.
//
//  It states the order rather than showing a bare glyph, because the first
//  question a sorted list raises is "why is that one at the top", and the
//  answer belongs on screen next to it. Apple's sort glyph leads it, in the
//  glass the controls beside it are drawn in.
//
//  A change of order is felt where the list says so, with a
//  `sensoryFeedback` on this view rather than inside it: a menu's content is
//  built into a platform menu and torn down the instant a row is tapped, so
//  feedback declared in there has no view left to fire from.
//

import SwiftUI

/// The capsule's measures, for a control drawn beside it to match.
enum SortMenuMetrics {
    static let height: CGFloat = 40
    static let horizontalPadding: CGFloat = 14
}

/// One order a ``SortMenu`` offers.
struct SortMenuOption<Value: Hashable>: Identifiable, Equatable {
    let value: Value
    /// What the menu calls it.
    let title: String
    let symbol: String

    var id: Value { value }
}

struct SortMenu<Value: Hashable>: View {
    let options: [SortMenuOption<Value>]
    /// The order in force, or `nil` where it is none of ``options``, which
    /// ticks nothing and so leaves every entry a change.
    @Binding var selection: Value?
    /// What the capsule says: the order in force.
    let title: String
    /// What the control is, spoken: *Sort hikes*.
    let label: LocalizedStringResource
    /// The order in force as it is spoken, where that is not ``title``.
    var value: String?
    let identifier: String

    var body: some View {
        Menu {
            Picker("Order", selection: $selection) {
                ForEach(options) { option in
                    Label(option.title, systemImage: option.symbol)
                        .tag(Value?.some(option.value))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, SortMenuMetrics.horizontalPadding)
            .frame(height: SortMenuMetrics.height)
            .glassSurface(.regular.interactive(), in: .capsule)
            .minimumTapTarget()
        }
        .accessibilityLabel(Text(label))
        .accessibilityValue(value ?? title)
        .accessibilityIdentifier(identifier)
    }
}
