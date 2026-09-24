//
//  CommunityFootnoteLabel.swift
//  OpenHikes
//

import OpenHikesData
import SwiftUI

/// One sentence with a tinted symbol beside it, at footnote size.
///
/// The Community forms say a handful of things this way and nothing else
/// does: what a person will do with what is about to be sent, how long that
/// takes, that photographs are on another device, that this hike has been
/// shared once already. They are asides rather than content — the form works
/// without reading them — which is what the size and the symbol are saying.
///
/// Written out, each one is a `Label` whose icon closure exists only to hang
/// a `foregroundStyle` on an `Image`, and the seven of them had drifted into
/// three spellings of that. The symbol and its tint are the part that
/// genuinely differs, so they are what this takes.
///
/// `Text` rather than `LocalizedStringKey`, because one of these is handed a
/// string counted at runtime — see ``CommunitySharePhotoTally`` — and the
/// rest are literals that localize on the way in either way.
struct CommunityFootnoteLabel: View {
    let text: Text
    let systemImage: String
    let tint: AnyShapeStyle
    /// Set only where a screen names this line for the accessibility tree.
    /// Naming it is also what merges the symbol into it, so the identifier
    /// resolves to the sentence rather than to a container holding two
    /// children.
    var identifier: String?

    var body: some View {
        if let identifier {
            label
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            text
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.footnote)
    }
}
