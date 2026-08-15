//
//  HikeRecorder+Helpers.swift
//  OpenHikes
//
//  Private helper methods for HikeRecorder, split out to keep the main file
//  under the type-body-length and file-length limits.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesShared
import os
import SwiftData

// MARK: - Helpers

extension HikeRecorder {

    // MARK: Live matching

    func scheduleLiveMatching() {
        guard phase == .waitingForFix || phase == .recording,
              let trailGraphProvider,
              liveMatchWindow.count > 1 else {
            stats.matchedTrailName = nil
            return
        }
        guard liveMatchingTask == nil else {
            liveMatchNeedsRun = true
            return
        }

        liveMatchNeedsRun = false
        let points = Array(
            liveMatchWindow.prefix(Self.liveMatchingMaximumPoints + 1)
        )
        let expectedGeneration = trace.generation
        let expectedSessionID = sessionID
        let retainedStart = Self.liveWindowRetainedStart(in: points)
        let taskID = UUID()
        liveMatchingTaskID = taskID
        // `.utility` on the whole task rather than pinned to the match alone:
        // matching is now `@concurrent`, so it takes its priority from here.
        // Graph loading is the same background work by the same deadline, so
        // it belongs at the same priority rather than at the main actor's.
        liveMatchingTask = Task(priority: .utility) { [weak self] in
            await self?.performLiveMatchTask(
                points: points,
                retainedStart: retainedStart,
                expectedGeneration: expectedGeneration,
                expectedSessionID: expectedSessionID,
                taskID: taskID,
                trailGraphProvider: trailGraphProvider
            )
        }
    }

    func performLiveMatchTask(
        points: [RecordingPoint],
        retainedStart: Int,
        expectedGeneration: Int,
        expectedSessionID: UUID?,
        taskID: UUID,
        trailGraphProvider: any TrailGraphProviding
    ) async {
        let graph = await loadLiveGraph(for: points, provider: trailGraphProvider)
        guard !Task.isCancelled else { return }
        let match = await TrailMatcher.matchOffMain(points: points, graph: graph)

        guard isMatchStillValid(
            expectedSessionID: expectedSessionID,
            expectedGeneration: expectedGeneration,
            taskID: taskID
        ) else { return }
        liveMatchingTask = nil
        liveMatchingTaskID = nil

        guard !Task.isCancelled,
              phase == .waitingForFix || phase == .recording else {
            if liveMatchNeedsRun {
                scheduleLiveMatching()
            }
            return
        }

        let currentPrefix = liveMatchWindow.prefix(points.count)
        guard currentPrefix.count == points.count,
              zip(currentPrefix, points).allSatisfy({ (lhs, rhs) in
                  lhs.timestamp == rhs.timestamp
                      && lhs.latitude == rhs.latitude
                      && lhs.longitude == rhs.longitude
              }) else {
            scheduleLiveMatching()
            return
        }

        let newerPoints = Array(liveMatchWindow.dropFirst(points.count))
        guard applyMatchWindowUpdate(
            match: match,
            points: points,
            retainedStart: retainedStart,
            newerPoints: newerPoints,
            expectedGeneration: expectedGeneration
        ) else {
            if liveMatchNeedsRun {
                scheduleLiveMatching()
            }
            return
        }

        stats.matchedTrailName = newerPoints.isEmpty ? match.currentTrailName : nil
        RenderSignpost.mark("LiveTrailMatchApplied")
        if liveMatchNeedsRun || !newerPoints.isEmpty {
            scheduleLiveMatching()
        }
    }

    func loadLiveGraph(
        for points: [RecordingPoint],
        provider: any TrailGraphProviding
    ) async -> TrailGraph {
        do {
            return try await provider.cachedGraph(
                covering: points.map(\.coordinate)
            ) ?? .empty
        } catch {
            Self.logger.error(
                "Live trail graph could not be loaded: \(error.localizedDescription, privacy: .public)"
            )
            return .empty
        }
    }

    func isMatchStillValid(
        expectedSessionID: UUID?,
        expectedGeneration: Int,
        taskID: UUID
    ) -> Bool {
        liveMatchingTaskID == taskID
            && sessionID == expectedSessionID
            && trace.generation == expectedGeneration
    }

