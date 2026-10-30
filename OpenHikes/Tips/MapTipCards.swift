//
//  MapTipCards.swift
//  OpenHikes
//
//  The main screen's tips about the map's own buttons — *Record a hike*,
//  *Make a trail* and *Search this area* — drawn as cards on the map, beside
//  the control each one is about.
//
//  **A card rather than a popover, and that is the design.** A popover is a
//  presentation, and this screen's sheet is presented for as long as the app
//  is open, so a popover over the map would have to be presented *by* the
//  sheet — and while it was up, the sheet could present nothing else. UIKit
//  refuses a second presentation from a controller that already has one, with
//  nothing but a line in the console (see `TrailDraftPhotoCopyAlert.swift`),
//  and the sheet presents things nobody tapped for: the track choice a GPX
//  opened from Files asks, the alert a search that found nothing raises.
//  SwiftUI queues its own presentations behind each other, and knows nothing
//  of a UIKit popover. A card is a view: it blocks nothing, takes no tap that
//  is not aimed at it, and rides and fades with the control it explains for
//  free, the way the camera pill rides the credit line. A tap that is aimed
//  at it is its own, and not the line's drawn underneath — see
//  ``MapView/Coordinator/isTapClaimed(at:in:)``.
//
//  `TipUIView` rather than a card of our own, so the words, the close button
//  and the look are TipKit's, and closing one retires it the way every other
//  tip is retired. Its accessibility is the one thing this file adds back —
//  see ``MapTipCardView``.
//
//  Which card, if any, is ``MapTipPlacement``'s decision. This file acts on it
//  at the three moments it can change: the tips themselves (one closed, one
//  used, the library loaded, a new hiker found), the pill coming or going,
//  and *Search this area* coming, going or answering.
//

import MapKit
import SwiftUI
import TipKit
#if os(iOS)
import UIKit
#endif

/// What the map holds for the main screen's tips, as one stored property of
/// the coordinator — see ``MapView/Coordinator/tipCards``.
struct MapTipCardState {
    /// Where the tips come from, or `nil` for a launch that shows none.
    weak var tips: AppTips?
    /// The map the card is drawn on.
    weak var mapView: MKMapView?
    /// What the card on the map is for, or `nil` while there is none.
    var shown: MapTipPlacement?

    #if os(iOS)
    /// The card itself, which the map holds while it is on it, and which
    /// claims the taps that land on it — see
    /// ``MapView/Coordinator/isTapClaimed(at:in:)``.
    ///
    /// A ``MapTipCardView`` whenever the app puts one here, held as a plain
    /// view so a suite can stand one in: the real card's content is TipKit's
    /// own view, and a suite never reaches TipKit's store (``TipLaunch``).
    weak var card: UIView?
    #endif
}

#if os(iOS)
/// A first-run tip's card on the map: TipKit's own view, inside one that says
/// the tip's words to VoiceOver itself.
///
/// MapKit builds the map's accessibility by walking the UIKit views on it, and
/// collects the ones that are elements: every button and caption on this map
/// is one. TipKit draws a card's words and its close button in SwiftUI, inside
/// a single UIKit view that is not, so the walk passes straight through a bare
/// `TipUIView` — measured: a card plainly on screen was absent from the tree,
/// title, message and close button alike. This view is one element in its
/// place, reading the title and the message, with closing the tip as an
/// action, which is what VoiceOver's actions rotor offers.
final class MapTipCardView: UIView {
    init(_ tip: any MapTip, arrowEdge: Edge?) {
        super.init(frame: .zero)
        let content = TipUIView(tip, arrowEdge: arrowEdge)
        // The glyph in the colour its button draws it in, rather than in the
        // app's green: the shared glyph is what ties a card to its button, and
        // a red record button beside a green record glyph reads as two things.
        content.imageStyle = tip is RecordHikeTip ? Color(uiColor: .systemRed) : Color.primary
        content.translatesAutoresizingMaskIntoConstraints = false
        // Said once, by this view, rather than a second time by any walker
        // that does find TipKit's own.
        content.accessibilityElementsHidden = true
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let words = type(of: tip)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: words.titleWords)
        accessibilityValue = String(localized: words.messageWords)
        accessibilityIdentifier = "map-tip"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Close")) { _ in
                tip.invalidate(reason: .tipClosed)
                return true
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapTipCardView is created in code only")
    }
}
#endif

