//
//  RecordingTraceWidgetPolylineTests.swift
//  OpenHikesTests
//
//  `RecordingTrace.widgetPolyline(maxPoints:)` is the only producer of the line
//  in every `SharedRecordingSnapshot` the widget draws, and it is the one place
//  that has to *account* for the trace's chunk overlap rather than merely
//  maintain it: a sealed chunk repeats the first coordinate of the one after
//  it, and the tail repeats the last coordinate of the final chunk, so the walk
//  skips a point in every chunk but the first and again in the tail. Off by one
//  there does not crash. It publishes a route of the wrong length, drawn on a
//  surface — a widget, and a Live Activity after it — that no other test looks
//  at.
//
//  The suite is written against the trace's public behaviour rather than
//  against those two expressions: a route appended a fix at a time, then read
//  back as the widget would read it. What that buys is an exact identity to
//  assert against, because a coordinate the trace kept is bit-for-bit the one
//  that went in.
//

import CoreLocation
@testable import OpenHikes
import OpenHikesShared
import Testing

@MainActor
@Suite("Recording trace widget polyline")
struct RecordingTraceWidgetPolylineTests {
    /// Points about 1.1 m apart — comfortably past the 5 cm below which the
    /// trace treats a fix as noise and drops it, so every appended coordinate
    /// survives and an output's position in the result is its position here.
    static func route(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { index in
            CLLocationCoordinate2D(
                latitude: 47.63 + Double(index) * 0.00001,
                longitude: 12.86
            )
        }
    }

    static func trace(over route: [CLLocationCoordinate2D]) -> RecordingTrace {
        let trace = RecordingTrace()
        for coordinate in route {
            trace.append(coordinate)
        }
        return trace
    }

    /// Where each output coordinate sits in the route it came from.
    ///
    /// Latitude alone identifies a point here because `route(_:)` only varies
    /// latitude, and the comparison is exact on purpose: the trace copies
    /// coordinates, so anything but the identical `Double` means the polyline
    /// invented a point rather than sampled one.
    static func routeIndices(
        of polyline: [SharedTrailSnapshot.CodableCoordinate],
        in route: [CLLocationCoordinate2D]
    ) -> [Int] {
        let byLatitude = Dictionary(
            uniqueKeysWithValues: route.enumerated().map { ($0.element.latitude, $0.offset) }
        )
        return polyline.compactMap { byLatitude[$0.latitude] }
    }

    /// Long enough to seal two chunks and still end mid-chunk, so both the
    /// chunk seam and the tail seam are on the walk.
    static let multiChunkPointCount = 600

    // MARK: Degenerate inputs

    @Test("a trace with nothing in it publishes no line")
    func emptyTraceProducesNothing() {
        #expect(RecordingTrace().widgetPolyline().isEmpty)
    }

    /// The guard exists because the stride below it divides by
    /// `outputCount - 1`; a caller asking for nothing has to leave before it.
    @Test("a budget of no points publishes no line")
    func zeroBudgetProducesNothing() {
        let trace = Self.trace(over: Self.route(5))

        #expect(trace.widgetPolyline(maxPoints: 0).isEmpty)
        #expect(
            trace.widgetPolyline(maxPoints: 1).count == 1,
            "otherwise the empty result above says nothing about the budget"
        )
    }

    /// One fix is the state a recording spends its first seconds in, and it is
    /// the case the stride cannot compute: it would divide by zero.
    @Test("a single fix is carried through as a single point")
    func singleFixIsCarriedThrough() throws {
        let route = Self.route(1)
        let polyline = Self.trace(over: route).widgetPolyline()

        #expect(polyline.count == 1)
        let only = try #require(polyline.first)
        #expect(only.latitude == route[0].latitude)
        #expect(only.longitude == route[0].longitude)
    }

    // MARK: Identity

    @Test("a route inside the budget is published whole and in order")
    func shortRouteIsPublishedUnchanged() {
        let route = Self.route(40)
        let polyline = Self.trace(over: route).widgetPolyline()

        #expect(polyline.map(\.latitude) == route.map(\.latitude))
        #expect(polyline.map(\.longitude) == route.map(\.longitude))
    }

    /// The one that the overlap arithmetic can actually get wrong. A route this
    /// long has been sealed into chunks, each repeating its predecessor's last
    /// coordinate, and the tail repeats the last chunk's — so a widget line
    /// that counted them would be four points longer than the walk, with a
    /// stutter at each seam.
    @Test("a route spanning several sealed chunks publishes each point once")
    func sealedChunksArePublishedWithoutTheirSeams() {
        let route = Self.route(Self.multiChunkPointCount)
        let trace = Self.trace(over: route)

        // Stated rather than assumed: without these the assertion below would
        // pass just as happily on a trace that never sealed anything, and it
        // is the seams that the arithmetic under test exists for.
        #expect(trace.committedChunks.count == 2)
        #expect(trace.tail.count > 1, "and the walk has to end mid-chunk, so the tail overlaps too")

        let generousBudget = Self.multiChunkPointCount * 2
        let polyline = trace.widgetPolyline(maxPoints: generousBudget)
        #expect(polyline.count == route.count)
        #expect(polyline.map(\.latitude) == route.map(\.latitude))
    }

    // MARK: Downsampling

    @Test("a route past the budget keeps its ends, its order and its count")
    func longRouteIsDownsampledInPlace() {
        let route = Self.route(Self.multiChunkPointCount)
        let budget = 180
        let polyline = Self.trace(over: route).widgetPolyline(maxPoints: budget)

        #expect(polyline.count == budget)
        let indices = Self.routeIndices(of: polyline, in: route)
        #expect(indices.count == polyline.count, "every published point must be a point of the route")
        #expect(indices.first == 0)
        #expect(indices.last == route.count - 1)
        #expect(
            zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 },
            "a widget line that doubled back would be drawn doubling back"
        )
    }

    /// The property the widget actually depends on, swept rather than sampled:
    /// whatever the recording's length and whatever the budget, the line is as
    /// long as the budget allows, starts where the walk started, ends where it
    /// has got to, and never goes backwards.
    ///
    /// Seeded so a shape that breaks it can be generated again — re-run with
    /// `OPENHIKES_TEST_SEED` set to the seed quoted in the failure.
    @Test("any route and any budget downsample to an exact, ordered line")
    func downsamplingHoldsForEveryShape() {
        var generator = SeededGenerator()
        let seed = generator.seed
        let sweeps = 30
        let longestRoute = 520
        let largestBudget = 400
        for _ in 0..<sweeps {
            let route = Self.route(Int.random(in: 1...longestRoute, using: &generator))
            let budget = Int.random(in: 1...largestBudget, using: &generator)
            let polyline = Self.trace(over: route).widgetPolyline(maxPoints: budget)
            let expectedCount = min(budget, route.count)
            let context = "\(route.count) points, budget \(budget) (seed \(seed))"

            #expect(polyline.count == expectedCount, "\(context)")
            let indices = Self.routeIndices(of: polyline, in: route)
            #expect(indices.count == polyline.count, "invented a point: \(context)")
            #expect(indices.first == 0, "\(context)")
            #expect(
                zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 },
                "not strictly forward: \(context)"
            )
            // A budget of one has only the start to spend itself on; every
            // other budget owes the widget the walker's current position.
            if expectedCount > 1 {
                #expect(indices.last == route.count - 1, "\(context)")
            }
        }
    }
}
