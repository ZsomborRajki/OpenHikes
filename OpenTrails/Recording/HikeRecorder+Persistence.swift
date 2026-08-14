//
//  HikeRecorder+Persistence.swift
//  OpenTrails
//
//  Persistence, route review, session lifecycle, and failure/reset helpers
//  for HikeRecorder, split out to keep HikeRecorderHelpers.swift under the
//  file-length limit.
//

import Foundation
import Observation
import OpenTrailsShared
import os
import SwiftData

// MARK: - Save Preparation & Persistence

extension HikeRecorder {

    // MARK: Save preparation

    func prepareForSave(
        _ session: TrackJournalSession
    ) async throws(RecordingFailure) -> (
        prepared: PreparedRecording,
        review: PendingReviewSave?
    ) {
        guard let endedAt = session.metadata.endedAt else {
            throw .save("The recording has not been finished yet.")
        }

        let (normalized, graph, gapEvidence) = await normalizeSession(session)
        let prepared: PreparedRecording
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                assertOffMainThread(
                    "Recording preparation must stay off the main thread"
                )
                return try RecordingPreparation.prepare(
                    points: normalized,
                    startedAt: session.metadata.startedAt,
                    endedAt: endedAt,
                    graph: graph,
                    gapDistances: gapEvidence
                )
            }.value
        } catch let failure as RecordingFailure {
            throw failure
        } catch {
            throw .save(error.localizedDescription)
        }

        let sections = await groupedSections(in: prepared.matchResult)
        Self.logger.debug(
            """
            Prepared recording: points=\(normalized.count, privacy: .public) \
            graph=\(graph != nil, privacy: .public) \
            matched=\(prepared.matchResult != nil, privacy: .public) \
            sections=\(sections.count, privacy: .public)
            """
        )

        let review: PendingReviewSave?
        if graph != nil,
           let matchResult = prepared.matchResult,
           !sections.isEmpty {
            review = PendingReviewSave(
                session: session,
                normalizedPoints: normalized,
                matchResult: matchResult,
                sections: sections
            )
        } else {
            review = nil
        }
        return (prepared, review)
    }

    /// Grouping walks every leg, so it joins the rest of the save pipeline off
    /// the main thread rather than running at stop time on the UI.
    private func groupedSections(
        in matchResult: TrailMatchResult?
    ) async -> [RouteReviewSection] {
        guard let matchResult else { return [] }
        return await Task.detached(priority: .userInitiated) {
            assertOffMainThread(
                "Route review grouping must stay off the main thread"
            )
            return RouteReviewSection.sections(in: matchResult)
        }.value
    }

    func normalizeSession(
        _ session: TrackJournalSession
    ) async -> (        normalized: [RecordingPoint],
        graph: TrailGraph?,
        gapEvidence: [Int: Double]
    ) {
        let normalized = await Task.detached(
            priority: .userInitiated
        ) {
            assertOffMainThread(
                "Recording normalization must stay off the main thread"
            )
            return RecordingPreparation.normalizedPoints(session.points)
        }.value

        let graph: TrailGraph?
        if let trailGraphProvider {
            do {
                graph = try await trailGraphProvider.cachedGraph(
                    covering: normalized.map(\.coordinate)
                )
            } catch {
                Self.logger.error(
                    "Cached trail graph could not be loaded: \(error.localizedDescription, privacy: .public)"
                )
                graph = nil
            }
        } else {
            graph = nil
        }
        let gapEvidence = await gapDistances(for: normalized)
        return (normalized, graph, gapEvidence)
    }

    // MARK: Persistence

    func persist(
        _ session: TrackJournalSession,
        prepared: PreparedRecording
    ) throws(RecordingFailure) -> Hike {
        let hikeID = session.metadata.sessionID
        stats.matchedTrailName = prepared.matchedTrailName
        if let existing = try existingHike(sessionID: hikeID) {
            guard existing.isRecording else {
                return existing
            }

            let previousDistance = existing.distanceMeters
            let previousDate = existing.date
            let previousRoute = existing.route
            let previousRawRoute = existing.rawRoute

            existing.distanceMeters = prepared.distanceMeters
            existing.date = prepared.startedAt
            existing.route = prepared.route
            existing.rawRoute = prepared.rawRoute
            existing.isRecording = false
            do {
                try container.mainContext.save()
                return existing
            } catch {
                existing.distanceMeters = previousDistance
                existing.date = previousDate
                existing.route = previousRoute
                existing.rawRoute = previousRawRoute
                existing.isRecording = true
                throw .save(error.localizedDescription)
            }
        }

        let hike = Hike(
            title: session.metadata.title ?? Self.defaultTitle(for: prepared.startedAt),
            distanceMeters: prepared.distanceMeters,
            id: hikeID,
            date: prepared.startedAt,
            tintHex: Hike.randomTintHex(),
            route: prepared.route,
            rawRoute: prepared.rawRoute,
            isRecording: false
        )
        container.mainContext.insert(hike)
        do {
            try container.mainContext.save()
            return hike
        } catch {
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    func ensureRecordingHike(
        sessionID: UUID,
        startedAt: Date,
        title: String?
    ) throws(RecordingFailure) -> Hike {
        if let existing = try existingHike(sessionID: sessionID) {
            if existing.isRecording {
                currentHike = existing
            }
            return existing
        }

        let hike = Hike(
            title: title ?? Self.defaultTitle(for: startedAt),
            distanceMeters: 0,
            id: sessionID,
            date: startedAt,
            tintHex: Hike.randomTintHex(),
            route: [],
            isRecording: true
        )
        container.mainContext.insert(hike)
        do {
            try container.mainContext.save()
            currentHike = hike
            return hike
        } catch {
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    func deleteRecordingHike(sessionID: UUID?) throws(RecordingFailure) {
        guard let sessionID,
              let hike = try existingHike(sessionID: sessionID),
              hike.isRecording else {
            return
        }
        container.mainContext.delete(hike)
        do {
            try container.mainContext.save()
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    func deleteOrphanedRecordingHikes(
        except sessionID: UUID? = nil
    ) throws(RecordingFailure) {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.isRecording }
        )
        let drafts: [Hike]
        do {
            drafts = try container.mainContext.fetch(descriptor)
        } catch {
            throw .save(error.localizedDescription)
        }
        let orphans = drafts.filter { $0.id != sessionID }
        guard !orphans.isEmpty else {
            return
        }

        if let currentHike,
           orphans.contains(where: { $0.id == currentHike.id }) {
            self.currentHike = nil
        }
        for hike in orphans {
            container.mainContext.delete(hike)
        }
        do {
            try container.mainContext.save()
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    func finishPreparedSession(
        _ session: TrackJournalSession,
        journal: TrackJournal
    ) async throws(RecordingFailure) -> RecordingStopOutcome {
        if let existing = try existingHike(
            sessionID: session.metadata.sessionID
        ), !existing.isRecording {
            await finishSavedSession(session, journal: journal)
            return .saved(existing)
        }

        let result = try await prepareForSave(session)
        if let pending = result.review {
            pendingReviewSave = pending
            routeReview = RecordingRouteReview(sections: pending.sections)
            phase = .reviewing
            updateReviewPreview()
            publishSharedRecordingSnapshot(force: true)
            return .needsReview
        }

        let hike = try persist(session, prepared: result.prepared)
        await finishSavedSession(session, journal: journal)
        return .saved(hike)
    }

    func existingHike(sessionID: UUID) throws(RecordingFailure) -> Hike? {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            return try container.mainContext.fetch(descriptor).first
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    // MARK: Route review

    func updateReviewPreview() {
        guard let pendingReviewSave,
              let routeReview else {
            return
        }
        let points = pendingReviewSave.matchResult.points(
            resolving: routeReview.legChoices
        )
        let highlighted = routeReview.current.map { section in
            section.points(for: routeReview.choice(for: section))
                .map(\.coordinate)
        }
        trace.showReview(
            route: points.map(\.coordinate),
            highlightedSegment: highlighted ?? []
        )
    }

    func finishSavedSession(
        _ session: TrackJournalSession,
        journal: TrackJournal
    ) async {
        await clearSharedRecordingState(
            sessionID: session.metadata.sessionID
        )
        do {
            try await journal.discard()
        } catch {
            Self.logger.error(
                "Saved hike but could not remove its finished journal: \(error.localizedDescription, privacy: .public)"
            )
        }
        resetSession()
    }

    // MARK: Failure / reset

    func fail(
        _ failure: RecordingFailure,
        endLocationUpdates: Bool = true
    ) {
        cancelLiveMatching(clearWindow: false)
        if endLocationUpdates {
            stopLocationSensors()
        }
        journalFlushTask?.cancel()
        journalFlushTask = nil
        phase = .failed(failure)
        startRequested = false
        if sessionID != nil {
            publishSharedRecordingSnapshot(force: true)
        }
    }

    func resetSession() {
        phase = .idle
        recoveryState = .absent
        sessionStartedAt = nil
        currentHike = nil
        routeReview = nil
        pendingReviewSave = nil
        sessionID = nil
        sessionUptimeBase = nil
        lastAcceptedPoint = nil
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        latestMotionState = .unknown
        requestedGraphRegions = []
        startRequested = false
        isActivating = false
        pendingResumeFlag = false
        acceptedFixRevision = 0
        liveMatchWindow = []
        liveMatchingTask?.cancel()
        liveMatchingTask = nil
        liveMatchingTaskID = nil
        liveMatchNeedsRun = false
        journalFlushTask?.cancel()
        journalFlushTask = nil
        pendingFixMergeTask?.cancel()
        pendingFixMergeTask = nil
        lastSharedSnapshotAt = nil
        lastSharedSnapshotPointCount = 0
        stats.reset()
        trace.reset()
    }

    // MARK: Default title

    nonisolated private static let afternoonEndHour = 17
    nonisolated private static let eveningEndHour = 22

    nonisolated static func defaultTitle(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        let timeOfDay: String
        switch calendar.component(.hour, from: date) {
        case 5..<12: timeOfDay = "Morning Hike"
        case 12..<Self.afternoonEndHour: timeOfDay = "Afternoon Hike"
        case Self.afternoonEndHour..<Self.eveningEndHour: timeOfDay = "Evening Hike"
        default: timeOfDay = "Hike"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.calendar = calendar
        return "\(timeOfDay) – \(formatter.string(from: date))"
    }

    // MARK: Session lifecycle helpers

    func cleanUpMissingSession() async {
        do {
            try deleteOrphanedRecordingHikes()
        } catch {
            fail(error, endLocationUpdates: false)
            return
        }
        await clearSharedRecordingState(sessionID: nil)
        phase = .idle
    }

    func initializeSessionState(id: UUID, startedAt: Date) {
        sessionID = id
        sessionStartedAt = startedAt
        sessionUptimeBase = uptime()
        cancelLiveMatching(clearWindow: true)
        stats.reset()
        trace.reset()
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        latestMotionState = .unknown
        lastAcceptedPoint = nil
        requestedGraphRegions = []
        pendingResumeFlag = false
        recoveryState = .absent
        startElevationUpdates()
        startMotionUpdates()
        source.startRecordingUpdates()
        phase = .waitingForFix
        publishSharedRecordingSnapshot(force: true)
    }

    func scheduleAndPublishAfterPoint(_ point: RecordingPoint) {
        let pointToJournal = point
        enqueueJournalOperation { journal in
            try await journal.append(pointToJournal)
        }
        scheduleJournalFlush()
        schedulePendingWidgetFixMerge()
        publishSharedRecordingSnapshot(force: stats.pointCount == 1)
    }
}
