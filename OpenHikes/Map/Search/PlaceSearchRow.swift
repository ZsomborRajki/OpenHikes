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
//  search, a spinner while a tapped suggestion resolves.
//

import SwiftUI

struct PlaceSearchRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    /// The address, which is the reason these lists are Apple's completer's
    /// rather than lists of bare names. Not drawn when it is empty.
    let subtitle: String
    var glyphFont: Font = .title2
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(glyphFont)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
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
    init(systemImage: String, title: String, subtitle: String, glyphFont: Font = .title2) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, glyphFont: glyphFont) {
            EmptyView()
        }
    }
}
