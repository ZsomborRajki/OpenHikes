//
//  CuratedElevationSampleIndexesPinTests.swift
//  OpenHikesTests
//
//  Exactly which points are asked of Stadia, for small routes whose answers
//  can be read whole (#1084). The spread is the widget's stride,
//  `decimatedIndices(count:maxPoints:)`, and the fill around a route's pause
//  ends is the helper the widget and the watch share; these pin the answers
//  the elevation's own copies gave before that change. The one place the two
//  copies differed is pinned to the shared stride's answer: a position that
//  falls on a half, which the shared stride and this file's own once rounded
//  apart. At the request's real size, two hundred, no position falls on one.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Elevation sample indexes, pinned")
struct CuratedElevationSampleIndexesPinTests {
    /// A straight line north of `count` points, paused at each of `pausedAt`.
    private static func line(count: Int, pausedAt: Set<Int> = []) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: 47.6 + Double(index) * 0.0001,
                longitude: 12.86,
                boundary: pausedAt.contains(index) ? .paused : nil
            )
        }
    }

    private static func indexes(count: Int, pausedAt: Set<Int> = [], limit: Int = 10) -> [Int] {
        CuratedElevationRequest.sampleIndexes(of: line(count: count, pausedAt: pausedAt), limit: limit)
    }

    @Test("an empty route, a single point and a route of exactly the limit are asked about whole")
    func shortRoutesAreWhole() {
        #expect(Self.indexes(count: 0).isEmpty)
        #expect(Self.indexes(count: 1) == [0])
        #expect(Self.indexes(count: 10, pausedAt: [4]) == Array(0..<10))
    }

    @Test("a route past the limit, with no pause, is spread along its line")
    func plainSpread() {
        #expect(Self.indexes(count: 23) == [0, 2, 5, 7, 10, 12, 15, 17, 20, 22])
        #expect(CuratedElevationRequest.sampleIndexes(count: 23, limit: 10) == [0, 2, 5, 7, 10, 12, 15, 17, 20, 22])
    }

    @Test("pause ends within half the limit are read, and the rest spread over the other points")
    func pauseEndsAreRead() {
        #expect(Self.indexes(count: 23, pausedAt: [9]) == [0, 3, 6, 8, 9, 11, 13, 16, 19, 22])
        #expect(Self.indexes(count: 40, pausedAt: [10, 20]) == [0, 7, 9, 10, 16, 19, 20, 25, 32, 39])
        #expect(Self.indexes(count: 40, pausedAt: [10, 11]) == [0, 6, 9, 10, 11, 15, 21, 27, 33, 39])
        #expect(Self.indexes(count: 40, pausedAt: [39]) == [0, 5, 11, 16, 21, 26, 32, 37, 38, 39])
    }

    @Test("pause ends past half the limit leave the route spread along its line")
    func tooManyPauseEnds() {
        #expect(Self.indexes(count: 40, pausedAt: [10, 20, 30]) == [0, 4, 9, 13, 17, 22, 26, 30, 35, 39])
    }

    /// Integer arithmetic is an independent oracle for the old elevation
    /// spread: each ideal position rounds to its nearest route index. The
    /// 199 intervals cannot put a position exactly on a half. Comparing the
    /// wrapper to the shared stride itself would pass with any rounding in
    /// that stride, so it would not prove the request stayed unchanged.
    @Test("at two hundred points the spread keeps the previous rounding")
    func productionSpreadKeepsPreviousRounding() {
        let limit = CuratedElevationRequest.maximumShapePoints
        let differing = (0...3000).filter { count in
            let expected = count <= limit ? Array(0..<count) : (0..<limit).map { position in
                (position * (count - 1) + (limit - 1) / 2) / (limit - 1)
            }
            return CuratedElevationRequest.sampleIndexes(count: count, limit: limit) != expected
        }
        #expect(differing.isEmpty, "route lengths whose readings changed: \(differing.prefix(5))")
    }

    /// Fifteen points over 62 put one position on 30.5. Multiplied out
    /// first, as this file's own copy did, it rounded up to 31; the shared
    /// stride multiplies a step that is already rounded and lands on 30. A
    /// limit with an even number of intervals is reached on the real request
    /// only when the pause ends are odd in number, adjacent pauses sharing
    /// one, and then one reading moves by a point.
    @Test("a position on a half is rounded as the shared stride rounds it")
    func halfRoundsAsTheSharedStride() {
        #expect(CuratedElevationRequest.sampleIndexes(count: 62, limit: 15)
            == [0, 4, 9, 13, 17, 22, 26, 30, 35, 39, 44, 48, 52, 57, 61])
        #expect(Self.indexes(count: 65, pausedAt: [30, 31], limit: 18)
            == [0, 4, 9, 13, 17, 22, 26, 29, 30, 31, 33, 38, 42, 47, 51, 55, 60, 64])
    }
}

// swiftlint:enable no_magic_numbers
