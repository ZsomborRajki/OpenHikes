//
//  RecordingObservables.swift
//  OpenHikes
//

import CoreLocation
import DequeModule
import Foundation
import Observation
import OpenHikesShared

@Observable
final class RecordingStats {
    nonisolated deinit { /* intentionally ignored */ }

    var distanceMeters = 0.0
    var pointCount = 0
    var horizontalAccuracy: Double?
    var matchedTrailName: String?
    var averageSpeedMetersPerSecond: Double?
    /// Metres climbed so far, `nil` until the recording has two trusted
    /// altitudes to subtract. Published to the widget alongside distance.
    var elevationGainMeters: Double?

    func reset() {
        distanceMeters = 0
        pointCount = 0
        horizontalAccuracy = nil
        matchedTrailName = nil
        averageSpeedMetersPerSecond = nil
        elevationGainMeters = nil
    }
}

@Observable
final class RecordingTrace {
    nonisolated deinit { /* intentionally ignored */ }

    static let chunkSize = 256

    @ObservationIgnored private(set) var committedChunks: [[CLLocationCoordinate2D]] = []
    @ObservationIgnored private(set) var tail: [CLLocationCoordinate2D] = []
    @ObservationIgnored private(set) var reviewSegment:
        [CLLocationCoordinate2D] = []
    @ObservationIgnored private(set) var generation = 0
    /// Change tokens for the two overlays a consumer draws separately. `revision`
    /// says "something moved"; these say *which*, so `MapCoordinator` can rebuild
    /// one `MKPolyline` instead of both. Bumped only on a real change — a token
    /// that moved for an identical geometry would defeat its own purpose.
    @ObservationIgnored private(set) var tailRevision = 0
    @ObservationIgnored private(set) var reviewRevision = 0
    /// Drained from the front every time a chunk is sealed, so it's a `Deque`
    /// rather than an `Array`: `removeFirst(_:)` on an array shifts every
    /// surviving element down, and this runs on the main actor once per 255
    /// fixes for the whole life of a recording.
    @ObservationIgnored private var stableTail: Deque<CLLocationCoordinate2D> = []
    @ObservationIgnored private var provisionalTail: [CLLocationCoordinate2D] = []
    /// Bumped whenever `stableTail` or `committedChunks` moves. `rebuildTail()`
    /// uses it to decide whether the stable prefix of `tail` is still valid,
    /// which is what lets the common case avoid copying it.
    @ObservationIgnored private var stableRevision = 0
    @ObservationIgnored private var tailStableRevision = -1
    /// How many leading elements of `tail` came from `stableTail`.
    @ObservationIgnored private var tailStableCount = 0
    /// Scratch for comparing the provisional remainder across a rebuild.
    /// Held rather than allocated per call because this runs once per fix.
    @ObservationIgnored private var previousProvisional: [CLLocationCoordinate2D] = []
    /// The route last handed to ``showReview(route:highlightedSegment:)``, held
    /// to compare the next one against. Cleared by ``replace(stable:provisional:)``
    /// and ``reset()``, which is every way in and out of a review — `append`
    /// and `applyLiveMatch` cannot run against a stopped recorder.
    @ObservationIgnored private var reviewRoute: [CLLocationCoordinate2D] = []
    private(set) var revision = 0

    func append(
        _ coordinate: CLLocationCoordinate2D,
        provisional: Bool = false
    ) {
        var changed = clearReviewSegment()
        if provisional {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        } else {
            appendStable([coordinate])
            provisionalTail = []
        }
        changed = rebuildTail() || changed
        if changed {
            revision &+= 1
        }
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
        reviewRoute = []
        _ = clearReviewSegment()
        clearTails()
        guard !stableCoordinates.isEmpty
            || !provisionalCoordinates.isEmpty else {
            revision &+= 1
            return
        }

        appendStable(stableCoordinates)
        for coordinate in provisionalCoordinates {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        }
        _ = rebuildTail()
        revision &+= 1
    }

    @discardableResult func applyLiveMatch(
        committing stableCoordinates: [CLLocationCoordinate2D],
        provisional provisionalCoordinates: [CLLocationCoordinate2D],
        expectedGeneration: Int
    ) -> Bool {
        guard generation == expectedGeneration else { return false }
        var changed = clearReviewSegment()
        appendStable(stableCoordinates)
        provisionalTail = []
        for coordinate in provisionalCoordinates {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        }
        changed = rebuildTail() || changed
        // A match that lands on the geometry already drawn is not news. Saying
        // so anyway would cost an overlay rebuild to draw the same line, and a
        // stationary recorder produces exactly that match repeatedly.
        if changed {
            revision &+= 1
        }
        return true
    }

    func showReview(
        route: [CLLocationCoordinate2D],
        highlightedSegment: [CLLocationCoordinate2D] = []
    ) {
        // Change detection, because every caller is a tap handler and
        // `replace(with:)` has none of its own. Re-tapping the already-selected
        // review option, or stepping to a section whose alternatives resolve to
        // the same line, rebuilt both `MKPolyline`s to draw exactly what was
        // already on screen — and on a long hike that is the whole route. Every
        // other mutator here moves a token only on a real change; this was the
        // one path that did not.
        let routeChanged = !Self.isSame(reviewRoute, route[...])
        let highlightChanged = !Self.isSame(reviewSegment, highlightedSegment[...])
        guard routeChanged || highlightChanged else { return }

        if routeChanged {
            replace(with: route)
            reviewRoute = route
        }
        reviewSegment = highlightedSegment
        reviewRevision &+= 1
        revision &+= 1
    }

