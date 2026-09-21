//
//  TrailPointQuery.swift
//  OpenHikes
//
//  What this app asks OpenStreetMap when a hiker wants to know what is near
//  the trail they are drawing — and, mostly, what it deliberately does not
//  ask for.
//
//  ``MKLocalSearch`` cannot answer this question and the reason is countable.
//  Measured on 2026-09-21 against `overpass-api.de` (0.7.62.11) over the box
//  the curated work uses, `47.52,12.85,47.72,13.10` — about 22 × 19 km of the
//  densest Alpine mapping there is — the share of each kind of place that
//  carries a `name` at all:
//
//      natural=peak            200   89% named
//      tourism=viewpoint       122   19%
//      amenity=drinking_water   70    5%
//      amenity=parking          38    5%
//      natural=saddle           35   85%
//      amenity=shelter          20   25%
//      natural=spring           20   25%
//      waterway=waterfall       18   22%
//      tourism=alpine_hut        1  100%
//
//  **Unnamed is the normal case**, and a search index that keys on names
//  cannot offer four fifths of the best answers this feature has. A summit is
//  named because a summit *is* a name; a waterfall, a spring and a viewpoint
//  mostly are not. So a row and a pin here are built from the **symbol** plus
//  **how far along the line** the thing sits — "Waterfall · 2.3 km" — and a
//  name is the optional extra it usually is not. See ``TrailPlace/displayName``.
//
//  ## What is left out, and why each one
//
//  **`tourism=information` is not asked for, and that single exclusion is
//  most of the answer.** It is 579 of the 1,206 elements every candidate tag
//  returns over that box — 48% — and 6% of them carry a name. They are the
//  boards, the maps and the guideposts; they cluster at every junction and
//  trailhead; and on screen they are not information at all but a wall of
//  identical pins over the line the hiker is trying to draw. `amenity=toilets`
//  is 55 more of the same kind of noise. Excluded, they are 57% of the bytes.
//
//  **`natural=cave_entrance`** (35 in the box, 63% named) has no glyph in the
//  eight ``TrailPlaceSymbol`` offers, and **`tourism=picnic_site`** (8, none
//  named) has none either — a picnic table is not a ``TrailPlaceSymbol/camp``.
//  Both are left out rather than forced into a symbol that would make a claim
//  about a place this app has never been. Adding a ninth symbol later is a
//  case in an enumeration.
//
//  **`junction` and `caution` are asked for nothing at all.** The only OSM
//  answer for a junction *is* the guidepost, which is the 579 rows above; and
//  a hazard — loose rock, a ford that is up, a traverse nobody liked — is a
//  judgement about a place rather than a tag on one. Both stay hand-placed,
//  which is exactly what Phase 4 already builds. A search that has nothing to
//  offer for two of eight symbols is a search that says so rather than one
//  that invents a mapping.
//
//  ## Nodes, except where the thing is a building
//
//  Measured over the same box on 2026-09-21:
//
//      node[...]   526 elements   99 KB
//      nwr[...]  1,275 elements  272 KB
//
//  and **695 of those 749 extra elements are car parks drawn as polygons**.
//  That is `tourism=information` again in another costume: three times the
//  bytes to put a pin on every kerbside bay in the valley. But the rest of the
//  difference is the good half — a mountain hut is routinely a building, so
//  `tourism=alpine_hut` goes from 1 to 7 over that box and `amenity=shelter`
//  from 20 to 53. So areas are asked for exactly where a place is normally
//  mapped as one and nowhere else: 578 elements and 122 KB, measured, which is
//  99 KB of nodes plus 23 KB of huts.
//
//  `out tags center` is what makes that affordable — a way comes back as its
//  tags and one coordinate rather than as its outline.
//

import CoreLocation
import Foundation

