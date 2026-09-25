//
//  MapTrailPointSearchControl.swift
//  OpenHikes
//
//  *Search this area*, in the trail maker.
//
//  **The button is the one that already exists.** ``MapAreaSearchView`` is the
//  Community tab's one verb — the glass capsule centred on the map's top edge,
//  the spinner in place of its glyph while a request is out, the caption
//  underneath saying what came back — and every one of those is exactly what
//  this needs. So this file builds a second one rather than a second design:
//  the same class, the same treatment, the same two sentences it already knows
//  how to draw. What is this feature's own is the callback, the caption's
//  words and when the pill is on screen at all.
//
//  ## The two are never up together, and this one *is* a rule
//
//  Everywhere else in the maker the exclusions fall out of existing
//  definitions: the camera pill and the draw pill are offered on opposite
//  answers to *is a screen pushed*, so neither knows the other exists. This
//  pair is not like that, and the plan issue assumed it was. Selecting the
//  *Community* tab is what raises the other pill, and a tab selection survives
//  a push — so a hiker browsing shared trails who then taps *make a trail* had
//  two pills in one strip, one asking OpenStreetMap for routes and one asking
//  it for places, with no way to tell which was which.
//
//  ``MapView/Coordinator/withdrawAreaSearchForDrawing(_:)`` is the rule, and
//  the maker's is the one that stays: it is what the hiker is doing. It is
//  written at the far end, beside the control it withdraws, rather than here.
//
//  ## What it is offered on
//
//  The maker being up, and nothing else. Not on whether there is a line yet —
//  *what is near here* is a question a hiker can ask before drawing anything,
//  and marking the hut before drawing the walk to it is the most useful order
//  to work in. Not on whether the last search failed, for the reason the
//  Community pill is not disabled by a rate limit either: the answer to a busy
//  server is to tap again in a moment, and a control that disabled itself
//  would be taking that away.
//
//  The one state it is disabled in is above ``TrailPointQuery/maximumRadiusMeters``,
//  where a tap would ask nothing. Disabled rather than withdrawn, exactly as
//  the Community pill is above its own ceiling: a control that vanished at a
//  zoom level would be reporting policy by absence.
//

import Foundation
import MapKit

#if os(iOS)
extension MapView {
    /// The maker's *Search this area*, in the same strip the Community tab's
    /// sits in.
    ///
    /// The same geometry as ``addAreaSearchControl(to:_:alignedTo:)`` — the
    /// top of the map rather than the sheet's edge, held clear of MapKit's
    /// compass and of the weather badge by the same side clearances. Two views
    /// occupying one strip is safe because only one of them is ever visible;
    /// see this file's header for why that needed saying out loud.
    func addTrailPointSearchControl(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let control = MapAreaSearchView(
            identifiers: .trailPoints,
            onTap: { [trailMaker] in trailMaker.searchNearbyPlaces() },
            onDismissNotice: { [trailMaker] in trailMaker.finder.dismissNotice() }
        )
        control.translatesAutoresizingMaskIntoConstraints = false
        // Starts out of the way: the maker is not up on launch, and a pill
        // that flashed in before its first visibility pass would be offering
        // to search an area for a screen nobody has opened.
        control.isHidden = true
        control.alpha = 0
        mapView.addSubview(control)
        coordinator.trailPointSearchControl = control

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
        // The map's own top edge, not the guide's, for the reason the other
        // one says: the weather badge the caption is kept clear of is measured
        // from the screen's edge and the map ignores its safe area.
        control.keepNoticeClear(of: mapView.topAnchor)
    }
}
#endif

extension MapView.Coordinator {
    /// Observes whether the maker is up, whether a search is out, whether a
    /// tap would ask anything and what the last one said — and shows, hides,
    /// dims, spins or captions the pill.
    ///
    /// All four in one registration because they are four parts of one
    /// question, the arrangement ``observeAreaPrompt(_:)`` uses one feature
    /// over. All four are coarse: a screen is pushed by hand, a search is a
    /// tap, and the area only changes when the map settles somewhere a
    /// different size.
    ///
    /// Idempotent, like every registration here: a second would leave two
    /// observers running overlapping fades against one view, and
    /// `withObservationTracking` offers no way to cancel the first.
    func observeTrailPointSearch(_ controller: TrailDraftController) {
        guard !isObservingTrailPointSearch else { return }
        isObservingTrailPointSearch = true
        trackTrailPointSearch(controller, animated: false)
    }

    /// Applies once per change and then re-registers, the shape
    /// ``trackAreaPrompt(_:animated:)`` uses — including its `animated` flag,
    /// which is what the two callers disagree about and all they disagree
    /// about: the first pass is arranging a control nobody has seen.
    private func trackTrailPointSearch(_ controller: TrailDraftController, animated: Bool) {
        applyTrailPointSearchVisibility(animated: animated)
        reobserving(self, controller) {
            _ = controller.isEditing
            _ = controller.finder.isSearching
            _ = controller.finder.searchableArea
            _ = controller.finder.notice
            // Every switch off disables the pill — see `canSearch`.
            _ = controller.finder.filter.hidden
            // And the one above them withdraws it.
            _ = controller.finder.filter.placesShown
        } onChange: { coordinator, model in
            coordinator.trackTrailPointSearch(model, animated: true)
        }
    }

    /// Takes the maker's pill off the map while a callout is open, and puts it
    /// back when one closes.
    ///
    /// The same reason the Community one is withdrawn: MapKit draws a callout
    /// *above* its pin, so a pin the camera has framed near the top of the map
    /// opens underneath the pill. The maker's own pins open the place sheet
    /// rather than a callout, so this is about the shared hikes' pins. Driven
    /// from ``withdrawAreaSearchForCallout(open:)``, which is where
    /// ``hasOpenCallout`` is kept, because there is one answer for both.
    func applyTrailPointSearchVisibility(animated: Bool) {
        #if os(iOS)
        guard let trailPointSearchControl, let controller = trailDraftController else { return }
        let finder = controller.finder
        // Withheld entirely on a launch with no source — a preview, or a UI
        // run that was never given one. A pill that spun and then said
        // *unavailable* would be worse than no pill: the honest statement is
        // that this launch cannot ask. Withdrawn too while the switch beside
        // *Search This Area* has hidden the trail's places: a search would add
        // pins nobody can see.
        let visible = controller.isEditing && finder.isAvailable && finder.filter.placesShown
            && !hasOpenCallout
        trailPointSearchControl.isSearching = finder.isSearching
        // Busy and out of range are different states and only one of them is a
        // policy — see ``MapCommunitySearchControl``, where the same pair of
        // reasons shares one `isEnabled` for the same reason: a control can
        // only be tapped or not, and the spinner is what tells them apart.
        trailPointSearchControl.isEnabled = finder.canSearch
        // Cleared along with the pill, so a caption never outlives the maker
        // it is about.
        trailPointSearchControl.notice = visible ? finder.notice?.caption : nil
        // The switch is re-read along with the maker when a fade-out lands,
        // because it withdraws the pill with the maker still up.
        trailPointSearchControl.fadeMapControl(visible: visible, restingAlpha: 1, animated: animated) { [weak self] in
            guard let self else { return false }
            return trailDraftController.map { $0.isEditing && $0.finder.filter.placesShown } != true
        }
        #endif
    }
}
