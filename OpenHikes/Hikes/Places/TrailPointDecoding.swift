//
//  TrailPointDecoding.swift
//  OpenHikes
//
//  Turning one Overpass answer into places a hiker could mark.
//
//  Smaller than ``CuratedTrailDecoding`` by the whole of its interesting half:
//  there are no member ways to assemble here, because a place is one point.
//  What it does share is the reading that is not optional — an aborted query
//  answers with HTTP 200, well-formed JSON and a `remark`, and a decoder that
//  looked only at `elements` would read *the server gave up* as *there is
//  nothing here*. See ``OverpassRequest/abort(_:)``.
//
//  ## A candidate is an unmarked ``TrailPlace``, with its element beside it
//
//  Not a type of its own, and that is the phase's cheapest decision. What a
//  hiker does with one of these is mark it, and what marking it produces is a
//  ``TrailPlace`` — so the row view, the along-route ranking, the callout's
//  subtitle and the pin's glyph are all the ones Phase 4 already wrote, and
//  adopting is `addPlace` rather than a conversion. What makes a candidate a
//  candidate is only that nothing holds it yet.
//
//  What is *beside* it is the OSM element it came from, and that pairing has
//  one job: being the name of the file ``TrailPointStore`` keeps it in, so the
//  same spring is the same row across searches rather than a fresh `UUID`
//  every time. It goes no further than the store — see ``FoundTrailPlace``.
//
//  The name is left as OpenStreetMap has it, which is usually nothing at all.
//  Naming an unnamed one after its symbol happens where it is *adopted* rather
//  than here — see ``TrailDraftController/adopt(_:)`` — because until then
//  there is nothing to name: ``TrailPlace/displayName`` already reads an
//  unnamed waterfall as "Waterfall", and writing that into the field would
//  make the list of candidates a list of things that look as though somebody
//  had already named them.
//

import CoreLocation
import Foundation
import OpenHikesShared

nonisolated enum TrailPointDecoding {
    /// Every place in an `out tags center` response, in the order Overpass
    /// listed them.
    ///
    /// Order is not meaning here — it is Overpass's own — and what the hiker
    /// sees is sorted against the line they are drawing before it reaches a
    /// screen. See ``TrailPointRanking``.
    static func found(in data: Data) throws -> [FoundTrailPlace] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TrailGraphProviderError.malformedGraph(error.localizedDescription)
        }
        if let abort = OverpassRequest.abort(response.remark) { throw abort }
        return response.elements.compactMap(found(in:))
    }

    /// One element as a place, or `nil` for one this app cannot draw.
    ///
    /// Four ways to be `nil` and all four are the element's fault rather than
    /// a failure: a way with no `center` (nothing to put a pin at), a
    /// coordinate the projection cannot take, an element carrying none of the
    /// tags ``TrailPointQuery/kinds`` names, and one with no `type` or `id` —
    /// which `out` writes for every element it has ever emitted, and without
    /// which there is nothing to file the answer under.
    ///
    /// The tag one is worth stating: a place with no symbol would draw a plain
    /// pin and read as "Place", which is a thing the hiker marked themselves
    /// rather than an answer to *what is here*.
    private static func found(in element: Element) -> FoundTrailPlace? {
        guard let symbol = TrailPointQuery.symbol(for: element.tags) else { return nil }
        guard let type = element.type, let id = element.id else { return nil }
        guard let latitude = element.lat ?? element.center?.lat,
              let longitude = element.lon ?? element.center?.lon,
              Mercator.isRepresentable(latitude: latitude, longitude: longitude)
        else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return FoundTrailPlace(
            elementType: type,
            elementID: id,
            place: TrailPlace(
                coordinate: coordinate,
                // Bounded where it enters, like every other name that arrives
                // unattended — see ``HikeTitle``. `nil` becomes empty, which
                // is how a hiker says *unnamed* and what the vast majority of
                // these are.
                name: BoundedText.boundedOrEmpty(element.tags["name"], to: .title),
                symbol: symbol
            )
        )
    }
}

// MARK: - The wire format

nonisolated extension TrailPointDecoding {
    /// A way's or relation's representative point, which is what `out center`
    /// puts on it in place of an outline.
    struct Centre: Decodable {
        let lat: Double
        let lon: Double
    }

    struct Element: Decodable {
        /// `node`, `way` or `relation`, and the element's own id.
        ///
        /// Optional in the reading rather than in the format — `out` writes
        /// both for every element it emits — so a mirror that omitted one
        /// would cost that element rather than the whole answer.
        let type: String?
        let id: Int64?
        let lat: Double?
        let lon: Double?
        let center: Centre?
        let tags: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            id = try container.decodeIfPresent(Int64.self, forKey: .id)
            lat = try container.decodeIfPresent(Double.self, forKey: .lat)
            lon = try container.decodeIfPresent(Double.self, forKey: .lon)
            center = try container.decodeIfPresent(Centre.self, forKey: .center)
            tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        }

        enum CodingKeys: String, CodingKey {
            case type = "type"
            case id = "id"
            case lat = "lat"
            case lon = "lon"
            case center = "center"
            case tags = "tags"
        }
    }

    struct Response: Decodable {
        let elements: [Element]
        /// What the server has to say about a query it did not finish — see
        /// ``found(in:)`` for why reading it is not optional.
        let remark: String?
    }
}