/// The Overpass request a *Search this area* in the trail maker makes, and
/// the table of what counts as a place worth offering.
///
/// A type of its own beside ``CuratedTrailQuery`` for the same reason that one
/// is separate from its fetcher: which tags count, how wide a box is worth
/// asking for and which of them is a summit are decisions that are invisible
/// in the result and would otherwise only be testable through the network.
nonisolated enum TrailPointQuery {
    /// The widest search this will ask Overpass about, in metres of radius.
    ///
    /// **Set by density rather than by taste, and the figures in this file's
    /// header are its worst case.** A 10 km radius circumscribes a 20 × 20 km
    /// box, which is within a per cent of the 22 × 19 km box everything above
    /// was measured over — so a search at the ceiling, in the densest mapping
    /// there is, is the 578 elements and 122 KB recorded there.
    ///
    /// Deliberately a quarter of ``CuratedTrailQuery/maximumRadiusMeters``.
    /// That one lists relations, whose count grows slowly with area; this
    /// lists individual features, whose count grows with it directly — 40 km
    /// is roughly fifteen times the area, some 8,000 elements and well over a
    /// megabyte, to fill a map the hiker cannot read anyway.
    static let maximumRadiusMeters: Double = 10_000

    /// How long Overpass is allowed to spend on it, in seconds.
    ///
    /// The same figure ``CuratedTrailQuery/listingTimeoutSeconds`` uses, and
    /// for the same reason: this is a tag scan over a box and is quick, and it
    /// sits under the client's own patience so the server gives up first and
    /// the app gets a diagnosable answer rather than a cancelled socket. See
    /// ``OverpassRequest/idleTimeout(forServerTimeout:)``.
    static let timeoutSeconds = 25

    /// How many of the answers are kept, drawn and listed.
    ///
    /// 578 pins is not a map, so the nearest few to the line are what the
    /// hiker is offered — see ``TrailPointRanking``. Forty because it is about
    /// what a valley's worth of drawn trail actually has beside it and about
    /// as long a list as anybody scrolls; it is the one number in this phase
    /// picked by argument rather than measured, and the thing to check it
    /// against is a screenshot rather than a paragraph.
    static let maximumResults = 40

    /// One kind of place: what OpenStreetMap calls it, and which of the eight
    /// symbols it is drawn as.
    ///
    /// A value rather than a dictionary from tag to symbol, because two of the
    /// three facts here are not the symbol: whether areas are asked for is per
    /// kind (see this file's header), and the order the list is written in is
    /// the order a tie is broken in — a peak that is also tagged a viewpoint
    /// is a summit.
    struct Kind: Equatable, Sendable {
        let key: String
        let value: String
        let symbol: TrailPlaceSymbol
        /// Whether ways and relations are asked for as well as nodes. True
        /// only where the thing is normally a building or an enclosure.
        let includesAreas: Bool

        init(_ key: String, _ value: String, _ symbol: TrailPlaceSymbol, includesAreas: Bool = false) {
            self.key = key
            self.value = value
            self.symbol = symbol
            self.includesAreas = includesAreas
        }
    }

    /// Everything this asks for, in the order a tie is broken in.
    ///
    /// Summits first, because a peak that also carries `tourism=viewpoint` is
    /// a summit to a hiker; water before shelter, because a spring beside a
    /// hut is the thing you were looking for.
    static let kinds: [Kind] = [
        Kind("natural", "peak", .summit),
        Kind("natural", "saddle", .summit),
        Kind("waterway", "waterfall", .water),
        Kind("natural", "spring", .water),
        Kind("amenity", "drinking_water", .water),
        Kind("tourism", "alpine_hut", .shelter, includesAreas: true),
        Kind("tourism", "wilderness_hut", .shelter, includesAreas: true),
        Kind("amenity", "shelter", .shelter, includesAreas: true),
        Kind("tourism", "viewpoint", .viewpoint),
        Kind("tourism", "camp_site", .camp, includesAreas: true),
        Kind("amenity", "parking", .parking),
    ]

    /// The boxes a search of `area` asks about: one, two where the circle
    /// crosses the antimeridian, or none at all.
    ///
    /// ``CuratedTrailQuery/searchBoxes(for:)`` does the arithmetic, including
    /// the date-line split, because a circumscribing box is the same geometry
    /// problem whichever feature is asking. What is this type's own is the
    /// ceiling in front of it: that one refuses at 40 km and this refuses at
    /// 10, so the guard here is what makes the header's figures true.
    ///
    /// `[]` rather than a throw for a search too wide to make, which is an
    /// answer and is drawn as one — the pill dims, exactly as it does above
    /// the community list's own ceiling.
    static func searchBoxes(for area: CommunitySearchArea) -> [CuratedTrailQuery.BoundingBox] {
        guard area.radiusMeters > 0, area.radiusMeters <= maximumRadiusMeters else { return [] }
        return CuratedTrailQuery.searchBoxes(for: area)
    }

    /// Every place worth offering whose node — or, for the four kinds that are
    /// normally buildings, whose way or relation — touches one of `boxes`.
    ///
    /// A union of filters, and a union even when there is one box, for the
    /// reason ``CuratedTrailQuery/listingQuery(in:)`` is: that is what lets an
    /// antimeridian search be a single request rather than two. `nil` for no
    /// boxes at all — a caller with nothing to ask about should not be making
    /// a request.
    static func query(in boxes: [CuratedTrailQuery.BoundingBox]) -> String? {
        guard !boxes.isEmpty else { return nil }
        let filters = boxes.flatMap { box in
            kinds.map { kind in
                let element = kind.includesAreas ? "nwr" : "node"
                return "  \(element)[\"\(kind.key)\"=\"\(kind.value)\"](\(box.overpassLiteral));"
            }
        }
        .joined(separator: "\n")
        return """
        [out:json][timeout:\(timeoutSeconds)];
        (
        \(filters)
        );
        out tags center;
        """
    }

    /// Which of the eight symbols `tags` describes, or `nil` for an element
    /// that carries none of them.
    ///
    /// In ``kinds`` order rather than in the dictionary's, which has none:
    /// one element frequently carries several of these tags, and a viewpoint
    /// on a summit has to come back as the same symbol every time or the same
    /// search would draw a different map twice.
    ///
    /// `nil` is reachable even though every element was asked for by one of
    /// these filters — a relation can arrive with its members' tags, and a
    /// mirror can answer with more than was asked. A place this cannot name is
    /// not offered; see ``TrailPointDecoding``.
    static func symbol(for tags: [String: String]) -> TrailPlaceSymbol? {
        kinds.first { kind in tags[kind.key] == kind.value }?.symbol
    }
}
