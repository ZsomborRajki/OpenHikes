//
//  CommunityQueryPolicy.swift
//  OpenHikes
//
//  Decides whether the map having moved is a new question, separately from
//  asking it.
//
//  Its own type for the reason ``SearchQueryPolicy`` and ``TileNetworkPolicy``
//  are theirs: the interesting behaviour is the requests that must *not* be
//  made, and those are invisible in the result. A pan that changes nothing and
//  a pan that was never asked about both leave the same rows on screen.
//
//  ## Deciding and asking are two steps, and the hiker is in between
//
//  This used to return "search now", and the browser searched. The thresholds
//  below were the *whole* of the decision, which made them do a job they are
//  not shaped for: a hiker panning across a county watched the list under
//  their thumb replace itself for reasons they had no way to see, while a
//  pan the thresholds refused left the list describing somewhere else with
//  nothing on screen admitting it.
//
//  So a region that clears the thresholds is now an ``CommunityQueryAction/offer``
//  — drawn as *Search this area* over the map — and ``commit(_:)`` is what
//  records it, when the hiker takes it. The thresholds are unchanged and
//  still load-bearing; what changed is that they now decide when to *ask the
//  hiker* rather than when to ask CloudKit, which is strictly cheaper: a pan
//  nobody confirms costs nothing at all.
//
//  There are three separate reasons to refuse, and they are worth naming
//  because only one of them is the obvious one.
//
//  1. **The server cannot tell, and the other one is being asked nicely.**
//     CloudKit's `distanceToLocation:` resolves at around ten kilometres, so
//     nudging the map two streets over asks a different question and gets the
//     same answer back — offering to re-ask after every small pan would be a
//     button that changes nothing. That was the whole of the argument while
//     CloudKit was the whole of the list. It is not any more: an accepted
//     offer now also spends an Overpass request, against a volunteer-run API
//     that allows a handful of slots per address, so ``recenterFraction`` is
//     set by the source that minds being asked rather than by the one that
//     cannot tell the difference.
//  2. **A country is not a place.** Zoomed out far enough, "near here" stops
//     meaning anything — every hike in Europe is within the radius, and the
//     twenty that come back are twenty arbitrary ones. Above the ceiling the
//     honest answer is ``CommunityQueryAction/tooFarOut``, which the sheet
//     says in as many words rather than leaving a button that would answer
//     badly.
//  3. **Nobody asked.** Browsing is opt-in, and a hiker who has never asked
//     for shared hikes should never put a request on the radio — the same
//     bargain the rest of the app's energy policies make.
//
//  ## One ceiling, and it is OpenStreetMap's
//
//  There used to be two, 150 km here and 40 km in ``CuratedTrailQuery``, and
//  the band between them was written down as intended rather than as a gap.
//  It was a gap. Inside it the pill was enabled, a tap spent a CloudKit query,
//  and the curated half answered `[]` with no failure to report — so a hiker
//  looking at 100 km of map tapped *Search this area*, got no trails, and had
//  nothing on screen telling them that zooming in was the answer. Two ceilings
//  also meant two sentences to keep true about one control.
//
//  So this one *is* ``CuratedTrailQuery/maximumRadiusMeters`` rather than
//  merely being checked against it. What is given up is searching published
//  hikes between 40 and 150 km, and the argument above is the reason that is
//  affordable: a result that wide was already twenty arbitrary hikes.
//

import CoreLocation
import Foundation
import MapKit
import OpenHikesData

/// What the latest map region means for the community list.
enum CommunityQueryAction: Equatable {
    /// Leave everything alone. Nothing moved far enough to be a different
    /// question, or browsing is off.
    case ignore
    /// This is a different question, and the hiker may ask it.
    case offer(CommunitySearchArea)
    /// The map is too far out for "near here" to mean anything. Distinct from
    /// ``ignore`` because there is something to *say* — see
    /// ``CommunityQueryPolicy/maximumRadiusMeters``.
    case tooFarOut
}

