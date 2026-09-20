//
//  PhotoStepButton.swift
//  OpenHikes
//
//  The circular chevron that moves a photo gallery on by one.
//
//  Two galleries draw a pair of them — ``HikePhotoViewer`` for the hiker's own
//  pictures and ``CommunityPhotoViewer`` for a stranger's — and the button was
//  written out identically in both, down to the weight of the glyph and the
//  order of the four modifiers. So was the *pair*: which way each chevron
//  points, what it is called, and the rule that a gallery of one photograph
//  shows neither. ``PhotoStepControls`` is that half. What differed was only
//  how each screen works out whether there is anything to step to, which is
//  the caller's question about its own list and stays there.
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

/// Both steps of a photo gallery, and the rule about when there are none.
///
/// The chevrons and their labels are fixed here rather than passed: a gallery
/// whose *previous* button pointed right, or whose next button was called
/// something else, would be a bug rather than a variation. What is passed is
/// each screen's own answer about its own list.
///
/// Whether there is anything to step to at all is
/// ``SwiftUI/View/photoStepVisibility(count:)``, applied by the caller rather
/// than here: one gallery puts these in a glass pill and the pill has to fade
/// with them, or a single-photograph gallery keeps an empty pill on screen.
struct PhotoStepControls: View {
    let previousIdentifier: String
    let nextIdentifier: String
    /// Whether there is a photograph this many steps away — see each viewer's
    /// `destination`.
    let hasDestination: (Int) -> Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            PhotoStepButton(
                systemImage: "chevron.left",
                label: "Previous photo",
                identifier: previousIdentifier,
                hasDestination: hasDestination(-1),
                step: { step(-1) }
            )
            PhotoStepButton(
                systemImage: "chevron.right",
                label: "Next photo",
                identifier: nextIdentifier,
                hasDestination: hasDestination(1),
                step: { step(1) }
            )
        }
    }
}

extension View {
    /// Fades a gallery's step controls away when there is nowhere to step.
    ///
    /// Opacity rather than removal, so a single-photograph gallery keeps the
    /// space and nothing beside it moves — the same reason the two buttons are
    /// disabled at the ends rather than taken away. `accessibilityHidden`
    /// because an invisible control is still reachable by label otherwise, and
    /// by label is exactly how automation reaches these.
    ///
    /// Applied by the caller, at whatever it is that has to fade: the hiker's
    /// gallery fades the pair, and the community gallery fades the glass pill
    /// around it.
    func photoStepVisibility(count: Int) -> some View {
        opacity(count > 1 ? 1 : 0)
            .accessibilityHidden(count <= 1)
    }
}
