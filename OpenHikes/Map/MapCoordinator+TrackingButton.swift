//
//  MapCoordinator+TrackingButton.swift
//  OpenHikes
//
//  The "my location" button: what it is made of, where it sits, and when it
//  gets out of the way.
//
//  MapKit gives the button no placement of its own on iOS, and this app puts a
//  persistent sheet over the bottom of the map, so the button has to ride above
//  whatever detent the sheet is resting at. It follows the sheet imperatively —
//  a drag reaches the constraint without a SwiftUI pass in between, the same
//  arrangement `observeHighlight` and `observeRouteStyle` use.
//
//  The credit line on the opposite edge rides the same arithmetic, from the
//  same call, and the camera pill rides the credit line: see
//  ``MapPhotoControlsView`` for why the pill is a UIKit subview rather than a
//  SwiftUI overlay.
//
//  It follows the sheet only as far as the middle detent, and fades out over
//  the rest of the way up. Two things had to be measured rather than assumed to
//  get there. Where the middle detent rests, because it is 43% of the way down
//  an iPhone 17 Pro and 48% down an iPhone 14 Pro Max — a spread wider than the
//  room the button needs, so any fraction is either useless or puts the button
//  behind the sheet. And how far the fade runs, which is exactly the climb the
//  button gives up by stopping, so it is finished by the point it would have
//  been forced to stop anyway.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    /// Where the sheet's top is assumed to be until it says otherwise: the
    /// compact detent, plus the room its shadow and grabber want.
    private static let sheetFallbackOffset: CGFloat = 92
    /// Gap kept between the button and whatever bounds it — the sheet below it,
    /// or the top safe area above.
    private static let trackingButtonSpacing: CGFloat = 16
    /// Used only before the button has been laid out or measured.
    private static let trackingButtonFallbackHeight: CGFloat = 44

    /// Observes `sheetMetrics.topY` and repositions the tracking button
    /// imperatively, then re-registers. Keeps sheet drags off SwiftUI's
    /// render path — the same technique as `observeHighlight`.
    func observeSheetMetrics(_ metrics: SheetMetrics, on mapView: MKMapView) {
        sheetMetrics = metrics
        applySheetTop(on: mapView)
        reobserving(self, mapView, metrics) {
            _ = metrics.topY
        } onChange: { coordinator, map, model in
            coordinator.observeSheetMetrics(model, on: map)
        }
    }

    /// Reapplies the button position only when the map's own geometry has
    /// changed (first layout, rotation, a safe-area change) — everything else
    /// `topY`-driven is already handled reactively by `observeSheetMetrics`.
    func applySheetTopIfHeightChanged(on mapView: MKMapView) {
        let geometry = (
            height: mapView.bounds.height,
            topInset: mapView.safeAreaInsets.top
        )
        guard geometry != lastAppliedGeometry else { return }
        lastAppliedGeometry = geometry
        applySheetTop(on: mapView)
    }

    /// Positions the "my location" button — and the credit line opposite it,
    /// with the camera pill stacked on top of that line — just above the
    /// sheet's top edge, and hands them over to the sheet once the sheet is
    /// expanding past them.
    ///
    /// The constraint's constant is the control's *bottom* in the map's own
    /// coordinates, and the map fills the screen, so this is one comparison
    /// between two Ys in the same space: where the sheet starts, and the
    /// highest the controls are allowed to sit.
    ///
    /// `limit` is a floor on that constant, so the controls stop climbing at
    /// the middle detent. Past that the sheet rises over the parked controls,
    /// which is what the fade is for: a control left visible behind the
    /// sheet's top curve reads as a glitch, the more so once tracking mode
    /// fills it in.
    ///
    /// Everything on this row takes the same constant and the same opacity,
    /// which is the reason the pill is a UIKit subview at all — see
    /// ``MapPhotoControlsView``.
    ///
    /// Two constraints rather than three. The camera pill has no driven
    /// constant of its own: it is constrained a fixed gap above the credit
    /// line, so writing the line's bottom moves both — see
    /// ``MapView/addPhotoControls(to:_:alignedTo:)``.
    func applySheetTop(on mapView: MKMapView) {
        guard mapView.bounds.height > 0 else { return }
        let wanted = sheetTop(in: mapView) - Self.trackingButtonSpacing
        let limit = trackingButtonLimit(in: mapView)
        let controls = max(wanted, limit)
        trackingBottomConstraint?.constant = controls
        attributionBottomConstraint?.constant = controls
        applyControlAlpha(
            encroachment: limit - wanted,
            over: fadeDistance(from: limit, in: mapView)
        )
    }

    /// Where the sheet starts, in the map's coordinates.
    ///
    /// ``SheetMetrics`` reports a global Y and the map ignores the safe area,
    /// so the two already agree. A report outside the map is refused rather
    /// than followed: the sheet is presented over this map, so a value that
    /// doesn't land on it isn't the sheet's edge but a reading taken in some
    /// other space, and the compact detent is a better guess than a button
    /// parked off screen. That is also the state on the first frames of a
    /// launch, before the sheet has reported anything.
    ///
    /// **Landscape has no sheet at all**, and that is not the same as a sheet
    /// that has not reported yet. The contents move into ``MapSidePanel``,
    /// which takes a leading edge and leaves the bottom of the map clear —
    /// and ``SheetMetrics/withdraw()`` zeroes the reading on the way, so
    /// without this the fallback above parked the whole leading-edge stack
    /// 92 points above a sheet that is not there, with nothing underneath it.
    /// The panel's own inset is what tells the two apart: it is non-zero for
    /// exactly as long as there is a panel instead of a sheet.
    private func sheetTop(in mapView: MKMapView) -> CGFloat {
        let height = mapView.bounds.height
        guard sidePanelInset == 0 else { return height - mapView.safeAreaInsets.bottom }
        let reported = sheetMetrics?.topY ?? 0
        guard reported > 0, reported <= height else { return height - Self.sheetFallbackOffset }
        return reported
    }

    /// The highest the button may sit, as the Y of its bottom edge.
    ///
    /// It rides the sheet up to the middle detent and stops there. Beyond that
    /// the sheet is on its way to covering the map, and a control that keeps
    /// climbing ahead of it — all the way into the status bar — is both
    /// distracting and pointless, since there is less and less map left to
    /// recentre. Maps stops its controls at the same place.
    ///
    /// Until the sheet has been seen resting at that detent, the only limit is
    /// the top safe area.
    private func trackingButtonLimit(in mapView: MKMapView) -> CGFloat {
        let clearOfStatusBar = clearOfStatusBar(in: mapView)
        guard let middleRestY = sheetMetrics?.middleRestY, middleRestY > 0 else { return clearOfStatusBar }
        return max(clearOfStatusBar, middleRestY - Self.trackingButtonSpacing)
    }

    /// Clear of the status bar and the Dynamic Island, measured from the map's
    /// own safe area and the controls' own height rather than from a fraction
    /// of the screen.
    private func clearOfStatusBar(in mapView: MKMapView) -> CGFloat {
        mapView.safeAreaInsets.top
            + trackingButtonHeight
            + Self.trackingButtonSpacing
    }

    /// How far the sheet travels between the button being fully visible and
    /// fully gone: exactly the climb the button gives up by stopping at the
    /// middle detent, so it has finished fading by the point it would have
    /// been forced to stop anyway.
    ///
    /// Derived rather than chosen, and never shorter than the button itself,
    /// so there is still a fade rather than a blink before the sheet's resting
    /// place has been measured.
    private func fadeDistance(from limit: CGFloat, in mapView: MKMapView) -> CGFloat {
        max(limit - clearOfStatusBar(in: mapView), trackingButtonHeight)
    }

    /// The button's own height, measured where possible.
    var trackingButtonHeight: CGFloat {
        #if canImport(UIKit)
        guard let trackingButton else { return Self.trackingButtonFallbackHeight }
        let measured = max(
            trackingButton.bounds.height,
            trackingButton.intrinsicContentSize.height
        )
        return measured > 0 ? measured : Self.trackingButtonFallbackHeight
        #else
        Self.trackingButtonFallbackHeight
        #endif
    }

    /// Fades the row out as the sheet takes its place, the way Maps does.
    ///
    /// `encroachment` is how far past them the sheet has come: at or below
    /// zero they still have their full spacing and are fully opaque. No
    /// animation of its own — this is driven by the same continuous `topY`
    /// reports that move them, which arrive at display rate throughout a drag,
    /// so the fade tracks the hand directly and an animation would only lag
    /// behind it.
    ///
    /// The credit line fades with them rather than being exempt as a legal
    /// notice would suggest. It is only ever transparent where the sheet is
    /// already drawn over that part of the map, and a credit showing through
    /// the sheet's top curve is not a credit anybody can read — it is the
    /// glitch the fade exists to prevent.
    private func applyControlAlpha(encroachment: CGFloat, over fadeDistance: CGFloat) {
        #if canImport(UIKit)
        let alpha = Self.trackingButtonAlpha(
            encroachment: encroachment,
            over: fadeDistance
        )
        if let trackingButton, trackingButton.alpha != alpha {
            trackingButton.alpha = alpha
        }
        if let attributionView, attributionView.alpha != alpha {
            attributionView.alpha = alpha
        }
        // The pill has a second reason to be hidden — there may be no hike to
        // photograph — so it takes this through the accessor that combines the
        // two rather than having it written at it directly.
        applyPhotoControlsAlpha(alpha)
        #endif
    }

    /// Full opacity until the sheet reaches the button, then linearly to
    /// nothing across the rest of the sheet's travel.
    static func trackingButtonAlpha(
        encroachment: CGFloat,
        over fadeDistance: CGFloat
    ) -> CGFloat {
        guard encroachment > 0 else { return 1 }
        guard fadeDistance > 0 else { return 0 }
        return max(0, 1 - encroachment / fadeDistance)
    }

    #if canImport(UIKit)
    /// Colours the arrow for what tracking is currently doing.
    ///
    /// The button used to be accent green at all times, which spent the one
    /// colour the app reserves for "this is on" on a control that is almost
    /// always off — and spent it against map tiles, where it could not be read
    /// (see ``MapView/makeTrackingButton(for:_:)``). Now the capsule carries
    /// the legibility and the glyph carries the state: label colour at rest,
    /// accent while the map is following the hiker.
    ///
    /// `.label` rather than a fixed grey because it is on glass, not on the
    /// map: the surface and the glyph turn over together with the appearance,
    /// so the pair stays legible whatever the tiles underneath are doing.
    func applyTrackingTint(for mode: MKUserTrackingMode) {
        guard let trackingGlyph else { return }
        let tint: UIColor = mode == .none ? .label : UIColor(Color.accentColor)
        guard trackingGlyph.tintColor != tint else { return }
        trackingGlyph.tintColor = tint
    }

    /// Tracking turning on or off is the only thing that changes the glyph's
    /// colour, and MapKit reports it here whether the button or the app asked
    /// for it — a pan that drops out of `.follow` included.
    func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
        applyTrackingTint(for: mode)
    }
    #endif
}