    func reset() {
        generation &+= 1
        committedChunks = []
        reviewRoute = []
        _ = clearReviewSegment()
        clearTails()
        revision &+= 1
    }

    /// Clears the review highlight, reporting whether there was one to clear.
    /// The report is what stops a fix from publishing a revision purely to say
    /// that an already-empty highlight is still empty.
    private func clearReviewSegment() -> Bool {
        guard !reviewSegment.isEmpty else { return false }
        reviewSegment = []
        reviewRevision &+= 1
        return true
    }

    /// Empties both halves of the tail and invalidates the cached stable
    /// prefix, so the next `rebuildTail()` rebuilds rather than trusting
    /// bookkeeping that describes a tail which no longer exists.
    private func clearTails() {
        stableRevision &+= 1
        stableTail = []
        provisionalTail = []
        tail = []
        tailStableCount = 0
    }

    private func appendStable(
        _ coordinates: [CLLocationCoordinate2D]
    ) {
        guard !coordinates.isEmpty else { return }
        var appended = false
        for coordinate in coordinates {
            appended = Self.appendDistinct(coordinate, to: &stableTail) || appended
        }
        // A fix too close to the last one is dropped, which leaves the stable
        // prefix byte-for-byte what it was. Bumping the revision anyway would
        // invalidate the tail's prefix cache and force a full rebuild to
        // produce the identical tail.
        guard appended else { return }
        stableRevision &+= 1
        while stableTail.count >= Self.chunkSize {
            committedChunks.append(
                Array(stableTail.prefix(Self.chunkSize))
            )
            stableTail.removeFirst(Self.chunkSize - 1)
        }
    }

    /// Rebuilds `tail` from the stable and provisional halves, and reports
    /// whether the result differs from what was there before.
    ///
    /// Two things this deliberately avoids. The first is copying the stable
    /// prefix on every fix: a live match rewrites the provisional tail far more
    /// often than it moves the stable one, and `stableRevision` is what makes
    /// "the prefix is still valid" an O(1) question instead of an O(255) copy.
    /// The second is publishing a revision for a tail that did not actually
    /// change — every such revision costs an `MKPolyline` rebuild and a MapKit
    /// overlay swap, which is far more expensive than the comparison that
    /// prevents it. Only the provisional remainder is compared, because the
    /// prefix cannot have changed without `stableRevision` saying so.
    private func rebuildTail() -> Bool {
        let changed = RenderSignpost.interval("RecordingTailRebuilt") {
            guard tailStableRevision == stableRevision else {
                tail = Array(stableTail)
                tailStableCount = tail.count
                tailStableRevision = stableRevision
                appendProvisionalToTail()
                return true
            }

            previousProvisional.removeAll(keepingCapacity: true)
            previousProvisional.append(contentsOf: tail[tailStableCount...])
            tail.removeLast(tail.count - tailStableCount)
            appendProvisionalToTail()
            return !Self.isSame(previousProvisional, tail[tailStableCount...])
        }
        if changed {
            tailRevision &+= 1
        }
        return changed
    }

    private func appendProvisionalToTail() {
        for coordinate in provisionalTail {
            Self.appendDistinct(coordinate, to: &tail)
        }
    }

    private static func isSame(
        _ lhs: [CLLocationCoordinate2D],
        _ rhs: ArraySlice<CLLocationCoordinate2D>
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs)
        where left.latitude != right.latitude
            || left.longitude != right.longitude {
            return false
        }
        return true
    }

    /// Appends `coordinate` unless it is close enough to the previous one to be
    /// noise, and reports whether it was in fact appended.
    @discardableResult private static func appendDistinct<C>(
        _ coordinate: CLLocationCoordinate2D,
        to coordinates: inout C
    ) -> Bool where C: RangeReplaceableCollection & BidirectionalCollection,
        C.Element == CLLocationCoordinate2D {
        let minimumDistinctDistanceMeters = 0.05
        if let previous = coordinates.last,
           RouteGeometry.distanceMeters(
               from: previous,
               to: coordinate
           ) <= minimumDistinctDistanceMeters {
            return false
        }
        coordinates.append(coordinate)
        return true
    }

    func widgetPolyline(
        maxPoints: Int = 180
    ) -> [SharedTrailSnapshot.CodableCoordinate] {
        guard maxPoints > 0 else { return [] }
        let committedCount = committedChunks.enumerated().reduce(0) { count, item in
            count + max(0, item.element.count - (item.offset == 0 ? 0 : 1))
        }
        let tailCount = max(
            0,
            tail.count - (committedChunks.isEmpty ? 0 : 1)
        )
        let totalCount = committedCount + tailCount
        guard totalCount > 0 else { return [] }

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
