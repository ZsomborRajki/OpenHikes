//
//  PlaceSearchRow.swift
//  OpenHikes
//
//  One row of a place search, the way Apple Maps draws one: a glyph, the
//  name, and the address or the line that says where it is under it.
//
//  The map sheet's search and the trail maker's stop search each drew this
//  for a completion, and the stop search drew it a second time for a recent
//  pick — three copies that differed in the glyph's size and, on the stop
//  search, a spinner while a tapped suggestion resolves. The two rows that
//  are the list's own actions rather than results — *My Location* and
//  *Search Maps for "…"* — were a fourth and fifth, and differ only in the
//  glyph's colour and in dimming while they cannot be used.
//

import SwiftUI

struct PlaceSearchRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    /// The address, which is the reason these lists are Apple's completer's
    /// rather than lists of bare names. Not drawn when it is empty.
    let subtitle: String
    var glyphFont: Font = .title2
    /// Secondary for a result; the tint for an action of the list's own once
    /// it can be taken.
    var glyphStyle = AnyShapeStyle(.secondary)
    /// Secondary for a row that cannot be used yet, alongside its glyph.
    var titleStyle = HierarchicalShapeStyle.primary
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(glyphFont)
                .foregroundStyle(glyphStyle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(titleStyle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .contentShape(.rect)
        // One element rather than three, the rule every composite row here
        // follows — see ``HikeRow``.
        .accessibilityElement(children: .combine)
    }
}

extension PlaceSearchRow where Accessory == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String,
        glyphFont: Font = .title2,
        glyphStyle: AnyShapeStyle = AnyShapeStyle(.secondary),
        titleStyle: HierarchicalShapeStyle = .primary
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            glyphFont: glyphFont,
            glyphStyle: glyphStyle,
            titleStyle: titleStyle
        ) {
            EmptyView()
        }
    }
}
