//
//  TrailWidgetPauseTests.swift
//  OpenHikesSharedTests
//
//  The trail widget's line, cut at its pauses (#1034). The snapshot carried
//  one flat line decimated by index, so the widget drew a drive between two
//  walked pieces as trail, in the same cased stroke, and the stride could drop
//  either end of the paused leg, so the straight line drawn might not even be
//  the pause. These hold the three halves of the fix: the decimation keeps
//  both ends of a pause within a bound, the snapshot names exactly those legs,
//  and the stroke draws them apart from the trail.
//

import CoreGraphics
import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Trail widget pauses")
struct TrailWidgetPauseTests {
    /// A route point: where it is, and whether a pause arrives at it.
    private struct Point {
        let coordinate: SharedTrailSnapshot.CodableCoordinate
        let paused: Bool
    }

    /// `count` points along the equator, about eleven metres apart, with a
    /// pause arriving at each of `pauses`. A pause's leg is stretched to
    /// `pauseLength(index)` points' worth of ground, so lengths can differ.
    private static func route(
        count: Int,
        pauses: Set<Int>,
        pauseLength: (Int) -> Double = { _ in 50 }
    ) -> [Point] {
        var longitude = 0.0
        return (0..<count).map { index in
            let paused = pauses.contains(index)
            if index > 0 { longitude += 0.0001 * (paused ? pauseLength(index) : 1) }
            return Point(coordinate: .init(latitude: 0, longitude: longitude), paused: paused)
        }
    }

    private static func line(
        _ route: [Point],
        maxPoints: Int = 180
    ) -> (polyline: [SharedTrailSnapshot.CodableCoordinate], pauseIndices: [Int]) {
        SharedTrailSnapshot.line(of: route, maxPoints: maxPoints, coordinate: \.coordinate, isPauseBoundary: \.paused)
    }

    // MARK: Decimation

    @Test("a short route keeps every point, and names every pause")
    func shortRouteKeepsEverything() {
        let route = Self.route(count: 40, pauses: [12, 30])
        let line = Self.line(route)
        #expect(line.polyline == route.map(\.coordinate))
        #expect(line.pauseIndices == [12, 30])
    }

    /// The stride alone keeps index 0, then every fifth-or-so point, so a
    /// pause arriving at 137 or 501 loses at least one end. Each pause must
    /// come through as one leg of the line, between the same two points it
    /// joins on the route.
    @Test("a long route keeps both ends of every pause, adjacent ones included, within the budget")
    func longRouteKeepsPauseEnds() throws {
        let pauses: Set<Int> = [137, 500, 501, 863]
        let route = Self.route(count: 1000, pauses: pauses)
        let line = Self.line(route)

        #expect(line.polyline.count <= 180)
        #expect(line.pauseIndices.count == pauses.count)
        for position in line.pauseIndices {
            let arriving = try #require(route.firstIndex { $0.coordinate == line.polyline[position] })
            let leaving = try #require(route.firstIndex { $0.coordinate == line.polyline[position - 1] })
            #expect(pauses.contains(arriving))
            #expect(leaving == arriving - 1, "the leg drawn as a pause has walking in it")
        }
        #expect(line.polyline.first == route.first?.coordinate)
        #expect(line.polyline.last == route.last?.coordinate)
    }

    /// A GPX file broken into hundreds of segments: the ends of every gap
    /// would be the whole line and more. The bound holds, the longest gaps are
    /// the ones kept, and a gap that could not be afforded is not named — its
    /// leg in the line would be a stride across walking as well.
    @Test("a heavily segmented route spends no more than the pause budget, on the longest pauses")
    func segmentedRouteIsBounded() throws {
        let pauses = Set(stride(from: 3, to: 2000, by: 4))
        let long: Set<Int> = [403, 1203, 1803]
        let route = Self.route(count: 2000, pauses: pauses) { long.contains($0) ? 400 : 5 }
        let line = Self.line(route)

        #expect(line.polyline.count <= 180)
        #expect(line.pauseIndices.count <= SharedTrailSnapshot.pauseEndBudget / 2)
        #expect(!line.pauseIndices.isEmpty)
        let named = try line.pauseIndices.map { position in
            try #require(route.firstIndex { $0.coordinate == line.polyline[position] })
        }
        #expect(long.isSubset(of: Set(named)), "the longest gaps are the ones a widget must not draw as trail")
        for (position, arriving) in zip(line.pauseIndices, named) {
            #expect(route.firstIndex { $0.coordinate == line.polyline[position - 1] } == arriving - 1)
        }
    }

    @Test("kept indices never exceed the budget, however many pauses there are", arguments: [0, 1, 30, 31, 500])
    func keptIndicesAreBounded(pauseCount: Int) {
        let legs = (0..<pauseCount).map { $0 * 3 }
        let kept = SharedTrailSnapshot.keptIndices(count: 2000, maxPoints: 180, pausedLegs: legs, pauseEndBudget: 60)
        #expect(kept.count <= 180)
        #expect(kept.first == 0)
        #expect(kept.last == 1999)
        #expect(kept == kept.sorted() && Set(kept).count == kept.count)
        let affordable = legs.prefix(30)
        #expect(affordable.allSatisfy { kept.contains($0) && kept.contains($0 + 1) })
    }

    @Test("an unpaused route decimates exactly as the plain stride does")
    func unpausedRouteIsTheStride() {
        let route = Self.route(count: 1000, pauses: [])
        let line = Self.line(route)
        #expect(line.pauseIndices.isEmpty)
        #expect(line.polyline == decimatedIndices(count: 1000, maxPoints: 180).map { route[$0].coordinate })
    }

    // MARK: The snapshot

    @Test("the snapshot carries its pauses across the App Group and reads them as runs")
    func snapshotRoundTripsPauses() throws {
        let route = Self.route(count: 6, pauses: [2, 4])
        let snapshot = SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Two drives",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 1000,
            polyline: route.map(\.coordinate),
            pauseIndices: [2, 4]
        )
        let decoded = try JSONDecoder().decode(SharedTrailSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.runs.walkedRuns == [0..<2, 2..<4, 4..<6])
        #expect(decoded.runs.pausedStretches == [1..<3, 3..<5])
    }

    // MARK: The stroke

    @Test("a line with no pause is stroked as one run of every point")
    func unpausedStrokeIsOneRun() {
        let points = (0..<5).map { CGPoint(x: Double($0), y: 0) }
        let pieces = TrailStroke.Pieces(points: points, pauseIndices: [])
        #expect(pieces.walked == [points])
        #expect(pieces.paused.isEmpty)
    }

    @Test("a paused leg is stroked as a pause, never as part of a walked run")
    func pausedLegIsNotTrail() {
        let points = (0..<6).map { CGPoint(x: Double($0), y: 0) }
        let pieces = TrailStroke.Pieces(points: points, pauseIndices: [2, 3])
        #expect(pieces.walked == [Array(points[0...1]), Array(points[3...5])])
        #expect(pieces.paused == [Array(points[1...3])])
    }
}

// swiftlint:enable no_magic_numbers
