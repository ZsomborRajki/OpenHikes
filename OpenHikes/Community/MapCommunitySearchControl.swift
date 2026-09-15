//
//  MapCommunitySearchControl.swift
//  OpenHikes
//
//  *Search this area*: the map's half of the *Community* tab, and the only
//  thing on screen that spends a request.
//
//  It exists because the alternative was invisible. The nearby list used to
//  re-query itself whenever ``CommunityQueryPolicy``'s thresholds were
//  crossed, so the rows under the hiker's thumb changed for reasons nothing
//  on screen gave — and the pans the thresholds refused left the list
//  describing somewhere else, equally silently.
//
//  It used to say that by coming and going: absent, the list was about what
//  you were looking at. It now stands for the whole of the *Community* tab
//  and goes with it — see ``MapSheetList``. A control that appears where the
//  hiker is already panning is a control they have to notice mid-gesture, and
//  the thing it does is the tab's one verb; a permanent one is somewhere to
//  aim. What the thresholds decide is therefore no longer whether the button
//  exists, only whether a tap has a *new* question to ask — and a tap with no
//  offer standing re-asks the visible region, which is a thing the hiker can
//  legitimately want and previously had no way to say. The page of results
//  that costs is still spent only on a tap.
//
//  The one state it cannot answer in is above the zoom ceiling, where it is
//  disabled rather than withdrawn: the list's footer says why, and a control
//  that vanished at a zoom level would be back to reporting policy by
//  absence.
//
//  It is also the cheaper half of the bargain. A pan nobody confirms now
//  costs nothing at all, where before every threshold crossing was a request
//  against the shared public-database quota.
//
//  UIKit rather than a SwiftUI overlay, for the reason ``MapPhotoControlsView``
//  is: this is a control over the map whose visibility is driven by an
//  `@Observable` the map already watches, and a SwiftUI overlay reading that
//  flag would put every offer and withdrawal through the root view's body —
//  the body that draws the map, the weather badge and the sheet. The
//  coordinator fades this in and out without SwiftUI hearing about it at all.
//

import Foundation
import MapKit

#if os(iOS)
import UIKit

/// The pill itself. Owns its appearance and its action, and nothing else —
/// where it sits is decided in `MapView.addAreaSearchControl`.
final class MapAreaSearchView: UIView {
    private static let symbolPointSize: CGFloat = 15
    private static let horizontalPadding: CGFloat = 14
    /// Matches the other floating controls, so the pill reads as one of the
    /// map's own rather than as something the sheet put there.
    private static let height: CGFloat = 44

    private let onTap: () -> Void
    /// Held so the ceiling can turn the pill off without taking it off screen.
    private var button: UIButton?

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        buildHierarchy()
    }

    /// Whether a tap would ask anything.
    ///
    /// Above ``CommunityQueryPolicy/maximumRadiusMeters`` there is nothing
    /// worth asking, so the pill dims and stops answering taps while staying
    /// where it is. `UIButton.Configuration` derives the disabled state from
    /// the base foreground colour itself, which is why nothing here sets one.
    var isEnabled: Bool {
        get { button?.isEnabled ?? false }
        set { button?.isEnabled = newValue }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapAreaSearchView is created in code only")
    }

    private func buildHierarchy() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "arrow.trianglehead.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Self.symbolPointSize,
                weight: .semibold
            )
        )
        configuration.title = String(localized: "Search this area")
        // The label's own colour rather than the app's tint.
        //
        // A `.plain` configuration takes `tintColor`, which here is the app's
        // green — a trail colour, on a pill that is not about a trail, over map
        // imagery that is frequently green itself. The other floating controls
        // on this map draw their labels in the ordinary label colour, and this
        // is the one that did not.
        //
        // Set as the *base* foreground rather than as a colour on the title, so
        // the disabled state above the zoom ceiling is still derived by
        // `UIButton.Configuration` rather than hard-coded here.
        configuration.baseForegroundColor = .label
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Self.horizontalPadding,
            bottom: 0,
            trailing: Self.horizontalPadding
        )
        // The label is the whole point of the control, so it stays legible at
        // every text size rather than truncating into a glyph and a comma.
        configuration.titleLineBreakMode = .byTruncatingTail

        let searchButton = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [onTap] _ in onTap() }
        )
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.titleLabel?.adjustsFontForContentSizeCategory = true
        searchButton.accessibilityIdentifier = "community-search-this-area"
        button = searchButton

        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .capsule()
        glass.contentView.addSubview(searchButton)
        addSubview(glass)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            searchButton.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            searchButton.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            searchButton.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            searchButton.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
    }
}
#endif

extension MapView.Coordinator {
    /// How long the pill takes to arrive or leave. The same quarter-second the
    /// camera pill uses, so the two controls on this map behave alike.
    private static let areaSearchFadeDuration: TimeInterval = 0.25

