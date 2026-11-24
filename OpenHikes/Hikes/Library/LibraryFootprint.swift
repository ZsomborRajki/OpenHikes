//
//  LibraryFootprint.swift
//  OpenHikes
//
//  Where a hike's line lies, as the box around it: enough for *Totals* to
//  tell a clocked hike that could hold a followed walk's ground from one
//  somewhere else that only shares its hours (`LibraryTotals`).
//
//  A box rather than the line, because the sweep keeps one per hike for the
//  whole library and asks it only of the few clocks that overlap a walk in
//  time. It answers "could be the same ground", never "is": two trails in
//  one valley share a box, and a recording that met the trail anywhere is
//  near it. What it rules out is the case that matters, a friend's file from
//  another trail imported for the same afternoon.
//

import Foundation
import OpenHikesData

nonisolated struct LibraryFootprint: Equatable, Sendable {
    /// Floors the cosine a margin in metres is turned into degrees of
    /// longitude by, so a box near a pole does not divide by nothing.
    private static let minimumCosineLatitude = 0.01

    let southLat: Double
    let northLat: Double
    /// West edge, in [-180, 180).
    let westLon: Double
    /// Degrees east from ``westLon`` to the east edge, in [0, 360]: the
    /// narrowest arc that holds the line, across the antimeridian when that
    /// is narrower (``TileBoundingBox``).
    let lonSpan: Double

    init(southLat: Double, northLat: Double, westLon: Double, lonSpan: Double) {
        self.southLat = southLat
        self.northLat = northLat
        self.westLon = westLon
        self.lonSpan = lonSpan
    }

    /// `nil` for a hike with no line.
    init?(route: [RouteCoordinate]) {
        guard let box = TileBoundingBox(route: route.map(\.clCoordinate)) else { return nil }
        self.init(southLat: box.southLat, northLat: box.northLat, westLon: box.westLon, lonSpan: box.lonSpan)
    }

    /// Whether this box, widened by `margin` metres on every side, meets
    /// `other`. The margin is what lets a line recorded a few metres beside a
    /// trail drawn along a meridian, whose box has no width, still meet it.
    func meets(_ other: Self, within margin: Double) -> Bool {
        let latitudePad = margin / RouteGeometry.metersPerDegreeLatitude
        guard southLat - latitudePad <= other.northLat, other.southLat <= northLat + latitudePad else { return false }
        let cosine = max(cos((southLat + northLat) / 2 * .pi / 180), Self.minimumCosineLatitude)
        let longitudePad = min(180, latitudePad / cosine)
        let span = lonSpan + 2 * longitudePad
        guard span < 360, other.lonSpan < 360 else { return true }
        // Where the other box begins, measured east from this one's padded
        // west edge: inside this arc, or far enough round to wrap onto it.
        var offset = (other.westLon - (westLon - longitudePad)).truncatingRemainder(dividingBy: 360)
        if offset < 0 { offset += 360 }
        return offset <= span || offset + other.lonSpan >= 360
    }
}