/// The little state machine behind ``CommunityBrowser``: one remembered
/// query, and the two thresholds that decide whether the next region is the
/// same question.
struct CommunityQueryPolicy {
    /// Smallest radius worth asking CloudKit about. Under this the server's
    /// own resolution is coarser than the question, so a smaller number would
    /// narrow the wording and not the answer.
    ///
    /// CloudKit's floor and nobody else's. OpenStreetMap is asked about the
    /// rectangle the hiker could see, however small, and Overpass answers a
    /// box exactly — see ``CommunitySearchArea/visibleSpan``. It used to
    /// inherit this one as a twenty-kilometre square, which at a valley's zoom
    /// was seventeen times the map above the sheet.
    static let minimumRadiusMeters: Double = 10_000
    /// Largest radius worth asking about, and the zoom ceiling with it: past
    /// this a result means "somewhere on this continent".
    ///
    /// **``CuratedTrailQuery/maximumRadiusMeters`` itself, not a number of its
    /// own.** See *One ceiling, and it is OpenStreetMap's* above. Spelled as a
    /// reference rather than copied so the two cannot drift back apart, which
    /// is how the band between them appeared in the first place.
    static let maximumRadiusMeters: Double = CuratedTrailQuery.maximumRadiusMeters
    /// How far the centre has to move, as a fraction of the last radius,
    /// before the question counts as a new one.
    ///
    /// Half, where it used to be a quarter. A quarter is the point at which
    /// *CloudKit's* answer can differ, and that was the right figure while
    /// CloudKit was the only thing being asked. Taking an offer now also
    /// spends an Overpass listing pass — and a geometry pass, for anything not
    /// already on the device — so the question this threshold answers is no
    /// longer "could the rows change" but "is this worth inviting a request
    /// for against a shared quota".
    ///
    /// It costs the hiker nothing, which is what makes it affordable: the pill
    /// stands for the whole *Community* tab rather than only while an offer is
    /// up, so a tap with no offer standing still re-asks through
    /// ``CommunityBrowser/retry()``. What a refused offer withholds is the
    /// invitation, never the ability.
    static let recenterFraction: Double = 0.5
    /// How far the radius has to change before a zoom counts as a new
    /// question, either way.
    private static let zoomFactor: Double = 2

    /// Whether the hiker has asked for community hikes at all. Nothing is
    /// offered or requested while this is false — ``action(for:)`` answers
    /// ``CommunityQueryAction/ignore`` to every settle — and the last
    /// committed query survives being turned off, so coming back to an
    /// unmoved map is recognised as the same question. See
    /// ``startBrowsing()``.
    private(set) var isBrowsing = false
    private var committed: CommunitySearchArea?

    /// Queries actually committed. The policy is otherwise invisible from
    /// outside — a refused pan and a pan nobody made look identical — so this
    /// is what pins it in tests.
    private(set) var issuedQueries = 0

    /// The tab was selected. Keeps the last committed query, so a hiker who
    /// comes back to a map they have not moved is asking the same question.
    ///
    /// Both of these used to forget it, so that turning the section back on
    /// asked again rather than showing a list from wherever the map used to
    /// be. The list is no longer from wherever the map used to be:
    /// ``CommunityBrowser/stopBrowsing()`` now keeps its rows and the area
    /// they answer, so forgetting here would make the returning region look
    /// like a new question and spend a request replacing rows that are already
    /// right — and, worse, replacing them with a
    /// ``CommunityNearbyScope/publishedOnly`` answer that has no OpenStreetMap
    /// trails in it at all.
    ///
    /// The browser forgets explicitly on the one path where this memory is of
    /// a question that never answered — see ``forgetLastQuery()``.
    mutating func startBrowsing() {
        isBrowsing = true
    }

    /// The tab was left. Keeps the last committed query for the same reason
    /// ``startBrowsing()`` does; ``isBrowsing`` alone is what stops anything
    /// being offered in the meantime.
    mutating func stopBrowsing() {
        isBrowsing = false
    }

