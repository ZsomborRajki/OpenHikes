//
//  MapGlassPill.swift
//  OpenHikes
//
//  What the map's glyph pills are made of: capsules of glass, one per button,
//  stacked in a container that merges them into one shape.
//
//  The camera pill and the trail maker's pill each built these for
//  themselves — the same button, the same capsule, the same container and
//  stack, and the same three figures — and one of them already reached into
//  the other for the fourth. They sit in one slot and take turns in it, so a
//  point of difference between them is a slot that changes size as it changes
//  hands. What each pill owns is which buttons it offers and what they do.
//

#if os(iOS)
import UIKit

enum MapGlassPill {
    /// The height every floating control on this map shares, so they line up
    /// across it rather than merely sitting near each other. The tracking
    /// button's capsule takes its size from here too — see
    /// ``MapView/makeTrackingButton(for:_:)``.
    static let controlSize: CGFloat = 44
    /// Over the 4pt gap between the buttons, so their glass merges into one
    /// shape at rest while each button stays a target of its own — the
    /// opposite of ``ActionTileMetrics/glassSpacing``, which keeps the sheet's
    /// tiles apart until their row tightens.
    private static let glassMergeSpacing: CGFloat = 10
    private static let buttonSpacing: CGFloat = 4
    private static let symbolPointSize: CGFloat = 17

    /// A glyph at the size and weight the pills draw every glyph at.
    static func symbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: symbolPointSize,
                weight: .medium
            )
        )
    }

    /// One glass capsule with a glyph-only button inside it.
    ///
    /// The button is sized to ``AccessibilityMetrics/minimumTapTarget`` rather
    /// than to its symbol, and carries a spoken name of its own: a glyph is
    /// not a label, and `performAccessibilityAudit` measures both — the same
    /// rule ``minimumTapTarget()`` and the explicit `accessibilityLabel`s
    /// enforce on the SwiftUI side.
    ///
    /// Both halves are handed back, for a pill that re-dresses a button in
    /// place — see ``MapTrailDraftControlsView/setRecording(_:)``.
    static func button(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> (glass: UIVisualEffectView, button: UIButton) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = Self.symbol(symbol)
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { _ in action() }
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier

        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .capsule()
        glass.contentView.addSubview(button)

        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: controlSize),
            glass.heightAnchor.constraint(equalToConstant: controlSize),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
        return (glass, button)
    }

    /// Stacks `capsules` top to bottom in one glass container that fills
    /// `host`.
    ///
    /// Grouped the way iOS groups bar items: a `UIGlassContainerEffect`
    /// renders every glass shape in one pass and merges them as they come
    /// close, so they read as one pill with seams rather than as floating
    /// circles. A hidden capsule leaves the stack, so the pill is only as tall
    /// as what it offers.
    static func install(_ capsules: [UIView], in host: UIView) {
        let container = UIVisualEffectView(
            effect: {
                let effect = UIGlassContainerEffect()
                effect.spacing = glassMergeSpacing
                return effect
            }()
        )
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: capsules)
        stack.axis = .vertical
        stack.spacing = buttonSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(container)
        container.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor),
        ])
    }
}
#endif
