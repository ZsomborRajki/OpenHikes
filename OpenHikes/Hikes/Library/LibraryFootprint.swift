//
//  LibraryFootprint.swift
//  OpenHikes
//
//  Where a stretch of ground lies, as the box around it: enough for *Totals*
//  to tell a clocked hike that could have been over a followed walk's ground
//  from one somewhere else that only shares its hours (`LibraryTotals`).
//
//  Each side is the ground of the hours weighed, not of the whole line. A
//  walk's is the stretches of its trail it covered, along the line it was
//  walked on (``Line/footprint(covering:)``): a walk over the first
//  kilometre of a long trail did not go where the trail's far end lies. A
//  clocked hike's
//  is its line from its first stamped point to its last
//  (``init(clockedPartOf:)``), the part its clock is the time of: a GPX whose
//  untimed start lies on a trail and whose stamped part is a valley away was
//  somewhere else in those hours.
//
//  A box rather than the line, because the sweep keeps one per hike and per
//  walk for the whole library and meets two only when their hours overlap.
//  It answers "could be the same ground", never "is": two trails in one
//  valley share a box, and a long recording that met the trail anywhere is
//  near it. What it rules out is the case that matters, a friend's file from
//  another trail imported for the same afternoon.
//
//  The longitudes are bounded in one pass, without sorting them, twice: as
//  they are, from -180° to 180°, and from 0° to 360°, which is how a line
//  across the antimeridian is narrow. The narrower of the two arcs is kept.
//  Either holds every point, which is all ``meets(_:within:)`` asks; a line
//  so long that both are wide meets nearly everything, which is the side a
//  box may err on.
//
//  ## A trail walked many times
//
//  A stretch's box is the box of every point it passes, and a trail walked a
//  thousand times end to end would have each of its points looked at a
//  thousand times. So a followed trail's line is read once into blocks of
//  ``Line/blockLength`` points, each kept as the box of its points
//  (``Line``), and a stretch takes the blocks it holds whole from there and
//  looks one by one only at the points of the two it begins and ends in.
//  Building the blocks is the one pass a single walk over the whole trail
//  made anyway, and a block is six numbers for sixty-four points. The
//  smallest and the largest of some numbers are the same however they are
//  grouped, so the box is the one the points give one by one, to the bit
//  (`LibraryFootprintTests`).
//
//  Measured through the sweep, optimized: a 10,000-point trail walked over
//  the whole of it 1,000 times was read in 65.6 ms point by point and in
//  40.3 ms with blocks, where reading it without placing any walk took
//  39.8 ms; at -Onone, 572, 100 and 82 ms. A library of 300 recordings and
//  300 walks over five long trails was read in 905 ms one way and 896 ms
//  the other, which is the routes' decoding.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated struct LibraryFootprint: Equatable, Sendable {
    let southLat: Double
    let northLat: Double
    /// West edge, in [-180, 180).
    let westLon: Double
    /// Degrees east from ``westLon`` to the east edge, from 0 to 360.
    let lonSpan: Double

    init(southLat: Double, northLat: Double, westLon: Double, lonSpan: Double) {
        self.southLat = southLat
        self.northLat = northLat
        self.westLon = westLon
        self.lonSpan = lonSpan
    }

    /// Where `route` lies from its first stamped point to its last, the part
    /// its clock is the time of — see ``HikeRouteStatistics/duration(of:)``.
    /// `nil` for a line with no stamp.
    init?(clockedPartOf route: [RouteCoordinate]) {
        guard let first = route.firstIndex(where: { $0.timestamp != nil }),
              let last = route.lastIndex(where: { $0.timestamp != nil })
        else { return nil }
        self.init(points: route[first...last].lazy.map(\.clCoordinate))
    }

    /// Where `points` lie; `nil` when none of them is a place.
    init?(points: some Sequence<CLLocationCoordinate2D>) {
        var bounds = Bounds()
        for point in points {
            bounds.add(point)
        }
        guard let footprint = bounds.footprint else { return nil }
        self = footprint
    }

    /// Whether this box and `other` come within `margin` metres of each
    /// other. The margin is what lets a line recorded a few metres beside a
    /// trail drawn along a meridian, whose box has no width, still meet it.
    ///
    /// The same answer either way round: a degree of longitude is measured
    /// where it is shortest, at the poleward edge of the band the two boxes
    /// could meet in, which is the most generous reading of the margin for
    /// both.
    func meets(_ other: Self, within margin: Double) -> Bool {
        let latitudePad = margin / RouteGeometry.metersPerDegreeLatitude
        // Where the two overlap in latitude, or the gap between them.
        let bandSouth = max(southLat, other.southLat)
        let bandNorth = min(northLat, other.northLat)
        guard bandSouth - bandNorth <= latitudePad else { return false }
        let poleward = min(90, max(abs(bandSouth), abs(bandNorth)) + latitudePad)
        let cosine = cos(poleward * .pi / 180)
        let longitudePad = cosine > 0 ? latitudePad / cosine : .infinity
        let span = lonSpan + 2 * longitudePad
        guard span < 360, other.lonSpan < 360 else { return true }
        // Where the other box begins, measured east from this one's padded
        // west edge: inside this arc, or far enough round to wrap onto it.
        var offset = (other.westLon - (westLon - longitudePad)).truncatingRemainder(dividingBy: 360)
        if offset < 0 { offset += 360 }
        return offset <= span || offset + other.lonSpan >= 360
    }
}

