//
//  MapCommunitySearchControl.swift
//  OpenHikes
//
//  *Search this area*: the map's half of the *Community* tab, and the only
//  thing on screen a hiker taps to spend a request.
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
//  legitimately want and previously had no way to say. A page of results is
//  still only ever spent on a tap: this one, or the tab selection that opened
//  the list in the first place.
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
//  This is the tap that spends an Overpass request — see
//  ``CommunityNearbyScope`` for the other two that do — so it is where what
//  OpenStreetMap had to say belongs. There are two such sentences and they are
//  not the same kind of thing. Overpass runs a handful of slots per address and
//  answers a busy one with a `429` and a `Retry-After`, which is a failure and
//  wears the warning glyph; an area with no waymarked day hikes in it is an
//  answer, wears a struck-through pin, and is here because without it the only
//  thing a hiker ever saw under this button was *OpenStreetMap trails
//  unavailable* — a list with no trails in it looked identical either way.
//  ``CuratedTrailNotice`` is the pair, and the caption draws whichever one the
//  last search came back with.
//
//  The caption is dropped clear of the weather badge rather than hung under
//  the pill, and carries an *x*. Both are about the same thing: this is the one
//  piece of the control whose size is a sentence's, so it is the one that
//  reaches other people's corners of the map and the one a hiker may want gone.
//  The badge is a SwiftUI overlay measured from the screen's own top edge while
//  this control hangs off the safe area, so there is no anchor between them and
//  no fixed gap that clears it on every phone — the caption keeps its distance
//  from the map's top edge instead, in the same space the badge is placed in.
//  Dismissing is a write to ``CommunityBrowser/curatedNotice`` rather than a
//  flag here, which is what makes the next refusal say so again: the caption
//  describes the last search, and there is always a next search.
//
//  **The button is not disabled by either, and that is the point.** A rate
//  limit is about one of the list's two sources. The hikes people published
//  are in CloudKit and are unaffected, so the tap still has something to do
//  and the caption says which half of the answer is missing rather than that
//  the control is broken. An empty area leaves it even more clearly useful:
//  moving the map and tapping again is the whole of what that caption is
//  advising. The zoom ceiling is the only thing here that disables anything,
//  because it is the only state where a tap would ask nothing at all.
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

/// Widens `rect` to a finger in both directions, leaving it centred on what it
/// was and leaving anything already that big alone.
///
/// Shared by the two halves of one promise: the hit test that answers over the
/// widened area, and the accessibility frame that says so.
private func fingerSized(_ rect: CGRect) -> CGRect {
    let target = AccessibilityMetrics.minimumTapTarget
    return rect.insetBy(
        dx: -max(0, (target - rect.width) / 2),
        dy: -max(0, (target - rect.height) / 2)
    )
}

/// The caption's *x*, which is drawn at a caption's size and navigated to at a
/// finger's.
///
/// A subclass for one override, because there is nowhere else to put it: a
/// `UIView`'s accessibility frame is derived from its own frame and recomputed
/// on every layout, so a value assigned from outside does not survive the next
/// pass. `performAccessibilityAudit`'s hit-region check, Switch Control and
/// Voice Control all navigate by this rather than by what
/// ``MapAreaSearchView/hitTest(_:with:)`` lets through — so a target that
/// existed only in the hit test would be a control they could see and not
/// reach.
private final class MapNoticeDismissButton: UIButton {
    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(fingerSized(bounds), in: self) }
        set { super.accessibilityFrame = newValue }
    }
}

/// The pill itself. Owns its appearance and its action, and nothing else —
/// where it sits is decided in `MapView.addAreaSearchControl`.
final class MapAreaSearchView: UIView {
    private static let symbolPointSize: CGFloat = 15
    private static let horizontalPadding: CGFloat = 14
    /// Matches the other floating controls, so the pill reads as one of the
    /// map's own rather than as something the sheet put there.
    private static let height: CGFloat = 44

    /// How close under the pill the caption may sit.
    ///
    /// A floor rather than the gap. What the caption actually clears is the
    /// weather badge — see ``noticeBadgeClearance`` — and this is what is left
    /// when there is no badge in the way.
    private static let noticeSpacing: CGFloat = 6
    /// How far down the map the caption starts, so as to clear the weather
    /// badge, measured from the map's own top edge.
    ///
    /// Built from the two numbers that place the badge rather than agreed with
    /// it, because the badge is a SwiftUI overlay in another hierarchy and
    /// there is nothing here to constrain against: ``WeatherBadge/topPadding``,
    /// which is measured from the screen's edge because the map ignores its
    /// safe area, and the tap target that decides the capsule's height. Then
    /// the same gap the caption would have kept from the pill.
    ///
    /// Measured from the *map* and not from this control on purpose. This one
    /// hangs off the safe area, which is most of a badge's height further down
    /// on a phone with a Dynamic Island than on one without — so a gap under
    /// the pill would clear the badge on some phones and overlap it on others.
    ///
    /// Portrait's number, like the padding it is built from; see
    /// ``applyNoticeClearance()``.
    private static let noticeBadgeClearance =
        WeatherBadge.topPadding + AccessibilityMetrics.minimumTapTarget + noticeSpacing
    private static let noticePadding: CGFloat = 10
    private static let noticeVerticalPadding: CGFloat = 5
    private static let noticeCornerRadius: CGFloat = 12
    private static let noticeSymbolPointSize: CGFloat = 11

