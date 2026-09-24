//
//  DirectionalPolylineRendererTests+Retrace.swift
//  OpenHikesTests
//
//  The out-and-back, drawn end to end.
//
//  ``RouteChevronFieldTests`` pins the rule itself, chevron by chevron. What
//  only the renderer can be asked is whether the rule is actually reached
//  from a polyline: that a walk which comes home along the way it went out
//  puts about as much ink on the map as the way out did on its own, rather
//  than the two opposed sets of chevrons that made the line underneath
//  unreadable at every zoom level.
//
//  Split from ``DirectionalPolylineRendererTests`` as an extension: one test
//  type per file, and this shares the canvas and the renderer next door.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension DirectionalPolylineRendererTests {
    /// A long diagonal run, and the same run walked home again. Built in map
    /// points rather than degrees so both fit inside the canvas they are
    /// drawn into — `point(for:)` offsets by the overlay's own bounding rect,
    /// so a route that spans a tenth of a degree leaves the bitmap long
    /// before its chevrons run out.
    ///
    /// Both share a bounding rect, so both draw into the same pixels: the ink
    /// counts are comparable.
    static func retraced(
        eastwards: Double = 760,
        southwards: Double = 560
    ) -> (oneWay: MKPolyline, thereAndBack: MKPolyline) {
        // Leaves the trailhead the suite's other routes leave from.
        let baseline = Self.line()
        let start = baseline.points()[0]
        let turn = MKMapPoint(x: start.x + eastwards, y: start.y + southwards)
        var oneWay = [start.coordinate, turn.coordinate]
        var thereAndBack = [start.coordinate, turn.coordinate, start.coordinate]
        return (
            MKPolyline(coordinates: &oneWay, count: oneWay.count),
            MKPolyline(coordinates: &thereAndBack, count: thereAndBack.count)
        )
    }

    /// Arrowheads, because they are the pattern with no line to hide behind:
    /// every pixel counted here is a chevron.
    @Test("an out-and-back draws one set of arrows, not two opposed ones")
    func retracedRouteDrawsOneSetOfChevrons() throws {
        let (oneWay, thereAndBack) = Self.retraced()

        let outbound = try Canvas(side: 1024)
        Self.render(Self.renderer(.arrowheads, on: oneWay), of: oneWay, into: outbound)
        let outboundInk = outbound.inkedPixels

        let retraced = try Canvas(side: 1024)
        Self.render(
            Self.renderer(.arrowheads, on: thereAndBack),
            of: thereAndBack,
            into: retraced
        )
        let retracedInk = retraced.inkedPixels

        #expect(outboundInk > 0, "precondition: the one-way run drew chevrons")
        // Not equality: the turnaround and the trailhead each leave a gap
        // wider than the clearance, so a chevron of the return leg can land
        // in one. What must not survive is the whole second set.
        #expect(
            retracedInk <= outboundInk * 5 / 4,
            "walking home over the way out inked \(retracedInk) against \(outboundInk)"
        )
        #expect(
            retracedInk >= outboundInk * 9 / 10,
            "the way out's own chevrons must survive the return leg"
        )
    }
}
