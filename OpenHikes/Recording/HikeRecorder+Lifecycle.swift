//
//  HikeRecorder+Lifecycle.swift
//  OpenHikes
//
//  Session lifecycle methods for HikeRecorder, split out to keep companion
//  files under the file-length limit.
//

import CoreLocation
import Foundation
import os
import SwiftData

// MARK: - Session Lifecycle

extension HikeRecorder {
    func recoverOpenSession(automaticallyResume: Bool = true) async {
        guard phase == .idle || phase == .recovering else { return }
        guard let journal else {
            phase = .idle
            return
        }
        phase = .recovering
        let loadedSession: TrackJournalSession?
        do {
            loadedSession = try await journal.loadSession()
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }
        guard let loadedSession else {
            await cleanUpMissingSession()
            return
        }
        var session = loadedSession
        let (recoveredHike, recoveryLastUpdatedAt): (Hike, Date)
        do {
            (recoveredHike, recoveryLastUpdatedAt) = try prepareRecoveredSession(from: session)
        } catch {
            fail(error, endLocationUpdates: false)
            return
        }
        if !recoveredHike.isRecording {
            phase = .saving
            await finishSavedSession(session, journal: journal)
            return
        }
        do {
            try await journal.reopenForAppending()
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }
        guard await mergeWidgetFixesAndReloadSession(&session, journal: journal) else { return }
        let recoveredPoints = session.points
        session.points = await RecordingPreparation
            .normalizedPointsOffMain(recoveredPoints)
        lastAcceptedPoint = session.points.last
        rebuildLiveState(from: session.points)
        await finishRecovery(
            session: session,
            journal: journal,
            recoveryLastUpdatedAt: recoveryLastUpdatedAt,
            automaticallyResume: automaticallyResume
        )
    }

    func finishRecovery(
        session: TrackJournalSession,
        journal: TrackJournal,
        recoveryLastUpdatedAt: Date,
        automaticallyResume: Bool
    ) async {
        if session.metadata.endedAt != nil {
            phase = .saving
            do {
                _ = try await finishPreparedSession(session, journal: journal)
            } catch {
                fail(error, endLocationUpdates: false)
            }
            return
        }
        let summary = RecordingRecoverySummary(
            startedAt: session.metadata.startedAt,
            lastUpdatedAt: recoveryLastUpdatedAt,
            distanceMeters: stats.distanceMeters,
            pointCount: stats.pointCount
        )
        let wasPaused = session.metadata.pausedIntervals.last.map { interval in
            interval.endedAt == nil
        } ?? false
        if wasPaused {
            phase = .paused
            recoveryState = .needsDecision(summary)
            source.releaseOrphanedBackgroundActivity()
            publishSharedRecordingSnapshot(force: true)
            return
        }
        let isRecent = clock().timeIntervalSince(recoveryLastUpdatedAt) < 5 * 60
        if automaticallyResume, isRecent,
           source.authorization == .authorized, source.hasFullAccuracy {
            startElevationUpdates(anchorElevation: lastAcceptedPoint?.elevation)
            startMotionUpdates()
            source.startRecordingUpdates(profile: resolvedEnergyProfile())
            phase = session.points.isEmpty ? .waitingForFix : .recording
            recoveryState = .resumed
        } else {
            phase = .paused
            recoveryState = .needsDecision(summary)
            // Nothing here reclaims the activity session this hike was started
            // with, so without this the location pill would outlive the
            // decision not to resume — and stay tappable, pointing at a
            // recording that is sitting paused rather than running.
            source.releaseOrphanedBackgroundActivity()
        }
        publishSharedRecordingSnapshot(force: true)
    }

