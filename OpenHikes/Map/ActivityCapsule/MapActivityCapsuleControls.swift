//
//  MapActivityCapsuleControls.swift
//  OpenHikes
//
//  The map's activity capsule as the map draws it: Stop or End, Pause or
//  Resume, and the status, three pieces of glass in a row that merge into
//  one — see ``MapActivityCapsule`` for what it is.
//
//  UIKit, as the pills beside it are, and for one more reason than theirs:
//  MapKit builds the map's accessibility by walking the UIKit views on it,
//  and walks straight past SwiftUI hosted there — measured, a capsule drawn
//  in SwiftUI was absent from the tree, buttons and all, as the first-run
//  tips' cards were (see ``MapTipCardView``). So each piece is a `UIButton`
//  with a name of its own, and only the status's words are SwiftUI — see
//  ``MapActivityCapsuleStatus`` — inside a button that says them itself.
//

import Foundation

#if os(iOS)
import SwiftUI
import UIKit

final class MapActivityCapsuleControlsView: UIView {
    private static let statusPadding: CGFloat = 14

    private let capsule: MapActivityCapsule
    private(set) var stopButton: UIButton?
    private var stopGlass: UIView?
    private(set) var pauseButton: UIButton?
    private var pauseGlass: UIView?
    private(set) var statusButton: UIButton?
    /// Kept because nothing else holds it: its view is a subview of the
    /// status button, and a controller let go of stops updating it.
    private var statusController: UIHostingController<MapActivityCapsuleStatus>?
    /// What ``apply(_:)`` last drew, so a repeat is free.
    private(set) var controls: MapActivityCapsule.Controls?

    init(capsule: MapActivityCapsule) {
        self.capsule = capsule
        super.init(frame: .zero)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapActivityCapsuleControlsView is created in code only")
    }

    /// Shows the buttons `controls` offers, in its activity's words. Left as
    /// it was for `nil`, so a capsule fading out keeps the buttons it had.
    func apply(_ controls: MapActivityCapsule.Controls?) {
        guard let controls, controls != self.controls else { return }
        self.controls = controls
        let isWalk = if case .walk = controls.activity { true } else { false }
        stopGlass?.isHidden = !controls.offersStop
        stopButton?.accessibilityLabel = isWalk
            ? String(localized: "End and Save Hike")
            : String(localized: "Stop")
        pauseGlass?.isHidden = controls.pause == nil
        if let pause = controls.pause {
            pauseButton?.configuration?.image = MapGlassPill.symbol(pause == .pause ? "pause.fill" : "play.fill")
            pauseButton?.accessibilityLabel = switch (pause, isWalk) {
            case (.pause, false): String(localized: "Pause")
            case (.resume, false): String(localized: "Resume")
            case (.pause, true): String(localized: "Pause Hike")
            case (.resume, true): String(localized: "Resume Hike")
            }
        }
        // As ``MapPhotoControlsView/setAddPlaceVisible(_:)`` says: the stack
        // re-arranges at once, and the map has to be told to lay out.
        superview?.setNeedsLayout()
    }

    private func buildHierarchy() {
        let stop = MapGlassPill.button(
            symbol: "stop.fill",
            label: String(localized: "Stop"),
            identifier: "activity-capsule-stop"
        ) { [capsule] in capsule.stop() }
        // White on red glass, as the record button was while a recording was
        // under way: a red glyph on red glass is a glyph nobody can see.
        stop.button.configuration?.baseForegroundColor = .white
        MapGlass.tint(stop.glass, with: .systemRed)
        stopButton = stop.button
        stopGlass = stop.glass

        let pause = MapGlassPill.button(
            symbol: "pause.fill",
            label: String(localized: "Pause"),
            identifier: "activity-capsule-pause"
        ) { [capsule] in capsule.togglePause() }
        pause.button.configuration?.baseForegroundColor = .label
        pauseButton = pause.button
        pauseGlass = pause.glass

        MapGlassPill.install([stop.glass, pause.glass, makeStatus()], in: self, axis: .horizontal)
    }

    /// The status: a capsule of glass holding a button the width of its words.
    private func makeStatus() -> UIView {
        let button = MapActivityCapsuleStatusButton(capsule: capsule)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [capsule] _ in capsule.openActivity() }, for: .primaryActionTriggered)
        statusButton = button

        let controller = UIHostingController(rootView: MapActivityCapsuleStatus(capsule: capsule))
        controller.sizingOptions = .intrinsicContentSize
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        // The button takes the tap and says the words.
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // The words give way only to the row's one required limit, the
        // tracking pill across the map: Stop and Pause are fixed squares, so
        // the words are what shrinks there. Above the button's own hugging,
        // which they used to tie with at the default low priority: measured,
        // the tie went to the button and squeezed the status to its clock.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controller.view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        statusController = controller
        button.addSubview(controller.view)

        let glass = MapGlass.view(.capsule)
        glass.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            glass.heightAnchor.constraint(equalToConstant: MapGlassPill.controlSize),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.statusPadding),
            controller.view.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.statusPadding),
            controller.view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        return glass
    }
}

/// The status, saying what it draws: the phase as its name and the figures
/// as its value, both read at the moment VoiceOver asks, because the clock
/// on screen ticks by itself where UIKit cannot see it.
private final class MapActivityCapsuleStatusButton: UIButton {
    private let capsule: MapActivityCapsule

    init(capsule: MapActivityCapsule) {
        self.capsule = capsule
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "activity-capsule-status"
        accessibilityHint = String(localized: "Goes back to the hike.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapActivityCapsuleStatusButton is created in code only")
    }

    override var accessibilityLabel: String? {
        get { capsule.statusTitle }
        set { /* read from the capsule */ }
    }

    override var accessibilityValue: String? {
        get { capsule.statusFigures }
        set { /* read from the capsule */ }
    }
}
#endif
