//
//  CommonsAreaPhotos.swift
//  OpenHikes
//
//  Which Wikimedia Commons photographs to show for an area of the map rather
//  than along a route — the trail maker's *Search this area*, and the
//  *Community* tab's.
//
//  ``CommonsTrailPhotos`` spreads a route's photographs along its length,
//  because a line has one dimension and *one per stretch* is what keeps a
//  dozen pictures from being twelve of the car park. An area has two, and the
//  same argument becomes a grid: the map on screen is cut into cells, each
//  cell offers the photograph nearest its own middle, and only once every cell
//  has had its turn do the rest fill in from the middle of the area outwards.
//  A geosearch answers nearest its centre first and stops at five hundred, so
//  without the grid a valley's whole allowance went to the village at the
//  middle of the screen.
//
//  ## The map on screen, asked about as a circle
//
//  Both pills hand over the rectangle of map above the sheet — see
//  ``CommunitySearchArea/visibleSpan`` — with a circle half as wide as its
//  longer side. A geosearch takes only a circle, and that one misses the
//  corners of the screen. So the circle asked about is the one through the
//  corners. What comes back is kept inside the rectangle, and the grid is cut
//  over it. With the sheet lowered the map is taller than it is wide, and a
//  grid over the circle's square spent half its cells off both sides of the
//  screen. A geosearch reaches no further than
//  ``CommonsTrailPhotos/maximumRadiusMeters``, so a rectangle wider than that
//  circle is kept and gridded only as far as the circle reaches. An area that
//  carries no rectangle is only a circle, and its square is the grid.
//
//  The per-photographer rule is the route's and for its reason: one uploader's
//  run of forty pictures of the same road is the commonest shape of a Commons
//  answer near a trail. Past ``CommonsTrailPhotos/perAuthorLimit`` from one
//  person, the rest only go into cells nothing else covers.
//
//  The pins stay where the camera stood. A route's photographs are snapped
//  onto it because a pin on a line is a claim about *where along it*; here
//  there is no line yet, and the spot is exactly what *Add Stop* is offered on.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum CommonsAreaPhotos {
    /// How many photographs one search shows at most: a four-by-four grid's
    /// worth, and about the dozen a curated route's strip carries, since each
    /// one is a thumbnail downloaded for a screen that may be glanced at.
    static let photoLimit = 16

    /// `area` as one geosearch asks about it: through the corners of its
    /// rectangle when it carries one, and no wider than a geosearch may ask
    /// about. The rectangle stays on it, because it is what the answer is
    /// kept inside — see this file's header.
    static func asked(_ area: CommunitySearchArea) -> CommunitySearchArea {
        var asked = area
        if let corner = corner(of: area) {
            asked.radiusMeters = (corner.east * corner.east + corner.north * corner.north).squareRoot()
        }
        guard asked.radiusMeters > CommonsTrailPhotos.maximumRadiusMeters else { return asked }
        asked.radiusMeters = CommonsTrailPhotos.maximumRadiusMeters
        return asked
    }

    /// At most `limit` of `candidates`, one per cell of a grid over `area`
    /// first, nearest the middle of the area first after that — returned
    /// nearest the middle first. Only what stands inside the area's rectangle
    /// and within its radius is kept.
    static func spread(
        _ candidates: [CommonsPhotoCandidate],
        in area: CommunitySearchArea,
        limit: Int
    ) -> [CommonsPhotoCandidate] {
        guard limit > 0 else { return [] }
        let reach = reach(of: area)
        let inside = candidates.uniqued(on: \.pageID).filter { candidate in
            let offset = offset(of: candidate, in: area)
            return offset.distance <= area.radiusMeters
                && abs(offset.east) <= reach.east
                && abs(offset.north) <= reach.north
        }
        let nearer = { (lhs: CommonsPhotoCandidate, rhs: CommonsPhotoCandidate) in
            nearerTheMiddle(lhs, rhs, of: area)
        }
        guard inside.count > limit else { return inside.sorted(by: nearer) }
        let side = side(for: limit)
        let byCell = Dictionary(grouping: inside) { cell(of: $0, in: area, side: side) }
        // A grid has at least `limit` cells, so there can be more first picks
        // than room for them; the ones nearest the middle are kept.
        var picked = Array(
            byCell.map { key, members in
                members.min { lhs, rhs in
                    nearerTheMiddle(lhs, rhs, ofCell: key, in: area, side: side)
                } ?? members[0]
            }
            .min(count: limit, sortedBy: nearer)
        )
        if picked.count < limit {
            let taken = Set(picked.map(\.pageID))
            picked += inside.filter { !taken.contains($0.pageID) }.min(count: limit - picked.count, sortedBy: nearer)
        }
        return picked.sorted(by: nearer)
    }

    /// The `limit` photographs to show out of the files that turned out to be
    /// showable, holding back a photographer's fourth and later pictures to
    /// cells nothing else covers.
    static func chosen(
        _ candidates: [CommonsPhotoCandidate],
        authors: [Int: String],
        limit: Int,
        in area: CommunitySearchArea
    ) -> [CommonsPhotoCandidate] {
        let nearer = { (lhs: CommonsPhotoCandidate, rhs: CommonsPhotoCandidate) in
            nearerTheMiddle(lhs, rhs, of: area)
        }
        var taken: [String: Int] = [:]
        var preferred: [CommonsPhotoCandidate] = []
        var heldBack: [CommonsPhotoCandidate] = []
        for photo in candidates.sorted(by: nearer) {
            guard let author = authors[photo.pageID] else {
                preferred.append(photo)
                continue
            }
            let count = taken[author, default: 0]
            if count < CommonsTrailPhotos.perAuthorLimit {
                taken[author] = count + 1
                preferred.append(photo)
            } else {
                heldBack.append(photo)
            }
        }
        let first = spread(preferred, in: area, limit: limit)
        guard first.count < limit else { return first }
        let side = side(for: limit)
        let covered = Set(first.map { cell(of: $0, in: area, side: side) })
        let gaps = Dictionary(grouping: heldBack) { cell(of: $0, in: area, side: side) }
            .filter { !covered.contains($0.key) }
            .values
            .compactMap { $0.min(by: nearer) }
            .sorted(by: nearer)
        return (first + gaps.prefix(limit - first.count)).sorted(by: nearer)
    }

    // MARK: - The grid

    /// How many cells a side of the grid has: enough that there is a cell for
    /// every photograph wanted.
    private static func side(for limit: Int) -> Int {
        max(1, Int(Double(limit).squareRoot().rounded(.up)))
    }

    private struct Cell: Hashable {
        var column: Int
        var row: Int
    }

    /// Metres east and north of the area's middle, and the distance between.
    ///
    /// Flat, which is the right amount of geometry for a circle no more than
    /// twenty kilometres across: the grid is a way of spreading pictures, not
    /// a survey. East is measured the short way round, so a photograph a
    /// kilometre over the date line is a kilometre away and not a lap of the
    /// planet.
    private static func offset(
        of candidate: CommonsPhotoCandidate,
        in area: CommunitySearchArea
    ) -> (east: Double, north: Double, distance: Double) {
        let offset = RouteGeometry.localOffset(from: area.coordinate, to: candidate.coordinate)
        return (offset.x, offset.y, (offset.x * offset.x + offset.y * offset.y).squareRoot())
    }

    /// Metres east and north from the middle of `area` to the north-east
    /// corner of its rectangle, measured as ``offset(of:in:)`` measures a
    /// camera — or `nil` for an area that is only a circle.
    private static func corner(of area: CommunitySearchArea) -> (east: Double, north: Double)? {
        guard let span = area.visibleSpan else { return nil }
        let corner = RouteGeometry.localOffset(
            from: area.coordinate,
            to: CLLocationCoordinate2D(
                latitude: area.latitude + span.latitudeDelta / 2,
                longitude: area.longitude + span.longitudeDelta / 2
            )
        )
        return (corner.x, corner.y)
    }

    /// Metres east and north from the middle of `area` to the edges of what
    /// is kept and gridded: its rectangle, as far as its radius reaches, or
    /// the square around its circle when it carries no rectangle.
    private static func reach(of area: CommunitySearchArea) -> (east: Double, north: Double) {
        let radius = area.radiusMeters
        guard let corner = corner(of: area) else { return (radius, radius) }
        return (min(corner.east, radius), min(corner.north, radius))
    }

    private static func cell(of candidate: CommonsPhotoCandidate, in area: CommunitySearchArea, side: Int) -> Cell {
        let offset = offset(of: candidate, in: area)
        let reach = reach(of: area)
        func index(_ meters: Double, within half: Double) -> Int {
            let width = 2 * max(half, 1) / Double(side)
            return min(max(Int(((meters + half) / width).rounded(.down)), 0), side - 1)
        }
        return Cell(column: index(offset.east, within: reach.east), row: index(offset.north, within: reach.north))
    }

    private static func nearerTheMiddle(
        _ lhs: CommonsPhotoCandidate,
        _ rhs: CommonsPhotoCandidate,
        of area: CommunitySearchArea
    ) -> Bool {
        let left = offset(of: lhs, in: area).distance
        let right = offset(of: rhs, in: area).distance
        return left == right ? lhs.pageID < rhs.pageID : left < right
    }

    private static func nearerTheMiddle(
        _ lhs: CommonsPhotoCandidate,
        _ rhs: CommonsPhotoCandidate,
        ofCell cell: Cell,
        in area: CommunitySearchArea,
        side: Int
    ) -> Bool {
        let reach = reach(of: area)
        let width = (east: 2 * max(reach.east, 1) / Double(side), north: 2 * max(reach.north, 1) / Double(side))
        let middle = (
            east: -reach.east + (Double(cell.column) + 0.5) * width.east,
            north: -reach.north + (Double(cell.row) + 0.5) * width.north
        )
        func distance(_ candidate: CommonsPhotoCandidate) -> Double {
            let offset = offset(of: candidate, in: area)
            let east = offset.east - middle.east
            let north = offset.north - middle.north
            return (east * east + north * north).squareRoot()
        }
        let left = distance(lhs)
        let right = distance(rhs)
        return left == right ? lhs.pageID < rhs.pageID : left < right
    }
}
