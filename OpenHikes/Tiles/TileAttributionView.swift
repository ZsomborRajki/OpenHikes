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

    var body: some View {
        Text(attributedCredits)
            // The links inherit this; without it they render in the footer's
            // secondary grey and read as plain text.
            .tint(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
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
            Text("Map")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(TileProvider.all) { provider in
                    TileAttributionView(attribution: provider.attribution)
                }
            }
        }
    }
}