#if os(iOS)
extension MapView {
    /// The "my location" button, inside a glass capsule of its own.
    ///
    /// `MKUserTrackingButton` arrives with no chrome: it draws its glyph
    /// straight onto whatever the map is showing, in the tint it inherits —
    /// the app's accent green. That reads on a dark surface and not much
    /// anywhere else, because the accent follows the *interface* appearance
    /// while these tiles do not follow anything: `openStreetMap`,
    /// `stadiaOutdoors` and `thunderforestOutdoors` are light-styled at every
    /// hour and in either mode, so dark mode put a bright green arrow
    /// (`#44EE6E`, 1.5:1) on a white map. Reported by the user 2026-09-18.
    ///
    /// So the contrast is carried by a surface rather than by the glyph, which
    /// is what the camera pill and *Search this area* already do — same
    /// effect, same corner, same 44pt — and the column of controls now reads
    /// as one set instead of two pills and a loose arrow. The glyph's own
    /// colour is then free to say something: see
    /// ``MapView/Coordinator/applyTrackingTint(for:)``.
    func makeTrackingButton(
        for mapView: MKMapView,
        _ coordinator: Coordinator
    ) -> UIVisualEffectView {
        let tracking = MKUserTrackingButton(mapView: mapView)
        tracking.translatesAutoresizingMaskIntoConstraints = false
        // Belt and braces: the button has no background of its own today, and
        // one appearing behind a capsule would show as a square inside it.
        tracking.backgroundColor = .clear

        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .capsule()
        glass.contentView.addSubview(tracking)

        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: MapPhotoControlsView.controlSize),
            glass.heightAnchor.constraint(equalToConstant: MapPhotoControlsView.controlSize),
            tracking.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            tracking.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])

        coordinator.trackingGlyph = tracking
        coordinator.applyTrackingTint(for: mapView.userTrackingMode)
        return glass
    }
}
#endif
