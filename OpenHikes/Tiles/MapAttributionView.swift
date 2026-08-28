//
//  MapAttributionView.swift
//  OpenHikes
//
//  The credit line drawn *on the map*, which is where every provider here
//  requires it to be.
//
//  Settings shows the same credits with the same links, and that is not a
//  substitute: the OSM Foundation's tile policy asks for attribution "on the
//  map", and Stadia's terms forbid "obscuring" theirs. A credit reachable only
//  by opening a settings screen is attribution of the app, not of the map.
//
//  UIKit rather than a SwiftUI overlay, for the same reason the camera pill is
//  — see ``MapPhotoControlsView``. It belongs to the map, not to the screen
//  over it: it is positioned against the map's own geometry, and as a subview
//  it costs the root view's body nothing. The weather badge is the
//  counter-example — an overlay in that body, and one more thing that has to
//  be reasoned about every time the body changes. That the two end up stacked
//  is why ``WeatherBadge`` publishes its padding and text style: nothing joins
//  the two hierarchies, so those numbers are the whole agreement.
//
//  One tap target rather than one per credit. A provider can require three
//  (Stadia credits itself, OpenMapTiles and OpenStreetMap), and three
//  independent links inside a line of caption-sized text is neither a
//  comfortable touch target nor a comprehensible VoiceOver element. A single
//  button opens the one link when there is one, and offers a menu of them when
//  there are several.
//
//  What it draws is ``TileAttribution/compactText`` rather than the canonical
//  ``TileAttribution/plainText``. This is the one placement the licences call
//  space-constrained, so it names every required party once and drops nothing
//  but the repeated "©", "Maps ©", "Data ©" and "contributors" decoration.
//  Settings and VoiceOver keep the canonical form, and both have the room.
//

import Foundation
#if canImport(UIKit)
import UIKit

/// The attribution line, hung beneath the weather badge at the top of the map.
///
/// Rebuilt only when the provider changes — ``update(with:)`` returns early
/// otherwise, so a repeated pass over an unchanged source costs nothing.
final class MapAttributionView: UIView {
    /// Small, but still Dynamic Type: this is a legal notice, and one that
    /// cannot be read is not one that has been given.
    ///
    /// A point under `.caption2`'s own size rather than the style itself. This
    /// is incidental chrome over a map somebody is reading, and the smallest
    /// built-in text style still draws it larger than any map app draws its
    /// credit. Scaled through `UIFontMetrics` rather than fixed at
    /// ten points, so it still grows with the system's text — a notice a
    /// walker who needs larger text cannot read is not a notice.
    private static let font = UIFontMetrics(forTextStyle: .caption2)
        .scaledFont(for: .systemFont(ofSize: 10))
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 3

    private let button = UIButton(type: .system)
    private let label = UILabel()
    private var attribution: TileAttribution?
    private let openURL: (URL) -> Void

    /// `openURL` is injected so a test can watch which licence a tap reaches
    /// without opening Safari on the simulator.
    init(openURL: @escaping (URL) -> Void = { url in UIApplication.shared.open(url) }) {
        self.openURL = openURL
        super.init(frame: .zero)
        // Hidden until there is something to credit. `update(with:)` returns
        // early when the credits have not changed, and the first thing it is
        // handed can be `nil` — no source resolved yet — so a view that started
        // visible would draw an empty pill on the map and never be told to stop.
        isHidden = true
        addGlassBackedButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapAttributionView is created in code, not from a nib")
    }