    /// What the map settling on `region` means.
    ///
    /// `region` is the part of the map the hiker can see — the map above the
    /// sheet, which is what `MapView.Coordinator` hands over rather than its
    /// whole view; see ``MapView/Coordinator/areaSearchRegion(of:sheet:)``.
    /// So its centre is the middle of what is on screen, which is where the
    /// rows are sorted outward from, and its span is the rectangle
    /// OpenStreetMap is asked about.
    ///
    /// Takes the region rather than a coordinate and a radius because the
    /// radius *is* the zoom: a hiker who has zoomed into one valley is asking
    /// about that valley, and one looking at a whole county is asking about
    /// the county. Deriving it here rather than at the call site is what keeps
    /// the zoom ceiling and the radius from being two separate opinions.
    ///
    /// Deliberately free of side effects. It is called on every settle — a
    /// pan produces a run of them — and an offer the hiker never takes must
    /// leave the remembered query exactly where it was, or the second settle
    /// of one gesture would withdraw the offer the first one made.
    func action(for region: MKCoordinateRegion) -> CommunityQueryAction {
        guard isBrowsing else { return .ignore }
        // Above the ceiling nothing is offered and nothing is forgotten:
        // zooming out to look at the country and back in to the same valley
        // should leave the valley's results standing rather than re-fetch
        // them.
        guard Self.isWithinCeiling(region) else { return .tooFarOut }
        // Both shapes of the one question: the floored circle CloudKit is
        // asked about, and the rectangle itself, which is what OpenStreetMap
        // is asked about — see ``CommunitySearchArea``.
        let area = CommunitySearchArea(
            coordinate: region.center,
            radiusMeters: max(Self.visibleRadiusMeters(for: region), Self.minimumRadiusMeters),
            visibleSpan: CommunitySearchArea.Span(
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta
            )
        )

        // Both thresholds measure the floored circle CloudKit is asked about,
        // not the rectangle OpenStreetMap is asked about, so from a view
        // narrower than the floor a pan can take the rectangle off what was
        // searched without raising an offer. That decides only whether the
        // prompt says ``CommunityAreaPrompt/search`` or
        // ``CommunityAreaPrompt/settled``, which nothing draws today: the
        // pill is permanent, and a tap with no offer standing re-asks through
        // ``CommunityBrowser/retry()``, which forgets this memory first. It
        // would start to matter if an offer were ever drawn again.
        if let committed {
            let moved = RouteGeometry.distanceMeters(
                from: committed.coordinate,
                to: area.coordinate
            )
            let zoomed = area.radiusMeters > committed.radiusMeters * Self.zoomFactor
                || area.radiusMeters < committed.radiusMeters / Self.zoomFactor
            guard moved > committed.radiusMeters * Self.recenterFraction || zoomed else {
                return .ignore
            }
        }

        return .offer(area)
    }

    /// Records `area` as the question the list is now answering, so the
    /// regions around it stop being offered.
    ///
    /// Separate from ``action(for:)`` because the hiker is between the two:
    /// an offer they ignore has to stay on screen through every settle of the
    /// gesture that raised it.
    mutating func commit(_ area: CommunitySearchArea) {
        issuedQueries += 1
        committed = area
    }

    /// Drops the remembered query without turning browsing off, so the next
    /// region is a new question whatever it is.
    ///
    /// What a retry means, and what a failed request leaves behind: a query
    /// that came back empty because the network was down must not be the
    /// reason the same region is never asked about again.
    mutating func forgetLastQuery() {
        committed = nil
    }

    /// Whether `region` is zoomed in far enough to be asked about at all.
    ///
    /// The *unclamped* radius is what the ceiling is tested against, and the
    /// distinction is load-bearing: clamping first would make every region
    /// look like it was exactly at the ceiling and this could never refuse
    /// one. Written as "within" rather than "past" so a region whose radius is
    /// not a number is refused rather than searched.
    ///
    /// Shared with the pill's tap, not only ``action(for:)``. A region the tap
    /// hands the browser has to be one this accepts, or the browser settles on
    /// a map it refuses, dims the pill it came from and asks nothing — see
    /// ``MapView/Coordinator/areaSearchRegionForTap(of:within:)``.
    static func isWithinCeiling(_ region: MKCoordinateRegion) -> Bool {
        visibleRadiusMeters(for: region) <= maximumRadiusMeters
    }

    /// Half the longer edge of the visible region, unclamped.
    ///
    /// The longer edge rather than the shorter so the circle reaches every
    /// edge of the screen: a hiker can see a trailhead at the edge of the
    /// map, and a radius that excluded it would be showing a hike and
    /// refusing to list it. It still falls short of the corners, which only
    /// half the diagonal reaches. That is the circle Commons is asked about,
    /// because its answer is kept to the screen — see ``CommonsAreaPhotos``.
    ///
    /// Returned raw so ``isWithinCeiling(_:)`` can tell "zoomed out past the
    /// ceiling" from "at the ceiling", which are different answers.
    static func visibleRadiusMeters(for region: MKCoordinateRegion) -> Double {
        let metersPerDegree = RouteGeometry.metersPerDegreeLatitude
        let latitudeMeters = region.span.latitudeDelta * metersPerDegree
        let longitudeMeters = region.span.longitudeDelta * metersPerDegree
            * cos(region.center.latitude * .pi / 180)
        return max(latitudeMeters, abs(longitudeMeters)) / 2
    }
}