    func applyMatchWindowUpdate(
        match: TrailMatchResult,
        points: [RecordingPoint],
        retainedStart: Int,
        newerPoints: [RecordingPoint],
        expectedGeneration: Int
    ) -> Bool {
        var retainedPoints = Array(points[retainedStart...])
        let stablePoints: [RecordingPoint]
        let provisionalPoints: [RecordingPoint]
        if retainedStart > 0 {
            let cutoff = points[retainedStart].timestamp
            stablePoints = match.points.filter { point in
                point.timestamp <= cutoff
            }
            provisionalPoints = match.points.filter { point in
                point.timestamp >= cutoff
            }
            if let matchedBoundary = match.points.last(where: { point in
                point.timestamp <= cutoff
            }) {
                retainedPoints[0] = matchedBoundary
            }
        } else {
            stablePoints = []
            provisionalPoints = match.points
        }

        guard trace.applyLiveMatch(
            committing: stablePoints.map(\.coordinate),
            provisional: (provisionalPoints + newerPoints).map(\.coordinate),
            expectedGeneration: expectedGeneration
        ) else { return false }

        liveMatchWindow = retainedPoints + newerPoints
        return true
    }

    nonisolated static func liveWindowRetainedStart(
        in points: [RecordingPoint]
    ) -> Int {
        guard points.count > 2 else { return 0 }
        let latest = points[points.count - 1].timestamp
        let earliest = latest.addingTimeInterval(-liveMatchingDuration)
        var start = max(0, points.count - liveMatchingMaximumPoints)
        while start < points.count - 2,
              points[start + 1].timestamp < earliest {
            start += 1
        }
        return start
    }

    func cancelLiveMatching(clearWindow: Bool) {
        liveMatchingTask?.cancel()
        liveMatchingTask = nil
        liveMatchingTaskID = nil
        liveMatchNeedsRun = false
        stats.matchedTrailName = nil
        if clearWindow {
            liveMatchWindow = []
        }
    }

    // MARK: Gap distances

    func gapDistances(for points: [RecordingPoint]) async -> [Int: Double] {
        guard let distanceEvidenceSource, points.count > 1 else { return [:] }
        var distances: [Int: Double] = [:]
        for index in 1..<points.count
        where TrailMatcher.needsDistanceEvidence(
            from: points[index - 1],
            to: points[index]
        ) {
            if let distance = await distanceEvidenceSource.distance(
                from: points[index - 1].timestamp,
                to: points[index].timestamp
            ), distance.isFinite, distance >= 0 {
                distances[index] = distance
            }
        }
        return distances
    }

    // MARK: Sensors

    /// Releases the sensors a session holds. Shared because the journal
    /// queue also does this once a pause is durably written, so the walker
    /// can't lose a pause boundary to a crash between the two.
    func stopLocationSensors() {
        source.stopRecordingUpdates()
        elevationSource?.stop()
        motionSource?.stop()
    }

    // MARK: Journal

    func enqueueJournalOperation(
        _ operation: @escaping @Sendable (TrackJournal) async throws -> Void
    ) {
        guard let journal else {
            fail(.storageUnavailable)
            return
        }
        journalQueue.enqueue { [weak self] in
            do {
                try await operation(journal)
            } catch {
                await self?.fail(.storage(error.localizedDescription))
            }
        }
    }

