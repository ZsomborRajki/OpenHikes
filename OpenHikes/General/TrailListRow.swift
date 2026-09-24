//
//  TrailListRow.swift
//  OpenHikes
//
//  The row shape every list in this app uses: something round on the left, a
//  title with an optional badge and a subtitle beside it, and a chevron at the
//  end.
//
//  Three lists draw it — the library, a trail's history, and the community
//  search results — and they drew it three times. The measurements agreed by
//  hand: a 38-point leading circle, twelve points to the text, two between the
//  two lines, six between a badge and the subtitle, a capsule at 0.22 of the
//  tint, and a subheadline semibold chevron in tertiary. Any one of those
//  drifting is a list that looks like two lists.
//
//  ## One accessibility element, spoken from the row's own words
//
//  Every row here is a single tap target, so it is a single element:
//  `.combine` rather than four stops that say a symbol, a badge and a chevron
//  before reaching the subtitle. `AccessibilityUITests` and
//  `AccessibilityLabelUITests` hold every composite row in the app to that.
//
//  Combining speaks the text that is drawn, which is right where the drawn
//  text is words and wrong where it is abbreviations — "50% walked · 4m 12s"
//  is a line to read, not a sentence to hear. So a row whose subtitle is
//  shorthand passes `spokenSubtitle`, and the combined label is built from
//  that instead. It is the same treatment for all three rows and not a fourth
//  exception: what differs is the words, which is what a label is for.
//
//  The leading view is the caller's, because it is the one genuinely
//  different part — a glyph in a hike's tint, a glyph in a listing's, a
//  coverage ring — and it is hidden from VoiceOver here rather than there, so
//  a new leading view cannot forget to be.
//

import SwiftUI

/// The two figures a row and its leading view have to agree about.
///
/// Their own type because ``TrailListRow`` is generic over what it leads with,
/// and a generic type cannot hold a static stored property. The same shape
/// ``PhotoCalloutMetrics`` takes, for a version of the same reason.
enum TrailListRowMetrics {
    /// The round thing on the left, in points square.
    ///
    /// Sized and hidden by the row: it is decoration in every list that has
    /// one, and what it says is said again in words by the title or the
    /// subtitle.
    static let leadingSize: CGFloat = 38

    /// How much colour a badge carries behind its label.
    ///
    /// Raised with everything else that was drawn at an alpha chosen against
    /// the sheet's old glass — see ``Color/contentSurface``. The capsule is
    /// decoration rather than the signal (the label inside it is the tint at
    /// full strength), so this only has to be visible, not legible.
    static let badgeOpacity: Double = 0.22
}

/// One row in a list of trails or walks.
struct TrailListRow<Leading: View>: View {
    /// A word about the row's state, in the row's own colour.
    struct Badge {
        let title: String
        let tint: Color
    }

    let title: String
    var badge: Badge?
    let subtitle: String
    /// What to say instead of `subtitle`, where the drawn form is shorthand.
    var spokenSubtitle: String?
    /// Draws the chevron and the selection trait in this colour when set —
    /// being the row the map is drawing is otherwise carried by colour alone.
    var selectionTint: Color?
    let identifier: String
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: TrailListRowMetrics.leadingSize, height: TrailListRowMetrics.leadingSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let badge {
                        Text(badge.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(badge.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.tint.opacity(TrailListRowMetrics.badgeOpacity), in: Capsule())
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(spokenSubtitle ?? subtitle)
                }
                .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chevronStyle)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectionTint == nil ? [] : [.isSelected])
        .accessibilityIdentifier(identifier)
    }

    private var chevronStyle: AnyShapeStyle {
        selectionTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary)
    }
}

/// The filled circle with a symbol in it that two of the three rows lead with.
///
/// The colour is the row's own rather than the app's, so a page of results is
/// not a column of identical circles and a row matches the line and the pin
/// the map draws for the same trail.
struct TrailListRowGlyph: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint, in: Circle())
            // Decoration: what it says is said again in words by the row's
            // title or subtitle, and ``TrailListRow`` hides the leading view
            // anyway. Stated here too so the glyph is safe wherever it goes.
            .accessibilityHidden(true)
    }
}
