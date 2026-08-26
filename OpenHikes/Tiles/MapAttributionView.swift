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
//  — see ``MapPhotoControlsView``. This has to ride the sheet's top edge, and
//  that edge is reported by ``SheetMetrics`` at display rate throughout a drag.
//  Reading it from a SwiftUI body would re-render the map's whole ancestry on
//  every frame of that drag; as a subview it takes the same driven constant
//  ``MapView/Coordinator/applySheetTop(on:)`` already computes for the other
//  two controls.
//
//  One tap target rather than one per credit. A provider can require three
//  (Stadia credits itself, OpenMapTiles and OpenStreetMap), and three
//  independent links inside a line of caption-sized text is neither a
//  comfortable touch target nor a comprehensible VoiceOver element. A single
//  button opens the one link when there is one, and offers a menu of them when
//  there are several.
//

import Foundation
#if canImport(UIKit)
import UIKit

/// The attribution line that hugs the sheet's top edge.
///
/// Rebuilt only when the provider changes — ``update(with:)`` returns early
/// otherwise, so the sheet-driven repositioning never touches the text.
final class MapAttributionView: UIView {
    /// Small, but still Dynamic Type: this is a legal notice, and one that
    /// cannot be read is not one that has been given.
    private static let font = UIFont.preferredFont(forTextStyle: .caption2)
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 4

    private let button = UIButton(type: .system)
    private let label = UILabel()
    private var attribution: TileAttribution?
    private let openURL: (URL) -> Void

    /// `openURL` is injected so a test can watch which licence a tap reaches
    /// without opening Safari on the simulator.
    init(openURL: @escaping (URL) -> Void = { url in UIApplication.shared.open(url) }) {
        self.openURL = openURL
        super.init(frame: .zero)
        addGlassBackedButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapAttributionView is created in code, not from a nib")
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
        label.text = attribution.plainText
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

    /// A glass pill sized to the text, with a full-height transparent button
    /// over it.
    ///
    /// Two views rather than a glass-backed button, because the two sizes
    /// disagree on purpose: a credit line is caption-sized text, and a control
    /// is never smaller than ``AccessibilityMetrics/minimumTapTarget`` — the
    /// same rule ``minimumTapTarget()`` applies on the SwiftUI side, and the
    /// one `performAccessibilityAudit` measures. The pill stays small; the
    /// thing a finger and the audit see is 44 points tall.
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

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),

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
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: AccessibilityMetrics.minimumTapTarget
            ),
        ])
    }
}
#endif