    func activateSessionIfPossible() async {
        guard startRequested, sessionID == nil, !isActivating else { return }
        isActivating = true
        defer { isActivating = false }
        if !source.hasFullAccuracy {
            await source.requestTemporaryFullAccuracy()
        }
        guard source.hasFullAccuracy else {
            fail(.preciseLocationRequired, endLocationUpdates: false)
            return
        }
        guard let journal else {
            fail(.storageUnavailable, endLocationUpdates: false)
            return
        }
        do {
            try deleteOrphanedRecordingHikes()
        } catch {
            fail(error, endLocationUpdates: false)
            return
        }
        let id = UUID()
        let startedAt = clock()
        do {
            try await journal.start(
                sessionID: id,
                startedAt: startedAt
            )
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }
        do {
            _ = try ensureRecordingHike(sessionID: id, startedAt: startedAt, title: nil)
        } catch {
            let failure = error
            do {
                try await journal.discard()
            } catch {
                Self.logger.error(
                    "Draft journal removal after failed recording: \(error.localizedDescription, privacy: .public)"
                )
            }
            fail(failure, endLocationUpdates: false)
            return
        }
        initializeSessionState(id: id, startedAt: startedAt)
    }

    /// Consuming, because `pendingResumeFlag` is a one-shot: the flag belongs
    /// to the first point after a resume and to no other.
    private func consumeFlagsForNextPoint() -> RecordingPointFlags {
        var flags: RecordingPointFlags = []
        if pendingResumeFlag {
            flags.insert(.resumed)
            pendingResumeFlag = false
        }
        switch latestMotionState {
        case .stationary: flags.insert(.motionStationary)
        case .nonPedestrian: flags.insert(.nonPedestrian)
        case .unknown, .pedestrian: break
        }
        return flags
    }

