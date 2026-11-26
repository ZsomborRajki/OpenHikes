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
//  walked on (``init(covering:along:)``): a walk over the first kilometre of
//  a long trail did not go where the trail's far end lies. A clocked hike's
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
        var bounds = Bounds()
        for point in route[first...last] {
            bounds.add(latitude: point.latitude, longitude: point.longitude)
        }
        guard let footprint = bounds.footprint else { return nil }
        self = footprint
    }

    /// Where `stretches`, in metres along the line `profile` indexes, lie.
    /// `nil` when they cover nothing of it.
    init?(covering stretches: [ClosedRange<Double>], along profile: RouteProfile) {
        var bounds = Bounds()
        for stretch in stretches {
            for end in [stretch.lowerBound, stretch.upperBound] {
                if let coordinate = profile.coordinate(atDistance: end) {
                    bounds.add(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
            }
            // Every point the stretch reaches, those at its ends included: at
            // a pause, the point the line stops on and the one it resumes on
            // stand at the same distance, and both are on the ground covered.
            let first = profile.distances.partitioningIndex { $0 >= stretch.lowerBound }
            let past = profile.distances.partitioningIndex { $0 > stretch.upperBound }
            for coordinate in profile.coordinates[first..<past] {
                bounds.add(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
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
    mutating func add(latitude: Double, longitude: Double) {
        guard latitude.isFinite, abs(latitude) <= 90, longitude.isFinite else { return }
        south = min(south, latitude)
        north = max(north, latitude)
        let normalized = RouteGeometry.normalizedLongitude(longitude)
        west = min(west, normalized)
        east = max(east, normalized)
        let fromZero = normalized < 0 ? normalized + 360 : normalized
        westFromZero = min(westFromZero, fromZero)
        eastFromZero = max(eastFromZero, fromZero)
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
