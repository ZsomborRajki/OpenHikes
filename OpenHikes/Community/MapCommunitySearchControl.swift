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
//  ## While it is answering
//
//  The glyph becomes a spinner and the pill stops taking taps until *both*
//  halves of the question have come back. That is one request rather than two
//  kept in step — ``MergedCommunityTransport`` asks CloudKit and Overpass side
//  by side and returns when both have answered or failed — so there is no
//  state here in which the control could claim one half was done.
//
//  Refusing the tap is the point rather than a side effect.
//  ``CommunityBrowser``'s `perform` awaits the task it supersedes before
//  starting, so a second tap during a search cannot produce an answer sooner;
//  it can only queue another listing pass against an API that allows a handful
//  of slots per address. A spinner that still accepted taps would be inviting
//  exactly the thing the rest of this feature was rearranged to avoid.
//
//  ## The caption under it
//
//  This is also the tap that asks OpenStreetMap — the only one, now that every
//  other nearby request is published-only, see ``CommunityNearbyScope`` — so
//  it is where a refusal from OpenStreetMap belongs. Overpass runs a handful
//  of slots per address and answers a busy one with a `429` and a
//  `Retry-After`; ``CuratedTrailOutage`` is what that becomes, and the caption
//  under the pill is what draws it.
//
//  **The button is not disabled by it, and that is the point.** A rate limit
//  is about one of the list's two sources. The hikes people published are in
//  CloudKit and are unaffected, so the tap still has something to do and the
//  caption says which half of the answer is missing rather than that the
//  control is broken. The zoom ceiling is the only thing here that disables
//  anything, because it is the only state where a tap would ask nothing at
//  all.
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

    /// How far the caption sits below the pill.
    private static let noticeSpacing: CGFloat = 6
    private static let noticePadding: CGFloat = 10
    private static let noticeVerticalPadding: CGFloat = 5
    private static let noticeCornerRadius: CGFloat = 12
    private static let noticeSymbolPointSize: CGFloat = 11

    private let onTap: () -> Void
    /// Held so the ceiling can turn the pill off without taking it off screen.
    private var button: UIButton?
    /// The caption's capsule, hidden until there is something to say. Held so
    /// the stack can collapse it rather than leave a gap under the pill.
    private var noticeView: UIView?
    private var noticeLabel: UILabel?

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
    ///
    /// Deliberately *not* what ``notice`` writes — see this file's header. A
    /// rate-limited OpenStreetMap leaves the published half of the list
    /// perfectly askable, so the caption appears and the button keeps working.
    var isEnabled: Bool {
        get { button?.isEnabled ?? false }
        set { button?.isEnabled = newValue }
    }

    /// Whether a search is in flight, drawn as a spinner in place of the
    /// glyph.
    ///
    /// `UIButton.Configuration.showsActivityIndicator` rather than a
    /// `UIActivityIndicatorView` of our own: it puts the indicator exactly
    /// where the image was, keeps the title beside it, and leaves the metrics
    /// to UIKit — a hand-placed one would have to reproduce the image's
    /// padding and would change the pill's width as it came and went.
    ///
    /// It says *both* halves are still out. The nearby request asks CloudKit
    /// and Overpass side by side and comes back when both have answered or
    /// failed — see ``CommunityBrowser/isSearching`` — so there is nothing
    /// here that could report one half without the other.
    var isSearching = false {
        didSet {
            guard isSearching != oldValue else { return }
            button?.configuration?.showsActivityIndicator = isSearching
            // The glyph is gone while this is true, so the state has to be
            // said rather than shown. A value rather than a replacement label,
            // because what the control *does* has not changed and a button
            // that renamed itself mid-press would be read out as a different
            // control.
            button?.accessibilityValue = isSearching
                ? String(localized: "Searching")
                : nil
        }
    }

    /// One line under the pill, or `nil` for none.
    ///
    /// Idempotent on purpose: this is written from a `withObservationTracking`
    /// re-registration that fires for a change to either of the two values it
    /// watches, so the same string arrives repeatedly and a setter that
    /// reloaded the hierarchy each time would be doing it during a pan.
    var notice: String? {
        didSet {
            guard notice != oldValue else { return }
            noticeLabel?.text = notice
            noticeView?.isHidden = notice == nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapAreaSearchView is created in code only")
    }

    /// Only the button answers a touch.
    ///
    /// The caption is regularly wider than the pill, which makes this view
    /// wider than the pill — and everything inside it is claimed by
    /// `MapView.Coordinator`'s own hit test, which is how a tap on a control
    /// is kept from also being a tap on the map. Without this, the map would
    /// stop answering taps in the empty air either side of the button, and the
    /// width it stopped answering in would depend on how long the current
    /// caption was.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let button, isUserInteractionEnabled, !isHidden else { return nil }
        return button.point(inside: convert(point, to: button), with: event) ? button : nil
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

        let noticeCapsule = buildNotice()
        // A stack rather than two pinned views, for the one thing a stack does
        // that constraints would each need a copy of: `isHidden` on an
        // arranged subview takes its height with it, so a control with nothing
        // to say is exactly the pill it was before the caption existed.
        let stack = UIStackView(arrangedSubviews: [glass, noticeCapsule])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Self.noticeSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: stack.leadingAnchor),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            glass.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            searchButton.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            searchButton.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            searchButton.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            searchButton.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
    }

    /// The caption's own glass, with the warning glyph the list's failure rows
    /// already use so the two read as the same kind of thing.
    ///
    /// Rounded rather than a capsule: this one wraps to two lines at the
    /// larger text sizes, and a capsule around two lines is a stadium.
    private func buildNotice() -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: "exclamationmark.triangle.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Self.noticeSymbolPointSize,
                    weight: .semibold
                )
            )
        )
        icon.tintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The sentence beside it already says everything this glyph does, and
        // a second element that read "warning" would make VoiceOver announce
        // the caption twice.
        icon.isAccessibilityElement = false

        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 2
        label.accessibilityIdentifier = "community-curated-outage"
        noticeLabel = label

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false

        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .corners(radius: .fixed(Self.noticeCornerRadius))
        glass.contentView.addSubview(row)
        // Starts collapsed: there is nothing to report until a search has been
        // refused, and a gap under the pill on launch would be a control
        // reserving room for a failure.
        glass.isHidden = true
        noticeView = glass

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: glass.contentView.leadingAnchor,
                constant: Self.noticePadding
            ),
            row.trailingAnchor.constraint(
                equalTo: glass.contentView.trailingAnchor,
                constant: -Self.noticePadding
            ),
            row.topAnchor.constraint(
                equalTo: glass.contentView.topAnchor,
                constant: Self.noticeVerticalPadding
            ),
            row.bottomAnchor.constraint(
                equalTo: glass.contentView.bottomAnchor,
                constant: -Self.noticeVerticalPadding
            ),
        ])
        return glass
    }
}
#endif