    /// The tap target is taller than the pill it is centred on, and therefore
    /// taller than this view. Without this, UIKit would refuse every touch
    /// landing on that overhang: `hitTest` does not descend into a subview
    /// once its superview has said the point is outside itself.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        button.frame.contains(point) || super.point(inside: point, with: event)
    }

    /// Shows `attribution`'s credits, or hides the view when there is nothing
    /// the app is responsible for crediting — the system base map, whose one
    /// credit MapKit draws its own **Legal** link for.
    func update(with attribution: TileAttribution?) {
        guard attribution != self.attribution else { return }
        self.attribution = attribution

        guard let attribution, attribution.hasLinks else {
            isHidden = true
            return
        }
        isHidden = false
        // Compact on the map, canonical to VoiceOver: the line is the
        // space-constrained placement, a spoken label is not, and dropping a
        // word from what is read aloud would buy nothing.
        label.text = attribution.compactText
        button.accessibilityLabel = attribution.plainText
        applyAction(for: attribution)
    }

    /// One link opens directly; several become a menu. A menu in front of a
    /// single destination is a tap spent on nothing.
    private func applyAction(for attribution: TileAttribution) {
        let links = attribution.credits.compactMap { credit in
            credit.url.map { (title: credit.title, url: $0) }
        }
        guard links.count > 1 else {
            button.menu = nil
            button.showsMenuAsPrimaryAction = false
            let url = links.first?.url
            button.accessibilityHint = String(localized: "Opens the map licence in your browser")
            button.removeTarget(nil, action: nil, for: .primaryActionTriggered)
            button.addAction(
                UIAction { [weak self] _ in
                    guard let self, let url else { return }
                    openURL(url)
                },
                for: .primaryActionTriggered
            )
            return
        }
        button.accessibilityHint = String(localized: "Shows the map licences you can open")
        button.menu = UIMenu(
            children: links.map { link in
                UIAction(title: link.title) { [weak self] _ in
                    self?.openURL(link.url)
                }
            }
        )
        button.showsMenuAsPrimaryAction = true
    }

    /// A glass pill sized to the text, with a taller transparent button
    /// centred over it.
    ///
    /// Two views rather than a glass-backed button, because the two sizes
    /// disagree on purpose: a credit line is caption-sized text, and a control
    /// is never smaller than ``AccessibilityMetrics/minimumTapTarget`` — the
    /// same rule ``minimumTapTarget()`` applies on the SwiftUI side, and the
    /// one `performAccessibilityAudit` measures. The pill stays small; the
    /// thing a finger and the audit see is 44 points tall.
    ///
    /// The button overhangs this view rather than stretching it, which is what
    /// keeps the credit line the height of the text it draws while the thing a
    /// finger lands on stays 44 points tall. Sized to the button, the line
    /// would reserve a block of empty space at the top of the map far taller
    /// than the words in it. ``point(inside:with:)`` is what keeps the
    /// overhang tappable.
    private func addGlassBackedButton() {
        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .capsule()
        // The button above it is the control; a background that swallowed
        // touches would leave the tap target it is centred in unreachable.
        glass.isUserInteractionEnabled = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.font
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        // The button carries the spoken name; a second element reading the
        // same words is one more stop with nothing behind it.
        label.isAccessibilityElement = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "map-attribution"

        addSubview(glass)
        glass.contentView.addSubview(label)
        addSubview(button)

        // Taller than the pill at ordinary text sizes, and exactly the pill
        // once Dynamic Type has grown it past 44 points. Low priority so the
        // minimum below always wins.
        let matchesPill = button.heightAnchor.constraint(equalTo: glass.heightAnchor)
        matchesPill.priority = .defaultLow

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.leadingAnchor.constraint(
                equalTo: glass.contentView.leadingAnchor,
                constant: Self.horizontalPadding
            ),
            label.trailingAnchor.constraint(
                equalTo: glass.contentView.trailingAnchor,
                constant: -Self.horizontalPadding
            ),
            label.topAnchor.constraint(
                equalTo: glass.contentView.topAnchor,
                constant: Self.verticalPadding
            ),
            label.bottomAnchor.constraint(
                equalTo: glass.contentView.bottomAnchor,
                constant: -Self.verticalPadding
            ),

            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            matchesPill,
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: AccessibilityMetrics.minimumTapTarget
            ),
        ])
    }
}
#endif
