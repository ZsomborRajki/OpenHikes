//
//  MapCoordinator+ActivityCapsule.swift
//  OpenHikes
//
//  Where the activity capsule stands on the map, and when — see
//  ``MapActivityCapsule`` for what it is.
//
//  At the foot of the leading column, directly above the credit line, where
//  the record button stood: the owner asked for the controls to live where
//  the red stop button was and grow from there toward the middle of the map.
//  So its leading edge is the column's, and whichever pill shares the column
//  — the maker's on the search screen, the camera's on a hike's — stands on
//  the capsule while it is up, rather than on the line. The record button
//  itself steps aside while a recording is under way, because the capsule's
//  Stop is where it was — see ``MapTrailDraftControlsView/setRecording(_:)``.
//
//  It grows no further than the tracking pill across the map, and its status
//  gives way first — see ``MapActivityCapsuleView``.
//
//  Hosted SwiftUI in a column of UIKit, for the reason the column is UIKit at
//  all: its height is a constraint the sheet drives without a SwiftUI pass —
//  see ``MapView/Coordinator/applySheetTop(on:)`` — and the capsule rides the
//  same line. What it draws is SwiftUI because it reads a recording, a walk
//  and a clock, and a hosting controller is a root of its own: nothing it
//  reads re-runs anything on the map or in the sheet.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
/// What the coordinator keeps of the capsule.
struct ActivityCapsuleParts {
    /// The hosting controller, kept because nothing else holds it: its view is
    /// a subview of the map's, and a controller let go of stops updating it.
    var controller: UIHostingController<MapActivityCapsuleView>?
    weak var host: UIView?
    weak var capsule: MapActivityCapsule?
    /// The capsule's own pair against the credit line.
    var clearance: CreditLineClearance?
    /// Whether it is offered, which is what the column stands on.
    var isUp = false
    var isObserving = false
}

extension MapView {
    /// The gap between the capsule and the tracking pill across the map,
    /// which is as near as it may grow.
    private static let activityCapsuleTrailingGap: CGFloat = 8

    /// Puts the capsule at the foot of the leading column, withdrawn until its
    /// first pass says there is something under way.
    ///
    /// Built before the two pills, whose constraints name it.
    func addActivityCapsule(
        _ activityCapsule: MapActivityCapsule,
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide,
        beside trackingPill: UIView
    ) {
        let controller = UIHostingController(rootView: MapActivityCapsuleView(capsule: activityCapsule))
        controller.sizingOptions = .intrinsicContentSize
        // The map ignores the safe area, and the capsule is placed by the
        // column's constraints; insets of its own would pad it off its line.
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        coordinator.activityCapsule.controller = controller
        coordinator.activityCapsule.capsule = activityCapsule
        let host: UIView = controller.view
        coordinator.activityCapsule.clearance = placeInCreditLineSlot(
            host,
            on: mapView,
            coordinator,
            alignedTo: guide
        )
        coordinator.activityCapsule.host = host
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(
                lessThanOrEqualTo: trackingPill.leadingAnchor,
                constant: -Self.activityCapsuleTrailingGap
            ),
        ])
        coordinator.applyCreditLineClearance()
    }
}

extension MapView.Coordinator {
    /// Observes what the capsule stands for and fades it in or out, then
    /// re-registers — the arrangement every observation on this map uses, so
    /// a recording starting or a screen being pushed re-renders nothing here.
    ///
    /// Idempotent, as every registration here is.
    func observeActivityCapsule(_ capsule: MapActivityCapsule) {
        guard !activityCapsule.isObserving else { return }
        activityCapsule.isObserving = true
        trackActivityCapsule(capsule)
    }

    private func trackActivityCapsule(_ capsule: MapActivityCapsule) {
        applyActivityCapsuleVisibility(capsule, animated: activityCapsule.host?.window != nil)
        reobserving(self, capsule) {
            _ = capsule.activity
        } onChange: { coordinator, model in
            coordinator.trackActivityCapsule(model)
        }
    }

    private func applyActivityCapsuleVisibility(_ capsule: MapActivityCapsule, animated: Bool) {
        guard let host = activityCapsule.host else { return }
        let visible = capsule.activity != nil
        // Out of VoiceOver's and the tests' way at once rather than once the
        // fade is over: its Stop and the bar's carry one name, and only one is
        // ever the one meant.
        host.accessibilityElementsHidden = !visible
        if visible != activityCapsule.isUp {
            activityCapsule.isUp = visible
            // The pills step up onto it, or back down onto the line, as it
            // comes and goes.
            applyCreditLineClearance()
            applyJunctionButtonPlacement()
            if animated, let superview = host.superview {
                UIView.animate(withDuration: UIView.mapControlFadeDuration) {
                    superview.layoutIfNeeded()
                }
            }
        }
        host.fadeMapControl(
            visible: visible,
            restingAlpha: photoControlsSheetAlpha,
            animated: animated
        ) { [weak capsule] in
            capsule?.activity == nil
        }
    }

    /// Applies the sheet's fade, which the capsule shares with the column it
    /// stands at the foot of.
    func applyActivityCapsuleAlpha(_ alpha: CGFloat) {
        guard let host = activityCapsule.host,
              activityCapsule.isUp,
              host.alpha != alpha
        else { return }
        host.alpha = alpha
    }
}
#endif