    func accept(_ location: CLLocation) {
        guard phase == .waitingForFix || phase == .recording else { return }
        // Counted before any policy runs, so the report can show the whole
        // funnel: what CoreLocation delivered, what survived the quality gate,
        // and what the recording kept. A wide gap between the first and the
        // last is radio energy spent on fixes the app was always going to
        // discard, and the distance filter is what closes it.
        RenderSignpost.mark("RecordingFixReceived")
        if LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.foregroundMaximumAge,
            now: clock()
        ) {
            // Keep rejected low-quality fixes visible as "Weak signal" while
            // the stricter recording policy waits for usable geometry.
            stats.horizontalAccuracy = location.horizontalAccuracy
        }
        guard RecordingFixPolicy.accepts(
            location,
            after: lastAcceptedPoint,
            motionState: latestMotionState,
            now: clock()
        ) else {
            RenderSignpost.mark("RecordingFixRejected")
            return
        }
        var point = RecordingPoint(location: location, flags: consumeFlagsForNextPoint())
        point.elevation = elevationFilter.elevation(for: location)
        let distance = accumulator.append(point)
        // An immutable copy: the journal append below hands this to a
        // `@Sendable` closure, which cannot capture the mutable `point`.
        let accepted = point
        lastAcceptedPoint = accepted
        acceptedFixRevision &+= 1
        let liveMatchingEnabled = trailGraphProvider != nil
        if liveMatchingEnabled {
            liveMatchWindow.append(accepted)
        }
        trace.append(accepted.coordinate, provisional: liveMatchingEnabled)
        stats.distanceMeters = distance
        stats.pointCount += 1
        stats.horizontalAccuracy = accepted.horizontalAccuracy
        stats.averageSpeedMetersPerSecond = accumulator.averageSpeedMetersPerSecond
        stats.elevationGainMeters = accumulator.elevationGainMeters
        // Explicitly conditional, not `phase = .recording`. `@Observable`'s
        // expansion happens to skip a write that compares equal, so the
        // unconditional form is quiet *today* — but only because `Phase` is
        // `Equatable`. Give one case a non-`Equatable` payload and every body
        // reading `phase` (this view's, and the whole hikes sheet's via
        // `isActive`) silently starts re-rendering at fix rate, blowing the
        // one-invalidation-per-phase-change budget. Say it out loud.
        if phase != .recording {
            phase = .recording
        }
        RenderSignpost.mark("LiveFixAccepted")
        // After the accumulator has seen this point, so a walker who has just
        // stopped moving gets the wider distance filter on the strength of the
        // fix that proved it rather than one fix later.
        updateEnergyProfile()
        prefetchTrailGraphIfNeeded(around: accepted.coordinate)
        scheduleLiveMatching()
        enqueueJournalOperation { journal in
            try await journal.append(accepted)
        }
        scheduleJournalFlush()
        schedulePendingWidgetFixMerge()
        publishSharedRecordingSnapshot(force: stats.pointCount == 1)
    }

    func startElevationUpdates(anchorElevation: Double? = nil) {
        elevationSource?.stop()
        elevationFilter.restart(at: anchorElevation)
        guard let elevationSource, elevationSource.isAvailable else { return }
        elevationSource.start { [weak self] relativeAltitude in
            onMainActor { [weak self] in
                self?.elevationFilter.update(relativeAltitude: relativeAltitude)
            }
        }
    }

    func startMotionUpdates() {
        motionSource?.stop()
        latestMotionState = .unknown
        guard let motionSource, motionSource.isAvailable else { return }
        motionSource.start { [weak self] state in
            onMainActor { [weak self] in
                self?.latestMotionState = state
            }
        }
    }

    func prefetchTrailGraphIfNeeded(around coordinate: CLLocationCoordinate2D) {
        guard let trailGraphProvider,
              let region = trailGraphProvider.region(containing: coordinate) else { return }

        let previousFailures: Int
        switch trailGraphPrefetchStates[region] {
        case nil: previousFailures = 0
        case let .waiting(failures, retryAt):
            guard clock() >= retryAt else { return }
            previousFailures = failures
        case .fetching, .loaded: return
        }

        trailGraphPrefetchStates[region] = .fetching(
            previousFailures: previousFailures
        )
        startTrailGraphPrefetch(
            trailGraphProvider,
            around: coordinate,
            region: region,
            previousFailures: previousFailures
        )
    }

    private func startTrailGraphPrefetch(
        _ provider: any TrailGraphProviding,
        around coordinate: CLLocationCoordinate2D,
        region: TrailGraphRegion,
        previousFailures: Int
    ) {
        let expectedSessionID = sessionID
        let taskID = UUID()
        let task = Task { [weak self] in
            defer {
                if let self,
                   trailGraphPrefetchTasks[region]?.id == taskID {
                    trailGraphPrefetchTasks[region] = nil
                }
            }
            do {
                try await provider.prefetch(around: coordinate)
                guard let self,
                      !Task.isCancelled,
                      sessionID == expectedSessionID else { return }
                trailGraphPrefetchStates[region] = .loaded
                prefetchNeighbouringTrailGraphRegions(around: coordinate)
            } catch is CancellationError {
                // `prefetch` now propagates cancellation, so this path is
                // reachable where it previously was not. A cancelled prefetch
                // must not leave its region pinned in `.fetching`: that is the
                // state `prefetchTrailGraph` reads to decide the region is
                // already being handled, so a stranded one is never retried
                // and the region silently never gets a graph.
                guard let self,
                      sessionID == expectedSessionID,
                      trailGraphPrefetchTasks[region]?.id == taskID,
                      case .fetching? = trailGraphPrefetchStates[region]
                else { return }
                trailGraphPrefetchStates[region] = nil
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      sessionID == expectedSessionID else { return }
                recordTrailGraphPrefetchFailure(
                    error,
                    region: region,
                    previousFailures: previousFailures
                )
            }
        }
        trailGraphPrefetchTasks[region] = (id: taskID, task: task)
    }

    private func recordTrailGraphPrefetchFailure(
        _ error: any Error,
        region: TrailGraphRegion,
        previousFailures: Int
    ) {
        let failures = previousFailures + 1
        var delay = trailGraphRetryPolicy.delay(
            afterFailures: failures,
            jitter: trailGraphRetryJitter()
        )
        if let providerError = error as? TrailGraphProviderError,
           case .rateLimited(let retryAfter) = providerError {
            delay = max(delay, retryAfter)
        }
        let retryAt = clock().addingTimeInterval(delay)
        trailGraphPrefetchStates[region] = .waiting(
            failures: failures,
            retryAt: retryAt
        )
        Self.logger.error(
            """
            Trail graph prefetch failed; retrying after \
            \(retryAt, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }

    func cancelTrailGraphPrefetches() {
        for entry in trailGraphPrefetchTasks.values {
            entry.task.cancel()
        }
        trailGraphPrefetchTasks.removeAll()
        trailGraphPrefetchStates.removeAll()
        neighbourPrefetchTask?.cancel()
        neighbourPrefetchTask = nil
    }

    /// Downloads the regions around the one that just landed, so the graph is
    /// on disk before the walker reaches them — or before the connection that
    /// would have fetched them is gone.
    ///
    /// Serial, and deliberately so: these are guesses, and Overpass is a
    /// shared service that rate-limits. Eight parallel queries for regions the
    /// walker may never enter is exactly the burst that earns a 429 for the
    /// region they are standing in. Speculative under
    /// ``TileNetworkPolicy`` for the same reason it exists there — nobody is
    /// waiting for these, so they are the first thing to give up on cellular,
    /// in Low Power Mode, or on a warm device.
    ///
    /// Failures are not recorded. A miss here must not put the *arrival* at
    /// that region into backoff, because by then it will be the one fetch
    /// somebody is actually waiting for.
    func prefetchNeighbouringTrailGraphRegions(
        around coordinate: CLLocationCoordinate2D
    ) {
        guard let trailGraphProvider,
              trailGraphNetworkDecision(.speculative).isAllowed else { return }
        let neighbours = trailGraphProvider
            .neighbouringRegionCoordinates(around: coordinate)
            .filter { neighbour in
                guard let region = trailGraphProvider.region(
                    containing: neighbour
                ) else { return false }
                return trailGraphPrefetchStates[region] == nil
            }
        guard !neighbours.isEmpty else { return }
        neighbourPrefetchTask?.cancel()
        let expectedSessionID = sessionID
        neighbourPrefetchTask = Task { [weak self] in
            for neighbour in neighbours {
                guard !Task.isCancelled else { return }
                try? await trailGraphProvider.prefetch(around: neighbour)
            }
            guard let self,
                  !Task.isCancelled,
                  sessionID == expectedSessionID else { return }
            neighbourPrefetchTask = nil
        }
    }

    // MARK: Recovery helpers

    private func prepareRecoveredSession(
        from session: TrackJournalSession
    ) throws(RecordingFailure) -> (Hike, Date) {
        sessionID = session.metadata.sessionID
        sessionStartedAt = session.metadata.startedAt
        let recoveryLastUpdatedAt = session.metadata.lastUpdatedAt
        startRequested = true
        try deleteOrphanedRecordingHikes(except: session.metadata.sessionID)
        let recoveredHike = try ensureRecordingHike(
            sessionID: session.metadata.sessionID,
            startedAt: session.metadata.startedAt,
            title: session.metadata.title
        )
        return (recoveredHike, recoveryLastUpdatedAt)
    }

    private func mergeWidgetFixesAndReloadSession(
        _ session: inout TrackJournalSession,
        journal: TrackJournal
    ) async -> Bool {
        await mergePendingWidgetFixes(for: session.metadata.sessionID)
        if case .failed = phase { return false }
        do {
            if let merged = try await journal.loadSession() {
                session = merged
            }
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return false
        }
        return true
    }
}

// MARK: - CLLocationManagerDelegate

extension HikeRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }
        // Synchronous on the main actor rather than a task per delivery. The
        // sort above only orders a batch *within itself*; it is `onMainActor`
        // that keeps two consecutive batches from arriving out of order and
        // losing the older one to `RecordingFixPolicy`'s `interval > 0` guard.
        onMainActor { [weak self] in
            guard let self else { return }
            for location in ordered {
                accept(location)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        // Still a task, and deliberately: the authorized branch awaits, and an
        // authorization change arrives once per session rather than once per
        // fix, so the allocation this saves elsewhere is not worth an
        // `assumeIsolated` on a path that has to suspend anyway.
        Task { @MainActor [weak self] in
            guard let self, startRequested else { return }
            switch source.authorization {
            case .notDetermined: return
            case .denied: fail(.locationDenied, endLocationUpdates: sessionID != nil)
            case .authorized:
                if sessionID != nil {
                    if !source.hasFullAccuracy {
                        fail(.preciseLocationRequired)
                    }
                    return
                }
                await activateSessionIfPossible()
            }
        }
    }
}
