//
//  TileAttributionView.swift
//  OpenHikes
//
//  Draws a tile source's credits with each credited party linked to its
//  licence.
//
//  Built from one `AttributedString` rather than an `HStack` of `Link`s so the
//  credits wrap like the sentence they are. Stadia's three parties do not fit
//  one line at larger Dynamic Type sizes, and a row of links would either
//  clip them or push them off-screen — which is the one thing every provider
//  here forbids outright.
//

import SwiftUI

struct TileAttributionView: View {
    let attribution: TileAttribution

    @Environment(\.openURL) private var openURL

    var body: some View {
        Text(attributedCredits)
            // The links inherit this; without it they render in the footer's
            // secondary grey and read as plain text.
            .tint(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
            // One element rather than a node per link. Each inline link is
            // its own run of caption text — 16pt tall — and Switch Control and
            // Voice Control aim at nodes, so a link node is a target nobody
            // can hit; the audit says so. Combined, the line is one target of
            // at least the minimum size, and each licence stays reachable as
            // a named action. It sat below the fold in Settings until the map
            // choice became one row of cards, which is when the audit saw it.
            .frame(minHeight: AccessibilityMetrics.minimumTapTarget, alignment: .leading)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(attribution.plainText)
            .accessibilityActions {
                ForEach(attribution.credits.filter { $0.url != nil }) { credit in
                    Button(credit.title) {
                        if let url = credit.url { openURL(url) }
                    }
                }
            }
            .accessibilityIdentifier("tile-attribution")
    }

    /// The credits as one run of text, with each party's title carrying its
    /// licence link. Tapping one hands the URL to the environment's
    /// `openURL`, which sends an `https` link to the user's browser.
    private var attributedCredits: AttributedString {
        var result = AttributedString()
        for (index, credit) in attribution.credits.enumerated() {
            if index > 0 {
                result += AttributedString(", ")
            }
            result += AttributedString("\(credit.prefix) ")

            var title = AttributedString(credit.title)
            if let url = credit.url {
                title.link = url
                // Underlined as well as tinted: colour alone is not an
                // affordance for a user who cannot distinguish it, and these
                // links are a term of use rather than a nicety.
                title.underlineStyle = .single
            }
            result += title
        }
        return result
    }
}

#Preview("Attribution") {
    Form {
        Section {
            // Verbatim for the same reason as SettingsView's DEBUG line:
            // Xcode's catalog sync skips previews and deleted the key.
            Text(verbatim: "Map")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(TileProvider.all) { provider in
                    TileAttributionView(attribution: provider.attribution)
                }
            }
        }
    }
}