    /// Observes which list the sheet is showing and what the map has to offer
    /// about the region on screen, and shows, hides or dims the pill — the
    /// same imperative arrangement ``observePhotoControls(_:)`` uses, so
    /// panning and tab switches never re-render anything in SwiftUI.
    ///
    /// Both flags are read in one tracking closure because they answer the
    /// two halves of one question: `isBrowsing` decides whether the control is
    /// there at all, `areaPrompt` whether it can answer. Both are coarse —
    /// a tab is selected by hand and the policy refuses everything under a
    /// quarter of the search radius — so this fires a handful of times in a
    /// browsing session.
    ///
    /// Idempotent, like every other registration here: a second would leave
    /// two observers running overlapping fades against one view, and
    /// `withObservationTracking` offers no way to cancel the first.
    func observeAreaPrompt(_ browser: CommunityBrowser) {
        guard !isObservingAreaPrompt else { return }
        isObservingAreaPrompt = true
        trackAreaPrompt(browser, animated: false)
    }

    /// Applies the pill's visibility exactly once per change and then
    /// re-registers, the shape ``trackCommunityRoutes(_:on:)`` uses.
    ///
    /// The `animated` flag is what the two callers disagree about, and the
    /// only thing they disagree about: the first registration is arranging a
    /// control nobody has seen yet, so it takes its state outright, while
    /// every re-registration is answering a change the hiker is looking at.
    /// Applying in both places instead would run the unanimated branch second
    /// and hide the view before its fade had anything left to fade.
    private func trackAreaPrompt(_ browser: CommunityBrowser, animated: Bool) {
        applyAreaSearchVisibility(animated: animated)
        withObservationTracking {
            _ = browser.isBrowsing
            _ = browser.areaPrompt
        } onChange: { [weak self, weak browser] in
            let coordinator = self
            let model = browser
            Task { @MainActor in
                guard let coordinator, let model else { return }
                coordinator.trackAreaPrompt(model, animated: true)
            }
        }
    }

    private func applyAreaSearchVisibility(animated: Bool) {
        #if os(iOS)
        guard let areaSearchControl else { return }
        // The tab decides, not the offer. The pill is the *Community* list's
        // one verb, so it is on screen for as long as that list is and gone
        // the moment the hiker switches back to their own hikes — where a
        // control offering to search for published trails would be offering
        // to fill a list that is not there.
        let visible = community?.isBrowsing == true
        // Above the ceiling it stays put and stops answering. `zoomIn` has
        // something to say and nothing to do; the list's footer says it, and
        // a pill that disappeared at a zoom level would be reporting policy by
        // absence again — the thing this control exists to stop.
        areaSearchControl.isEnabled = community?.areaPrompt != .zoomIn
        // Hidden as well as transparent, for the reason the camera pill is:
        // an invisible view still answers hit tests, and this one sits over
        // the map the hiker is panning. Interaction goes at once rather than
        // when the fade lands.
        areaSearchControl.isUserInteractionEnabled = visible
        if visible { areaSearchControl.isHidden = false }
        guard animated else {
            areaSearchControl.alpha = visible ? 1 : 0
            areaSearchControl.isHidden = !visible
            return
        }
        UIView.animate(withDuration: Self.areaSearchFadeDuration) {
            areaSearchControl.alpha = visible ? 1 : 0
        } completion: { [weak self] _ in
            // Re-read rather than trusting the value this animation started
            // with: two settles in quick succession overlap, and a completion
            // that hid the pill the next animation had just brought back would
            // leave a visible control answering no taps.
            guard let self, community?.isBrowsing != true else { return }
            areaSearchControl.isHidden = true
        }
        #endif
    }
}

#if os(iOS)
extension MapView {
    /// How far below the map's safe area the pill sits. The same inset the
    /// map's other floating controls use, spelled here because that one is
    /// private to `MapView.swift` and this is the file that owns this control.
    private static let areaSearchTopInset: CGFloat = 12

    /// How much room the pill leaves on each side.
    ///
    /// Enough for MapKit's compass on the trailing edge and the weather badge
    /// on the leading one, both of which live in the same strip and neither of
    /// which can be anchored against — the compass belongs to MapKit and the
    /// badge is a SwiftUI overlay in another hierarchy.
    private static let areaSearchSideClearance: CGFloat = 56

    /// *Search this area*, centred at the top of the map.
    ///
    /// It takes no part in ``MapView/Coordinator/applySheetTop(on:)``, unlike
    /// the two controls that ride the sheet: this one answers a question about
    /// the region on screen, so it belongs at the top where the most map is
    /// visible, and the sheet never reaches it. Its own visibility is the
    /// whole of its behaviour — see ``MapCommunitySearchControl``.
    ///
    /// Held clear of MapKit's compass and of the weather badge by the side
    /// clearances rather than by a fixed width, so a long localisation
    /// truncates instead of sliding underneath either.
    func addAreaSearchControl(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let control = MapAreaSearchView { [community] in community.searchVisibleArea() }
        control.translatesAutoresizingMaskIntoConstraints = false
        // Starts out of the way: nothing is offered until the map has settled
        // somewhere the list does not describe, and a pill that flashed in on
        // launch would be offering to re-ask a question nobody has asked yet.
        control.isHidden = true
        control.alpha = 0
        mapView.addSubview(control)
        coordinator.areaSearchControl = control

        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            control.topAnchor.constraint(equalTo: guide.topAnchor, constant: Self.areaSearchTopInset),
            control.leadingAnchor.constraint(
                greaterThanOrEqualTo: guide.leadingAnchor,
                constant: Self.areaSearchSideClearance
            ),
            control.trailingAnchor.constraint(
                lessThanOrEqualTo: guide.trailingAnchor,
                constant: -Self.areaSearchSideClearance
            ),
        ])
    }
}
#endif