    func scheduleJournalFlush() {
        guard journalFlushTask == nil else { return }
        let delay = journalFlushDelay
        journalFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            journalFlushTask = nil
            enqueueJournalOperation { journal in
                try await journal.flush()
            }
        }
    }

    // MARK: Widget fix merge

    func schedulePendingWidgetFixMerge() {
        guard phase == .waitingForFix
                || phase == .recording
                || phase == .paused,
              pendingFixMergeTask == nil,
              let sessionID,
              sharedStateStore != nil else { return }
        pendingFixMergeTask = Task { [weak self] in
            guard let self else { return }
            await mergePendingWidgetFixes(for: sessionID)
            pendingFixMergeTask = nil
        }
    }

    func mergePendingWidgetFixes(for expectedSessionID: UUID) async {
        guard sessionID == expectedSessionID,
              let sharedStateStore,
              let journal else { return }

        let fixes: [SharedRecordingFix]
        do {
            fixes = try await sharedStateStore.pendingFixes(
                for: expectedSessionID
            )
        } catch {
            Self.logger.error(
                "Pending widget fixes could not be read: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard !fixes.isEmpty else { return }

        // Every fix accepted before now is on disk once the queue drains, so
        // the merge sees a settled journal. A fix arriving after this point is
        // genuinely later than the widget's, and `mergeWidgetFixes`
        // deduplicates by timestamp, so it needs no ordering of its own.
        let mergeRevision = acceptedFixRevision
        await journalQueue.drain()
        guard sessionID == expectedSessionID else { return }
        if case .failed = phase { return }
        let mergedCount: Int
        do {
            mergedCount = try await journal.mergeWidgetFixes(
                fixes.map(RecordingPoint.init(sharedFix:))
            )
        } catch {
            fail(.storage(error.localizedDescription))
            return
        }

        do {
            try await sharedStateStore.removePendingFixes(
                ids: Set(fixes.map(\.id))
            )
        } catch {
            // The journal merge is already durable. Leaving the shared copies
            // behind is safe because the next merge deduplicates by timestamp.
            Self.logger.error(
                "Merged widget fixes could not be cleared: \(error.localizedDescription, privacy: .public)"
            )
        }

        guard mergedCount > 0 else { return }
        await refreshLiveStateAfterJournalMerge(
            expectedSessionID: expectedSessionID,
            journal: journal,
            minimumRevision: mergeRevision
        )
    }

    func refreshLiveStateAfterJournalMerge(
        expectedSessionID: UUID,
        journal: TrackJournal,
        minimumRevision: UInt64
    ) async {
        while sessionID == expectedSessionID,
              acceptedFixRevision >= minimumRevision {
            let revision = acceptedFixRevision
            await journalQueue.drain()
            guard sessionID == expectedSessionID else { return }
            if case .failed = phase { return }

            do {
                guard let mergedSession = try await journal.loadSession() else { return }
                let points = mergedSession.points
                let normalized = await RecordingPreparation
                    .normalizedPointsOffMain(points)
                guard acceptedFixRevision == revision,
                      sessionID == expectedSessionID else { continue }
                lastAcceptedPoint = normalized.last
                rebuildLiveState(from: normalized)
                publishSharedRecordingSnapshot(force: true)
                return
            } catch {
                fail(.storage(error.localizedDescription))
                return
            }
        }
    }

    // MARK: Shared state

    func publishSharedRecordingSnapshot(force: Bool) {
        guard sharedStateStore != nil,
              let sessionID,
              let sessionStartedAt else { return }
        let now = clock()
        let firstPoint = stats.pointCount == 1
            && lastSharedSnapshotPointCount == 0
        let intervalElapsed = lastSharedSnapshotAt.map { snapshotDate in
            now.timeIntervalSince(snapshotDate) >= Self.sharedSnapshotInterval
        } ?? true
        guard force || firstPoint || intervalElapsed else { return }

        let snapshot = SharedRecordingSnapshot(
            sessionID: sessionID,
            startedAt: sessionStartedAt,
            distanceMeters: stats.distanceMeters,
            pointCount: stats.pointCount,
            polyline: trace.widgetPolyline(),
            isCapturingFixes: isCapturingFixes,
            updatedAt: now
        )
        lastSharedSnapshotAt = now
        lastSharedSnapshotPointCount = stats.pointCount
        let reloadWidget = force || firstPoint
        enqueueSharedStateOperation { store in
            try await store.save(snapshot, reloadWidget: reloadWidget)
        }
    }

    func enqueueSharedStateOperation(
        _ operation: @escaping @Sendable (
            any RecordingSharedStateStoring
        ) async throws -> Void
    ) {
        guard let sharedStateStore else { return }
        sharedStateQueue.enqueue {
            do {
                try await operation(sharedStateStore)
            } catch {
                Self.logger.error(
                    "Recording widget state update failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func clearSharedRecordingState(sessionID: UUID?) async {
        guard let sharedStateStore else { return }
        await sharedStateQueue.drain()
        do {
            try await sharedStateStore.clear(sessionID: sessionID)
        } catch {
            Self.logger.error(
                "Recording widget state could not be cleared: \(error.localizedDescription, privacy: .public)"
            )
        }
        lastSharedSnapshotAt = nil
        lastSharedSnapshotPointCount = 0
    }

    // MARK: Live state rebuild

    func rebuildLiveState(from points: [RecordingPoint]) {
        cancelLiveMatching(clearWindow: true)
        accumulator = RecordingDistanceAccumulator()
        for point in points {
            accumulator.append(point)
        }
        stats.distanceMeters = accumulator.distanceMeters
        stats.pointCount = points.count
        stats.horizontalAccuracy = points.last?.horizontalAccuracy
        stats.averageSpeedMetersPerSecond = accumulator.averageSpeedMetersPerSecond
        if trailGraphProvider != nil, !points.isEmpty {
            let windowStart = Self.liveWindowRetainedStart(in: points)
            liveMatchWindow = Array(points[windowStart...])
            let stable = windowStart > 0
                ? Array(points[...windowStart]).map(\.coordinate)
                : []
            trace.replace(
                stable: stable,
                provisional: liveMatchWindow.map(\.coordinate)
            )
            scheduleLiveMatching()
        } else {
            trace.replace(with: points.map(\.coordinate))
        }
    }

}