extension LibraryFootprint {
    /// A followed trail's line, read into blocks so that any stretches of it
    /// are placed without looking at every point they pass — see the file
    /// header.
    nonisolated struct Line: Sendable {
        static let blockLength = 64

        private let profile: RouteProfile
        /// The box of each run of ``blockLength`` points, in order.
        private let blocks: [Bounds]

        init(_ profile: RouteProfile) {
            self.profile = profile
            blocks = profile.coordinates.chunks(ofCount: Self.blockLength).map { block in
                var bounds = Bounds()
                for point in block {
                    bounds.add(point)
                }
                return bounds
            }
        }

        /// Where `stretches`, in metres along the line, lie; `nil` when they
        /// cover nothing of it.
        func footprint(covering stretches: [ClosedRange<Double>]) -> LibraryFootprint? {
            var bounds = Bounds()
            for stretch in stretches {
                if let start = profile.coordinate(atDistance: stretch.lowerBound) {
                    bounds.add(start)
                }
                if let end = profile.coordinate(atDistance: stretch.upperBound) {
                    bounds.add(end)
                }
                addPoints(in: pointsPassed(by: stretch), to: &bounds)
            }
            return bounds.footprint
        }

        /// The points `stretch` reaches, those at its ends included: at a
        /// pause, the point the line stops on and the one it resumes on stand
        /// at the same distance, and both are on the ground covered.
        private func pointsPassed(by stretch: ClosedRange<Double>) -> Range<Int> {
            let first = profile.distances.partitioningIndex { $0 >= stretch.lowerBound }
            let past = profile.distances.partitioningIndex { $0 > stretch.upperBound }
            return first..<past
        }

        /// Adds the points in `range` to `bounds`: a block the range holds
        /// whole by its box, and the points of the two it holds in part one
        /// by one.
        private func addPoints(in range: Range<Int>, to bounds: inout Bounds) {
            var index = range.lowerBound
            while index < range.upperBound {
                if index.isMultiple(of: Self.blockLength), index + Self.blockLength <= range.upperBound {
                    bounds.add(blocks[index / Self.blockLength])
                    index += Self.blockLength
                } else {
                    bounds.add(profile.coordinates[index])
                    index += 1
                }
            }
        }
    }
}

/// The extremes of the points seen so far, both ways round the globe — see
/// the file header.
nonisolated private struct Bounds {
    private var south = Double.infinity
    private var north = -Double.infinity
    /// Longitudes in [-180, 180).
    private var west = Double.infinity
    private var east = -Double.infinity
    /// The same longitudes in [0, 360).
    private var westFromZero = Double.infinity
    private var eastFromZero = -Double.infinity

    /// A point with a latitude past a pole, or a coordinate that is not a
    /// number, says nothing about where a line lies and is passed over.
    mutating func add(_ point: CLLocationCoordinate2D) {
        guard point.latitude.isFinite, abs(point.latitude) <= 90, point.longitude.isFinite else { return }
        south = min(south, point.latitude)
        north = max(north, point.latitude)
        let normalized = RouteGeometry.normalizedLongitude(point.longitude)
        west = min(west, normalized)
        east = max(east, normalized)
        let fromZero = normalized < 0 ? normalized + 360 : normalized
        westFromZero = min(westFromZero, fromZero)
        eastFromZero = max(eastFromZero, fromZero)
    }

    /// Adds every point `other` has seen.
    mutating func add(_ other: Self) {
        south = min(south, other.south)
        north = max(north, other.north)
        west = min(west, other.west)
        east = max(east, other.east)
        westFromZero = min(westFromZero, other.westFromZero)
        eastFromZero = max(eastFromZero, other.eastFromZero)
    }

    /// `nil` before a point.
    var footprint: LibraryFootprint? {
        guard south <= north else { return nil }
        guard eastFromZero - westFromZero < east - west else {
            return LibraryFootprint(southLat: south, northLat: north, westLon: west, lonSpan: east - west)
        }
        return LibraryFootprint(
            southLat: south,
            northLat: north,
            westLon: RouteGeometry.normalizedLongitude(westFromZero),
            lonSpan: eastFromZero - westFromZero
        )
    }
}
