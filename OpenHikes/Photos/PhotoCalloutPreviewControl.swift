//
//  PhotoCalloutPreviewControl.swift
//  OpenHikes
//
//  The box a photograph is drawn in inside a MapKit callout, and the glyph
//  that stands in for one that is not there yet.
//
//  ``PhotoCalloutMetrics`` already holds the four numbers the two callout
//  previews agreed on. This holds the rest of what they agreed on: the view
//  hierarchy built from those numbers, the constraints, the tap target, the
//  accessibility traits, and the placeholder glyph. Both were written out
//  twice, identically, down to the order of the constraints.
//
//  What stays in the subclasses is what ``PhotoCalloutMetrics``' header says
//  is genuinely different about them — they hold different photographs, keyed
//  differently, loaded down different paths, with different answers for a
//  picture that will not load, and different things to say to VoiceOver. None
//  of that is chrome, and none of it moves here. A subclass supplies its own
//  accessibility identifier, because the two are asserted separately, and
//  overrides ``handleTap()`` with what a tap on *its* picture means.
//

import UIKit

#if os(iOS)
/// The shared chrome of a photo pin's callout preview.
class PhotoCalloutPreviewControl: UIControl {
    /// The picture, or the glyph standing in for one.
    ///
    /// Owned here because the constraints below are what give it its size, and
    /// a subclass that held its own would be laying the box out a second time.
    let imageView = UIImageView()

    /// - Parameter accessibilityIdentifier: The name a UI test asks for this
    ///   preview by. Per subclass rather than shared: the hiker's own pictures
    ///   and a stranger's are two different things to find on one map, and the
    ///   suites that look for them assert them apart.
    init(accessibilityIdentifier: String) {
        super.init(frame: .zero)
        buildHierarchy(accessibilityIdentifier: accessibilityIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("A photo callout preview is created in code only")
    }

    /// What a tap on this preview means, which is the one thing every subclass
    /// has to answer for itself.
    ///
    /// The target is added once, below, so a subclass that forgets to override
    /// this gets a preview that does nothing rather than one that opens the
    /// wrong photograph.
    @objc func handleTap() {
        // Nothing by default. See above.
    }

    /// A glyph rather than a spinner, for the reason the gallery strip's tiles
    /// use one: a thumbnail already on disk arrives within a frame or two, and
    /// a spinner that appears and vanishes reads as a glitch.
    ///
    /// Which glyph carries the whole difference between "in a moment" and "not
    /// here at all", exactly as the strip's tiles do — so the symbol is the
    /// caller's to choose and never this method's.
    func showPlaceholder(_ symbolName: String) {
        imageView.contentMode = .center
        imageView.tintColor = .tertiaryLabel
        imageView.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: PhotoCalloutMetrics.placeholderPointSize
            )
        )
    }

    private func buildHierarchy(accessibilityIdentifier: String) {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = PhotoCalloutMetrics.cornerRadius
        layer.cornerCurve = .continuous

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        // The control answers the touch, not the picture inside it.
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PhotoCalloutMetrics.previewWidth),
            heightAnchor.constraint(equalToConstant: PhotoCalloutMetrics.previewHeight),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        // One element with a button trait: what is inside is a picture
        // VoiceOver cannot describe, so the label a subclass sets is the whole
        // of what it says.
        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
#endif
