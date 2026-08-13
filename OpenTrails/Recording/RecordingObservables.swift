//
//  RecordingObservables.swift
//  OpenTrails
//

import CoreLocation
import DequeModule
import Foundation
import Observation
import OpenTrailsShared

@Observable
final class RecordingStats {
    nonisolated deinit { /* intentionally ignored */ }

    var distanceMeters = 0.0
    var pointCount = 0
    var horizontalAccuracy: Double?
    var matchedTrailName: String?
    var averageSpeedMetersPerSecond: Double?

    func reset() {
        distanceMeters = 0
        pointCount = 0
        horizontalAccuracy = nil
        matchedTrailName = nil
        averageSpeedMetersPerSecond = nil
    }
}

@Observable
final class RecordingTrace {
    nonisolated deinit { /* intentionally ignored */ }

    static let chunkSize = 256
    private static let minimumDistinctDistanceMeters = 0.05

    @ObservationIgnored private(set) var committedChunks: [[CLLocationCoordinate2D]] = []
    @ObservationIgnored private(set) var tail: [CLLocationCoordinate2D] = []
    @ObservationIgnored private(set) var reviewSegment:
        [CLLocationCoordinate2D] = []
    @ObservationIgnored private(set) var generation = 0
    /// Drained from the front every time a chunk is sealed, so it's a `Deque`
    /// rather than an `Array`: `removeFirst(_:)` on an array shifts every
    /// surviving element down, and this runs on the main actor once per 255
    /// fixes for the whole life of a recording.
    @ObservationIgnored private var stableTail: Deque<CLLocationCoordinate2D> = []
    @ObservationIgnored private var provisionalTail: [CLLocationCoordinate2D] = []
    private(set) var revision = 0

    func append(
        _ coordinate: CLLocationCoordinate2D,
        provisional: Bool = false
    ) {
        reviewSegment = []
        if provisional {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        } else {
            appendStable([coordinate])
            provisionalTail = []
        }
        rebuildTail()
        revision &+= 1
    }

    func replace(with coordinates: [CLLocationCoordinate2D]) {
        replace(stable: coordinates, provisional: [])
    }

    func replace(
        stable stableCoordinates: [CLLocationCoordinate2D],
        provisional provisionalCoordinates: [CLLocationCoordinate2D]
    ) {
        generation &+= 1
        committedChunks = []
        reviewSegment = []
        stableTail = []
        provisionalTail = []
        tail = []
        guard !stableCoordinates.isEmpty
            || !provisionalCoordinates.isEmpty else {
            revision &+= 1
            return
        }

        appendStable(stableCoordinates)
        for coordinate in provisionalCoordinates {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        }
        rebuildTail()
        revision &+= 1
    }

    @discardableResult func applyLiveMatch(
        committing stableCoordinates: [CLLocationCoordinate2D],
        provisional provisionalCoordinates: [CLLocationCoordinate2D],
        expectedGeneration: Int
    ) -> Bool {
        guard generation == expectedGeneration else {
            return false
        }
        reviewSegment = []
        appendStable(stableCoordinates)
        provisionalTail = []
        for coordinate in provisionalCoordinates {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        }
        rebuildTail()
        revision &+= 1
        return true
    }

    func showReview(
        route: [CLLocationCoordinate2D],
        highlightedSegment: [CLLocationCoordinate2D] = []
    ) {
        replace(with: route)
        reviewSegment = highlightedSegment
        revision &+= 1
    }

    func reset() {
        generation &+= 1
        committedChunks = []
        reviewSegment = []
        stableTail = []
        provisionalTail = []
        tail = []
        revision &+= 1
    }

    private func appendStable(
        _ coordinates: [CLLocationCoordinate2D]
    ) {
        for coordinate in coordinates {
            Self.appendDistinct(coordinate, to: &stableTail)
        }
        while stableTail.count >= Self.chunkSize {
            committedChunks.append(
                Array(stableTail.prefix(Self.chunkSize))
            )
            stableTail.removeFirst(Self.chunkSize - 1)
        }
    }

    private func rebuildTail() {
        tail = Array(stableTail)
        for coordinate in provisionalTail {
            Self.appendDistinct(coordinate, to: &tail)
        }
    }

    private static func appendDistinct<C>(
        _ coordinate: CLLocationCoordinate2D,
        to coordinates: inout C
    ) where C: RangeReplaceableCollection & BidirectionalCollection,
        C.Element == CLLocationCoordinate2D {
        if let previous = coordinates.last,
           RouteGeometry.distanceMeters(
               from: previous,
               to: coordinate
           ) <= minimumDistinctDistanceMeters {
            return
        }
        coordinates.append(coordinate)
    }

    func widgetPolyline(
        maxPoints: Int = 180
    ) -> [SharedTrailSnapshot.CodableCoordinate] {
        guard maxPoints > 0 else {
            return []
        }
        let committedCount = committedChunks.enumerated().reduce(0) { count, item in
            count + max(0, item.element.count - (item.offset == 0 ? 0 : 1))
        }
        let tailCount = max(
            0,
            tail.count - (committedChunks.isEmpty ? 0 : 1)
        )
        let totalCount = committedCount + tailCount
        guard totalCount > 0 else {
            return []
        }

        let outputCount = min(maxPoints, totalCount)
        let targetIndices: [Int]
        if outputCount == 1 {
            targetIndices = [0]
        } else {
            let stride = Double(totalCount - 1) / Double(outputCount - 1)
            targetIndices = (0..<outputCount).map { index in
                min(Int((Double(index) * stride).rounded()), totalCount - 1)
            }
        }

        var result: [SharedTrailSnapshot.CodableCoordinate] = []
        result.reserveCapacity(outputCount)
        var globalIndex = 0
        var targetIndex = 0

        func consume(_ coordinate: CLLocationCoordinate2D) {
            guard targetIndex < targetIndices.count else {
                globalIndex += 1
                return
            }
            if globalIndex == targetIndices[targetIndex] {
                result.append(
                    SharedTrailSnapshot.CodableCoordinate(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
                targetIndex += 1
            }
            globalIndex += 1
        }

        for (chunkIndex, chunk) in committedChunks.enumerated() {
            let start = chunkIndex == 0 ? 0 : 1
            for coordinate in chunk.dropFirst(start) {
                consume(coordinate)
            }
        }
        let tailStart = committedChunks.isEmpty ? 0 : 1
        for coordinate in tail.dropFirst(tailStart) {
            consume(coordinate)
        }
        return result
    }
}
