//
//  CommunityRoutePayload.swift
//  OpenHikes
//
//  The route JSON hanging off a public submission, read as what it is: a file
//  somebody else wrote.
//
//  Everything else about a shared hike arrives already suspected. A title and
//  a description are bounded by ``BoundedText`` because any client with an
//  Apple Account can write one; an outline is decoded by
//  ``CommunityRouteOutline/decoded(_:)``, which refuses a coordinate outside
//  the world and a line longer than the budget the map is sized against. The
//  full route was the hole in that: opening a listing read the whole asset,
//  decoded a ``CommunityRouteDocument`` out of it, and handed the result
//  straight to the map and to ``CommunityImport`` — so the one path that
//  produces a *saved* hike was the one path that checked nothing.
//
//  A person approving a listing in the CloudKit Console is not validation of
//  the file behind it. They read a title, a distance and a name; the route is
//  an asset they cannot open, and what a reviewer approves is the hike rather
//  than the JSON.
//
//  ## What is refused, and what is only cleaned
//
//  Both budgets refuse the route outright, for the reason the outline's point
//  budget refuses rather than truncates: a route cut down to fit is a trail
//  that stops in the middle of nowhere and claims to be somebody's walk.
//
//  A single unusable *point* is dropped instead, and the rest of the walk is
//  kept. That is the same call ``GPXImport`` makes about an unprojectable
//  waypoint and the same one ``CommunityRouteOutline/simplified(_:)`` already
//  makes on the way out, and it is the proportionate one: dropping a point
//  joins its neighbours, which is the shape a lost fix already leaves in every
//  recorded route, while refusing the walk costs the hiker a real trail over
//  one bad sample. A route with fewer than two points left is refused, because
//  that is not a line.
//
//  A refusal is an empty route, which is
//  ``CommunityRouteOutline/decoded(_:)``'s answer to the same question and
//  for the same reason: there is one way to say *no line here*, the callers
//  already have to handle a hike whose route did not arrive, and a second
//  spelling of nothing is a second branch at every call site.
//
//  It reaches the hiker as ``CommunityFailure/noLongerAvailable``, the same
//  sentence as a submission a reviewer has taken down. Both are true in the
//  only sense the hiker can act on — there is no hike here to open — and
//  "this route is malformed" is an invitation to do something about it that
//  nobody browsing can do.
//
//  ## Why this is not in the transport
//
//  So that it can be tested. A suite must never reach the real transport, and
//  the check that matters is the one applied to bytes rather than to a
//  `CKRecord` — so the decode is a seam taking a `URL` and a `Data`, and every
//  malformed and oversized case is exercised without an Apple Account, a
//  network or the public database. See `CommunityRoutePayloadTests`.
//

import CoreLocation
import Foundation
import OpenHikesShared