extension MapView {
    /// The map `makeUIView` builds: ``makeMapView(_:)``'s, drawing the
    /// first-run tips about its own buttons.
    ///
    /// The tips arrive from the environment rather than as a property of this
    /// view, so neither its `==` nor the call site in `OpenHikesView` — both
    /// at their length limits — had to change. A suite builds its map with
    /// ``makeMapView(_:)`` and gets none.
    func makeMapView(_ coordinator: Coordinator, drawingTips tips: AppTips?) -> MKMapView {
        let mapView = makeMapView(coordinator)
        coordinator.observeTips(tips, on: mapView)
        return mapView
    }
}

extension MapView.Coordinator {
    #if os(iOS)
    /// No wider than a phone held upright, so a card on a map turned sideways
    /// stays a line length rather than becoming a banner.
    private static let tipCardMaximumWidth: CGFloat = 420
    /// The gap between a card and the control it is about.
    private static let tipCardSpacing: CGFloat = 8
    #endif

    /// Starts drawing the main screen's tips on `mapView`, once.
    ///
    /// Handed what the environment holds by `MapView.makeUIView`, which is
    /// `nil` for every suite and preview: a map built by
    /// ``MapView/makeMapView(_:)`` alone draws no tips.
    func observeTips(_ tips: AppTips?, on mapView: MKMapView) {
        guard let tips, tipCards.tips == nil else { return }
        tipCards.tips = tips
        tipCards.mapView = mapView
        trackTips(tips, animated: false)
    }

    /// Applies, then registers again — the shape every observation on this map
    /// has. Both values move a handful of times in an install's whole life.
    private func trackTips(_ tips: AppTips, animated: Bool) {
        syncMapTips(animated: animated)
        reobserving(self, tips) {
            _ = tips.main.currentTip
            _ = tips.creationAudience
        } onChange: { coordinator, model in
            coordinator.trackTips(model, animated: true)
        }
    }

    /// Puts on the map the card the due tip calls for, and takes off one it no
    /// longer does.
    func syncMapTips(animated: Bool) {
        #if os(iOS)
        guard let tips = tipCards.tips, let mapView = tipCards.mapView else { return }
        let due = tips.main.currentTip
        let wanted = MapTipPlacement(
            tipID: due?.id,
            creationTipsAreWanted: tips.creationAudience.wantsTips,
            pillIsOffered: trailDraftController?.isAvailable == true,
            areaSearchIsIdle: isAreaSearchOffered && community?.isSearching != true
        )
        guard wanted != tipCards.shown else { return }
        removeTipCard(animated: animated)
        // Every tip a placement is decided for is one of the map's own.
        guard let wanted, let mapTip = due as? any MapTip else { return }
        addTipCard(for: mapTip, at: wanted, on: mapView, animated: animated)
        #endif
    }

    /// Retires `tip`, because the hiker has just tapped the control it is
    /// about and so has no more need of it.
    func controlUsed(retiring tip: some Tip) {
        tipCards.tips?.used(tip)
    }

    /// ``controlUsed(retiring:)`` for the pill's two buttons, whose first tap
    /// on an empty list also says this is a new hiker — see
    /// ``CreationTipsAudience``.
    func pillUsed(retiring tip: some Tip) {
        tipCards.tips?.pillUsed(retiring: tip)
    }