    private let onTap: () -> Void
    /// Takes the caption off by hand — see
    /// ``CommunityBrowser/dismissCuratedNotice()``.
    private let onDismissNotice: () -> Void
    /// Held so the ceiling can turn the pill off without taking it off screen.
    private var button: UIButton?
    /// The caption's capsule, hidden until there is something to say. Held so
    /// the stack can collapse it rather than leave a gap under the pill.
    private var noticeView: UIView?
    private var noticeLabel: UILabel?
    /// The caption's glyph. Held because it says which *kind* of caption this
    /// is — see ``CuratedTrailNotice`` — and so changes with it.
    private var noticeIcon: UIImageView?
    /// The caption's *x*. Held for the hit test, which widens it to a finger.
    private var dismissButton: MapNoticeDismissButton?
    /// What holds the caption clear of the weather badge. Held because the
    /// badge is only over the top of the map in one orientation — see
    /// ``applyNoticeClearance()`` — and because it is made by the placing code,
    /// which is the half of this that knows the map.
    private var noticeClearanceConstraint: NSLayoutConstraint?

    init(onTap: @escaping () -> Void, onDismissNotice: @escaping () -> Void) {
        self.onTap = onTap
        self.onDismissNotice = onDismissNotice
        super.init(frame: .zero)
        buildHierarchy()
        // Where the weather badge is depends on the orientation, so the room
        // held for it is read again whenever that changes rather than once.
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (control: Self, _) in
            control.applyNoticeClearance()
        }
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
    /// watches, so the same value arrives repeatedly and a setter that
    /// reloaded the hierarchy each time would be doing it during a pan.
    ///
    /// The whole notice rather than its sentence, because the glyph is part of
    /// what it says: a refusal is a warning and an empty area is not. See
    /// ``CuratedTrailNotice``.
    var notice: CuratedTrailNotice? {
        didSet {
            guard notice != oldValue else { return }
            noticeLabel?.text = notice?.text
            if let notice {
                noticeIcon?.image = Self.noticeSymbol(named: notice.symbolName)
                noticeIcon?.tintColor = notice.isWarning ? .systemOrange : .secondaryLabel
            }
            noticeView?.isHidden = notice == nil
        }
    }