/// Reads the full route off a published submission, and refuses what should
/// not be drawn or saved.
nonisolated enum CommunityRoutePayload {
    /// What one published route is allowed to cost.
    ///
    /// Two bounds because neither implies the other, the same split
    /// ``GPXImport/Limits`` makes — and with the same honesty about which one
    /// does which. The byte cap is the one that bounds memory: it is checked
    /// against the file before `Data(contentsOf:)` is called, because that
    /// call brings the whole asset in as a single allocation and a size
    /// learned afterwards has already been paid for. The point cap bounds what
    /// is *used* — a polyline the map draws, a hit-test that projects every
    /// point of it on the main actor, a walk of the route for the elevation
    /// profile, and an array a saved `Hike` keeps for good. `JSONDecoder` does
    /// not stream, so the point cap cannot bound the decode itself; the byte
    /// cap is what stands in front of that.
    ///
    /// Taken as a parameter rather than read as a constant so the suite can
    /// drive both directly instead of having to build a 64 MB file; every
    /// caller in the app takes ``standard``.
    struct Limits: Sendable, Equatable {
        var maximumAssetBytes: Int
        var maximumPointCount: Int

        /// Sized so that nothing this app can publish is something it then
        /// refuses to open, which is the bound that actually matters here.
        ///
        /// The point cap is ``GPXImport/Limits/standard``'s, and deliberately
        /// the same number: a route reaches the library either from the
        /// recorder or from an imported GPX, the import is what can produce
        /// the larger of the two, and ``CommunityPublisher`` uploads a hike's
        /// route whole. A tighter cap here would mean a hike this app
        /// published and then declined to show.
        ///
        /// The byte cap is twice the GPX file cap for the same reason with a
        /// margin: the same points weigh less as JSON than as GPX XML — no
        /// element names, no ISO-8601 timestamps — so anything that got into
        /// the library through a 32 MB import fits well inside 64 MB on the
        /// way back out. A real day's walk is around 2 MB, so this is over an
        /// order of magnitude above anything anybody would recognise as their
        /// own hike.
        ///
        /// Both are loose on purpose, which is ``GPXImport``'s call and holds
        /// doubly here: a cap that refuses a real trail is worse than one that
        /// lets an absurd file through, and the hiker who loses the real trail
        /// is not the one who wrote the absurd file.
        static let standard = Self(
            maximumAssetBytes: standardAssetBytes,
            maximumPointCount: GPXImport.Limits.standard.maximumPointCount
        )

        private static let standardAssetBytes = 64 * 1024 * 1024
    }

    /// The route in the asset at `url`, or an empty array for one this app
    /// will not draw or save.
    ///
    /// The size is asked of the file system before the read, where the file
    /// system will answer — and checked again against what was actually read,
    /// because not every URL answers `.fileSizeKey`. A `CKAsset`'s URL points
    /// into CloudKit's own cache, which is exactly the kind of URL that may
    /// not.
    static func route(atAssetURL url: URL, limits: Limits = .standard) -> [RouteCoordinate] {
        contents(atAssetURL: url, limits: limits).route
    }

    /// The route and the places along it, read out of one asset.
    struct Contents: Equatable, Sendable {
        var route: [RouteCoordinate]
        var places: [TrailPlace]

        static let empty = Self(route: [], places: [])
    }

    /// The route in the asset at `url` and the places marked along it, or
    /// ``Contents/empty`` for a route this app will not draw or save — a
    /// refused route carries no places, because there is no trail for them to
    /// be on.
    static func contents(atAssetURL url: URL, limits: Limits = .standard) -> Contents {
        if let reportedSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           reportedSize > limits.maximumAssetBytes { return .empty }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return contents(from: data, limits: limits)
    }

    /// The same, from bytes already in hand.
    static func contents(from data: Data, limits: Limits = .standard) -> Contents {
        guard data.count <= limits.maximumAssetBytes,
              let document = try? JSONDecoder().decode(CommunityRouteDocument.self, from: data)
        else { return .empty }
        let route = usable(document.route, limits: limits)
        guard !route.isEmpty else { return .empty }
        return Contents(route: route, places: places(document.places))
    }

    /// The places a stranger's file lists, as this app will keep them.
    ///
    /// The route's own rules, applied to a second list from the same author:
    /// a place off the map is dropped rather than costing the others; the
    /// list is capped at ``GPXImport/maximumPlaces`` for the reason an
    /// imported file's is (every place becomes a record in the saving hiker's
    /// private database); names and notes are bounded as an imported `<wpt>`'s
    /// are; a symbol this build does not know is *no symbol*; and an
    /// OpenStreetMap element is kept only if it names one Overpass could
    /// have answered with, its facts re-read through ``TrailPlaceFact`` so
    /// they are bounded and limited to the tags this app shows.
    ///
    /// Duplicate ids keep the first: a photograph names its place by id, and
    /// two places answering to one id would be a photograph on both.
    static func places(_ raw: [CommunityPlace]) -> [TrailPlace] {
        var seen: Set<UUID> = []
        return raw.prefix(GPXImport.maximumPlaces).compactMap { place in
            guard Mercator.isRepresentable(latitude: place.latitude, longitude: place.longitude),
                  seen.insert(place.id).inserted
            else { return nil }
            let osm: TrailPlaceOSM? = {
                guard let type = place.osmElementType, TrailPlaceOSM.elementTypes.contains(type),
                      let id = place.osmElementID, id > 0 else { return nil }
                return TrailPlaceOSM(
                    elementType: type,
                    elementID: id,
                    facts: TrailPlaceFact.facts(in: place.osmTags ?? [:])
                )
            }()
            return TrailPlace(
                latitude: place.latitude,
                longitude: place.longitude,
                name: BoundedText.boundedOrEmpty(place.name, to: .title),
                symbol: place.symbol.flatMap(TrailPlaceSymbol.named),
                note: BoundedText.boundedOrEmpty(place.note, to: .notes),
                osm: osm,
                id: place.id
            )
        }
    }

    /// The same, from bytes already in hand.
    ///
    /// Where the suite works, and where the transport's own read lands once it
    /// has a file. The byte cap is applied here as well rather than trusted to
    /// the caller: this is the seam, and a seam that only checks what it is
    /// told to check is one more thing to get wrong at the next call site.
    static func route(from data: Data, limits: Limits = .standard) -> [RouteCoordinate] {
        contents(from: data, limits: limits).route
    }

    /// `route` with the points this app cannot use taken out, or an empty
    /// array for a route that is over budget or has no line left in it.
    ///
    /// The budget is spent before the points are cleaned, and on the count as
    /// it arrived: a route half of whose points are nonsense is not brought
    /// under the cap by discarding them.
    static func usable(
        _ route: [RouteCoordinate],
        limits: Limits = .standard
    ) -> [RouteCoordinate] {
        guard route.count <= limits.maximumPointCount else { return [] }
        let points = route.compactMap(usable)
        guard points.count >= 2 else { return [] }
        return points
    }

    /// One point, or `nil` for a position this app cannot project.
    ///
    /// ``Mercator/isRepresentable(latitude:longitude:)`` rather than
    /// `CLLocationCoordinate2DIsValid`, because it is the stricter of the two
    /// and it is the question actually being asked: everything here ends up on
    /// a Web Mercator map. It also settles `NaN` on the way — a range does not
    /// contain one — which `CLLocationCoordinate2DIsValid` does not.
    ///
    /// The height and the time are emptied rather than costing the point,
    /// which is ``GPXImport``'s distinction and the same one: a position is
    /// what the line is made of, while an elevation and a timestamp are fields
    /// the route can do without. `1e400` decodes to an infinity and `nan`
    /// decodes to a `NaN` — both are ordinary JSON numbers — and either one
    /// poisons every figure walked out of the route afterwards, because a
    /// `NaN` loses every comparison it is in and so survives `min` and `max`
    /// as the answer.
    private static func usable(_ point: RouteCoordinate) -> RouteCoordinate? {
        guard Mercator.isRepresentable(latitude: point.latitude, longitude: point.longitude)
        else { return nil }
        var usable = point
        if let elevation = point.elevation, !elevation.isFinite { usable.elevation = nil }
        if let timestamp = point.timestamp,
           !timestamp.timeIntervalSinceReferenceDate.isFinite { usable.timestamp = nil }
        return usable
    }
}
