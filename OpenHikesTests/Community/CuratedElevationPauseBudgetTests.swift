//
//  CuratedElevationPauseBudgetTests.swift
//  OpenHikesTests
//
//  How many points a route with pauses asks Stadia about, and what a route
//  with too many pauses to read the ends of is filled with.
//
//  Both ends of every pause are read, so each walked stretch has heights of
//  its own (#1032). They come out of the request, never on top of it: the
//  privacy policy tells a subscriber that up to two hundred coordinates are
//  sent, and a GPX file opens a pause with every `<trkseg>` after the first,
//  with nothing bounding how many segments it holds. Past half the request,
//  a route is read evenly along its line, and still filled across no pause.
//  The source is a stub: the real one is billed.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Pause ends within the elevation request")
struct CuratedElevationPauseBudgetTests {
    private static let limit = CuratedElevationRequest.maximumShapePoints
    /// Long enough to be sampled, with room for thousands of pauses.
    private static let pointCount = 3000

    nonisolated private enum Ground {
        static let south = 47.6
        static let longitude = 12.86
        /// About eleven metres north.
        static let spacing = 0.0001
        static let valleyMeters = 600.0
        static let ridgeMeters = 1600.0
        static let segmentCount = 300
        static let segmentLength = 10

        /// Valley and ridge by turns, so a height carried across any break
        /// lands a kilometre from the ground beside it.
        static func level(ofSegment segment: Int) -> Double {
            segment.isMultiple(of: 2) ? valleyMeters : ridgeMeters
        }

        static func level(at coordinate: CLLocationCoordinate2D) -> Double {
            let index = Int(((coordinate.latitude - south) / spacing).rounded())
            return level(ofSegment: index / segmentLength)
        }

        /// A GPX of ``segmentCount`` `<trkseg>`s and no `<ele>`, as the
        /// importer reads it: every segment after the first opens a pause.
        static let segmentedLine: [RouteCoordinate] = GPXImport.Track.route(
            of: (0..<segmentCount).map { segment in
                (0..<segmentLength).map { offset in
                    GPXImport.Point(
                        coordinate: CLLocationCoordinate2D(
                            latitude: south + Double(segment * segmentLength + offset) * spacing,
                            longitude: longitude
                        ),
                        elevation: nil,
                        time: nil
                    )
                }
            }
        )
    }

    /// Answers with the level of the segment each point is on, and counts
    /// how many points each request asked about.
    nonisolated private final class SegmentSource: CuratedElevationSourcing, @unchecked Sendable {
        private let sizes = Mutex<[Int]>([])
        var asked: [Int] { sizes.withLock { $0 } }

        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
            sizes.withLock { $0.append(coordinates.count) }
            return coordinates.map(Ground.level(at:))
        }
    }

    /// A straight line north of ``pointCount`` points, paused at each of
    /// `pausedAt`.
    private static func line(pausedAt: [Int]) -> [RouteCoordinate] {
        let paused = Set(pausedAt)
        return (0..<pointCount).map { index in
            RouteCoordinate(
                latitude: Ground.south + Double(index) * Ground.spacing,
                longitude: Ground.longitude,
                boundary: paused.contains(index) ? .paused : nil
            )
        }
    }

    /// `pauses` pauses spread along the line, no two of them adjacent while
    /// there is room between them.
    private static func pausedAt(_ pauses: Int) -> [Int] {
        (0..<pauses).map { ($0 + 1) * pointCount / (pauses + 1) }
    }

    private static func ends(of pausedAt: [Int]) -> Set<Int> {
        Set(pausedAt.flatMap { [$0 - 1, $0] })
    }

    /// Either side of the cap, a route with one pause, and one paused on
    /// every leg. Whatever the pauses, the request is the limit.
    @Test(
        "the request is the limit however many pauses the route has",
        arguments: [0, 1, 49, 50, 51, 99, 100, 300, 2999]
    )
    func requestIsTheLimit(pauses: Int) {
        let indexes = CuratedElevationRequest.sampleIndexes(of: Self.line(pausedAt: Self.pausedAt(pauses)))

        #expect(indexes.count == Self.limit, "never more, and nothing left unspent")
        #expect(indexes == indexes.sorted() && Set(indexes).count == indexes.count, "ascending, once each")
        #expect(indexes.first == 0 && indexes.last == Self.pointCount - 1, "both ends of the route")
    }

    /// The cap's two sides. Fifty pauses have a hundred ends, exactly half
    /// the request, and every one of them is read. A fifty-first pause would
    /// make them more than half, and the route is read evenly instead.
    @Test("pause ends are read up to half the request, and past it the line is read evenly")
    func pauseEndsUpToHalfTheRequest() {
        let fitting = Self.pausedAt(Self.limit / 4)
        let tooMany = Self.pausedAt(Self.limit / 4 + 1)
        #expect(Self.ends(of: fitting).count == Self.limit / 2, "precondition: exactly half the request")

        let read = CuratedElevationRequest.sampleIndexes(of: Self.line(pausedAt: fitting))
        let even = CuratedElevationRequest.sampleIndexes(of: Self.line(pausedAt: tooMany))

        #expect(Self.ends(of: fitting).isSubset(of: read), "both ends of every one of the fifty")
        #expect(even == CuratedElevationRequest.sampleIndexes(count: Self.pointCount), "the plain spread")
    }

    /// A logger that starts a segment at every loss of signal: hundreds of
    /// pauses, far more ends than half the request. The line is read evenly,
    /// and a segment no reading lands on is left without heights rather
    /// than given another segment's.
    @Test("a GPX of hundreds of segments asks the limit and fills nothing across a break")
    func hundredsOfSegmentsFillNothingAcrossABreak() async {
        let route = Ground.segmentedLine
        let source = SegmentSource()

        let filled = await source.filled(route)

        #expect(route.count(where: \.isPauseBoundary) == Ground.segmentCount - 1, "precondition: a pause a segment")
        #expect(source.asked == [Self.limit], "one request, of the limit")
        #expect(filled.contains { $0.elevation != nil }, "precondition: heights landed")
        let strays = filled.indices.filter { index in
            filled[index].elevation.map { $0 != Ground.level(ofSegment: index / Ground.segmentLength) } ?? false
        }
        #expect(strays.isEmpty, "points with another segment's height: \(strays.prefix(5))")
        #expect(RouteProfile(route: filled).elevation.gainMeters == 0, "no climb from one segment to the next")
    }
}
