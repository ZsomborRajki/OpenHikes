//
//  CommonsAreaPhotos.swift
//  OpenHikes
//
//  Which Wikimedia Commons photographs to show for an area of the map rather
//  than along a route — the trail maker's *Search this area*.
//
//  ``CommonsTrailPhotos`` spreads a route's photographs along its length,
//  because a line has one dimension and *one per stretch* is what keeps a
//  dozen pictures from being twelve of the car park. An area has two, and the
//  same argument becomes a grid: the circle's square is cut into cells, each
//  cell offers the photograph nearest its own middle, and only once every cell
//  has had its turn do the rest fill in from the middle of the area outwards.
//  A geosearch answers nearest its centre first and stops at five hundred, so
//  without the grid a valley's whole allowance went to the village at the
//  middle of the screen.
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

nonisolated enum CommonsAreaPhotos {
    /// How many photographs one search shows at most: a four-by-four grid's
    /// worth, and about the dozen a curated route's strip carries, since each
    /// one is a thumbnail downloaded for a screen that may be glanced at.
    static let photoLimit = 16

    /// `area`, no wider than a geosearch may ask about.
    static func asked(_ area: CommunitySearchArea) -> CommunitySearchArea {
        guard area.radiusMeters > CommonsTrailPhotos.maximumRadiusMeters else { return area }
        return CommunitySearchArea(coordinate: area.coordinate, radiusMeters: CommonsTrailPhotos.maximumRadiusMeters)
    }

    /// At most `limit` of `candidates`, one per cell of a grid over `area`
    /// first, nearest the middle of the area first after that — returned
    /// nearest the middle first.
    static func spread(
        _ candidates: [CommonsPhotoCandidate],
        in area: CommunitySearchArea,
        limit: Int
    ) -> [CommonsPhotoCandidate] {
        guard limit > 0 else { return [] }
        var seen: Set<Int> = []
        let inside = candidates.filter { candidate in
            seen.insert(candidate.pageID).inserted && offset(of: candidate, in: area).distance <= area.radiusMeters
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
    /// Flat, which is the right amount of geometry for a circle ten kilometres
    /// across: the grid is a way of spreading pictures, not a survey.
    private static func offset(
        of candidate: CommonsPhotoCandidate,
        in area: CommunitySearchArea
    ) -> (east: Double, north: Double, distance: Double) {
        let metersPerDegree = 111_320.0
        let north = (candidate.latitude - area.latitude) * metersPerDegree
        let east = (candidate.longitude - area.longitude) * metersPerDegree * cos(area.latitude * .pi / 180)
        return (east, north, (east * east + north * north).squareRoot())
    }

    private static func cell(of candidate: CommonsPhotoCandidate, in area: CommunitySearchArea, side: Int) -> Cell {
        let offset = offset(of: candidate, in: area)
        let width = 2 * max(area.radiusMeters, 1) / Double(side)
        func index(_ meters: Double) -> Int {
            min(max(Int(((meters + area.radiusMeters) / width).rounded(.down)), 0), side - 1)
        }
        return Cell(column: index(offset.east), row: index(offset.north))
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
        let width = 2 * max(area.radiusMeters, 1) / Double(side)
        let middle = (
            east: -area.radiusMeters + (Double(cell.column) + 0.5) * width,
            north: -area.radiusMeters + (Double(cell.row) + 0.5) * width
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
