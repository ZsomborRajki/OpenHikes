//
//  CommunityBrowser+CommonsPhotos.swift
//  OpenHikes
//
//  The *Community* tab's Wikimedia Commons photographs, as the map reads them
//  and as a tap on one leaves it — see ``CommunityCommonsPhotos`` for when
//  they are asked for.
//

import Foundation
import MapKit

extension CommunityBrowser {
    /// The photographs the map stands on the area the list answers about.
    ///
    /// Empty while the tab is away, for the reason ``nearbyListings`` is: the
    /// photographs outlive ``stopBrowsing()`` with the rows, and the drawing of
    /// them must not. Read by `MapCommunityAnnotations.swift`'s observation,
    /// so a search landing redraws MapKit's annotations and no SwiftUI view.
    var commonsPins: [CommonsPhoto] {
        isBrowsing ? areaPhotos.shown : []
    }

    /// Where a tapped photo pin goes. Set by ``OpenHikesView``, which owns the
    /// sheet's navigation path, for the reason ``onOpenListing(_:)`` is.
    func onOpenCommonsPhoto(_ open: @escaping (CommonsPhoto) -> Void) {
        openCommonsPhoto = open
    }

    /// Opens a photograph's screen. Called from the map's photo pins.
    func open(_ photo: CommonsPhoto) {
        openCommonsPhoto?(photo)
    }

    /// Where a tapped group of photo pins goes — photographs standing too
    /// close together to draw apart. Set by ``OpenHikesView`` with the other
    /// two.
    func onOpenCommonsPhotos(_ open: @escaping ([CommonsPhoto]) -> Void) {
        openCommonsPhotos = open
    }

    /// Opens a group's grid, newest first. Called from the map's grouped
    /// photo pins — see `MapCommunityCommonsPhotos.swift`.
    func open(_ group: [CommonsPhoto]) {
        openCommonsPhotos?(group)
    }

    /// The part of a searched `area` the map is showing: what Commons is
    /// asked about.
    ///
    /// Not the area itself, which is never narrower than
    /// ``CommunityQueryPolicy/minimumRadiusMeters`` so the list can offer the
    /// trails a short drive away. A photograph is only worth anything as a
    /// thumbnail the hiker can see, and sixteen spread over ten kilometres
    /// around a map zoomed to two would leave one or two on screen. So the
    /// circle is the visible one — and never wider than the area, nor than a
    /// geosearch goes, which ``WikimediaCommonsSource`` clamps.
    static func photoArea(
        of area: CommunitySearchArea,
        showing region: MKCoordinateRegion?
    ) -> CommunitySearchArea {
        guard let region else { return area }
        let visible = CommunityQueryPolicy.visibleRadiusMeters(for: region)
        // The rectangle travels with it, because it is what the photographs
        // are kept inside. Commons is asked about the circle through its
        // corners, which reaches further than this one — see
        // ``CommonsAreaPhotos`` — and a stand-in stands its own inside it —
        // see ``SeededCommonsPhotoSource``.
        return CommunitySearchArea(
            coordinate: area.coordinate,
            radiusMeters: min(area.radiusMeters, visible),
            visibleSpan: area.visibleSpan
        )
    }
}