extension MapView.Coordinator {
    /// How long the pill takes to arrive or leave. The same quarter-second the
    /// camera pill uses, so the two controls on this map behave alike.
    private static let areaSearchFadeDuration: TimeInterval = 0.25

    /// Observes which list the sheet is showing, what the map has to offer
    /// about the region on screen, whether a search is in flight and whether
    /// OpenStreetMap refused the last one, and shows, hides, dims, spins or
    /// captions the pill — the same imperative arrangement
    /// ``observePhotoControls(_:)`` uses, so panning and tab switches never
    /// re-render anything in SwiftUI.
    ///
    /// All four are read in one tracking closure because they answer four
    /// parts of one question: `isBrowsing` decides whether the control is
    /// there at all, `areaPrompt` whether it can answer, `isSearching` whether
    /// it is busy answering, and `curatedOutage` what it has to say about the
    /// answer it gave. All four are coarse — a tab is selected by hand, the
    /// policy refuses everything under half the search radius, and the other
    /// two move only when a search starts or lands — so this fires a handful
    /// of times in a browsing session.
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
            _ = browser.curatedOutage
            _ = browser.isSearching
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
        // Busy and disabled are different states and only one of them is a
        // policy: the ceiling means *this question is not worth asking*, and a
        // search in flight means *it is being asked*. They share `isEnabled`
        // because a control can only be tapped or not, and the spinner is what
        // tells the two apart on screen.
        let searching = community?.isSearching == true
        areaSearchControl.isSearching = searching
        areaSearchControl.isEnabled = community?.areaPrompt != .zoomIn && !searching
        // What OpenStreetMap said about the last search that asked it, and
        // nothing about whether the control works — see this file's header.
        // Cleared along with the pill when the tab goes, so the caption never
        // outlives the list it is about.
        areaSearchControl.notice = visible ? community?.curatedOutage?.notice : nil
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
