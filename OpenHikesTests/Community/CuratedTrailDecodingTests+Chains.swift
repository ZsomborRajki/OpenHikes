//
//  CuratedTrailDecodingTests+Chains.swift
//  OpenHikesTests
//
//  A run grows at its start as often as at its end.
//
//  OpenStreetMap lists a relation's ways in no walking order, so the way a run
//  is seeded from can be the last one along the walk, and then every way after
//  it is put before the line built so far. These cases hold the line that comes
//  back to one answer however the ways are listed and drawn: a chain long
//  enough that growing at either end is most of the work, a loop, and a
//  junction met while growing backward. Each answer is the one
//  ``CuratedTrailDecoding/assemble(_:)`` gave while its run was an array, which
//  is what lets the run's storage change underneath them.
//

import CoreLocation
@testable import OpenHikes
import RealModule
import Testing

extension CuratedTrailDecodingTests {
    /// A chain's ways, and the legs in each: enough of both that a line grown
    /// backward is put before itself a few hundred times.
    private static let chainWays = 300
    private static let legsPerWay = 3

    /// Where the chain starts, above Berchtesgaden, and its step up the
    /// meridian: about eleven metres.
    private static let originLatitude = 47.6
    private static let originLongitude = 12.86
    private static let chainStep = 0.0001

    /// The assembler copies points and computes none, so this only spells the
    /// comparison.
    private static let pointTolerance = 1e-9

    /// The `index`th point up the chain's meridian.
    private static func chainPoint(_ index: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: originLatitude + Double(index) * chainStep, longitude: originLongitude)
    }

    /// The `index`th point east of the chain's start, along its parallel.
    private static func eastPoint(_ index: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: originLatitude, longitude: originLongitude + Double(index) * chainStep)
    }

    /// Whether `line` is `expected`, point for point.
    private static func isLine(_ line: [CLLocationCoordinate2D], _ expected: [CLLocationCoordinate2D]) -> Bool {
        line.elementsEqual(expected) { point, other in
            point.latitude.isApproximatelyEqual(to: other.latitude, absoluteTolerance: pointTolerance)
                && point.longitude.isApproximatelyEqual(to: other.longitude, absoluteTolerance: pointTolerance)
        }
    }

    /// One walk up a meridian, cut into ways of a few legs each and listed
    /// forward or backward, each way drawn the way `drawnBackward` says, the
    /// pattern repeating along the walk: always forward, always backward, or
    /// every other way backward, so that a run grown at its start meets ways
    /// drawn both ways.
    ///
    /// It comes back as one line through every point, in the direction its
    /// first listed way was drawn.
    @Test(
        "a chain of ways is one line, whichever order the ways come in and whichever way each was drawn",
        arguments: [false, true], [[false], [true], [true, false]]
    )
    func chain(listedBackward: Bool, drawnBackward: [Bool]) {
        let points = (0...Self.chainWays * Self.legsPerWay).map(Self.chainPoint)
        let ways = (0..<Self.chainWays).map { way in
            let start = way * Self.legsPerWay
            let along = Array(points[start...start + Self.legsPerWay])
            return drawnBackward[way % drawnBackward.count] ? along.reversed() : along
        }
        let firstListed = listedBackward ? Self.chainWays - 1 : 0
        let expected = drawnBackward[firstListed % drawnBackward.count] ? points.reversed() : points

        let line = CuratedTrailDecoding.assemble(listedBackward ? ways.reversed() : ways)

        #expect(line.count == points.count)
        #expect(Self.isLine(line, expected))
    }

    /// Three ways that come back to where they started are one line, closed,
    /// beginning where the first listed way begins, in either listing.
    @Test("ways that come back to where they started are one closed line", arguments: [false, true])
    func loop(listedBackward: Bool) {
        let south = Self.chainPoint(0)
        let north = Self.chainPoint(Self.chainWays)
        let east = Self.eastPoint(Self.chainWays)
        let ways = [[south, north], [east, north], [east, south]]
        let expected = listedBackward ? [east, south, north, east] : [south, north, east, south]

        #expect(Self.isLine(CuratedTrailDecoding.assemble(listedBackward ? ways.reversed() : ways), expected))
    }

    /// Grown backward from the northern way, the run meets a junction where a
    /// spur and the rest of the walk both join, and takes the one listed
    /// first: the spur. The way it passed is a run of its own, shorter than
    /// the one through the spur, so the line drawn is the spur and the two
    /// ways above it.
    @Test("a run grown backward turns at a junction onto the way listed first there")
    func junctionMetGrowingBackward() {
        let walk = (0...3).map { Self.chainPoint($0 * Self.chainWays) }
        let spur = CLLocationCoordinate2D(
            latitude: walk[1].latitude,
            longitude: Self.eastPoint(Self.chainWays).longitude
        )
        let ways = [[walk[2], walk[3]], [walk[1], walk[2]], [spur, walk[1]], [walk[0], walk[1]]]

        #expect(Self.isLine(CuratedTrailDecoding.assemble(ways), [spur, walk[1], walk[2], walk[3]]))
    }
}