    /// The pill's card takes the pill's own fade as the sheet rises past it —
    /// see ``applySheetTop(on:)``.
    func applyTipCardAlpha(_ alpha: CGFloat) {
        #if os(iOS)
        guard case .abovePill = tipCards.shown,
              let card = tipCards.card,
              card.alpha != alpha else { return }
        card.alpha = alpha
        #endif
    }
}

#if os(iOS)
private extension MapView.Coordinator {
    func addTipCard(for tip: any MapTip, at placement: MapTipPlacement, on mapView: MKMapView, animated: Bool) {
        let anchor: UIView?
        let arrowEdge: Edge?
        let restingAlpha: CGFloat
        switch placement {
        case .abovePill:
            // No arrow: TipKit draws one in the middle of an edge, which over a
            // pill on the leading edge would point at the middle of the map.
            // The glyph the card shares with its button is what says which.
            anchor = trailDraftControls
            arrowEdge = nil
            restingAlpha = photoControlsSheetAlpha
        case .underAreaSearch:
            anchor = areaSearchControl
            arrowEdge = .top
            restingAlpha = 1
        }
        guard let anchor else { return }

        let card = MapTipCardView(tip, arrowEdge: arrowEdge)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.alpha = 0
        mapView.addSubview(card)
        switch placement {
        case .abovePill: place(card, above: anchor, on: mapView)
        case .underAreaSearch: place(card, under: anchor, on: mapView)
        }
        tipCards.card = card
        tipCards.shown = placement
        card.fadeMapControl(visible: true, restingAlpha: restingAlpha, animated: animated) { false }
    }

    /// Directly over the pill, against its leading edge and as wide as the map
    /// allows. Sitting on the two buttons is what says which pair the card is
    /// about, and rising and falling with them through the sheet's travel is
    /// what keeps it there.
    func place(_ card: UIView, above pill: UIView, on mapView: MKMapView) {
        let trailing = mapView.safeAreaLayoutGuide.trailingAnchor
        let fill = card.trailingAnchor.constraint(equalTo: trailing, constant: -MapView.controlInset)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            card.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Self.tipCardSpacing),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -MapView.controlInset),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: Self.tipCardMaximumWidth),
            fill,
        ])
    }

    /// Under *Search this area* and centered on it, with the arrow pointing up
    /// at it — and below the weather badge, as the pill's own caption is, since
    /// the badge sits directly under the strip the pill is in.
    ///
    /// Below the badge and the compass, nothing holds the card to that strip's
    /// width, so it takes the width every control on the map is laid out in:
    /// the guide whose leading edge ``MapView/Coordinator/controlsLeadingConstraint``
    /// pulls in past the side panel, which keeps the card out from behind it.
    func place(_ card: UIView, under control: UIView, on mapView: MKMapView) {
        let guide = controlsLeadingConstraint?.firstItem as? UILayoutGuide ?? mapView.safeAreaLayoutGuide
        let fill = card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: MapView.controlInset)
        fill.priority = .defaultHigh
        let snug = card.topAnchor.constraint(equalTo: control.bottomAnchor, constant: Self.tipCardSpacing)
        snug.priority = .defaultLow
        // From the guide's top, the safe area's, which is where the badge is
        // placed in both of the screen's shapes.
        let badge = card.topAnchor.constraint(
            greaterThanOrEqualTo: guide.topAnchor,
            constant: MapAreaSearchView.badgeClearance
        )
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: MapView.controlInset),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: Self.tipCardMaximumWidth),
            card.topAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor, constant: Self.tipCardSpacing),
            fill,
            snug,
            badge,
        ])
    }

    func removeTipCard(animated: Bool) {
        let card = tipCards.card
        tipCards.card = nil
        tipCards.shown = nil
        guard let card else { return }
        // Interaction goes at once, as a fading map control's does — see
        // `MapControlFade.swift`.
        card.isUserInteractionEnabled = false
        guard animated else {
            card.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: UIView.mapControlFadeDuration) {
            card.alpha = 0
        } completion: { _ in
            card.removeFromSuperview()
        }
    }
}
#endif
