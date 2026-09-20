//
//  CommunityOutcomeSection.swift
//  OpenHikes
//

import SwiftUI

/// The centred symbol, headline and sentence a Community form ends on.
///
/// Four screens finish this way and they arrived at it from two directions:
/// the two publishing forms through ``CommunitySentSection``, and the two
/// sheets that mail the reviewer through ``CommunityMailOutcomeSections``.
/// Each of those was already a fold of two copies — and the two folds were
/// the same eleven lines again, down to the vertical padding and the single
/// combined accessibility element.
///
/// What a form ends on is the last thing a hiker reads before putting the
/// phone away, so the four being the same size and the same shape is the
/// point rather than a coincidence worth preserving by hand.
///
/// `Text` rather than `LocalizedStringKey` for the two strings, because the
/// callers differ in a way that has to survive: the publishing forms pass
/// literals that localize, and the mail sheets pass a sentence already
/// interpolated with the noun that sheet calls its message.
struct CommunityOutcomeSection: View {
    let symbol: String
    let tint: AnyShapeStyle
    let headline: Text
    let detail: Text
    let identifier: String

    var body: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                headline
                    .font(.headline)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        }
    }
}
