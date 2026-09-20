//
//  PhotoStepButton.swift
//  OpenHikes
//
//  The circular chevron that moves a photo gallery on by one.
//
//  Two galleries draw a pair of them — ``HikePhotoViewer`` for the hiker's own
//  pictures and ``CommunityPhotoViewer`` for a stranger's — and the button was
//  written out identically in both, down to the weight of the glyph and the
//  order of the four modifiers. What differed was only how each screen works
//  out whether there is anything to step to, which is the caller's question
//  about its own list and stays there.
//
//  Reached by **label** rather than by identifier, on both screens and for the
//  same reason: each viewer carries its own identifier on the `ZStack` around
//  this, and SwiftUI pushes a container's identifier down onto every
//  descendant, smothering the leaf names inside. The identifier is still
//  passed and still set, so the two stay symmetrical and so a future layout
//  that escapes the container has one to find.
//

import SwiftUI

/// One step of a photo gallery, as a glass chevron.
struct PhotoStepButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let identifier: String
    /// Whether there is a photograph in this direction. The caller's question
    /// about its own list — see each viewer's `destination`.
    let hasDestination: Bool
    let step: () -> Void

    var body: some View {
        Button(action: step) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .minimumTapTarget()
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .disabled(!hasDestination)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