    /// One caption glyph, at the weight and size the caption is drawn at.
    private static func noticeSymbol(named name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: noticeSymbolPointSize,
                weight: .semibold
            )
        )
    }

    /// The *x* that takes the caption off.
    ///
    /// On both captions rather than on the warning alone. They are one capsule
    /// drawn two ways, and an *x* that came and went with the sentence would be
    /// a control a hiker has to read the caption to find. Neither one is
    /// load-bearing: both describe the search that has just been made, and the
    /// next search says its own piece — which is why this reaches for
    /// ``CommunityBrowser/dismissCuratedNotice()`` rather than remembering
    /// anything here.
    ///
    /// Drawn at the caption's own size and weight, from the same symbol
    /// configuration the notice glyph uses, so the two ends of the capsule
    /// match. It is hit at a finger's size all the same — see
    /// ``dismissTarget(around:)``.
    private func buildDismissButton() -> MapNoticeDismissButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = Self.noticeSymbol(named: "xmark")
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero

        let dismiss = MapNoticeDismissButton(
            configuration: configuration,
            primaryAction: UIAction { [onDismissNotice] _ in onDismissNotice() }
        )
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        dismiss.setContentHuggingPriority(.required, for: .horizontal)
        dismiss.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The glyph is the whole of the control, so it has to be named; the
        // caption beside it is what says what is being dismissed.
        dismiss.accessibilityLabel = String(localized: "Dismiss")
        dismiss.accessibilityIdentifier = "community-curated-notice-dismiss"
        dismissButton = dismiss
        return dismiss
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapAreaSearchView is created in code only")
    }

    /// Only the button and the caption's *x* answer a touch.
    ///
    /// This view is the full width of the strip the pill is centred in — and
    /// everything inside it is claimed by `MapView.Coordinator`'s own hit test,
    /// which is how a tap on a control is kept from also being a tap on the
    /// map. Without this, the map would stop answering taps in the empty air
    /// either side of the button and under the caption.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden else { return nil }
        if let button, button.point(inside: convert(point, to: button), with: event) {
            return button
        }
        guard let dismiss = dismissButton, noticeView?.isHidden == false,
              dismissTarget(around: dismiss).contains(point) else { return nil }
        return dismiss
    }

    /// The *x*'s touch area, in this view's own space.
    ///
    /// Widened around the glyph rather than by padding the button, because the
    /// capsule is a caption line tall and its height is the glyph's: a control
    /// padded to a finger inside it would set the size of the thing it sits in.
    /// The pill is tested first, so a target that reaches up past the gap
    /// cannot take a tap away from the button.
    private func dismissTarget(around dismiss: UIButton) -> CGRect {
        fingerSized(convert(dismiss.bounds, from: dismiss))
    }

    /// Holds the caption clear of the weather badge, which is drawn over the
    /// same corner of the map from another hierarchy.
    ///
    /// Takes the map's own top edge, because that is the space the badge is
    /// placed in — see ``noticeBadgeClearance`` for why no gap under the pill
    /// can do this job. Made by the placing code and applied here, since where
    /// the badge *is* depends on a trait and the constant therefore changes.
    func keepNoticeClear(of mapTop: NSLayoutYAxisAnchor) {
        guard let noticeView, noticeClearanceConstraint == nil else { return }
        let clearance = noticeView.topAnchor.constraint(greaterThanOrEqualTo: mapTop)
        noticeClearanceConstraint = clearance
        clearance.isActive = true
        applyNoticeClearance()
    }

    /// How much room the badge needs, which is none at all in landscape.
    ///
    /// Turned sideways the badge moves inside the safe area and against
    /// ``MapSidePanel``'s leading margin — see `OpenHikesView` — where it is
    /// nowhere near a caption centred over what is left of the map. Holding
    /// portrait's room there would leave the caption floating in the middle of
    /// a map a third the height.
    ///
    /// The size class rather than the panel's own flag: this is UIKit's copy of
    /// the input `SheetLayoutReader` reads, not a second opinion about it.
    private func applyNoticeClearance() {
        noticeClearanceConstraint?.constant = traitCollection.verticalSizeClass == .compact
            ? 0
            : Self.noticeBadgeClearance
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
        addSubview(glass)
        addSubview(noticeCapsule)

        // Two pinned views rather than a vertical stack, which is what this
        // was until the caption had to clear the weather badge: a stack's
        // spacing is one required constraint, and where the caption starts is
        // the *lower* of two — the pill above it, and a badge belonging to
        // another hierarchy. The pair below is how "as high as it is allowed to
        // be" is spelled. The two `>=` floors say where it may not go, and the
        // optional pull holds it against whichever of them is lower down.
        //
        // What the stack was doing is not lost. It collapsed its own height
        // around a hidden caption, and nothing measures this view's height:
        // the sheet does not reach it, no control is stacked under it, and the
        // hit test above answers for the button and the *x* rather than for
        // the frame.
        let hugsPill = noticeCapsule.topAnchor.constraint(
            equalTo: glass.bottomAnchor,
            constant: Self.noticeSpacing
        )
        hugsPill.priority = .defaultLow

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            glass.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            noticeCapsule.topAnchor.constraint(
                greaterThanOrEqualTo: glass.bottomAnchor,
                constant: Self.noticeSpacing
            ),
            hugsPill,
            noticeCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            noticeCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            noticeCapsule.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: noticeCapsule.bottomAnchor),
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
        // No image and no colour until there is a notice to take them from.
        // The capsule is hidden while that is true, so an icon built here
        // would only be a claim about which kind of caption the next one is.
        let icon = UIImageView()
        noticeIcon = icon
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
        label.accessibilityIdentifier = "community-curated-notice"
        noticeLabel = label

        let sentence = UIStackView(arrangedSubviews: [icon, label])
        sentence.axis = .horizontal
        sentence.alignment = .firstBaseline
        sentence.spacing = 5

        let row = UIStackView(arrangedSubviews: [sentence, buildDismissButton()])
        row.axis = .horizontal
        // Centred rather than baselined, unlike the sentence inside it: the
        // *x* is a glyph with no text to sit on, and what it is beside is two
        // lines at the larger text sizes.
        row.alignment = .center
        row.spacing = Self.noticePadding
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
    /// about the region on screen, whether a search is in flight and what
    /// OpenStreetMap had to say about the last one, and shows, hides, dims,
    /// spins or captions the pill — the same imperative arrangement
    /// ``observePhotoControls(_:)`` uses, so panning and tab switches never
    /// re-render anything in SwiftUI.
    ///
    /// All four are read in one tracking closure because they answer four
    /// parts of one question: `isBrowsing` decides whether the control is
    /// there at all, `areaPrompt` whether it can answer, `isSearching` whether
    /// it is busy answering, and `curatedNotice` what it has to say about the
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
        reobserving(self, browser) {
            _ = browser.isBrowsing
            _ = browser.areaPrompt
            _ = browser.curatedNotice
            _ = browser.isSearching
        } onChange: { coordinator, model in
            coordinator.trackAreaPrompt(model, animated: true)
        }
    }

    /// Takes the *Search this area* pill off the map while a callout is open,
    /// and puts it back when one closes.
    ///
    /// The two float over the same corner, and MapKit draws a callout *above*
    /// its pin — so a pin the camera has framed near the top of the map opens
    /// underneath the pill. On a photo pin that is the pill sitting on the
    /// picture, and an invisible half of it swallowing the tap that opens the
    /// gallery, which is the whole of what the callout is for.
    ///
    /// Not specific to photographs, and deliberately: every callout on this map
    /// is something the hiker has just opened and is reading, and the pill is a
    /// standing offer that can wait. Reachable by hand for as long as pins have
    /// been tappable — *Show on map* opening one is what made it easy to see.
    func withdrawAreaSearchForCallout(open: Bool) {
        guard hasOpenCallout != open else { return }
        hasOpenCallout = open
        applyAreaSearchVisibility(animated: true)
    }

    /// Asks the map itself whether a callout is still up, rather than waiting
    /// to be told.
    ///
    /// `didDeselect` is the ordinary way one closes, and it is not the only
    /// way: taking a selected annotation off the map takes its callout with it
    /// — which is what backing out of a preview does to every photo pin on it
    /// — and MapKit does not reliably report that as a deselection. Without
    /// this, a hiker who opened a photo pin's callout and then left the
    /// preview would find *Search this area* gone for the rest of the session,
    /// which is the Community tab's one verb. Called wherever annotations are
    /// removed, where `selectedAnnotations` is the answer rather than a guess.
    /// `canShowCallout` for the same reason `didSelect` asks it: a route dot
    /// left selected is a selection with nothing drawn above it.
    func refreshOpenCallout(on mapView: MKMapView) {
        let open = mapView.selectedAnnotations.contains { annotation in
            mapView.view(for: annotation)?.canShowCallout == true
        }
        withdrawAreaSearchForCallout(open: open)
    }

    private func applyAreaSearchVisibility(animated: Bool) {
        #if os(iOS)
        guard let areaSearchControl else { return }
        // The tab decides, not the offer. The pill is the *Community* list's
        // one verb, so it is on screen for as long as that list is and gone
        // the moment the hiker switches back to their own hikes — where a
        // control offering to search for published trails would be offering
        // to fill a list that is not there.
        // ...and not while a callout is standing where it draws — see
        // ``withdrawAreaSearchForCallout(open:)``.
        let visible = community?.isBrowsing == true && !hasOpenCallout
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
        // What OpenStreetMap had to say about the last search that asked it,
        // and nothing about whether the control works — see this file's
        // header.
        // Cleared along with the pill when the tab goes, so the caption never
        // outlives the list it is about.
        areaSearchControl.notice = visible ? community?.curatedNotice : nil
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

    /// How much room the control leaves on each side.
    ///
    /// Enough for MapKit's compass on the trailing edge and the weather badge
    /// on the leading one, both of which live in the same strip and neither of
    /// which can be anchored against — the compass belongs to MapKit and the
    /// badge is a SwiftUI overlay in another hierarchy. It is what a long
    /// localisation truncates against and what a caption wraps against, and it
    /// clears the badge *sideways* only: the badge hangs lower than this strip,
    /// which is what ``MapAreaSearchView`` drops the caption past.
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
    /// truncates instead of sliding underneath either. The control is the whole
    /// of that strip and its contents are centred in it — the pill and the
    /// caption are each their own size, and what the strip decides is where
    /// either of them runs out of room.
    func addAreaSearchControl(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let control = MapAreaSearchView { [community] in
            community.searchVisibleArea()
        } onDismissNotice: { [community] in
            community.dismissCuratedNotice()
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        // Starts out of the way: nothing is offered until the map has settled
        // somewhere the list does not describe, and a pill that flashed in on
        // launch would be offering to re-ask a question nobody has asked yet.
        control.isHidden = true
        control.alpha = 0
        mapView.addSubview(control)
        coordinator.areaSearchControl = control

        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: guide.topAnchor, constant: Self.areaSearchTopInset),
            control.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: Self.areaSearchSideClearance
            ),
            control.trailingAnchor.constraint(
                equalTo: guide.trailingAnchor,
                constant: -Self.areaSearchSideClearance
            ),
        ])
        // The map's own top edge, not the guide's: the badge the caption is
        // being kept clear of is measured from the screen's, and the map
        // ignores its safe area. See ``MapAreaSearchView/keepNoticeClear(of:)``.
        control.keepNoticeClear(of: mapView.topAnchor)
    }
}
#endif
